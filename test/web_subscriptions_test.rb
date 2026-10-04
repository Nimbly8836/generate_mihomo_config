# frozen_string_literal: true

require 'minitest/autorun'
require 'net/http'
require 'json'
require 'socket'
require 'tmpdir'
require 'fileutils'
require 'rbconfig'
require_relative '../lib/subscription_store'

class WebSubscriptionsTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  CONFIG = "mixed-port: 7890\nsecret: test-only\nproxy-groups: []\nrules: []\n"

  def setup
    @directory = Dir.mktmpdir
    port_socket = TCPServer.new('127.0.0.1', 0)
    @port = port_socket.addr[1]
    port_socket.close
    @origin = "http://127.0.0.1:#{@port}"
    start_server
  end

  def start_server
    @pid = Process.spawn({ 'HOST' => '127.0.0.1', 'PORT' => @port.to_s, 'DATA_DIR' => File.join(@directory, 'data'), 'PUBLIC_BASE_URL' => @origin },
                         RbConfig.ruby, File.join(ROOT, 'web_server.rb'), out: File.join(@directory, 'log'), err: [:child, :out])
    100.times do
      begin
        return if request('GET', '/api/v1/health').code == '200'
      rescue Errno::ECONNREFUSED
        sleep 0.05
      end
    end
    flunk 'server did not start'
  end

  def stop_server
    Process.kill('TERM', @pid)
    Process.wait(@pid)
    @pid = nil
  end

  def teardown
    stop_server if @pid
    FileUtils.remove_entry(@directory)
  end

  def request(method, path, payload = nil, cookie: nil, headers: {})
    http = Net::HTTP.new('127.0.0.1', @port, nil)
    http.read_timeout = 10
    message = Net::HTTPGenericRequest.new(method, method != 'GET', true, path)
    if method != 'GET'
      message['Origin'] = @origin
      message['X-Mihomo-Request'] = '1'
      message['Content-Type'] = 'application/json'
      message.body = JSON.generate(payload || {})
    end
    message['Cookie'] = cookie if cookie
    headers.each { |key, value| message[key] = value }
    http.request(message)
  end

  def json(response)
    JSON.parse(response.body)
  end

  def identity
    response = request('POST', '/api/identity')
    assert_equal '200', response.code
    [response['set-cookie'].split(';').first, json(response)['recovery_code']]
  end

  def create(cookie, config = CONFIG)
    response = request('POST', '/api/subscriptions', { config: config }, cookie: cookie)
    assert_equal '201', response.code, response.body
    json(response)
  end

  def read_url(url)
    request('GET', URI(url).request_uri)
  end

  def test_exact_generated_snapshot_survives_restart_update_reset_delete
    browser, = identity
    generated = request('POST', '/api/generate', { values: { proxy_providers: [], local_proxies: [] } })
    assert_equal '200', generated.code
    snapshot = json(generated)['config']
    row = create(browser, snapshot)
    assert_equal @origin, row['url'].split('/s/').first
    2.times { assert_equal snapshot.b, read_url(row['url']).body.b }
    stop_server
    start_server
    assert_equal snapshot.b, read_url(row['url']).body.b
    assert_equal row, json(request('GET', '/api/subscriptions', cookie: browser))['subscriptions'].first
    id = row['id']
    updated = request('PUT', "/api/subscriptions/#{id}", { config: CONFIG }, cookie: browser)
    assert_equal '200', updated.code
    assert_equal row['url'], json(updated)['url']
    assert_equal CONFIG, read_url(row['url']).body
    reset = json(request('POST', "/api/subscriptions/#{id}/reset", cookie: browser))
    refute_equal row['url'], reset['url']
    assert_equal '404', read_url(row['url']).code
    assert_equal CONFIG, read_url(reset['url']).body
    assert_equal '200', request('DELETE', "/api/subscriptions/#{id}", cookie: browser).code
    assert_equal '404', read_url(reset['url']).code
  end

  def test_owner_isolation_and_read_token_is_not_management_authentication
    first, = identity
    second, = identity
    row = create(first)
    assert_equal [], json(request('GET', '/api/subscriptions', cookie: second))['subscriptions']
    [['PUT', '', { config: CONFIG }], ['POST', '/reset', {}], ['DELETE', '', {}]].each do |method, suffix, payload|
      response = request(method, "/api/subscriptions/#{row['id']}#{suffix}", payload, cookie: second)
      assert_equal '404', response.code
      unknown = request(method, "/api/subscriptions/#{'0' * 64}#{suffix}", payload, cookie: second)
      assert_equal unknown.body, response.body
    end
    token = row['url'].split('/').last
    assert_equal '401', request('GET', '/api/subscriptions', cookie: "mihomo_session=#{token}").code
    assert_equal '401', request('DELETE', "/api/subscriptions/#{row['id']}", cookie: "mihomo_session=#{token}").code
    assert_equal '404', request('POST', '/api/identity/recover', { recovery_code: token }).code
    assert_equal CONFIG, read_url(row['url']).body
  end

  def test_recovery_is_one_use_and_rotates_session_and_recovery
    first, code = identity
    row = create(first)
    ['../subscriptions.json', nil, {}, '<script>', 'a' * 64].each do |invalid|
      assert_equal '404', request('POST', '/api/identity/recover', { recovery_code: invalid }).code
    end
    response = request('POST', '/api/identity/recover', { recovery_code: code })
    assert_equal '200', response.code
    recovered = response['set-cookie'].split(';').first
    new_code = json(response)['recovery_code']
    refute_equal code, new_code
    assert_equal '401', request('GET', '/api/subscriptions', cookie: first).code
    assert_equal '404', request('POST', '/api/identity/recover', { recovery_code: code }).code
    assert_equal row, json(request('GET', '/api/subscriptions', cookie: recovered))['subscriptions'].first
    rotated = json(request('POST', '/api/identity/recovery', cookie: recovered))['recovery_code']
    assert_equal '404', request('POST', '/api/identity/recover', { recovery_code: new_code }).code
    assert_equal '200', request('POST', '/api/identity/recover', { recovery_code: rotated }).code
    bytes = File.binread(File.join(@directory, 'data/subscriptions.json'))
    [code, new_code, rotated, first.split('=').last, recovered.split('=').last].each { |secret| refute_includes bytes, secret }
    log = File.read(File.join(@directory, 'log'))
    [code, CONFIG, row['url']].each { |secret| refute_includes log, secret }
  end

  def test_csrf_cookie_headers_host_and_no_get_mutations
    response = request('POST', '/api/identity')
    assert_includes response['set-cookie'], 'HttpOnly'
    assert_includes response['set-cookie'], 'SameSite=Strict'
    refute_includes response['set-cookie'], '; Secure'
    browser = response['set-cookie'].split(';').first
    row = create(browser)
    original = File.binread(File.join(@directory, 'data/subscriptions.json'))
    bad_headers = [{ 'Origin' => nil }, { 'Origin' => 'https://evil.example' }, { 'X-Mihomo-Request' => nil },
                   { 'Content-Type' => 'text/plain' }, { 'Host' => 'evil.example' }, { 'Sec-Fetch-Site' => 'cross-site' }]
    bad_headers.each do |headers|
      ['/api/identity', '/api/identity/recover', '/api/identity/recovery', '/api/subscriptions', "/api/subscriptions/#{row['id']}/reset"].each do |path|
        assert_equal '403', request('POST', path, {}, cookie: browser, headers: headers).code
        assert_equal original, File.binread(File.join(@directory, 'data/subscriptions.json'))
      end
    end
    ['/api/identity', '/api/identity/recovery', '/api/identity/recover', "/api/subscriptions/#{row['id']}/reset"].each do |path|
      refute_equal '200', request('GET', path, cookie: browser).code
      assert_equal original, File.binread(File.join(@directory, 'data/subscriptions.json'))
    end
    assert_equal '404', request('GET', '/s/../../data/subscriptions.json').code
    [read_url(row['url']), request('GET', '/api/subscriptions', cookie: browser)].each do |result|
      assert_equal 'private, no-store', result['cache-control']
      assert_equal 'no-referrer', result['referrer-policy']
      assert_equal 'nosniff', result['x-content-type-options']
      refute result['access-control-allow-origin']
    end
    forwarded = request('POST', '/api/subscriptions', { config: CONFIG }, cookie: browser,
                        headers: { 'X-Forwarded-Host' => 'evil.example', 'X-Forwarded-Proto' => 'https' })
    assert json(forwarded)['url'].start_with?(@origin)
  end

  def test_invalid_updates_and_oversize_body_do_not_change_snapshot
    browser, = identity
    row = create(browser)
    ['proxies: []', "rules: [", 'x' * (SubscriptionStore::MAX_CONFIG + 1), nil].each do |config|
      assert_equal '422', request('PUT', "/api/subscriptions/#{row['id']}", { config: config }, cookie: browser).code
      assert_equal CONFIG, read_url(row['url']).body
    end
    socket = TCPSocket.new('127.0.0.1', @port)
    socket.write("PUT /api/subscriptions/#{row['id']} HTTP/1.1\r\nHost: 127.0.0.1:#{@port}\r\nContent-Length: 999999999\r\n\r\n")
    # No body sent: size rejection must happen before a blocking read/allocation.
    assert IO.select([socket], nil, nil, 2)
    assert_match(/HTTP\/1.1 413/, socket.read)
    socket.close
    assert_equal CONFIG, read_url(row['url']).body
    socket = TCPSocket.new('127.0.0.1', @port)
    socket.write("GET / HTTP/1.1\r\nX-Large: #{'x' * 17_000}")
    assert_match(/HTTP\/1.1 431/, socket.gets)
    socket.close
  end

  def test_alias_mapping_key_is_rejected_without_blocking_reads_or_later_updates
    browser, = identity
    row = create(browser)
    payload = "#{CONFIG}a: &a [1]\n"
    12.times do |index|
      previous = index.zero? ? 'a' : "a#{index - 1}"
      payload << "a#{index}: &a#{index} [*#{previous}, *#{previous}]\n"
    end
    payload << "? *a11\n: value\n"
    response = request('PUT', "/api/subscriptions/#{row['id']}", { config: payload }, cookie: browser)
    assert_equal '422', response.code
    assert_equal CONFIG, read_url(row['url']).body
    assert_equal '200', request('GET', '/api/v1/health').code
    response = request('PUT', "/api/subscriptions/#{row['id']}", { config: CONFIG + "# valid update\n" }, cookie: browser)
    assert_equal '200', response.code
    assert_equal CONFIG + "# valid update\n", read_url(row['url']).body
  end

  def test_request_rate_ignores_forwarded_ip
    125.times do |index|
      result = request('GET', '/api/v1/health', headers: { 'X-Forwarded-For' => "192.0.2.#{index}" })
      if result.code == '429'
        assert_operator index, :<=, 120
        return
      end
    end
    flunk 'rate limit missing'
  end

  def test_partial_headers_time_out_and_server_remains_available
    socket = TCPSocket.new('127.0.0.1', @port)
    socket.write('GET / HTTP/1.1')
    assert IO.select([socket], nil, nil, 7)
    assert_match(/HTTP\/1.1 408/, socket.read)
    socket.close
    assert_equal '200', request('GET', '/api/v1/health').code
  end

  def test_https_canonical_origin_sets_secure_cookie_without_trusting_forwarded_headers
    stop_server
    @origin = 'https://subscriptions.example.test'
    start_server
    response = request('POST', '/api/identity', headers: { 'Host' => 'subscriptions.example.test', 'X-Forwarded-Proto' => 'http' })
    assert_equal '200', response.code
    assert_includes response['set-cookie'], '; Secure'
    browser = response['set-cookie'].split(';').first
    response = request('POST', '/api/subscriptions', { config: CONFIG }, cookie: browser,
                       headers: { 'Host' => 'subscriptions.example.test', 'X-Forwarded-Host' => 'evil.example' })
    assert_equal '201', response.code
    assert json(response)['url'].start_with?('https://subscriptions.example.test/s/')
  end

  def test_corrupt_store_fails_closed_without_error_echo_or_replacement
    browser, = identity
    row = create(browser)
    path = File.join(@directory, 'data/subscriptions.json')
    File.write(path, 'corrupt-secret-test-only')
    response = read_url(row['url'])
    assert_equal '503', response.code
    refute_includes response.body, 'corrupt-secret-test-only'
    assert_equal '503', request('POST', '/api/identity').code
    assert_equal 'corrupt-secret-test-only', File.read(path)
  end

  def test_unwritable_store_rejects_update_without_altering_existing_snapshot
    browser, = identity
    row = create(browser)
    directory = File.join(@directory, 'data')
    skip 'root bypasses filesystem write permissions' if Process.uid.zero?
    File.chmod(0o500, directory)
    begin
      assert_equal '503', request('PUT', "/api/subscriptions/#{row['id']}", { config: CONFIG + "# new\n" }, cookie: browser).code
      assert_equal CONFIG, read_url(row['url']).body
    ensure
      File.chmod(0o700, directory)
    end
  end

  def test_legacy_transient_cache_is_bounded_and_apis_still_work
    ids = 33.times.map do
      response = request('POST', '/api/v1/configs', { values: { proxy_providers: [], local_proxies: [] } })
      assert_equal '201', response.code
      json(response)['id']
    end
    refute_equal '200', request('GET', "/api/v1/configs/#{ids.first}").code
    assert_equal '200', request('GET', "/api/v1/configs/#{ids.last}/download").code
  end
end
