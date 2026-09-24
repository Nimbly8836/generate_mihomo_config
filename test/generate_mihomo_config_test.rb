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
    hk
    jp
    tw
    us
    sg
    kr
    eu
    others
  ].freeze
  PROVIDER_GROUP_NAMES = (REGION_GROUP_NAMES + %w[all_nodes]).freeze
  ROUTING_GROUP_NAMES = %w[
    default
    ai
    game
    media
    chat
    dev
    cloud
    download
    adult
    china
    other
    final
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

  def test_provider_groups_keep_local_fallback_and_europe
    with_generated_config(provider_present_values) do |config, _output_path|
      assert_equal(%w[hk hk_auto jp jp_auto tw tw_auto sg sg_auto us us_auto kr kr_auto eu eu_auto others others_auto],
                   config.fetch('proxy-groups').last(16).map { |group| group.fetch('name') })
      assert_equal ['my_proxy'], proxy_group(config, 'all_nodes').fetch('proxies')
      assert_equal 'select', proxy_group(config, 'eu').fetch('type')
      assert_equal 'url-test', proxy_group(config, 'eu_auto').fetch('type')
      assert_equal true, proxy_group(config, 'eu_auto').fetch('hidden')
    end
  end

  def test_handwritten_only_structure_routes_provider_groups_through_my_proxy
    values = empty_provider_values([handwritten_proxy])

    with_generated_config(values) do |config, _output_path|
      assert_equal ['handwritten'], proxy_group(config, 'my_proxy').fetch('proxies')

      REGION_GROUP_NAMES.each do |name|
        group = proxy_group(config, name)
        automatic_group = proxy_group(config, "#{name}_auto")
        assert_equal 'select', group.fetch('type'), name
        assert_equal ["#{name}_auto", 'my_proxy'], group.fetch('proxies'), name
        assert_equal 'url-test', automatic_group.fetch('type'), name
        assert_equal ['my_proxy'], automatic_group.fetch('proxies'), name
        refute group.key?('use'), name
        refute automatic_group.key?('use'), name
      end

      assert_equal ['my_proxy'], proxy_group(config, 'all_nodes').fetch('proxies')
      assert_equal ['my_proxy'], directly_referencing_groups(config, 'handwritten')
    end
  end

  def test_direct_only_structure_uses_my_proxy_fallback
    values = empty_provider_values([])

    with_generated_config(values) do |config, _output_path|
      assert_equal ['DIRECT'], proxy_group(config, 'my_proxy').fetch('proxies')

      REGION_GROUP_NAMES.each do |name|
        group = proxy_group(config, name)
        automatic_group = proxy_group(config, "#{name}_auto")
        assert_equal 'select', group.fetch('type'), name
        assert_equal ["#{name}_auto", 'my_proxy'], group.fetch('proxies'), name
        assert_equal 'url-test', automatic_group.fetch('type'), name
        assert_equal ['my_proxy'], automatic_group.fetch('proxies'), name
        refute group.key?('use'), name
        refute automatic_group.key?('use'), name
      end

      assert_equal ['my_proxy'], proxy_group(config, 'all_nodes').fetch('proxies')
    end
  end

  def test_proxy_is_available_in_all_category_groups
    with_generated_config(provider_present_values) do |config, _output_path|
      ROUTING_GROUP_NAMES.each do |name|
        assert_includes proxy_group(config, name).fetch('proxies'), 'proxy', name
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
        group = proxy_group(config, name)
        automatic_group = proxy_group(config, "#{name}_auto")

        assert_equal 'select', group.fetch('type'), name
        assert_equal "#{name}_auto", group.fetch('proxies').first, name
        assert_equal "#{name}_auto", group.fetch('default-selected'), name
        assert_equal ['remote_provider'], group.fetch('use'), name
        assert_equal 'url-test', automatic_group.fetch('type'), name
        assert_equal true, automatic_group.fetch('hidden'), name
        assert_equal url_test, automatic_group.slice(*url_test.keys), name
        assert_equal ['remote_provider'], automatic_group.fetch('use'), name
        refute automatic_group.key?('proxies'), name
      end
    end
  end

  def test_local_groups_are_prioritized_and_region_groups_are_last
    values = provider_present_values.merge(
      'local_proxy_groups' => [
        { 'name' => 'custom_primary', 'type' => 'select', 'proxies' => ['DIRECT'] }
      ]
    )
    expected_region_tail = %w[
      hk hk_auto
      jp jp_auto
      tw tw_auto
      sg sg_auto
      us us_auto
      kr kr_auto
      eu eu_auto
      others others_auto
    ]

    with_generated_config(values) do |config, _output_path|
      group_names = config.fetch('proxy-groups').map { |group| group.fetch('name') }

      assert_operator group_names.index('custom_primary'), :<, group_names.index('ai')
      assert_equal expected_region_tail, group_names.last(expected_region_tail.length)
    end
  end

  def test_custom_group_is_not_injected_into_a_group_it_references
    values = empty_provider_values([]).merge(
      'local_proxy_groups' => [
        {
          'name' => 'mx_emby',
          'type' => 'select',
          'proxies' => ['default']
        }
      ]
    )

    with_generated_config(values) do |config, output_path|
      refute_includes proxy_group(config, 'default').fetch('proxies'), 'mx_emby'
      assert_includes proxy_group(config, 'mx_emby').fetch('proxies'), 'default'
      assert_mihomo_valid(output_path) if mihomo_available?
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
        assert_equal %w[default proxy] + ROUTING_GROUP_NAMES.drop(1),
                     directly_referencing_groups(config, name), name
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
      assert_equal 'DIRECT', remote_provider.fetch('proxy')
      assert_operator rules.index('RULE-SET,local_ruleset,custom_policy'), :<,
                      rules.index('RULE-SET,ads,ad_block')
    end
  end

  def test_simple_rule_lists_insert_into_proxy_direct_and_named_groups
    values = empty_provider_values([]).merge(
      'proxy_rules' => ['DOMAIN-SUFFIX,example-proxy.test'],
      'direct_rules' => ['DOMAIN-SUFFIX,example-direct.test'],
      'group_rules' => {
        'chat' => ['DOMAIN-SUFFIX,example-telegram.test'],
        'media' => ['DOMAIN-SUFFIX,example-media.test']
      }
    )

    with_generated_config(values) do |config, _output_path|
      rules = config.fetch('rules')
      assert_includes rules, 'DOMAIN-SUFFIX,example-proxy.test,proxy'
      assert_includes rules, 'DOMAIN-SUFFIX,example-direct.test,DIRECT'
      assert_includes rules, 'DOMAIN-SUFFIX,example-telegram.test,chat'
      assert_includes rules, 'DOMAIN-SUFFIX,example-media.test,media'
    end
  end

  def test_defaults_include_yacd_and_direct_rule_downloads
    with_generated_config(empty_provider_values([])) do |config, _output_path|
      assert_equal './Yacd-meta-gh-pages/', config.fetch('external-ui')
      assert_equal 'https://github.com/MetaCubeX/yacd/archive/gh-pages.zip',
                   config.fetch('external-ui-url')
      %w[ads private cn non_cn tracker].each do |name|
        provider = config.fetch('rule-providers').fetch(name)
        assert_equal 'DIRECT', provider.fetch('proxy'), name
      end
    end
  end

  def test_ui_and_group_mode_can_be_overridden
    values = empty_provider_values([]).merge(
      'external_ui' => './custom-ui',
      'external_ui_url' => 'https://example.com/custom-ui.zip',
      'group_mode' => 'detailed'
    )

    with_generated_config(values) do |config, _output_path|
      assert_equal './custom-ui', config.fetch('external-ui')
      assert_equal 'https://example.com/custom-ui.zip', config.fetch('external-ui-url')
      assert_equal %w[ai proxy hk jp tw sg us kr eu others DIRECT],
                   proxy_group(config, 'openai').fetch('proxies')
    end
  end

  def test_subscription_prefix_is_applied_and_provider_download_is_direct
    values = provider_present_values.merge(
      'proxy_providers' => [
        {
          'name' => 'primary',
          'prefix' => 'Main',
          'url' => 'https://example.com/subscription.yaml'
        }
      ]
    )

    with_generated_config(values) do |config, _output_path|
      provider = config.fetch('proxy-providers').fetch('primary')
      assert_equal 'DIRECT', provider.fetch('proxy')
      assert_equal 'Main | ', provider.fetch('override').fetch('additional-prefix')
    end
  end

  def test_detailed_groups_default_to_simple_parent
    values = empty_provider_values([]).merge('group_mode' => 'detailed')

    with_generated_config(values) do |config, _output_path|
      assert_equal 'ai', proxy_group(config, 'openai').fetch('proxies').first
      assert_equal 'game', proxy_group(config, 'steam').fetch('proxies').first
      assert_equal 'proxy', proxy_group(config, 'ai').fetch('proxies').first
    end
  end

  def test_telegram_rules_cover_domain_and_ip_fallback
    with_generated_config(empty_provider_values([])) do |config, _output_path|
      rules = config.fetch('rules')
      assert_includes rules, 'RULE-SET,telegram_domain,chat'
      assert_includes rules, 'RULE-SET,telegram_ip,chat,no-resolve'
      assert_includes rules, 'DOMAIN-SUFFIX,t.me,chat'
      assert_includes rules, 'DOMAIN-SUFFIX,telegram.org,chat'
    end

    with_generated_config(empty_provider_values([]).merge('group_mode' => 'detailed')) do |config, _output_path|
      assert_includes config.fetch('rules'), 'RULE-SET,telegram_domain,telegram'
    end
  end

  def test_builtin_rule_providers_restore_legacy_coverage
    with_generated_config(empty_provider_values([])) do |config, _output_path|
      providers = config.fetch('rule-providers')
      rules = config.fetch('rules')
      assert_equal 'https://raw.githubusercontent.com/217heidai/adblockfilters/main/rules/adblockmihomo.mrs',
                   providers.fetch('adblock_mihomo').fetch('url')
      assert_includes rules, 'RULE-SET,adblock_mihomo,ad_block'
      %w[openai claude gemini copilot ai games youtube github apple onedrive].each do |service|
        provider = providers.fetch("#{service}_domain")
        assert_equal 'domain', provider.fetch('behavior'), service
        assert_equal 'mrs', provider.fetch('format'), service
        assert_equal 'DIRECT', provider.fetch('proxy'), service
      end
      { 'google' => 'cloud', 'netflix' => 'media', 'telegram' => 'chat', 'twitter' => 'chat' }.each do |service, policy|
        provider = providers.fetch("#{service}_ip")
        assert_equal 'ipcidr', provider.fetch('behavior'), service
        assert_includes rules, "RULE-SET,#{service}_ip,#{policy},no-resolve"
      end
      assert_includes rules, 'RULE-SET,private_ip,DIRECT,no-resolve'
      assert_includes rules, 'RULE-SET,cn_ip,china,no-resolve'
    end
  end

  def test_provider_rules_have_valid_targets_and_specific_rules_win_in_both_modes
    %w[simple detailed].each do |mode|
      with_generated_config(empty_provider_values([]).merge('group_mode' => mode)) do |config, output_path|
        providers = config.fetch('rule-providers')
        rules = config.fetch('rules')
        targets = config.fetch('proxy-groups').map { |group| group.fetch('name') } + %w[DIRECT REJECT]
        references = rules.grep(/^RULE-SET,/).map { |rule| rule.split(',')[1] }
        assert_equal providers.keys.sort, references.uniq.sort, mode
        providers.each_value do |provider|
          assert_equal 'DIRECT', provider.fetch('proxy')
          assert_equal 'mrs', provider.fetch('format')
        end
        rules.each do |rule|
          fields = rule.split(',')
          target = fields[0] == 'MATCH' ? fields[1] : fields[2]
          assert_includes targets, target, rule
        end
        ai_policy = mode == 'simple' ? 'ai' : 'copilot'
        onedrive_policy = mode == 'simple' ? 'cloud' : 'onedrive'
        microsoft_policy = mode == 'simple' ? 'cloud' : 'microsoft'
        assert_operator rules.index("RULE-SET,copilot_domain,#{ai_policy}"), :<, rules.index('RULE-SET,ai_domain,ai')
        assert_operator rules.index("RULE-SET,onedrive_domain,#{onedrive_policy}"), :<,
                        rules.index("RULE-SET,microsoft_domain,#{microsoft_policy}")
        { 'google' => 'cloud', 'netflix' => 'media', 'telegram' => 'chat',
          'twitter' => 'chat' }.each do |service, parent|
          policy = if mode == 'simple'
                     parent
                   else
                     (service == 'twitter' ? 'x' : service)
                   end
          ip_rule = "RULE-SET,#{service}_ip,#{policy},no-resolve"
          assert_operator rules.index("RULE-SET,#{service}_domain,#{policy}"), :<, rules.index(ip_rule)
          assert_operator rules.index(ip_rule), :<, rules.index('RULE-SET,cn_ip,china,no-resolve')
        end
        assert_mihomo_valid(output_path) if mihomo_available?
      end
    end
  end

  def test_new_builtin_provider_names_cannot_be_overwritten
    Dir.mktmpdir('mihomo-reserved-provider') do |directory|
      values = empty_provider_values([]).merge('custom_rule_providers' => [
                                                 { 'name' => 'telegram_ip', 'behavior' => 'ipcidr', 'format' => 'mrs',
                                                   'url' => 'https://example.com/list.mrs', 'policy' => 'chat' }
                                               ])
      path = File.join(directory, 'values.yaml')
      File.write(path, YAML.dump(values))
      _stdout, stderr, status = Open3.capture3(RbConfig.ruby, GENERATOR, '-v', path,
                                               '-t', TEMPLATE, '-o', File.join(directory, 'config.yaml'))
      refute status.success?
      assert_includes stderr, 'reserved names: telegram_ip'
    end
  end

  def test_final_config_overrides_merge_ipv6_and_experimental_settings
    values = provider_present_values.merge('config_overrides' => {
                                             'ipv6' => true,
                                             'dns' => { 'ipv6' => true },
                                             'experimental' => { 'dialer-ip4p-convert' => true }
                                           })
    with_generated_config(values) do |config, _output_path|
      assert_equal true, config.fetch('ipv6')
      assert_equal true, config.fetch('dns').fetch('ipv6')
      assert_equal true, config.fetch('experimental').fetch('dialer-ip4p-convert')
      assert_equal 'fake-ip', config.fetch('dns').fetch('enhanced-mode')
      assert_includes config.fetch('dns').fetch('nameserver'), 'https://doh.pub/dns-query'
      assert_includes config.fetch('dns').fetch('fake-ip-filter'), '*.lan'
      assert_equal values.fetch('local_proxies'), config.fetch('proxies')
      assert_equal 'https://example.com/subscription.yaml',
                   config.fetch('proxy-providers').fetch('remote_provider').fetch('url')
      refute config.key?('config_overrides')
    end
  end

  def test_final_overrides_replace_lists_and_preserve_false_and_null
    values = empty_provider_values([]).merge(
      'port' => 7897,
      'fake_ip_filter' => ['+.append.example'],
      'config_overrides' => {
        'mixed-port' => 8888,
        'allow-lan' => false,
        'dns' => { 'enable' => false, 'nameserver' => ['1.1.1.1'], 'fake-ip-filter' => [] },
        'rules' => ['MATCH,DIRECT'],
        'experimental' => { 'custom-plugin-option' => nil }
      }
    )
    with_generated_config(values) do |config, _output_path|
      assert_equal 8888, config.fetch('mixed-port')
      assert_equal false, config.fetch('allow-lan')
      assert_equal false, config.fetch('dns').fetch('enable')
      assert_equal ['1.1.1.1'], config.fetch('dns').fetch('nameserver')
      assert_empty config.fetch('dns').fetch('fake-ip-filter')
      assert_equal ['MATCH,DIRECT'], config.fetch('rules')
      assert_nil config.fetch('experimental').fetch('custom-plugin-option')
    end
  end

  def test_empty_overrides_leave_output_unchanged
    values = empty_provider_values([]).merge('web_secret' => 'test-secret')
    original = nil
    with_generated_config(values) { |_config, path| original = File.read(path) }
    with_generated_config(values.merge('config_overrides' => {})) do |_config, path|
      assert_equal original, File.read(path)
    end
  end

  def test_override_does_not_mutate_other_yaml_alias_users
    values = provider_present_values.merge('config_overrides' => {
                                             'provider_defaults' => { 'health-check' => { 'interval' => 999 } }
                                           })
    with_generated_config(values) do |config, _output_path|
      assert_equal 999, config.fetch('provider_defaults').fetch('health-check').fetch('interval')
      assert_equal 300, config.fetch('proxy-providers').fetch('remote_provider').fetch('health-check').fetch('interval')
    end
  end

  def test_invalid_config_overrides_do_not_overwrite_output
    [[], false, 123, 'not-a-mapping'].each do |overrides|
      Dir.mktmpdir('mihomo-invalid-overrides') do |directory|
        input = File.join(directory, 'values.yaml')
        output = File.join(directory, 'config.yaml')
        File.write(input, YAML.dump(empty_provider_values([]).merge('config_overrides' => overrides)))
        File.write(output, 'existing-config')
        _stdout, stderr, status = Open3.capture3(RbConfig.ruby, GENERATOR, '-v', input, '-t', TEMPLATE, '-o', output)
        refute status.success?
        assert_includes stderr, 'config_overrides must be a mapping'
        assert_equal 'existing-config', File.read(output)
      end
    end
  end

  def test_ipv6_overridden_config_validates_with_mihomo
    skip 'mihomo executable is unavailable' unless mihomo_available?

    values = empty_provider_values([]).merge('config_overrides' => {
                                               'ipv6' => true, 'dns' => { 'ipv6' => true }
                                             })
    with_generated_config(values) do |_config, output_path|
      assert_mihomo_valid(output_path)
    end
  end

  def test_user_override_keys_appear_first_at_each_mapping_level
    overrides = {
      'experimental' => { 'dialer-ip4p-convert' => true },
      'ipv6' => true,
      'dns' => { 'ipv6' => true, 'nameserver' => ['1.1.1.1'] }
    }
    with_generated_config(empty_provider_values([]).merge('config_overrides' => overrides)) do |config, path|
      assert_equal %w[experimental ipv6 dns], config.keys.first(3)
      assert_equal %w[ipv6 nameserver], config.fetch('dns').keys.first(2)
      assert_equal true, config.fetch('dns').fetch('ipv6')
      assert_equal ['1.1.1.1'], config.fetch('dns').fetch('nameserver')
      assert_equal 'fake-ip', config.fetch('dns').fetch('enhanced-mode')
      assert_equal 1, File.read(path).scan(/^dns:/).length
    end
  end

  def test_basic_fake_ip_filter_keeps_common_exceptions_and_appends_user_entries
    values = empty_provider_values([]).merge('fake_ip_filter' => ['+.my-device.test', '*.lan'])
    with_generated_config(values) do |config, path|
      filters = config.fetch('dns').fetch('fake-ip-filter')
      assert_equal 19, filters.length
      %w[localhost *.lan *.local +.pool.ntp.org stun.*.* +.msftconnecttest.com +.my-device.test].each do |entry|
        assert_includes filters, entry
      end
      assert_equal 1, filters.count('*.lan')
      refute_includes filters, 'music.163.com'
      assert_mihomo_valid(path) if mihomo_available?
    end
  end

  def test_compat_fake_ip_filter_preserves_legacy_service_exceptions
    values = empty_provider_values([]).merge('fake_ip_filter_mode' => 'compat')
    with_generated_config(values) do |config, path|
      filters = config.fetch('dns').fetch('fake-ip-filter')
      assert_equal 89, filters.length
      %w[music.163.com time7.*.com +.srv.nintendo.net +.nflxvideo.net *.ffxiv.com].each do |entry|
        assert_includes filters, entry
      end
      assert_mihomo_valid(path) if mihomo_available?
    end
  end

  def test_invalid_fake_ip_filter_mode_fails_without_writing_output
    Dir.mktmpdir('mihomo-invalid-filter-mode') do |directory|
      input = File.join(directory, 'values.yaml')
      output = File.join(directory, 'config.yaml')
      File.write(input, YAML.dump(empty_provider_values([]).merge('fake_ip_filter_mode' => 'typo')))
      _stdout, stderr, status = Open3.capture3(RbConfig.ruby, GENERATOR, '-v', input, '-t', TEMPLATE, '-o', output)
      refute status.success?
      assert_includes stderr, 'fake_ip_filter_mode must be basic or compat'
      refute File.exist?(output)
    end
  end

  def wireguard_entry(extra = {})
    {
      'name' => 'office', 'server' => '192.0.2.10', 'port' => 51_820, 'ip' => '10.7.0.2',
      'private-key' => ['01' * 32].pack('H*').then { |bytes| [bytes].pack('m0') },
      'public-key' => ['02' * 32].pack('H*').then { |bytes| [bytes].pack('m0') },
      'allowed-ips' => ['10.7.0.0/24', '192.168.50.0/24']
    }.merge(extra)
  end

  def test_wireguard_quick_config_adds_isolated_group_and_priority_routes
    %w[simple detailed].each do |mode|
      values = empty_provider_values([]).merge('group_mode' => mode, 'wireguard' => [wireguard_entry],
                                               'local_rules' => ['IP-CIDR,10.7.0.1/32,DIRECT,no-resolve'])
      with_generated_config(values) do |config, path|
        node = config.fetch('proxies').find { |proxy| proxy['name'] == 'wg_office_node' }
        refute_nil node
        assert_equal 'wireguard', node.fetch('type')
        assert_equal wireguard_entry.fetch('allowed-ips'), node.fetch('allowed-ips')
        assert_equal true, node.fetch('udp')
        assert_equal %w[wg_office_node REJECT], proxy_group(config, 'wg_office').fetch('proxies')
        assert_equal ['DIRECT'], proxy_group(config, 'my_proxy').fetch('proxies')
        %w[proxy default final all_nodes hk].each do |name|
          refute_includes proxy_group(config, name).fetch('proxies', []), 'wg_office'
          refute_includes proxy_group(config, name).fetch('proxies', []), 'wg_office_node'
        end
        rules = config.fetch('rules')
        assert_equal 'IP-CIDR,10.7.0.1/32,DIRECT,no-resolve', rules.first
        %w[10.7.0.0/24 192.168.50.0/24].each do |cidr|
          rule = "IP-CIDR,#{cidr},wg_office,no-resolve"
          assert_includes rules, rule
          assert_operator rules.index(rule), :<, rules.index('DST-PORT,22,DIRECT')
          assert_operator rules.index(rule), :<, rules.index('RULE-SET,private_ip,DIRECT,no-resolve')
        end
        assert_mihomo_valid(path) if mihomo_available?
      end
    end
  end

  def test_wireguard_explicit_ipv6_routes_domains_and_node_options
    entry = wireguard_entry(
      'allowed-ips' => ['0.0.0.0/0', '::/0'],
      'routes' => ['192.168.50.0/24', 'fd00:50::/64'],
      'domains' => ['NAS.OFFICE.test', 'nas.office.test'],
      'ipv6' => 'fd00:50::2', 'ip-version' => 'ipv6-prefer', 'mtu' => 1420,
      'persistent-keepalive' => 25, 'refresh-server-ip-interval' => 60,
      'pre-shared-key' => ['03' * 32].pack('H*').then { |bytes| [bytes].pack('m0') }
    )
    with_generated_config(empty_provider_values([]).merge('wireguard' => [entry])) do |config, path|
      rules = config.fetch('rules')
      assert_includes rules, 'IP-CIDR,192.168.50.0/24,wg_office,no-resolve'
      assert_includes rules, 'IP-CIDR6,fd00:50::/64,wg_office,no-resolve'
      assert_equal 1, rules.count('DOMAIN-SUFFIX,nas.office.test,wg_office')
      refute(rules.any? { |rule| rule.include?('/0,wg_office') })
      node = config.fetch('proxies').find { |proxy| proxy['name'] == 'wg_office_node' }
      %w[private-key public-key pre-shared-key allowed-ips ipv6 ip-version mtu persistent-keepalive
         refresh-server-ip-interval].each do |key|
        assert_equal entry.fetch(key), node.fetch(key), key
      end
      refute node.key?('routes')
      refute node.key?('domains')
      assert_mihomo_valid(path) if mihomo_available?
    end
  end

  def test_wireguard_domain_only_and_multiple_tunnels
    entries = [
      wireguard_entry('allowed-ips' => ['0.0.0.0/0'], 'routes' => [], 'domains' => ['office.test']),
      wireguard_entry('name' => 'home', 'allowed-ips' => ['192.168.60.0/24'])
    ]
    with_generated_config(empty_provider_values([]).merge('wireguard' => entries)) do |config, _path|
      assert_equal(%w[wg_office_node wg_home_node], config.fetch('proxies').map { |node| node.fetch('name') })
      rules = config.fetch('rules')
      assert_includes rules, 'DOMAIN-SUFFIX,office.test,wg_office'
      refute(rules.any? { |rule| rule.start_with?('IP-CIDR') && rule.include?(',wg_office,') })
      assert_includes rules, 'IP-CIDR,192.168.60.0/24,wg_home,no-resolve'
      assert_equal %w[wg_home_node REJECT], proxy_group(config, 'wg_home').fetch('proxies')
    end
  end

  def test_invalid_wireguard_quick_configs_fail_without_exposing_keys_or_writing_output
    invalid_entries = [
      false, {}, ['not-a-mapping'], [wireguard_entry, wireguard_entry],
      [wireguard_entry('name' => 'office_node'), wireguard_entry],
      [wireguard_entry('name' => 'unsafe,REJECT')],
      [wireguard_entry('port' => 0)], [wireguard_entry('port' => '51820')],
      [wireguard_entry('server' => '')], [wireguard_entry('ip' => 'invalid')],
      [wireguard_entry('ipv6' => '10.7.0.2')],
      [wireguard_entry('private-key' => 'SECRET-MUST-NOT-APPEAR')],
      [wireguard_entry('public-key' => nil)],
      [wireguard_entry('pre-shared-key' => 'SECRET-MUST-NOT-APPEAR')],
      [wireguard_entry('allowed-ips' => [])],
      [wireguard_entry('allowed-ips' => ['10.7.0.0/99'])],
      [wireguard_entry('allowed-ips' => ['0.0.0.0/0'])],
      [wireguard_entry('allowed-ips' => ['::/0'])],
      [wireguard_entry('routes' => [])],
      [wireguard_entry('routes' => ['172.16.0.0/24'])],
      [wireguard_entry('domains' => ['office.test,DIRECT'])],
      [wireguard_entry('peers' => [])], [wireguard_entry('type' => 'ss')]
    ]
    invalid_entries.each do |entries|
      Dir.mktmpdir('mihomo-invalid-wireguard') do |directory|
        input = File.join(directory, 'values.yaml')
        output = File.join(directory, 'config.yaml')
        File.write(input, YAML.dump(empty_provider_values([]).merge('wireguard' => entries)))
        File.write(output, 'existing-config')
        stdout, stderr, status = Open3.capture3(RbConfig.ruby, GENERATOR, '-v', input, '-t', TEMPLATE, '-o', output)
        refute status.success?
        assert_includes stderr, 'wireguard'
        refute_includes stdout + stderr, 'SECRET-MUST-NOT-APPEAR'
        assert_equal 'existing-config', File.read(output)
      end
    end
  end

  def test_wireguard_names_cannot_collide_with_manual_nodes_or_groups
    collisions = [
      { 'local_proxies' => [handwritten_proxy(name: 'wg_office_node')] },
      { 'local_proxy_groups' => [{ 'name' => 'wg_office', 'type' => 'select', 'proxies' => ['DIRECT'] }] }
    ]
    collisions.each do |collision|
      Dir.mktmpdir('mihomo-wireguard-collision') do |directory|
        input = File.join(directory, 'values.yaml')
        output = File.join(directory, 'config.yaml')
        File.write(input, YAML.dump(empty_provider_values([]).merge(collision).merge('wireguard' => [wireguard_entry])))
        _stdout, stderr, status = Open3.capture3(RbConfig.ruby, GENERATOR, '-v', input, '-t', TEMPLATE, '-o', output)
        refute status.success?
        assert_includes stderr, 'conflicts with an existing node or group'
        refute File.exist?(output)
      end
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
