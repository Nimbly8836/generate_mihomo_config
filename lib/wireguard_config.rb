# frozen_string_literal: true

require 'base64'
require 'ipaddr'

# Expands single-peer intranet tunnels without making them general proxy exits.
class WireGuardConfig
  attr_reader :proxies, :groups, :rules

  def initialize(entries, reserved_names: [])
    entries = [] if entries.nil?
    invalid!('wireguard', 'must be an array of mappings') unless entries.is_a?(Array)
    @proxies = []
    @groups = []
    @rules = []
    occupied = reserved_names.dup
    entries.each_with_index { |entry, index| add_entry(entry, "wireguard[#{index}]", occupied) }
  end

  private

  def invalid!(path, message)
    # Never include the entry or secret values in validation errors.
    raise ArgumentError, "#{path} #{message}"
  end

  def add_entry(entry, path, occupied)
    invalid!(path, 'must be a mapping') unless entry.is_a?(Hash)
    name = entry['name']
    unless name.is_a?(String) && name.match?(/\A[a-z][a-z0-9_-]*\z/)
      invalid!("#{path}.name", 'must be a lowercase identifier (letters, digits, _ or -)')
    end
    group_name = "wg_#{name}"
    node_name = "#{group_name}_node"
    if [group_name, node_name].any? { |generated| occupied.include?(generated) }
      invalid!("#{path}.name", 'conflicts with an existing node or group')
    end
    occupied.concat([group_name, node_name])
    validate_node!(entry, path)
    allowed = networks(entry['allowed-ips'], "#{path}.allowed-ips")
    invalid!("#{path}.allowed-ips", 'must not be empty') if allowed.empty?
    routes = entry.key?('routes') ? networks(entry['routes'], "#{path}.routes") : allowed
    suffixes = domains(entry.fetch('domains', []), "#{path}.domains")
    validate_routes!(routes, allowed, suffixes, path)

    node = entry.reject { |key, _| %w[name routes domains].include?(key) }
    node = { 'udp' => true }.merge(node).merge('name' => node_name, 'type' => 'wireguard')
    @proxies << node
    @groups << { 'name' => group_name, 'type' => 'select', 'proxies' => [node_name, 'REJECT'] }
    @rules.concat(suffixes.map { |domain| "DOMAIN-SUFFIX,#{domain},#{group_name}" })
    @rules.concat(routes.map do |network|
      kind = network.ipv4? ? 'IP-CIDR' : 'IP-CIDR6'
      "#{kind},#{network}/#{network.prefix},#{group_name},no-resolve"
    end)
  end

  def validate_node!(entry, path)
    unless entry['server'].is_a?(String) && !entry['server'].strip.empty?
      invalid!("#{path}.server", 'must be a nonempty string')
    end
    unless entry['port'].is_a?(Integer) && (1..65_535).cover?(entry['port'])
      invalid!("#{path}.port", 'must be an integer from 1 to 65535')
    end
    invalid!("#{path}.type", 'must be wireguard when supplied') if entry.key?('type') && entry['type'] != 'wireguard'
    if entry.key?('peers')
      invalid!("#{path}.peers",
               'is not supported here; use local_proxies for multi-peer configurations')
    end
    invalid!(path, 'requires a client ip or ipv6 address') unless entry.key?('ip') || entry.key?('ipv6')
    validate_address!(entry['ip'], "#{path}.ip", 4) if entry.key?('ip')
    validate_address!(entry['ipv6'], "#{path}.ipv6", 6) if entry.key?('ipv6')
    %w[private-key public-key].each { |key| validate_key!(entry[key], "#{path}.#{key}") }
    validate_key!(entry['pre-shared-key'], "#{path}.pre-shared-key") if entry.key?('pre-shared-key')
  end

  def validate_address!(value, path, version)
    valid = value.is_a?(String) && !value.include?('/')
    begin
      address = IPAddr.new(value) if valid
      valid &&= version == 4 ? address.ipv4? : address.ipv6?
    rescue IPAddr::Error
      valid = false
    end
    invalid!(path, "must be an IPv#{version} client address without a prefix") unless valid
  end

  def validate_key!(value, path)
    begin
      valid = value.is_a?(String) && Base64.strict_decode64(value).bytesize == 32
    rescue ArgumentError
      valid = false
    end
    invalid!(path, 'must be a base64-encoded 32-byte WireGuard key') unless valid
  end

  def networks(value, path)
    invalid!(path, 'must be an array of CIDR strings') unless value.is_a?(Array)
    value.map do |cidr|
      invalid!(path, 'must contain valid IPv4/IPv6 CIDRs') unless cidr.is_a?(String) && cidr.match?(%r{\A[^\s/]+/\d+\z})
      begin
        IPAddr.new(cidr)
      rescue IPAddr::Error
        invalid!(path, 'must contain valid IPv4/IPv6 CIDRs')
      end
    end.uniq
  end

  def domains(value, path)
    invalid!(path, 'must be an array of domain suffixes') unless value.is_a?(Array)
    value.map do |domain|
      unless domain.is_a?(String) && domain.match?(/\A[a-zA-Z0-9_-]+(?:\.[a-zA-Z0-9_-]+)*\z/)
        invalid!(path, 'must contain plain domain suffixes (no wildcard, comma or URL)')
      end
      domain.downcase
    end.uniq
  end

  def validate_routes!(routes, allowed, suffixes, path)
    invalid!(path, 'requires at least one route or domain') if routes.empty? && suffixes.empty?
    if routes.any? { |network| network.prefix.zero? }
      invalid!("#{path}.routes",
               'cannot contain /0 in intranet mode; specify narrower routes or use routes: [] with domains')
    end
    routes.each do |network|
      covered = allowed.any? do |range|
        range.ipv4? == network.ipv4? && range.include?(network.to_range.first) && range.include?(network.to_range.last)
      end
      invalid!("#{path}.routes", 'must be contained in allowed-ips') unless covered
    end
  end
end
