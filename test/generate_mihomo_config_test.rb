# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "timeout"
require "tmpdir"
require "yaml"

class GenerateMihomoConfigTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  GENERATOR = File.join(ROOT, "generate_mihomo_config.rb")
  TEMPLATE = File.join(ROOT, "config-template.yaml.erb")
  PROVIDER_GROUP_NAMES = %w[
    private_vps
    hong_kong
    taiwan
    japan
    united_states
    singapore
    other_regions
    all_nodes
  ].freeze
  SNAPSHOT_GROUP_NAMES = (PROVIDER_GROUP_NAMES + %w[auto_select]).freeze
  MIHOMO_VALIDATION_TIMEOUT = 120
  MIHOMO_TERMINATION_TIMEOUT = 5
  MIHOMO_READER_TIMEOUT = 5
  SUITE_HOME = Dir.mktmpdir("mihomo-test-home")

  Minitest.after_run do
    FileUtils.remove_entry_secure(SUITE_HOME) if File.exist?(SUITE_HOME)
  end

  def with_generated_config(values)
    Dir.mktmpdir("mihomo-generator-test") do |directory|
      values_path = File.join(directory, "values.yaml")
      output_path = File.join(directory, "config.yaml")
      File.write(values_path, YAML.dump(values))

      stdout, stderr, status = Open3.capture3(
        RbConfig.ruby,
        GENERATOR,
        "--values", values_path,
        "--template", TEMPLATE,
        "--output", output_path
      )

      assert status.success?, "generator failed:\n#{stdout}\n#{stderr}"
      config = YAML.safe_load_file(output_path, permitted_classes: [], aliases: true)
      yield config, output_path
    end
  end

  def proxy_group(config, name)
    config.fetch("proxy-groups").find { |group| group.fetch("name") == name } ||
      flunk("missing proxy group #{name}")
  end

  def normalized_affected_groups(config)
    SNAPSHOT_GROUP_NAMES.to_h do |name|
      [name, proxy_group(config, name).reject { |key, _| key == "name" }]
    end
  end

  def handwritten_proxy(name: "handwritten", extra: {})
    {
      "name" => name,
      "type" => "ss",
      "server" => "127.0.0.1",
      "port" => 8388,
      "cipher" => "aes-128-gcm",
      "password" => "test-password"
    }.merge(extra)
  end

  def provider_present_values
    {
      "proxy_providers" => [
        {
          "name" => "remote_provider",
          "url" => "https://example.com/subscription.yaml"
        }
      ],
      "local_proxies" => [handwritten_proxy],
      "local_rules" => []
    }
  end

  def empty_provider_values(local_proxies)
    {
      "proxy_providers" => [],
      "local_proxies" => local_proxies,
      "local_rules" => []
    }
  end

  def directly_referencing_groups(config, proxy_name)
    config.fetch("proxy-groups").filter_map do |group|
      group.fetch("name") if Array(group["proxies"]).include?(proxy_name)
    end
  end

  def mihomo_available?
    system("command -v mihomo >/dev/null 2>&1")
  end

  def assert_mihomo_valid(output_path)
    stdout = +""
    stderr = +""
    status = nil
    timed_out = false
    cleanup_failure = nil
    pipes = []
    readers = []
    reader_errors = []
    wait_thr = nil

    stdin, stdout_pipe, stderr_pipe, wait_thr = Open3.popen3(
      "mihomo", "-d", SUITE_HOME, "-t", "-f", output_path,
      pgroup: true
    )
    pipes = [stdin, stdout_pipe, stderr_pipe]
    signal_group = lambda do |signal|
      Process.kill(signal, -wait_thr.pid)
    rescue Errno::ESRCH
      nil
    end
    group_alive = lambda do
      Process.kill(0, -wait_thr.pid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end

    begin
      stdin.close
      readers = [[stdout_pipe, stdout], [stderr_pipe, stderr]].map.with_index do |(pipe, output), index|
        Thread.new do
          loop { output << pipe.readpartial(16 * 1024) }
        rescue EOFError
          nil
        rescue IOError => error
          reader_errors[index] = error unless pipe.closed?
        end
      end

      status = Timeout.timeout(MIHOMO_VALIDATION_TIMEOUT) { wait_thr.value }
    rescue Timeout::Error
      timed_out = true
      signal_group.call("TERM")

      begin
        status = Timeout.timeout(MIHOMO_TERMINATION_TIMEOUT) { wait_thr.value }
      rescue Timeout::Error
        nil
      end

      signal_group.call("KILL") if group_alive.call

      if wait_thr.alive?
        begin
          status = Timeout.timeout(MIHOMO_TERMINATION_TIMEOUT) { wait_thr.value }
        rescue Timeout::Error
          cleanup_failure = "Mihomo did not exit after KILL"
        end
      end
    ensure
      if wait_thr&.alive?
        signal_group.call("KILL")
        begin
          status = Timeout.timeout(MIHOMO_TERMINATION_TIMEOUT) { wait_thr.value }
        rescue Timeout::Error
          cleanup_failure ||= "Mihomo did not exit during cleanup"
        end
      end

      readers.zip([stdout_pipe, stderr_pipe]).each do |reader, pipe|
        next if reader.join(MIHOMO_READER_TIMEOUT)

        pipe.close unless pipe.closed?
        reader.kill
        cleanup_failure ||= "Mihomo output reader did not exit"
      end
      readers.each do |reader|
        cleanup_failure ||= "Mihomo output reader did not exit" unless reader.join(MIHOMO_READER_TIMEOUT)
      end
      pipes.each { |pipe| pipe.close unless pipe.closed? }
    end

    cleanup_failure ||= "Mihomo output reader failed: #{reader_errors.compact.first}" if reader_errors.compact.any?
    diagnostics = "stdout:\n#{stdout}\nstderr:\n#{stderr}"
    flunk "Mihomo validation timed out after #{MIHOMO_VALIDATION_TIMEOUT} seconds" \
          "#{cleanup_failure ? " (#{cleanup_failure})" : ""}\n#{diagnostics}" if timed_out
    flunk "Mihomo validation cleanup failed: #{cleanup_failure}\n#{diagnostics}" if cleanup_failure

    assert status.success?, "mihomo validation failed (#{status.inspect}):\n#{diagnostics}"
  end

  def test_provider_present_groups_match_characterized_structure
    expected = YAML.safe_load_file(
      File.join(__dir__, "fixtures", "provider-present-groups.yaml"),
      permitted_classes: [],
      aliases: true
    )

    [
      [[handwritten_proxy], ["handwritten"], ["local_proxy"]],
      [[], ["DIRECT"], []]
    ].each do |local_proxies, expected_local_members, handwritten_references|
      values = provider_present_values.merge("local_proxies" => local_proxies)

      with_generated_config(values) do |config, _output_path|
        assert_equal expected, normalized_affected_groups(config)
        assert_equal expected_local_members, proxy_group(config, "local_proxy").fetch("proxies")
        assert_equal handwritten_references,
                     directly_referencing_groups(config, "handwritten")
      end
    end
  end

  def test_handwritten_only_structure_routes_provider_groups_through_local_proxy
    values = empty_provider_values([handwritten_proxy])

    with_generated_config(values) do |config, _output_path|
      assert_equal ["handwritten"], proxy_group(config, "local_proxy").fetch("proxies")

      PROVIDER_GROUP_NAMES.each do |name|
        group = proxy_group(config, name)
        assert_equal ["local_proxy"], group.fetch("proxies"), name
        refute group.key?("use"), name
      end

      auto_select = proxy_group(config, "auto_select")
      assert_equal ["local_proxy"], auto_select.fetch("proxies")
      refute auto_select.key?("use")
      assert_equal ["local_proxy"], directly_referencing_groups(config, "handwritten")
    end
  end

  def test_direct_only_structure_uses_local_proxy_fallback
    values = empty_provider_values([])

    with_generated_config(values) do |config, _output_path|
      assert_equal ["DIRECT"], proxy_group(config, "local_proxy").fetch("proxies")

      PROVIDER_GROUP_NAMES.each do |name|
        group = proxy_group(config, name)
        assert_equal ["local_proxy"], group.fetch("proxies"), name
        refute group.key?("use"), name
      end

      auto_select = proxy_group(config, "auto_select")
      assert_equal ["local_proxy"], auto_select.fetch("proxies")
      refute auto_select.key?("use")
    end
  end

  def test_handwritten_only_config_validates_with_mihomo
    skip "mihomo executable is unavailable" unless mihomo_available?

    values = empty_provider_values([handwritten_proxy])

    with_generated_config(values) do |_config, output_path|
      assert_mihomo_valid(output_path)
    end
  end

  def test_direct_only_config_validates_with_mihomo
    skip "mihomo executable is unavailable" unless mihomo_available?

    values = empty_provider_values([])

    with_generated_config(values) do |_config, output_path|
      assert_mihomo_valid(output_path)
    end
  end
end
