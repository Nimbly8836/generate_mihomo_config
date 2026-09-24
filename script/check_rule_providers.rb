#!/usr/bin/env ruby
# frozen_string_literal: true

# Optional live check: needs ax and mihomo. Does not read private values or subscriptions.
require 'digest'
require 'ipaddr'
require 'open3'
require 'psych'
require 'rbconfig'
require 'tmpdir'

ROOT = File.expand_path('..', __dir__)
DOMAIN_SAMPLES = {
  'openai_domain' => %w[chatgpt.com openai.com openaiapi-site.azureedge.net
                        openaicomproductionae4b.blob.core.windows.net],
  'claude_domain' => %w[claude.ai anthropic.com],
  'gemini_domain' => %w[gemini.google.com generativelanguage.googleapis.com],
  'copilot_domain' => %w[githubcopilot.com copilot-proxy.githubusercontent.com],
  'ai_domain' => %w[cursor.sh perplexity.ai],
  'telegram_domain' => %w[t.me telegram.org],
  'netflix_domain' => %w[netflix.com],
  'google_domain' => %w[google.com],
  'github_domain' => %w[github.com]
}.freeze
IP_SAMPLES = {
  'telegram_ip' => %w[149.154.167.50 91.108.56.100],
  'google_ip' => %w[8.8.8.8],
  'netflix_ip' => %w[23.246.0.1],
  'twitter_ip' => %w[104.244.42.1],
  'private_ip' => %w[10.0.0.20 192.168.1.1]
}.freeze

def run!(*command)
  stdout, stderr, status = Open3.capture3(*command)
  raise "#{command.first} failed: #{stderr}\n#{stdout}" unless status.success?

  stdout
end

def domain_in_list?(domain, entries)
  entries.any? do |entry|
    suffix = entry.delete_prefix('+.')
    entry == domain || (entry.start_with?('+.') && (domain == suffix || domain.end_with?(".#{suffix}")))
  end
end

def verify_samples!(name, entries)
  DOMAIN_SAMPLES.fetch(name, []).each do |domain|
    raise "sample domain missing: #{domain}" unless domain_in_list?(domain, entries)
  end
  samples = IP_SAMPLES.fetch(name, [])
  return if samples.empty?

  networks = entries.map { |entry| IPAddr.new(entry) }
  samples.each do |ip|
    raise "sample IP missing: #{ip}" unless networks.any? { |network| network.include?(ip) }
  end
end

failures = []
Dir.mktmpdir('mihomo-provider-check') do |directory|
  values_path = File.join(directory, 'values.yaml')
  config_path = File.join(directory, 'config.yaml')
  File.write(values_path, "proxy_providers: []\nlocal_proxies: []\nlocal_rules: []\n")
  run!(RbConfig.ruby, File.join(ROOT, 'generate_mihomo_config.rb'), '-v', values_path,
       '-t', File.join(ROOT, 'config-template.yaml.erb'), '-o', config_path)
  config = Psych.safe_load_file(config_path, aliases: true)
  providers = config.fetch('rule-providers')
  puts "Live check: #{providers.length} built-in providers; no user subscriptions."
  providers.each do |name, provider|
    binary_path = File.join(directory, "#{name}.mrs")
    text_path = File.join(directory, "#{name}.txt")
    begin
      run!('ax', provider.fetch('url'), '-f', '-o', binary_path, '-m', '30', '--max-bytes', '20971520')
      raise 'empty download' unless File.size?(binary_path)

      run!('mihomo', 'convert-ruleset', provider.fetch('behavior'), 'mrs', binary_path, text_path)
      entries = File.readlines(text_path, chomp: true).reject { |line| line.empty? || line.start_with?('#') }
      raise 'decoded ruleset is empty' if entries.empty?

      verify_samples!(name, entries)
      puts "PASS #{name}: entries=#{entries.length} sha256=#{Digest::SHA256.file(binary_path).hexdigest}"
    rescue StandardError => e
      failures << name
      warn "FAIL #{name}: #{e.message}"
    end
  end
  puts "#{providers.length - failures.length}/#{providers.length} providers passed download/decode/sample checks."
end
abort "Failed providers: #{failures.join(', ')}" unless failures.empty?
puts 'Sample inclusion is not a guarantee of complete coverage or correct live routing.'
