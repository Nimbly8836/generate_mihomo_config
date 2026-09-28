# frozen_string_literal: true

# Integration checks against an already running Web service (no real subscriptions).
require 'json'
require 'minitest/autorun'
require 'net/http'
require 'psych'

class WebSmokeTest < Minitest::Test
  BASE = URI(ENV.fetch('WEB_BASE_URL', 'http://127.0.0.1:4567'))

  def request(path, payload = nil)
    http = Net::HTTP.new(BASE.host, BASE.port, nil)
    http.use_ssl = BASE.scheme == 'https'
    http.open_timeout = 5
    http.read_timeout = 15
    message = payload ? Net::HTTP::Post.new(path) : Net::HTTP::Get.new(path)
    if payload
      message['Content-Type'] = 'application/json'
      message.body = JSON.generate(payload)
    end
    http.request(message)
  end

  def test_health_and_homepage
    health = request('/api/v1/health')
    assert_equal '200', health.code
    assert_equal 'ok', JSON.parse(health.body).fetch('status')
    homepage = request('/')
    assert_equal '200', homepage.code
    assert_includes homepage.body, 'name="ip4p"'
  end

  def test_public_reference_matches_repository_example_and_generates
    response = request('/examples/values.yaml')
    assert_equal '200', response.code
    expected = File.binread(File.expand_path('../config-values.example.yaml', __dir__))
    assert_equal expected, response.body.b
    values = response.body.dup.force_encoding(Encoding::UTF_8)
    assert values.valid_encoding?
    %w[proxy_providers config_overrides wireguard custom_rule_providers local_rules].each do |key|
      assert values.include?("#{key}:"), "missing reference section #{key}"
    end
    generated = request('/api/generate', 'values' => values)
    assert_equal '200', generated.code
    config = Psych.safe_load(JSON.parse(generated.body).fetch('config'), aliases: true)
    assert_equal 7890, config.fetch('mixed-port')
  end

  def test_yaml_editor_assets_are_available_locally
    assets = {
      'codemirror.js' => 'text/javascript', 'yaml.js' => 'text/javascript',
      'codemirror.css' => 'text/css', 'LICENSE' => 'text/plain'
    }
    assets.each do |name, content_type|
      response = request("/assets/codemirror/#{name}")
      assert_equal '200', response.code, name
      assert response.fetch('content-type').start_with?(content_type), name
      assert_equal 'nosniff', response.fetch('x-content-type-options')
      expected = File.binread(File.expand_path("../web/vendor/codemirror/#{name}", __dir__))
      assert_equal expected, response.body.b, name
    end
  end

  def test_unlisted_file_paths_are_not_served
    ['/config-values.yaml', '/examples/config-values-phone-wg.yaml',
     '/assets/codemirror/../../config-values.yaml', '/examples/../config-values.yaml'].each do |path|
      assert_equal '404', request(path).code, path
    end
  end

  def test_form_api_applies_ip4p_override
    response = request('/api/generate', 'values' => {
                         'proxy_providers' => [], 'local_proxies' => [], 'web_secret' => 'smoke-test-only',
                         'config_overrides' => { 'experimental' => { 'dialer-ip4p-convert' => true } }
                       })
    assert_equal '200', response.code
    config = Psych.safe_load(JSON.parse(response.body).fetch('config'), aliases: true)
    assert_equal true, config.fetch('experimental').fetch('dialer-ip4p-convert')
  end

  def test_versioned_api_generates_wireguard_and_downloads_result
    values = {
      'proxy_providers' => [], 'local_proxies' => [], 'web_secret' => 'smoke-test-only',
      'wireguard' => [{
        'name' => 'office', 'server' => '192.0.2.10', 'port' => 51_820, 'ip' => '10.7.0.2',
        'private-key' => ["\x01" * 32].pack('m0'), 'public-key' => ["\x02" * 32].pack('m0'),
        'allowed-ips' => ['10.7.0.0/24']
      }]
    }
    response = request('/api/v1/configs', 'values' => values)
    assert_equal '201', response.code
    created = JSON.parse(response.body)
    config = Psych.safe_load(created.fetch('config'), aliases: true)
    assert_includes config.fetch('rules'), 'IP-CIDR,10.7.0.0/24,wg_office,no-resolve'
    resource = request(response.fetch('location'))
    assert_equal '200', resource.code
    assert_equal created.fetch('config'), JSON.parse(resource.body).fetch('config')
    download = request(created.fetch('download_url'))
    assert_equal '200', download.code
    assert_includes download.fetch('content-disposition'), 'config.yaml'
    # Net::HTTP exposes attachment bytes as binary, while JSON decodes UTF-8.
    assert_equal created.fetch('config').b, download.body.b
  end

  def test_yaml_input_retains_explicit_false
    yaml = Psych.dump('proxy_providers' => [], 'local_proxies' => [], 'web_secret' => 'smoke-test-only',
                      'config_overrides' => { 'experimental' => { 'dialer-ip4p-convert' => false } })
    response = request('/api/generate', 'values' => yaml)
    assert_equal '200', response.code
    config = Psych.safe_load(JSON.parse(response.body).fetch('config'), aliases: true)
    assert_equal false, config.fetch('experimental').fetch('dialer-ip4p-convert')
  end
end
