# frozen_string_literal: true

require 'json'
require 'digest'
require 'securerandom'
require 'fileutils'
require 'psych'
require 'time'
require 'sqlite3'

class WebError < StandardError
  attr_reader :status

  def initialize(status, message)
    @status = status
    super(message)
  end
end

# SQLite owns normal read/write locking. The stable flock file only coordinates
# bootstrap/migration and remembers that an absent database must not be recreated.
class SubscriptionStore
  TOKEN = /\A[0-9a-f]{64}\z/
  MAX_CONFIG = 524_288
  MAX_SOURCE = 524_288
  MAX_NAME = 80
  MAX_BYTES = 32 * 1024 * 1024
  MAX_OWNERS = 1000
  MAX_SUBSCRIPTIONS = 1000
  MAX_PER_OWNER = 20
  SESSION_TTL = 365 * 24 * 60 * 60
  APPLICATION_ID = 0x4d484d53
  MARKER = "sqlite3-v1\n"
  EMPTY_BYTES = JSON.generate('version' => 1, 'owners' => {}, 'sessions' => {}, 'subscriptions' => {}).bytesize

  def initialize(directory)
    @directory = File.expand_path(directory)
    FileUtils.mkdir_p(@directory, mode: 0o700)
    File.chmod(0o700, @directory)
    @path = File.join(@directory, 'subscriptions.sqlite3')
    @legacy_path = File.join(@directory, 'subscriptions.json')
    lock_path = File.join(@directory, 'subscriptions.lock')
    begin
      lock = File.open(lock_path, File::RDWR | File::CREAT | File::EXCL, 0o600)
      fresh = true
    rescue Errno::EEXIST
      lock = File.open(lock_path, File::RDWR)
    end
    begin
      lock.flock(File::LOCK_EX)
      File.chmod(0o600, lock_path)
      marker = lock.read
      raise 'invalid initialization marker' unless marker.empty? || marker == MARKER

      if File.exist?(@path)
        File.chmod(0o600, @path)
        open_database(@path) { |db| verify_database(db) }
        mark_initialized(lock) if marker.empty?
      else
        # Never resurrect the retained JSON backup after SQLite was installed.
        raise 'missing initialized database' unless marker.empty?
        raise 'missing legacy database' unless fresh || File.exist?(@legacy_path)

        legacy = load_legacy if File.exist?(@legacy_path)
        install_database(lock, legacy)
      end
      stat = File.stat(@path)
      @file_identity = [stat.dev, stat.ino]
    ensure
      lock.close
    end
  rescue SQLite3::Exception, SystemCallError, IOError, RuntimeError, WebError
    raise unavailable
  end

  def digest(token)
    Digest::SHA256.hexdigest(token.to_s)
  end

  def token
    SecureRandom.hex(32)
  end

  def transaction(write: false)
    stat = File.stat(@path)
    raise 'database replaced' unless [stat.dev, stat.ino] == @file_identity && stat.size.positive?

    open_database(@path) do |db|
      db.transaction(write ? :immediate : :deferred) do
        verify_version(db)
        changes = db.total_changes
        result = yield db
        check_capacity(db) if write && db.total_changes > changes
        result
      end
    end
  rescue SQLite3::Exception, SystemCallError, IOError, RuntimeError
    raise unavailable
  end

  def owner(db, session)
    id = session_owner(db, session)
    raise WebError.new(401, '浏览器身份已失效，请恢复身份或重新打开我的订阅') unless id

    id
  end

  def identity(session)
    transaction(write: true) do |db|
      next [nil, nil] if session_owner(db, session)
      raise WebError.new(409, '身份容量已满') if db.get_first_value('SELECT COUNT(*) FROM owners') >= MAX_OWNERS

      id, recovery = token, token
      insert_owner(db, id, 'recovery_hash' => digest(recovery))
      [create_session(db, id), recovery]
    end
  end

  def recover(code, session = nil)
    raise WebError.new(404, '恢复码无效') unless code.is_a?(String) && code.match?(TOKEN)

    transaction(write: true) do |db|
      id = db.get_first_value('SELECT id FROM owners WHERE recovery_hash = ?', [digest(code)])
      raise WebError.new(404, '恢复码无效') unless id
      next [nil, nil] if session_owner(db, session) == id

      # Recovery codes are reusable until explicitly reset. Never rotate another
      # device's session, or pretend we can retrieve a stored plaintext code.
      [create_session(db, id), nil]
    end
  end

  def recovery(session)
    transaction(write: true) do |db|
      id = owner(db, session)
      code = token
      db.execute('UPDATE owners SET recovery_hash = ? WHERE id = ?', [digest(code), id])
      code
    end
  end

  def list(session)
    transaction do |db|
      id = owner(db, session)
      db.execute('SELECT id, token, updated_at, name, source IS NOT NULL AS has_source FROM subscriptions WHERE owner = ? ORDER BY rowid', [id]).map do |row|
        row.merge('has_source' => row['has_source'] == 1)
      end
    end
  end

  def summary(id, row)
    { 'id' => id, 'token' => row['token'], 'updated_at' => row['updated_at'],
      'name' => row['name'], 'has_source' => !row['source'].nil? }
  end

  def validate_config(config)
    raise WebError.new(422, '需要有效的完整配置快照') unless config.is_a?(String) && config.bytesize.between?(1, MAX_CONFIG)

    parsed = parse_yaml(config)
    unless parsed.is_a?(Hash) && parsed['proxy-groups'].is_a?(Array) && parsed['rules'].is_a?(Array)
      raise WebError.new(422, '需要完整 Mihomo 配置，而非节点订阅')
    end
  end

  def source(session, id)
    id = id.encode(Encoding::UTF_8) if id.is_a?(String)
    transaction do |db|
      owner_id = owner(db, session)
      row = db.get_first_row('SELECT id, name, source FROM subscriptions WHERE id = ? AND owner = ?', [id, owner_id])
      raise WebError.new(404, '订阅不存在') unless row

      row
    end
  end

  def change(session, action, id = nil, config = nil, name: nil, source: nil)
    id = id.encode(Encoding::UTF_8) if id.is_a?(String)
    transaction(write: true) do |db|
      owner_id = owner(db, session)
      if action == :create
        if db.get_first_value('SELECT COUNT(*) FROM subscriptions') >= MAX_SUBSCRIPTIONS || db.get_first_value('SELECT COUNT(*) FROM subscriptions WHERE owner = ?', [owner_id]) >= MAX_PER_OWNER
          raise WebError.new(409, '订阅容量已满')
        end
        id = token
        row = { 'owner' => owner_id, 'token' => token, 'name' => '未命名配置' }
      else
        row = db.get_first_row('SELECT owner, token, name, config, source, updated_at FROM subscriptions WHERE id = ? AND owner = ?', [id, owner_id])
        raise WebError.new(404, '订阅不存在') unless row
      end
      case action
      when :create, :update
        validate_config(config)
        validate_source(source) unless source.nil?
        row['name'] = validate_name(name) unless name.nil?
        row['config'] = config
        # No history/drafts. A config-only legacy update clears any stale source.
        row['source'] = source
      when :rename
        row['name'] = validate_name(name)
      when :reset
        row['token'] = token
      when :delete
        db.execute('DELETE FROM subscriptions WHERE id = ? AND owner = ?', [id, owner_id])
        next({ 'deleted' => true })
      else
        raise ArgumentError, 'unknown subscription action'
      end
      row['updated_at'] = Time.now.utc.iso8601
      if action == :create
        insert_subscription(db, id, row)
      else
        db.execute('UPDATE subscriptions SET token = ?, name = ?, config = ?, source = ?, updated_at = ?, storage_bytes = ? WHERE id = ? AND owner = ?',
                   [row['token'], row['name'], row['config'], row['source'], row['updated_at'], row_bytes(id, row), id, owner_id])
      end
      summary(id, row)
    end
  end

  def read(token)
    raise WebError.new(404, '订阅不存在') unless token.is_a?(String) && token.match?(TOKEN)

    transaction do |db|
      # HTTP paths arrive as ASCII-8BIT; sqlite3 binds those as BLOB, not TEXT.
      config = db.get_first_value('SELECT config FROM subscriptions WHERE token = ?', [token.encode(Encoding::UTF_8)])
      raise WebError.new(404, '订阅不存在') unless config

      config
    end
  end

  private

  def unavailable
    WebError.new(503, '订阅存储不可用，请检查权限或从备份恢复')
  end

  def open_database(path)
    # No CREATE flag: a missing/unlinked live database must never become empty.
    db = SQLite3::Database.new(path, flags: SQLite3::Constants::Open::READWRITE)
    db.results_as_hash = true
    db.busy_timeout = 5000
    db.execute('PRAGMA foreign_keys = ON')
    db.execute('PRAGMA secure_delete = ON')
    db.execute('PRAGMA synchronous = FULL')
    yield db
  ensure
    db&.close
  end

  def verify_version(db)
    unless db.get_first_value('PRAGMA application_id') == APPLICATION_ID && db.get_first_value('PRAGMA user_version') == 1
      raise 'invalid database version'
    end
  end

  def verify_database(db)
    verify_version(db)
    raise 'invalid database journal mode' unless db.get_first_value('PRAGMA journal_mode') == 'delete'
    raise 'invalid database' unless db.get_first_value('PRAGMA quick_check') == 'ok' && db.execute('PRAGMA foreign_key_check').empty?

    # Check the expected tables as well, including an otherwise empty database.
    db.execute('SELECT id, recovery_hash, storage_bytes FROM owners LIMIT 0')
    db.execute('SELECT session_hash, owner, expires_at, storage_bytes FROM sessions LIMIT 0')
    db.execute('SELECT id, owner, token, name, config, source, updated_at, storage_bytes FROM subscriptions LIMIT 0')
    check_capacity(db)
  end

  def check_capacity(db)
    # Only small integer columns are aggregated; never load/serialize all YAML.
    bytes = EMPTY_BYTES + db.get_first_value('SELECT COALESCE(SUM(storage_bytes), 0) FROM owners') +
            db.get_first_value('SELECT COALESCE(SUM(storage_bytes), 0) FROM sessions') +
            db.get_first_value('SELECT COALESCE(SUM(storage_bytes), 0) FROM subscriptions')
    raise WebError.new(409, '存储容量已满') if bytes > MAX_BYTES
  end

  def row_bytes(id, row)
    JSON.generate(id => row).bytesize - 1
  end

  def session_owner(db, session)
    return unless session.is_a?(String) && session.match?(TOKEN)

    db.get_first_value('SELECT owner FROM sessions WHERE session_hash = ? AND expires_at > ?', [digest(session), Time.now.to_i])
  end

  def create_session(db, owner_id)
    now = Time.now.to_i
    db.execute('DELETE FROM sessions WHERE expires_at <= ?', [now])
    session = token
    insert_session(db, digest(session), owner_id, now + SESSION_TTL)
    session
  end

  def insert_session(db, session_hash, owner_id, expires_at)
    row = { 'owner' => owner_id, 'expires_at' => expires_at }
    db.execute('INSERT INTO sessions (session_hash, owner, expires_at, storage_bytes) VALUES (?, ?, ?, ?)',
               [session_hash, owner_id, expires_at, row_bytes(session_hash, row)])
  end

  def insert_owner(db, id, row)
    row = { 'recovery_hash' => row['recovery_hash'] }
    db.execute('INSERT INTO owners (id, recovery_hash, storage_bytes) VALUES (?, ?, ?)',
               [id, row['recovery_hash'], row_bytes(id, row)])
  end

  def insert_subscription(db, id, row)
    db.execute('INSERT INTO subscriptions (id, owner, token, name, config, source, updated_at, storage_bytes) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
               [id, row['owner'], row['token'], row['name'], row['config'], row['source'], row['updated_at'], row_bytes(id, row)])
  end

  def mark_initialized(lock)
    lock.rewind
    lock.write(MARKER)
    lock.truncate(MARKER.bytesize)
    lock.flush
    lock.fsync
    File.open(@directory) { |directory| directory.fsync }
  end

  def install_database(lock, legacy)
    temporary = File.join(@directory, ".subscriptions-#{token}.sqlite3")
    File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600).close
    open_database(temporary) do |db|
      db.execute('PRAGMA journal_mode = DELETE')
      db.transaction(:immediate) do
        create_schema(db)
        if legacy
          expires_at = Time.now.to_i + SESSION_TTL
          legacy['owners'].each do |id, row|
            insert_owner(db, id, row)
            insert_session(db, row['session_hash'], id, expires_at)
          end
          legacy['subscriptions'].each do |id, row|
            insert_subscription(db, id, { 'owner' => row['owner'], 'token' => row['token'],
                                         'name' => row.fetch('name', '未命名配置'), 'config' => row['config'],
                                         'source' => row['source'], 'updated_at' => row['updated_at'] })
          end
        end
        check_capacity(db)
      end
      verify_database(db)
    end
    File.open(temporary) { |file| file.fsync }
    # Marker is durable BEFORE publication. A crash in this narrow window fails
    # closed rather than reimporting stale credentials from the JSON backup.
    mark_initialized(lock)
    File.rename(temporary, @path)
    File.open(@directory) { |directory| directory.fsync }
  ensure
    File.unlink(temporary) if temporary && File.exist?(temporary)
  end

  def create_schema(db)
    hex = "length(%s) = 64 AND %s NOT GLOB '*[^0-9a-f]*'"
    db.execute_batch(<<~SQL)
      CREATE TABLE owners (
        id TEXT PRIMARY KEY NOT NULL CHECK (#{hex % %w[id id]}),
        recovery_hash TEXT NOT NULL UNIQUE CHECK (#{hex % %w[recovery_hash recovery_hash]}),
        storage_bytes INTEGER NOT NULL CHECK (storage_bytes > 0)
      ) STRICT;
      CREATE TABLE sessions (
        session_hash TEXT PRIMARY KEY NOT NULL CHECK (#{hex % %w[session_hash session_hash]}),
        owner TEXT NOT NULL REFERENCES owners(id),
        expires_at INTEGER NOT NULL CHECK (expires_at > 0),
        storage_bytes INTEGER NOT NULL CHECK (storage_bytes > 0)
      ) STRICT;
      CREATE INDEX sessions_owner ON sessions(owner);
      CREATE INDEX sessions_expiry ON sessions(expires_at);
      CREATE TABLE subscriptions (
        id TEXT PRIMARY KEY NOT NULL CHECK (#{hex % %w[id id]}),
        owner TEXT NOT NULL REFERENCES owners(id),
        token TEXT NOT NULL UNIQUE CHECK (#{hex % %w[token token]}),
        name TEXT NOT NULL CHECK (length(name) BETWEEN 1 AND #{MAX_NAME}),
        config TEXT NOT NULL CHECK (length(CAST(config AS BLOB)) BETWEEN 1 AND #{MAX_CONFIG}),
        source TEXT CHECK (source IS NULL OR length(CAST(source AS BLOB)) BETWEEN 1 AND #{MAX_SOURCE}),
        updated_at TEXT NOT NULL,
        storage_bytes INTEGER NOT NULL CHECK (storage_bytes > 0)
      ) STRICT;
      CREATE INDEX subscriptions_owner ON subscriptions(owner);
      PRAGMA application_id = #{APPLICATION_ID};
      PRAGMA user_version = 1;
    SQL
  end

  # Older JSON gems ignore allow_duplicate_key, so retain a duplicate-checking
  # object class too. Never silently discard ambiguous legacy credentials.
  class LegacyObject < Hash
    def []=(key, value)
      raise 'duplicate legacy key' if key?(key)

      super
    end
  end

  def load_legacy
    File.chmod(0o600, @legacy_path)
    raise 'invalid store size' unless File.size(@legacy_path).between?(1, MAX_BYTES)

    data = JSON.parse(File.binread(@legacy_path), object_class: LegacyObject, allow_duplicate_key: false)
    valid = data.is_a?(Hash) && data['version'] == 1 && data['owners'].is_a?(Hash) && data['subscriptions'].is_a?(Hash)
    raise 'invalid store' unless valid
    raise 'invalid store limits' if data['owners'].size > MAX_OWNERS || data['subscriptions'].size > MAX_SUBSCRIPTIONS

    data['owners'].each do |id, row|
      raise 'invalid owner' unless id.match?(TOKEN) && row.is_a?(Hash) && %w[session_hash recovery_hash].all? { |key| row[key].is_a?(String) && row[key].match?(TOKEN) }
    end
    counts = Hash.new(0)
    data['subscriptions'].each do |id, row|
      unless id.match?(TOKEN) && row.is_a?(Hash) && data['owners'].key?(row['owner']) && row['token'].is_a?(String) && row['token'].match?(TOKEN) && row['updated_at'].is_a?(String)
        raise 'invalid subscription'
      end
      counts[row['owner']] += 1
      raise 'invalid owner subscription limit' if counts[row['owner']] > MAX_PER_OWNER

      validate_config(row['config'])
      validate_name(row['name']) if row.key?('name')
      validate_source(row['source']) unless row['source'].nil?
    end
    data
  rescue StandardError
    raise unavailable
  end

  def validate_name(name)
    unless name.is_a?(String) && name.strip.length.between?(1, MAX_NAME) && !name.match?(/[[:cntrl:]]/)
      raise WebError.new(422, '名称需为 1–80 个字符，不能包含控制字符')
    end
    name.strip
  end

  def validate_source(source)
    unless source.is_a?(String) && source.bytesize.between?(1, MAX_SOURCE) && parse_yaml(source).is_a?(Hash)
      raise WebError.new(422, '源配置必须是有效的 values.yaml 映射，且不超过 512 KiB')
    end
  end

  def parse_yaml(text)
    # The same pre-materialization safeguards apply to snapshots AND sources.
    tree = Psych.parse_stream(text)
    raise WebError.new(422, 'YAML 配置无效') unless tree.children.size == 1

    yaml_work(tree, {})
    Psych.safe_load(text, aliases: true)
  rescue Psych::Exception, ArgumentError
    raise WebError.new(422, 'YAML 配置无效')
  end

  # Count an alias's cached subtree cost, not just its single syntax node. This
  # bounds repeated merge/copy work without actually expanding shared subtrees.
  def yaml_work(node, anchors, depth = 0)
    raise WebError.new(422, '配置结构过于复杂') if depth > 64

    if node.is_a?(Psych::Nodes::Alias)
      cost = anchors[node.anchor]
      raise WebError.new(422, '配置包含循环或无效别名') unless cost

      return cost
    end
    if node.is_a?(Psych::Nodes::Mapping)
      unless node.children.each_slice(2).all? { |key, _value| key.is_a?(Psych::Nodes::Scalar) }
        raise WebError.new(422, '配置映射键必须为标量')
      end
    end
    anchor = node.respond_to?(:anchor) && node.anchor
    anchors[anchor] = nil if anchor # Incomplete anchors cannot reference themselves.
    cost = 1
    (node.children || []).each do |child|
      cost += yaml_work(child, anchors, depth + 1)
      raise WebError.new(422, '配置展开后过于复杂') if cost > 100_000
    end
    anchors[anchor] = cost if anchor
    cost
  end
end
