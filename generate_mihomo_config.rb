#!/usr/bin/env ruby
# frozen_string_literal: true

require "erb"
require "optparse"
require "psych"
require "securerandom"

DEFAULT_TEMPLATE = "config-template.yaml.erb"
DEFAULT_OUTPUT = "config.yaml"
DEFAULT_SCALARS = {
  "port" => 7890,
  "web_port" => 9090,
  "tun_device" => "utun-mihomo",
  "dns_split_cn_foreign" => false
}.freeze

def usage(parser)
  warn parser.to_s
  exit 1
end

def load_yaml_file(path)
  Psych.safe_load_file(path, permitted_classes: [], aliases: true) || {}
rescue Errno::ENOENT
  warn "File not found: #{path}"
  exit 1
rescue Psych::SyntaxError => e
  warn "YAML parse error in #{path}: #{e.message}"
  exit 1
end

def blank_value?(value)
  value.nil? || (value.is_a?(String) && value.strip.empty?)
end

def apply_defaults(values)
  normalized = values.transform_keys(&:to_s)
  applied = {}

  DEFAULT_SCALARS.each do |key, default_value|
    next unless blank_value?(normalized[key])

    normalized[key] = default_value
    applied[key] = default_value
  end

  if blank_value?(normalized["web_secret"])
    normalized["web_secret"] = SecureRandom.uuid
    applied["web_secret"] = normalized["web_secret"]
  end

  [normalized, applied]
end

def yaml_scalar(value)
  dumped = Psych.dump(value)
  dumped.sub(/\A---\s*\n?/, "").sub(/\n\.\.\.\s*\z/, "").strip
end

def append_fake_ip_filter(output, extra_filters)
  return output if extra_filters.empty?

  parsed_output = Psych.safe_load(output, permitted_classes: [], aliases: true) || {}
  existing_filters = Array(parsed_output.dig("dns", "fake-ip-filter")).map(&:to_s)
  filters_to_insert = extra_filters.map(&:to_s).uniq - existing_filters
  return output if filters_to_insert.empty?

  lines = output.lines
  key_index = lines.index { |line| line.match?(/^\s*fake-ip-filter:\s*$/) }

  unless key_index
    warn "Could not find dns.fake-ip-filter in rendered output"
    exit 1
  end

  key_indent = lines[key_index][/^\s*/].size
  insert_at = key_index + 1

  while insert_at < lines.length
    line = lines[insert_at]
    stripped = line.strip
    indent = line[/^\s*/].size

    break if stripped.empty? && indent <= key_indent
    break if stripped.start_with?("#") && indent <= key_indent
    break if !stripped.empty? && indent <= key_indent

    insert_at += 1
  end

  new_lines = filters_to_insert.map do |filter|
    "#{" " * (key_indent + 2)}- #{yaml_scalar(filter)}\n"
  end

  lines.insert(insert_at, *new_lines)
  lines.join
end

