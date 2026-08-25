# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'rbconfig'
require 'timeout'
require 'tmpdir'
require 'yaml'

class GenerateMihomoConfigTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  GENERATOR = File.join(ROOT, 'generate_mihomo_config.rb')
  TEMPLATE = File.join(ROOT, 'config-template.yaml.erb')
  REGION_GROUP_NAMES = %w[
    hong_kong
    taiwan
    japan
    united_states
    singapore
    other_regions
  ].freeze
  PROVIDER_GROUP_NAMES = (REGION_GROUP_NAMES + %w[all_nodes]).freeze
  SNAPSHOT_GROUP_NAMES = (PROVIDER_GROUP_NAMES + %w[auto_select]).freeze
  ROUTING_GROUP_NAMES = %w[
    default
    steam
    apple
    google
    openai
    telegram
    twitter
    ehentai
    bilibili
    bilibili_sea
    bahamut
    youtube
    netflix
    spotify
    github
    domestic
    other
  ].freeze
  MIHOMO_VALIDATION_TIMEOUT = 120
  MIHOMO_TERMINATION_TIMEOUT = 5
  MIHOMO_READER_TIMEOUT = 5
  SUITE_HOME = Dir.mktmpdir('mihomo-test-home')

  Minitest.after_run do
    FileUtils.remove_entry_secure(SUITE_HOME) if File.exist?(SUITE_HOME)
  end

  def with_generated_config(values)
    Dir.mktmpdir('mihomo-generator-test') do |directory|
      values_path = File.join(directory, 'values.yaml')
      output_path = File.join(directory, 'config.yaml')
      File.write(values_path, YAML.dump(values))

      stdout, stderr, status = Open3.capture3(
        RbConfig.ruby,
        GENERATOR,
        '--values', values_path,
        '--template', TEMPLATE,
        '--output', output_path
      )

      assert status.success?, "generator failed:\n#{stdout}\n#{stderr}"
      config = YAML.safe_load_file(output_path, permitted_classes: [], aliases: true)
      yield config, output_path
    end
  end

  def proxy_group(config, name)
    config.fetch('proxy-groups').find { |group| group.fetch('name') == name } ||
      flunk("missing proxy group #{name}")
  end

  def normalized_affected_groups(config)
    SNAPSHOT_GROUP_NAMES.to_h do |name|
      [name, proxy_group(config, name).reject { |key, _| key == 'name' }]
    end
  end

  def handwritten_proxy(name: 'handwritten', extra: {})
    {
      'name' => name,
      'type' => 'ss',
      'server' => '127.0.0.1',
      'port' => 8388,
      'cipher' => 'aes-128-gcm',
      'password' => 'test-password'
    }.merge(extra)
  end

  def provider_present_values
    {
      'proxy_providers' => [
        {
          'name' => 'remote_provider',
          'url' => 'https://example.com/subscription.yaml'
        }
      ],
      'local_proxies' => [handwritten_proxy],
      'local_rules' => []
    }
  end

  def empty_provider_values(local_proxies)
    {
      'proxy_providers' => [],
      'local_proxies' => local_proxies,
      'local_rules' => []
    }
  end

  def directly_referencing_groups(config, proxy_name)
    config.fetch('proxy-groups').filter_map do |group|
      group.fetch('name') if Array(group['proxies']).include?(proxy_name)
    end
  end

  def mihomo_available?
    system('command -v mihomo >/dev/null 2>&1')
  end

  def assert_mihomo_valid(output_path)
    stdout = +''
    stderr = +''
    status = nil
    timed_out = false
    cleanup_failure = nil
    readers = []
    reader_errors = []

    stdin, stdout_pipe, stderr_pipe, wait_thr = Open3.popen3(
      'mihomo', '-d', SUITE_HOME, '-t', '-f', output_path,
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
        rescue IOError => e
          reader_errors[index] = e unless pipe.closed?
        end
      end

      status = Timeout.timeout(MIHOMO_VALIDATION_TIMEOUT) { wait_thr.value }
    rescue Timeout::Error
      timed_out = true
      signal_group.call('TERM')

      begin
        status = Timeout.timeout(MIHOMO_TERMINATION_TIMEOUT) { wait_thr.value }
      rescue Timeout::Error
        nil
      end

      signal_group.call('KILL') if group_alive.call

      if wait_thr.alive?
        begin
          status = Timeout.timeout(MIHOMO_TERMINATION_TIMEOUT) { wait_thr.value }
        rescue Timeout::Error
          cleanup_failure = 'Mihomo did not exit after KILL'
        end
      end
    ensure
      if wait_thr&.alive?
        signal_group.call('KILL')
        begin
          status = Timeout.timeout(MIHOMO_TERMINATION_TIMEOUT) { wait_thr.value }
        rescue Timeout::Error
          cleanup_failure ||= 'Mihomo did not exit during cleanup'
        end
      end

      readers.zip([stdout_pipe, stderr_pipe]).each do |reader, pipe|
        next if reader.join(MIHOMO_READER_TIMEOUT)

        pipe.close unless pipe.closed?
        reader.kill
        cleanup_failure ||= 'Mihomo output reader did not exit'
      end
      readers.each do |reader|
        cleanup_failure ||= 'Mihomo output reader did not exit' unless reader.join(MIHOMO_READER_TIMEOUT)
      end
      pipes.each { |pipe| pipe.close unless pipe.closed? }
    end

    cleanup_failure ||= "Mihomo output reader failed: #{reader_errors.compact.first}" if reader_errors.compact.any?
    diagnostics = "stdout:\n#{stdout}\nstderr:\n#{stderr}"
    if timed_out
      flunk "Mihomo validation timed out after #{MIHOMO_VALIDATION_TIMEOUT} seconds" \
            "#{cleanup_failure ? " (#{cleanup_failure})" : ''}\n#{diagnostics}"
    end
    flunk "Mihomo validation cleanup failed: #{cleanup_failure}\n#{diagnostics}" if cleanup_failure

    assert status.success?, "mihomo validation failed (#{status.inspect}):\n#{diagnostics}"
  end

  def test_provider_present_groups_match_characterized_structure
    expected = YAML.safe_load_file(
      File.join(__dir__, 'fixtures', 'provider-present-groups.yaml'),
      permitted_classes: [],
      aliases: true
    )

    [
      [[handwritten_proxy], ['handwritten'], ['my_proxy']],
      [[], ['DIRECT'], []]
    ].each do |local_proxies, expected_local_members, handwritten_references|
      values = provider_present_values.merge('local_proxies' => local_proxies)

      with_generated_config(values) do |config, _output_path|
        assert_equal expected, normalized_affected_groups(config)
        assert_equal expected_local_members, proxy_group(config, 'my_proxy').fetch('proxies')
        assert_equal handwritten_references,
                     directly_referencing_groups(config, 'handwritten')
      end
    end
  end

  def test_handwritten_only_structure_routes_provider_groups_through_local_proxy
    values = empty_provider_values([handwritten_proxy])

    with_generated_config(values) do |config, _output_path|
      assert_equal ['handwritten'], proxy_group(config, 'my_proxy').fetch('proxies')

      REGION_GROUP_NAMES.each do |name|
        group = proxy_group(config, name)
        assert_equal ["#{name}_auto", 'my_proxy'], group.fetch('proxies'), name
        refute group.key?('use'), name

        automatic_group = proxy_group(config, "#{name}_auto")
        assert_equal ['my_proxy'], automatic_group.fetch('proxies'), name
        refute automatic_group.key?('use'), name
      end

      all_nodes = proxy_group(config, 'all_nodes')
      assert_equal ['my_proxy'], all_nodes.fetch('proxies')
      refute all_nodes.key?('use')

      auto_select = proxy_group(config, 'auto_select')
      assert_equal ['my_proxy'], auto_select.fetch('proxies')
      refute auto_select.key?('use')
      assert_equal ['my_proxy'], directly_referencing_groups(config, 'handwritten')
    end
  end

  def test_direct_only_structure_uses_local_proxy_fallback
    values = empty_provider_values([])

    with_generated_config(values) do |config, _output_path|
      assert_equal ['DIRECT'], proxy_group(config, 'my_proxy').fetch('proxies')

      REGION_GROUP_NAMES.each do |name|
        group = proxy_group(config, name)
        assert_equal ["#{name}_auto", 'my_proxy'], group.fetch('proxies'), name
        refute group.key?('use'), name

        automatic_group = proxy_group(config, "#{name}_auto")
        assert_equal ['my_proxy'], automatic_group.fetch('proxies'), name
        refute automatic_group.key?('use'), name
      end

      all_nodes = proxy_group(config, 'all_nodes')
      assert_equal ['my_proxy'], all_nodes.fetch('proxies')
      refute all_nodes.key?('use')

      auto_select = proxy_group(config, 'auto_select')
      assert_equal ['my_proxy'], auto_select.fetch('proxies')
      refute auto_select.key?('use')
    end
  end

  def test_my_proxy_is_available_in_all_routing_groups
    with_generated_config(provider_present_values) do |config, _output_path|
      (ROUTING_GROUP_NAMES + SNAPSHOT_GROUP_NAMES).each do |name|
        assert_includes proxy_group(config, name).fetch('proxies'), 'my_proxy', name
      end
    end
  end

  def test_each_region_has_a_configurable_url_test_group
    url_test = {
      'url' => 'https://example.com/generate_204',
      'interval' => 120,
      'tolerance' => 15,
      'lazy' => false
    }
    values = provider_present_values.merge('url_test' => url_test)

    with_generated_config(values) do |config, _output_path|
      REGION_GROUP_NAMES.each do |name|
        manual_group = proxy_group(config, name)
        automatic_group = proxy_group(config, "#{name}_auto")

        assert_equal "#{name}_auto", manual_group.fetch('proxies').first, name
        assert_equal 'url-test', automatic_group.fetch('type'), name
        assert_equal url_test, automatic_group.slice(*url_test.keys), name
        assert_equal ['remote_provider'], automatic_group.fetch('use'), name
        assert_equal manual_group.slice('filter', 'exclude-filter'),
                     automatic_group.slice('filter', 'exclude-filter'), name
      end

      assert_equal url_test, proxy_group(config, 'auto_select').slice(*url_test.keys)
    end
  end

  def test_custom_groups_are_added_to_routing_groups_but_not_node_aggregation_groups
    custom_group_names = %w[custom_primary custom_secondary]
    custom_groups = custom_group_names.map do |name|
      { 'name' => name, 'type' => 'select', 'proxies' => ['DIRECT'] }
    end
    values = provider_present_values.merge('local_proxy_groups' => custom_groups)

    with_generated_config(values) do |config, _output_path|
      ROUTING_GROUP_NAMES.each do |name|
        assert_equal custom_group_names, proxy_group(config, name).fetch('proxies') & custom_group_names, name
      end

      PROVIDER_GROUP_NAMES.each do |name|
        assert_empty proxy_group(config, name).fetch('proxies', []) & custom_group_names, name
      end

      custom_group_names.each do |name|
        assert_equal ROUTING_GROUP_NAMES, directly_referencing_groups(config, name), name
      end
    end
  end

  def test_custom_rule_providers_render_provider_entries_and_rules
    values = provider_present_values.merge(
      'local_proxy_groups' => [
        { 'name' => 'custom_policy', 'type' => 'select', 'proxies' => ['DIRECT'] }
      ],
      'custom_rule_providers' => [
        {
          'name' => 'local_ruleset',
          'behavior' => 'classical',
          'format' => 'text',
          'path' => './rules/local.list',
          'policy' => 'custom_policy'
        },
        {
          'name' => 'remote_ruleset',
          'behavior' => 'domain',
          'format' => 'yaml',
          'url' => 'https://example.com/rules.yaml',
          'policy' => 'google',
          'rule_options' => ['no-resolve']
        }
      ]
    )

    with_generated_config(values) do |config, _output_path|
      providers = config.fetch('rule-providers')
      assert_equal 'file', providers.fetch('local_ruleset').fetch('type')
      assert_equal './rules/local.list', providers.fetch('local_ruleset').fetch('path')

      remote_provider = providers.fetch('remote_ruleset')
      assert_equal 'http', remote_provider.fetch('type')
      assert_equal 86_400, remote_provider.fetch('interval')
      assert_equal './rule_providers/remote_ruleset.yaml', remote_provider.fetch('path')

      rules = config.fetch('rules')
      assert_includes rules, 'RULE-SET,local_ruleset,custom_policy'
      assert_includes rules, 'RULE-SET,remote_ruleset,google,no-resolve'
      assert_operator rules.index('RULE-SET,local_ruleset,custom_policy'), :<,
                      rules.index('RULE-SET,adblock_mihomo,ad_block')
    end
  end

  def test_generated_config_omits_global_client_fingerprint
    values = empty_provider_values([])

    with_generated_config(values) do |config, _output_path|
      refute config.key?('global-client-fingerprint')
    end
  end

  def test_node_level_client_fingerprint_passes_through
    proxy = handwritten_proxy(extra: { 'client-fingerprint' => 'chrome' })
    values = empty_provider_values([proxy])

    with_generated_config(values) do |config, _output_path|
      generated_proxy = config.fetch('proxies').find { |item| item.fetch('name') == proxy.fetch('name') }

      assert_equal proxy, generated_proxy
    end
  end

  def test_handwritten_only_config_validates_with_mihomo
    skip 'mihomo executable is unavailable' unless mihomo_available?

    values = empty_provider_values([handwritten_proxy])

    with_generated_config(values) do |_config, output_path|
      assert_mihomo_valid(output_path)
    end
  end

  def test_direct_only_config_validates_with_mihomo
    skip 'mihomo executable is unavailable' unless mihomo_available?

    values = empty_provider_values([])

    with_generated_config(values) do |_config, output_path|
      assert_mihomo_valid(output_path)
    end
  end
end
