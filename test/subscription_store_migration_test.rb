# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'timeout'
require_relative '../lib/subscription_store'

class SubscriptionStoreMigrationTest < Minitest::Test
  CONFIG = "# exact snapshot\r\nproxy-groups: []\r\nrules: []\r\n"
  SOURCE = "# original source\nproxy_providers: []\nunused: private-source\n"

  def setup
    @directory = Dir.mktmpdir
    @legacy_path = File.join(@directory, 'subscriptions.json')
    @db_path = File.join(@directory, 'subscriptions.sqlite3')
    @lock_path = File.join(@directory, 'subscriptions.lock')
    @session, @recovery, @owner, @id, @read_token = Array.new(5) { SecureRandom.hex(32) }
    @data = {
      'version' => 1,
      'owners' => { @owner => { 'session_hash' => Digest::SHA256.hexdigest(@session), 'recovery_hash' => Digest::SHA256.hexdigest(@recovery) } },
      'subscriptions' => { @id => { 'owner' => @owner, 'token' => @read_token, 'config' => CONFIG, 'updated_at' => '2024-01-02T03:04:05Z' } }
    }
    File.write(@lock_path, '') # Existing JSON deployment's stable lock.
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def write_legacy(data = @data)
    File.binwrite(@legacy_path, JSON.generate(data))
  end

  def test_import_preserves_ids_hashes_exact_payloads_timestamps_and_legacy_defaults
    named_id = SecureRandom.hex(32)
    @data['subscriptions'][named_id] = @data['subscriptions'][@id].merge('token' => SecureRandom.hex(32), 'name' => '工作电脑', 'source' => SOURCE)
    write_legacy
    original = File.binread(@legacy_path)
    store = SubscriptionStore.new(@directory)
    assert_equal [nil, nil], store.identity(@session)
    assert_equal [@id, named_id], store.list(@session).map { |row| row['id'] }
    assert_equal '未命名配置', store.list(@session).first['name']
    assert_equal '2024-01-02T03:04:05Z', store.list(@session).first['updated_at']
    assert_nil store.source(@session, @id)['source']
    assert_equal SOURCE, store.source(@session, named_id)['source']
    assert_equal CONFIG.b, store.read(@read_token.b).b
    assert_equal original, File.binread(@legacy_path)
    assert_equal 0o600, File.stat(@legacy_path).mode & 0o777
    assert_equal SubscriptionStore::MARKER, File.read(@lock_path)
    store.transaction do |db|
      assert_equal @data['owners'][@owner]['session_hash'], db.get_first_value('SELECT session_hash FROM sessions WHERE owner = ?', [@owner])
      assert_in_delta Time.now.to_i + SubscriptionStore::SESSION_TTL, db.get_first_value('SELECT expires_at FROM sessions WHERE owner = ?', [@owner]), 5
      assert_equal @data['owners'][@owner]['recovery_hash'], db.get_first_value('SELECT recovery_hash FROM owners WHERE id = ?', [@owner])
    end
    session, = store.recover(@recovery)
    assert_equal 2, store.list(@session).size
    another, = store.recover(@recovery)
    assert_equal 2, store.list(another).size
    assert_equal CONFIG, SubscriptionStore.new(@directory).read(@read_token)
    assert_equal 2, SubscriptionStore.new(@directory).list(session).size
    refute_includes File.binread(@db_path), @session
    refute_includes File.binread(@db_path), @recovery
  end

  def test_restart_never_reimports_stale_or_corrupt_backup_and_missing_database_fails_closed
    write_legacy
    store = SubscriptionStore.new(@directory)
    reset = store.change(@session, :reset, @id)
    store.change(@session, :update, @id, CONFIG + '# updated', source: SOURCE)
    session, = store.recover(@recovery)
    reset_code = store.recovery(session)
    File.write(@legacy_path, 'corrupt frozen backup')
    restarted = SubscriptionStore.new(@directory)
    assert_equal CONFIG + '# updated', restarted.read(reset['token'])
    assert_equal SOURCE, restarted.source(session, @id)['source']
    assert_equal 404, assert_raises(WebError) { restarted.read(@read_token) }.status
    assert_equal 404, assert_raises(WebError) { restarted.recover(@recovery) }.status
    assert_equal [nil, nil], restarted.recover(reset_code, session)
    write_legacy # Even a valid old backup must not resurrect revoked credentials.
    File.unlink(@db_path)
    assert_equal 503, assert_raises(WebError) { SubscriptionStore.new(@directory) }.status
    assert_equal 503, assert_raises(WebError) { store.identity(nil) }.status
    refute File.exist?(@db_path)
  end

  def test_bad_legacy_data_is_unchanged_and_never_becomes_an_empty_database
    variants = ['', 'garbage', '{}', '{"version":1,"version":1,"owners":{},"subscriptions":{}}']
    invalid_data = [
      ->(data) { data['version'] = 2 },
      ->(data) { data['owners'][@owner]['session_hash'] = 'invalid' },
      ->(data) { data['subscriptions'][@id]['owner'] = SecureRandom.hex(32) },
      ->(data) { data['subscriptions'][@id]['config'] = 'rules: [' },
      ->(data) { data['subscriptions'][@id]['config'] = 'x' * (SubscriptionStore::MAX_CONFIG + 1) },
      ->(data) { data['subscriptions'][@id]['source'] = '[]' },
      ->(data) { data['subscriptions'][@id]['name'] = "bad\nname" },
      ->(data) { data['subscriptions'][@id]['updated_at'] = nil },
      ->(data) { data['owners'][SecureRandom.hex(32)] = data['owners'][@owner].dup },
      ->(data) { data['owners'][SecureRandom.hex(32)] = data['owners'][@owner].merge('session_hash' => SecureRandom.hex(32)) },
      ->(data) { data['owners'][SecureRandom.hex(32)] = data['owners'][@owner].merge('recovery_hash' => SecureRandom.hex(32)) },
      ->(data) { data['subscriptions'][SecureRandom.hex(32)] = data['subscriptions'][@id].dup },
      lambda do |data|
        SubscriptionStore::MAX_PER_OWNER.times do
          data['subscriptions'][SecureRandom.hex(32)] = data['subscriptions'][@id].merge('token' => SecureRandom.hex(32))
        end
      end
    ]
    invalid_data.each do |mutate|
      data = Marshal.load(Marshal.dump(@data))
      mutate.call(data)
      variants << JSON.generate(data)
    end
    variants.each do |bytes|
      File.binwrite(@legacy_path, bytes)
      assert_equal 503, assert_raises(WebError) { SubscriptionStore.new(@directory) }.status
      assert_equal bytes, File.binread(@legacy_path)
      assert_equal '', File.read(@lock_path)
      refute File.exist?(@db_path)
      refute Dir.children(@directory).any? { |name| name.start_with?('.subscriptions-') }
    end
    write_legacy
    assert_equal CONFIG, SubscriptionStore.new(@directory).read(@read_token)
  end

  def test_failed_import_rolls_back_and_can_retry_after_repair
    @data['subscriptions'][SecureRandom.hex(32)] = @data['subscriptions'][@id].dup # SQL UNIQUE fails after first insert.
    write_legacy
    assert_equal 503, assert_raises(WebError) { SubscriptionStore.new(@directory) }.status
    refute File.exist?(@db_path)
    assert_equal '', File.read(@lock_path)
    @data['subscriptions'].delete(@data['subscriptions'].keys.last)
    write_legacy
    assert_equal 1, SubscriptionStore.new(@directory).list(@session).size
  end

  def test_crash_during_import_can_retry_without_partial_public_database
    write_legacy
    crashing_store = Class.new(SubscriptionStore) do
      private

      def insert_subscription(db, id, row)
        super
        exit! 77
      end
    end
    pid = fork { crashing_store.new(@directory) }
    assert_equal 77, Process.wait2(pid).last.exitstatus
    refute File.exist?(@db_path)
    assert_equal '', File.read(@lock_path)
    assert_equal CONFIG, SubscriptionStore.new(@directory).read(@read_token)
    assert_equal 1, SubscriptionStore.new(@directory).list(@session).size
  end

  def test_crash_after_durable_marker_fails_closed_and_complete_temporary_database_is_recoverable
    write_legacy
    crashing_store = Class.new(SubscriptionStore) do
      private

      def mark_initialized(lock)
        super
        exit! 78
      end
    end
    pid = fork { crashing_store.new(@directory) }
    assert_equal 78, Process.wait2(pid).last.exitstatus
    assert_equal SubscriptionStore::MARKER, File.read(@lock_path)
    refute File.exist?(@db_path)
    assert_equal 503, assert_raises(WebError) { SubscriptionStore.new(@directory) }.status
    temporary = Dir.glob(File.join(@directory, '.subscriptions-*.sqlite3')).fetch(0)
    assert_equal 0o600, File.stat(temporary).mode & 0o777
    File.rename(temporary, @db_path) # Operator recovery, with service stopped.
    assert_equal CONFIG, SubscriptionStore.new(@directory).read(@read_token)
  end

  def test_corrupt_sqlite_or_marker_does_not_fall_back_to_json
    write_legacy
    SubscriptionStore.new(@directory)
    File.binwrite(@db_path, 'corrupt-sensitive-database')
    assert_equal 503, assert_raises(WebError) { SubscriptionStore.new(@directory) }.status
    assert_equal 'corrupt-sensitive-database', File.binread(@db_path)
    File.unlink(@db_path)
    File.write(@lock_path, 'partial-marker')
    assert_equal 503, assert_raises(WebError) { SubscriptionStore.new(@directory) }.status
    refute File.exist?(@db_path)
  end

  def test_concurrent_first_start_imports_only_once
    write_legacy
    children = 4.times.map do
      fork do
        store = SubscriptionStore.new(@directory)
        store.change(@session, :create, nil, CONFIG)
        exit! 0
      end
    end
    children.each { |pid| assert Process.wait2(pid).last.success? }
    assert_equal 5, SubscriptionStore.new(@directory).list(@session).size
    assert_equal JSON.generate(@data), File.binread(@legacy_path)
  end
