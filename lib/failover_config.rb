# frozen_string_literal: true

require 'psych'
require 'uri'

# Opt-in, ordered airport -> self-hosted failover. Only nodes enter the pools;
# selectors (especially my_proxy's DIRECT fallback) must never be their members.
class FailoverConfig
  NAMES = %w[failover failover_primary failover_backup].freeze
  NON_PROXY_TYPES = %w[direct reject reject-drop pass compatible].freeze
  DEFAULTS = {
    'url' => 'https://www.google.com/generate_204', 'expected_status' => 204,
    'interval' => 30, 'timeout' => 5000
  }.freeze
  KEYS = (DEFAULTS.keys + %w[primary backup backup_nodes]).freeze

  def initialize(options, provider_aliases:, local_proxies:)
    @options = options
    @provider_aliases = provider_aliases
    @local_proxies = local_proxies
  end

  def apply(output)
    return output if @options.nil? || @options == {}

    require_valid(@options.is_a?(Hash), 'must be a mapping')
    require_valid((@options.keys - KEYS).empty?, 'contains unknown settings')
    primary = sources('primary')
    backup = sources('backup')
    nodes = names('backup_nodes')
    require_valid(!primary.empty?, 'primary requires at least one subscription')
    require_valid(!backup.empty? || !nodes.empty?, 'requires a backup subscription or backup_nodes')
    require_valid((primary & backup).empty?, 'primary and backup subscriptions must not overlap')
    nodes.each do |name|
      matches = @local_proxies.select { |node| node['name'] == name }
      require_valid(matches.size == 1, 'backup_nodes must name existing, unique local_proxies (not groups or internal WG nodes)')
      node = matches.first
      require_valid(!NON_PROXY_TYPES.include?(node['type'].to_s.downcase), 'backup_nodes cannot be direct/reject/pass nodes')
      require_valid([nil, '', 'DIRECT'].include?(node['dialer-proxy']), 'backup_nodes must connect independently, without another dialer-proxy')
    end
    settings = DEFAULTS.merge(@options.slice(*DEFAULTS.keys))
    %w[interval timeout expected_status].each do |key|
      range = { 'interval' => 1..3600, 'timeout' => 100..60_000, 'expected_status' => 100..599 }.fetch(key)
      require_valid(settings[key].is_a?(Integer) && range.cover?(settings[key]), "#{key} must be an integer within #{range}")
    end
    begin
      url = URI.parse(settings['url']) if settings['url'].is_a?(String)
      require_valid(url.is_a?(URI::HTTP) && url.host && !url.userinfo && !url.fragment, 'url must be an HTTP(S) probe URL without credentials or fragment')
    rescue URI::InvalidURIError
      raise ArgumentError, 'failover url must be a valid HTTP(S) probe URL'
    end

    config = Psych.safe_load(output, permitted_classes: [], aliases: true)
    groups = config.fetch('proxy-groups')
    providers = config.fetch('proxy-providers')
    existing_names = groups.map { |group| group['name'] } + config.fetch('proxies', []).map { |node| node['name'] } + providers.keys
    require_valid((NAMES & existing_names).empty?, 'group names failover / failover_primary / failover_backup are reserved when enabled')

    check = {
      'enable' => true, 'url' => settings['url'], 'interval' => settings['interval'],
      'timeout' => settings['timeout'], 'lazy' => false, 'expected-status' => settings['expected_status'].to_s
    }
    # Mihomo's group.interval does NOT replace an existing provider's interval,
    # and a same-URL task does not replace its expected-status. Set both layers.
    (primary + backup).each do |name|
      provider = providers.fetch(name).dup
      provider['health-check'] = check.dup
      providers[name] = provider
    end
    common = check.reject { |key, _| key == 'enable' }.merge(
      'type' => 'fallback', 'max-failed-times' => 2, 'empty-fallback' => 'REJECT'
    )
    groups << common.merge('name' => 'failover_primary', 'hidden' => true, 'use' => primary,
                           'exclude-type' => NON_PROXY_TYPES.join('|'))
    pool = common.merge('name' => 'failover_backup', 'hidden' => true,
                        'exclude-type' => NON_PROXY_TYPES.join('|'))
    pool['use'] = backup unless backup.empty?
    pool['proxies'] = nodes unless nodes.empty?
    groups << pool
    groups << common.merge('name' => 'failover', 'proxies' => %w[failover_primary failover_backup])
    # Do not change the selected default or contaminate region-only/my_proxy groups.
    %w[default proxy final].each do |name|
      group = groups.find { |entry| entry['name'] == name }
      additions = name == 'final' ? NAMES : ['failover']
      group['proxies'] = (Array(group['proxies']) + additions).uniq if group
    end
    Psych.dump(config)
  end

  private

  def require_valid(condition, message)
    raise ArgumentError, "failover #{message}" unless condition
  end

  def names(key)
    value = @options.fetch(key, [])
    require_valid(value.is_a?(Array) && value.all? { |name| name.is_a?(String) && !name.empty? }, "#{key} must be an array of names")
    value.uniq
  end

  def sources(key)
    names(key).flat_map do |name|
      require_valid(@provider_aliases.key?(name), "#{key} must name existing subscriptions")
      @provider_aliases.fetch(name)
    end.uniq
  end
end
