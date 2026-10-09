# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'timeout'
require_relative '../lib/subscription_store'
require_relative '../lib/web_security'

class SubscriptionStoreTest < Minitest::Test
  CONFIG = "mixed-port: 7890\nsecret: test-only\nproxy-groups: []\nrules: []\n"

  def setup
    @directory = Dir.mktmpdir
    @store = SubscriptionStore.new(@directory)
    @session, @recovery = @store.identity(nil)
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def test_credentials_are_distinct_hash_only_and_recovery_is_reusable_until_reset
    row = @store.change(@session, :create, nil, CONFIG)
    assert_equal 64, row['token'].size
    assert_equal 3, [@session, @recovery, row['token']].uniq.size
    bytes = File.binread(File.join(@directory, 'subscriptions.sqlite3'))
    refute_includes bytes, @session
    refute_includes bytes, @recovery
    assert_includes bytes, @store.digest(@session)
    assert_includes bytes, @store.digest(@recovery)
    session, code = @store.recover(@recovery)
    assert_nil code
    refute_equal @session, session
    assert_equal row, @store.list(session).first
    assert_equal row, @store.list(@session).first
    another, = @store.recover(@recovery)
    assert_equal row, @store.list(another).first
    rotated = @store.recovery(session)
    assert_raises(WebError) { @store.recover(@recovery) }
    assert @store.recover(rotated)
    [@session, session, another].each { |device| assert_equal row, @store.list(device).first }
    assert_raises(WebError) { @store.list(row['token']) }
  end

  def test_permissions_restart_and_atomic_rejection
    row = @store.change(@session, :create, nil, CONFIG)
    assert_equal 0o700, File.stat(@directory).mode & 0o777
    Dir.children(@directory).each { |name| assert_equal 0o600, File.stat(File.join(@directory, name)).mode & 0o777 }
    store = SubscriptionStore.new(@directory)
    assert_equal CONFIG, store.read(row['token'])
    [nil, {}, 'proxies: []', "rules: [", 'x' * (SubscriptionStore::MAX_CONFIG + 1),
     "nested: #{'[' * 100}0#{']' * 100}", "#{CONFIG}---\n#{CONFIG}"].each do |bad|
      assert_raises(WebError) { store.change(@session, :update, row['id'], bad) }
      assert_equal CONFIG, store.read(row['token'])
    end
    refute Dir.children(@directory).any? { |name| name.start_with?('.subscriptions-') }
  end

  def test_normal_anchors_alias_values_and_merges_are_preserved
    config = <<~YAML
      defaults: &defaults
        type: select
        proxies: [DIRECT]
      proxy-groups:
        - <<: *defaults
          name: proxy
      rule_defaults: &rules ["MATCH,proxy"]
      rules: *rules
    YAML
    row = @store.change(@session, :create, nil, config, source: config)
    assert_equal config, @store.read(row['token'])
    assert_equal config, @store.source(@session, row['id'])['source']
  end

  def test_complex_mapping_keys_cycles_and_alias_amplification_are_rejected_promptly
    arrays = "#{CONFIG}a: &a [1]\n"
    merges = "#{CONFIG}a: &a {key: value}\n"
    30.times do |index|
      previous = index.zero? ? 'a' : "a#{index - 1}"
      arrays << "a#{index}: &a#{index} [*#{previous}, *#{previous}]\n"
      merges << "a#{index}: &a#{index} {<<: [*#{previous}, *#{previous}]}\n"
    end
    payloads = [arrays + "? *a29\n: value\n", arrays, merges,
                "#{CONFIG}? [a, b]\n: value\n", "#{CONFIG}key: &key field\n? *key\n: value\n",
                "#{CONFIG}loop: &loop [*loop]\n", "#{CONFIG}missing: *missing\n"]
    # Run potentially expensive regressions in a killable child, not a thread
    # blocked inside Ruby hashing/Psych. A regression must not hang the suite.
    payloads.each_with_index do |payload, index|
      status = nil
      pid = fork do
        %i[validate_config validate_source].each do |validator|
          begin
            @store.send(validator, payload)
            exit! 1
          rescue WebError => error
            exit! 2 unless error.status == 422
          end
        end
        exit! 0
      end
      begin
        _pid, status = Timeout.timeout(2) { Process.wait2(pid) }
        assert status.success?, "payload #{index} was not rejected"
      ensure
        unless status
          begin
            Process.kill('KILL', pid)
          rescue Errno::ESRCH
            # The child may have exited just as the timeout fired.
          end
          begin
            Process.wait(pid)
          rescue Errno::ECHILD
            # wait2 may already have reaped the child at the deadline.
          end
        end
      end
    end
  end

  def test_named_source_is_owner_only_and_replaced_atomically_without_history
    source = "# keep original formatting\nproxy_providers: []\nunused: old-source-only-secret\n"
    row = @store.change(@session, :create, nil, CONFIG, name: '家里电脑', source: source)
    assert_equal '家里电脑', row['name']
    assert_equal true, row['has_source']
    assert_equal source, @store.source(@session, row['id'])['source']
    refute @store.list(@session).first.key?('source')
    assert_equal CONFIG, @store.read(row['token'])
    other, = @store.identity(nil)
    assert_equal 404, assert_raises(WebError) { @store.source(other, row['id']) }.status
    assert_equal 401, assert_raises(WebError) { @store.source(row['token'], row['id']) }.status
    assert_equal source, SubscriptionStore.new(@directory).source(@session, row['id'])['source']
    updated_source = "proxy_providers: []\nport: 7888\n"
    updated = @store.change(@session, :update, row['id'], CONFIG + "# changed\n", name: '新名称', source: updated_source)
    assert_equal row['token'], updated['token']
    assert_equal updated_source, @store.source(@session, row['id'])['source']
    refute_includes File.binread(File.join(@directory, 'subscriptions.sqlite3')), 'old-source-only-secret'
    renamed = @store.change(@session, :rename, row['id'], name: '最终名称')
    assert_equal row['token'], renamed['token']
    assert_equal updated_source, @store.source(@session, row['id'])['source']
    original = File.binread(File.join(@directory, 'subscriptions.sqlite3'))
    ['bad: [', '[]', ' ', 'x' * (SubscriptionStore::MAX_SOURCE + 1), "loop: &loop [*loop]\n"].each do |bad|
      assert_raises(WebError) { @store.change(@session, :update, row['id'], CONFIG, source: bad) }
      assert_equal original, File.binread(File.join(@directory, 'subscriptions.sqlite3'))
    end
    ['', 123, 'x' * 81, "bad\nname"].each do |bad|
      assert_raises(WebError) { @store.change(@session, :rename, row['id'], name: bad) }
      assert_equal original, File.binread(File.join(@directory, 'subscriptions.sqlite3'))
    end
  end

  def test_config_only_updates_clear_stale_sources
    row = @store.change(@session, :create, nil, CONFIG)
    store = SubscriptionStore.new(@directory)
    assert_equal '未命名配置', store.list(@session).first['name']
    assert_nil store.source(@session, row['id'])['source']
    store.change(@session, :update, row['id'], CONFIG, source: 'proxy_providers: []')
    store.change(@session, :update, row['id'], CONFIG + '# from legacy client')
    assert_nil store.source(@session, row['id'])['source']
    assert_equal false, store.list(@session).first['has_source']
  end

  def test_owner_limit_and_subscription_limit
    SubscriptionStore::MAX_PER_OWNER.times { @store.change(@session, :create, nil, CONFIG) }
    error = assert_raises(WebError) { @store.change(@session, :create, nil, CONFIG) }
    assert_equal 409, error.status
    @store.transaction(write: true) do |db|
      (SubscriptionStore::MAX_OWNERS - 1).times do
        @store.send(:insert_owner, db, @store.token, 'session_hash' => @store.digest(@store.token), 'recovery_hash' => @store.digest(@store.token))
      end
    end
    assert_raises(WebError) { @store.identity(nil) }
    assert_equal [nil, nil], @store.identity(@session)
  end

  def test_global_subscription_and_byte_limits
    @store.transaction(write: true) do |db|
      (SubscriptionStore::MAX_SUBSCRIPTIONS / SubscriptionStore::MAX_PER_OWNER).times do
        owner_id = @store.token
        @store.send(:insert_owner, db, owner_id, 'session_hash' => @store.digest(@store.token), 'recovery_hash' => @store.digest(@store.token))
        SubscriptionStore::MAX_PER_OWNER.times do
          @store.send(:insert_subscription, db, @store.token, 'owner' => owner_id, 'token' => @store.token,
                      'name' => 'limit', 'config' => CONFIG, 'source' => nil, 'updated_at' => Time.now.utc.iso8601)
        end
      end
    end
    other, = @store.identity(nil)
    assert_equal 409, assert_raises(WebError) { @store.change(other, :create, nil, CONFIG) }.status
    original = File.binread(File.join(@directory, 'subscriptions.sqlite3'))
    error = assert_raises(WebError) do
      @store.transaction(write: true) { |db| db.execute('UPDATE owners SET storage_bytes = ?', [SubscriptionStore::MAX_BYTES]) }
    end
    assert_equal 409, error.status
    assert_equal original, File.binread(File.join(@directory, 'subscriptions.sqlite3'))
  end

  def test_corrupt_and_missing_data_never_reinitialize
    path = File.join(@directory, 'subscriptions.sqlite3')
    ['', '{}', 'invalid', '{"version":1,"owners":{},"subscriptions":{"x":{}}}'].each do |bad|
      File.write(path, bad)
      assert_raises(StandardError) { SubscriptionStore.new(@directory) }
      assert_equal bad, File.read(path)
    end
    File.unlink(path)
    assert_raises(StandardError) { SubscriptionStore.new(@directory) }
    refute File.exist?(path)
  end

  def test_concurrent_processes_do_not_lose_updates
    children = 4.times.map do
      fork do
        store = SubscriptionStore.new(@directory)
        3.times { store.change(@session, :create, nil, CONFIG) }
        exit! 0
      end
    end
    children.each { |pid| assert Process.wait2(pid).last.success? }
    assert_equal 12, @store.list(@session).size
  end

  def test_canonical_origin_cookie_and_bounded_limiter
    %w[http://example.com https://example.com/path https://user@example.com https://example.com?query=1].each do |origin|
      assert_raises(ArgumentError) { WebSecurity.new(origin) }
    end
    security = WebSecurity.new('https://example.com')
    assert_includes security.cookie('test'), '; Secure'
    assert_includes security.cookie('test'), '; HttpOnly; SameSite=Strict;'
    120.times { security.rate!('127.0.0.1') }
    assert_equal 429, assert_raises(WebError) { security.rate!('127.0.0.1') }.status
    1023.times { |index| security.rate!(index.to_s) }
    assert_raises(WebError) { security.rate!('new-peer') }
    assert_equal 1024, security.instance_variable_get(:@buckets).size
  end
end