end

class SubscriptionStoreSqliteTest < Minitest::Test
  CONFIG = "proxy-groups: []\nrules: []\n"

  def setup
    @directory = Dir.mktmpdir
    @store = SubscriptionStore.new(@directory)
    @session, @recovery = @store.identity(nil)
    @row = @store.change(@session, :create, nil, CONFIG, source: 'source: original', name: 'original')
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def test_lookup_plans_use_indexes_and_lists_do_not_fetch_payloads
    @store.transaction do |db|
      ["SELECT owner FROM sessions WHERE session_hash = 'x' AND expires_at > 0", "SELECT id FROM owners WHERE recovery_hash = 'x'",
       'SELECT session_hash FROM sessions WHERE expires_at <= 1',
       "SELECT config FROM subscriptions WHERE token = 'x'", "SELECT id FROM subscriptions WHERE owner = 'x'",
       "SELECT source FROM subscriptions WHERE id = 'x' AND owner = 'x'"].each do |sql|
        details = db.execute("EXPLAIN QUERY PLAN #{sql}").map { |row| row['detail'] }.join(' ')
        assert_match(/SEARCH .*USING (COVERING )?INDEX/, details)
        refute_match(/SCAN /, details)
      end
      assert_equal 1, db.get_first_value('PRAGMA foreign_keys')
      assert_equal 1, db.get_first_value('PRAGMA secure_delete')
      assert_equal 2, db.get_first_value('PRAGMA synchronous')
      assert_equal 'delete', db.get_first_value('PRAGMA journal_mode')
    end
    assert_equal %w[has_source id name token updated_at], @store.list(@session).first.keys.sort
    assert_equal CONFIG, @store.read(@row['token'].b)
    assert_equal 'source: original', @store.source(@session, @row['id'].b)['source']
    assert_equal @row['token'], @store.change(@session, :rename, @row['id'].b, name: "quote ' -- 数据")['token']
    assert_equal 404, assert_raises(WebError) { @store.source(@session, "' OR 1=1 --") }.status
  end

  def test_all_public_writes_roll_back_after_injected_storage_failure
    operations = [
      -> { @store.identity(nil) }, -> { @store.recover(@recovery) }, -> { @store.recovery(@session) },
      -> { @store.change(@session, :create, nil, CONFIG) },
      -> { @store.change(@session, :update, @row['id'], CONFIG + '# changed', source: 'source: changed', name: 'changed') },
      -> { @store.change(@session, :rename, @row['id'], name: 'changed') },
      -> { @store.change(@session, :reset, @row['id']) }, -> { @store.change(@session, :delete, @row['id']) }
    ]
    before = File.binread(File.join(@directory, 'subscriptions.sqlite3'))
    operations.each do |operation|
      @store.define_singleton_method(:check_capacity) { |_db| raise SQLite3::IOException, 'sensitive internal error' }
      error = assert_raises(WebError, &operation)
      assert_equal 503, error.status
      refute_includes error.message, 'sensitive'
      @store.singleton_class.remove_method(:check_capacity)
      assert_equal before, File.binread(File.join(@directory, 'subscriptions.sqlite3'))
      assert_equal [@row], @store.list(@session)
      assert_equal 'source: original', @store.source(@session, @row['id'])['source']
      assert_equal CONFIG, @store.read(@row['token'])
    end
    assert @store.recover(@recovery)
  end

  def test_capacity_rejection_rolls_back_update_and_releases_capacity_after_delete
    # Reduce only the test budget; exercise the real per-row accounting path.
    limit = SubscriptionStore::MAX_BYTES
    SubscriptionStore.send(:remove_const, :MAX_BYTES)
    SubscriptionStore.const_set(:MAX_BYTES, 3000)
    before = @store.list(@session)
    assert_equal 409, assert_raises(WebError) { @store.change(@session, :update, @row['id'], CONFIG + '# ' + ('x' * 3000)) }.status
    assert_equal before, @store.list(@session)
    assert_equal CONFIG, @store.read(@row['token'])
    @store.change(@session, :delete, @row['id'])
    created = @store.change(@session, :create, nil, CONFIG + '# ' + ('x' * 2000))
    assert_equal 1, @store.list(@session).size
    assert_equal CONFIG + '# ' + ('x' * 2000), @store.read(created['token'])
  ensure
    SubscriptionStore.send(:remove_const, :MAX_BYTES)
    SubscriptionStore.const_set(:MAX_BYTES, limit)
  end

  def test_recovery_reuses_only_the_matching_live_session_and_supports_many_devices
    assert_equal [nil, nil], @store.recover(@recovery, @session)
    other, other_code = @store.identity(nil)
    recovered, returned_code = @store.recover(@recovery, other)
    assert_nil returned_code
    refute_equal other, recovered
    assert_equal [], @store.list(other)
    assert_equal [@row], @store.list(recovered)
    assert_equal [nil, nil], @store.recover(other_code, other)
    # No small arbitrary device cap or oldest-device eviction.
    sessions = 22.times.map { @store.recover(@recovery).first }
    sessions.each { |session| assert_equal [@row], @store.list(session) }
    assert_equal [@row], @store.list(@session)
    @store.transaction { |db| assert_equal 25, db.get_first_value('SELECT COUNT(*) FROM sessions') }
  end

  def test_session_expiry_prunes_on_creation_but_never_expires_recovery_code
    @store.transaction(write: true) do |db|
      db.execute('UPDATE sessions SET expires_at = ? WHERE session_hash = ?', [Time.now.to_i - 1, @store.digest(@session)])
    end
    assert_equal 401, assert_raises(WebError) { @store.list(@session) }.status
    session, code = @store.recover(@recovery, @session)
    assert_nil code
    refute_equal @session, session
    assert_equal [@row], @store.list(session)
    @store.transaction do |db|
      assert_equal 1, db.get_first_value('SELECT COUNT(*) FROM sessions')
      assert_in_delta Time.now.to_i + SubscriptionStore::SESSION_TTL, db.get_first_value('SELECT expires_at FROM sessions'), 5
    end
    reset = @store.recovery(session)
    assert_equal [@row], @store.list(session)
    assert_equal 404, assert_raises(WebError) { @store.recover(@recovery, session) }.status
    assert @store.recover(reset)
  end

  def test_new_sessions_are_capacity_bounded_but_reuse_succeeds_and_failure_does_not_revoke
    limit = SubscriptionStore::MAX_BYTES
    used = @store.transaction do |db|
      SubscriptionStore::EMPTY_BYTES + %w[owners sessions subscriptions].sum do |table|
        db.get_first_value("SELECT COALESCE(SUM(storage_bytes), 0) FROM #{table}")
      end
    end
    SubscriptionStore.send(:remove_const, :MAX_BYTES)
    SubscriptionStore.const_set(:MAX_BYTES, used)
    before = File.binread(File.join(@directory, 'subscriptions.sqlite3'))
    assert_equal 409, assert_raises(WebError) { @store.recover(@recovery) }.status
    assert_equal 409, assert_raises(WebError) { @store.identity(nil) }.status
    assert_equal [nil, nil], @store.recover(@recovery, @session)
    assert_equal [nil, nil], @store.identity(@session)
    assert_equal [@row], @store.list(@session)
    assert_equal before, File.binread(File.join(@directory, 'subscriptions.sqlite3'))
    # Resetting the recovery hash does not consume space or revoke devices.
    reset = @store.recovery(@session)
    assert_equal [nil, nil], @store.recover(reset, @session)
  ensure
    SubscriptionStore.send(:remove_const, :MAX_BYTES)
    SubscriptionStore.const_set(:MAX_BYTES, limit)
  end

  def test_crashed_writer_rolls_back_on_next_open
    pid = fork do
      store = SubscriptionStore.new(@directory)
      store.transaction(write: true) do |db|
        db.execute('UPDATE subscriptions SET config = ?', [CONFIG + '# uncommitted secret'])
        exit! 79
      end
    end
    assert_equal 79, Process.wait2(pid).last.exitstatus
    assert_equal CONFIG, SubscriptionStore.new(@directory).read(@row['token'])
    assert_equal [@row], @store.list(@session)
  end

  def test_concurrent_recovery_keeps_both_devices_and_cannot_overfill_owner
    pids = 2.times.map do
      fork do
        begin
          SubscriptionStore.new(@directory).recover(@recovery)
          exit! 0
        rescue WebError => error
          exit!(error.status == 404 ? 4 : 9)
        end
      end
    end
    assert_equal [0, 0], pids.map { |pid| Process.wait2(pid).last.exitstatus }.sort
    @store.transaction { |db| assert_equal 3, db.get_first_value('SELECT COUNT(*) FROM sessions') }
    assert_equal [@row], @store.list(@session)
    session, = @store.identity(nil)
    (SubscriptionStore::MAX_PER_OWNER - 1).times { @store.change(session, :create, nil, CONFIG) }
    pids = 2.times.map do
      fork do
        begin
          SubscriptionStore.new(@directory).change(session, :create, nil, CONFIG)
          exit! 0
        rescue WebError => error
          exit!(error.status == 409 ? 4 : 9)
        end
      end
    end
    assert_equal [0, 4], pids.map { |pid| Process.wait2(pid).last.exitstatus }.sort
    assert_equal SubscriptionStore::MAX_PER_OWNER, @store.list(session).size
  end
end