class TemplateContext
  PROVIDER_REQUIRED_KEYS = %w[name url].freeze
  LOCAL_PROXY_REQUIRED_KEYS = %w[name type server port].freeze
  LOCAL_PROXY_GROUP_REQUIRED_KEYS = %w[name type].freeze

  attr_reader :proxy_providers, :local_proxies, :local_proxy_groups, :local_rules, :fake_ip_filter

  def initialize(values)
    @values = values.transform_keys(&:to_s)
    @proxy_providers = normalize_hash_array(@values["proxy_providers"], "proxy_providers")
    @local_proxies = normalize_hash_array(@values["local_proxies"], "local_proxies")
    @local_proxy_groups = normalize_hash_array(@values["local_proxy_groups"], "local_proxy_groups")
    @local_rules = Array(@values["local_rules"]).map(&:to_s)
    @fake_ip_filter = normalize_string_array(optional_value("fake_ip_filter", "fake-ip-filter"), "fake_ip_filter")
    validate!
  end

  def get_binding
    binding
  end

  def provider_names
    @provider_names ||= proxy_providers.map { |provider| provider.fetch("name") }
  end

  def local_proxy_names
    @local_proxy_names ||= local_proxies.map { |proxy| proxy.fetch("name") }
  end

  def provider_uses_defaults?(provider)
    !provider["skip_defaults"]
  end

  def provider_body(provider)
    provider.reject { |key, _| %w[name skip_defaults].include?(key) }
            .merge("path" => provider["path"] || "./proxy_providers/#{provider.fetch('name')}.yaml")
  end

  def yaml_scalar(value)
    dumped = Psych.dump(value)
    dumped.sub(/\A---\s*\n?/, "").sub(/\n\.\.\.\s*\z/, "").strip
  end

  def render_hash(hash, indent:)
    return "#{" " * indent}{}\n" if hash.empty?

    lines = []
    hash.each do |key, value|
      append_mapping(lines, key, value, indent)
    end
    "#{lines.join("\n")}\n"
  end

  def render_list(items, indent:)
    return "#{" " * indent}[]\n" if items.empty?

    lines = []
    items.each_with_index do |item, index|
      append_list_item(lines, item, indent)
      lines << "" unless index == items.length - 1
    end
    "#{lines.join("\n")}\n"
  end

  def method_missing(name, *args)
    return super unless args.empty?

    key = name.to_s
    return @values[key] if @values.key?(key)

    super
  end

  def respond_to_missing?(name, include_private = false)
    @values.key?(name.to_s) || super
  end

  private

  def optional_value(*keys)
    found_keys = keys.select { |key| @values.key?(key) }

    if found_keys.length > 1
      warn "Only one of #{keys.join(' / ')} can be provided"
      exit 1
    end

    return nil if found_keys.empty?

    @values[found_keys.first]
  end

  def normalize_hash_array(value, key)
    case value
    when nil
      []
    when Array
      value.map do |item|
        unless item.is_a?(Hash)
          warn "#{key} must be an array of mappings"
          exit 1
        end

        item.transform_keys(&:to_s)
      end
    else
      warn "#{key} must be an array"
      exit 1
    end
  end

  def normalize_string_array(value, key)
    case value
    when nil
      []
    when Array
      value.map do |item|
        unless item.is_a?(String)
          warn "#{key} must be an array of strings"
          exit 1
        end

        item
      end
    else
      warn "#{key} must be an array"
      exit 1
    end
  end

  def validate!
    validate_hashes!(proxy_providers, PROVIDER_REQUIRED_KEYS, "proxy_providers")
    validate_hashes!(local_proxies, LOCAL_PROXY_REQUIRED_KEYS, "local_proxies")
    validate_hashes!(local_proxy_groups, LOCAL_PROXY_GROUP_REQUIRED_KEYS, "local_proxy_groups")
  end

  def validate_hashes!(items, required_keys, label)
    invalid_items = items.filter_map do |item|
      missing = required_keys.reject { |key| item.key?(key) }
      next if missing.empty?

      "#{item['name'] || '(unnamed)'} -> #{missing.join(', ')}"
    end

    return if invalid_items.empty?

    warn "Invalid #{label} entries:"
    invalid_items.each { |entry| warn "  #{entry}" }
    exit 1
  end

  def append_mapping(lines, key, value, indent)
    prefix = " " * indent

    case value
    when Hash
      if value.empty?
        lines << "#{prefix}#{key}: {}"
      else
        lines << "#{prefix}#{key}:"
        value.each do |child_key, child_value|
          append_mapping(lines, child_key, child_value, indent + 2)
        end
      end
    when Array
      if value.empty?
        lines << "#{prefix}#{key}: []"
      else
        lines << "#{prefix}#{key}:"
        value.each do |item|
          append_list_item(lines, item, indent + 2)
        end
      end
    else
      lines << "#{prefix}#{key}: #{yaml_scalar(value)}"
    end
  end

  def append_list_item(lines, value, indent)
    prefix = " " * indent

    case value
    when Hash
      if value.empty?
        lines << "#{prefix}- {}"
        return
      end

      pairs = value.to_a
      first_key, first_value = pairs.shift

      if first_value.is_a?(Hash) || first_value.is_a?(Array)
        lines << "#{prefix}-"
        append_mapping(lines, first_key, first_value, indent + 2)
      else
        lines << "#{prefix}- #{first_key}: #{yaml_scalar(first_value)}"
      end

      pairs.each do |child_key, child_value|
        append_mapping(lines, child_key, child_value, indent + 2)
      end
    when Array
      lines << "#{prefix}-"
      value.each do |item|
        append_list_item(lines, item, indent + 2)
      end
    else
      lines << "#{prefix}- #{yaml_scalar(value)}"
    end
  end
end

options = {
  template: DEFAULT_TEMPLATE,
  output: DEFAULT_OUTPUT
}

parser = OptionParser.new do |opts|
  opts.banner = "Usage: ruby generate_mihomo_config.rb --values values.yaml [options]"

  opts.on("-v", "--values PATH", "Input values YAML file") do |path|
    options[:values] = path
  end

  opts.on("-t", "--template PATH", "ERB template file (default: #{DEFAULT_TEMPLATE})") do |path|
    options[:template] = path
  end

  opts.on("-o", "--output PATH", "Output file (default: #{DEFAULT_OUTPUT})") do |path|
    options[:output] = path
  end

  opts.on("-h", "--help", "Show this help") do
    puts opts
    exit 0
  end
end

parser.parse!(ARGV)
usage(parser) unless options[:values]

values, applied_defaults = apply_defaults(load_yaml_file(options[:values]))
template = File.read(options[:template])
context = TemplateContext.new(values)
output = ERB.new(template, trim_mode: "-").result(context.get_binding)
output = append_fake_ip_filter(output, context.fake_ip_filter)

File.write(options[:output], output)
warn "Using default port=#{applied_defaults['port']}" if applied_defaults.key?("port")
warn "Using default web_port=#{applied_defaults['web_port']}" if applied_defaults.key?("web_port")
warn "Using default tun_device=#{applied_defaults['tun_device']}" if applied_defaults.key?("tun_device")
warn "Generated web_secret UUID: #{applied_defaults['web_secret']}" if applied_defaults.key?("web_secret")
puts "Generated #{options[:output]} from #{options[:template]}"
