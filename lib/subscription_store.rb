# frozen_string_literal: true

require 'json'
require 'digest'
require 'securerandom'
require 'fileutils'
require 'psych'
require 'time'

class WebError < StandardError
  attr_reader :status

  def initialize(status, message)
    @status = status
    super(message)
  end
end

# One bounded JSON database, protected by a stable flock file and atomic rename.
# Missing/corrupt data after initialization is an error, never a new identity store.
class SubscriptionStore
  TOKEN = /\A[0-9a-f]{64}\z/
  MAX_CONFIG = 524_288
  MAX_SOURCE = 524_288
  MAX_NAME = 80
  MAX_BYTES = 32 * 1024 * 1024
  MAX_OWNERS = 1000
  MAX_SUBSCRIPTIONS = 1000
  MAX_PER_OWNER = 20

  def initialize(directory)
    @directory = File.expand_path(directory)
    FileUtils.mkdir_p(@directory, mode: 0o700)
    File.chmod(0o700, @directory)
    @path = File.join(@directory, 'subscriptions.json')
    lock_path = File.join(@directory, 'subscriptions.lock')
    begin
      lock = File.open(lock_path, File::RDWR | File::CREAT | File::EXCL, 0o600)
      fresh = true
    rescue Errno::EEXIST
      lock = File.open(lock_path, File::RDWR)
    end
    @lock = lock
    File.chmod(0o600, lock_path)
    @lock.flock(File::LOCK_EX)
    if fresh && !File.exist?(@path)
      persist('version' => 1, 'owners' => {}, 'subscriptions' => {})
    end
    load_data
    File.chmod(0o600, @path)
  ensure
    @lock&.flock(File::LOCK_UN)
  end

  def digest(token)
    Digest::SHA256.hexdigest(token.to_s)
  end

  def token
    SecureRandom.hex(32)
  end

  def transaction(write: false)
    @lock.flock(write ? File::LOCK_EX : File::LOCK_SH)
    data = load_data
    result = yield data
    persist(data) if write
    result
  ensure
    @lock.flock(File::LOCK_UN)
  end

  def owner(data, session)
    entry = session.to_s.match?(TOKEN) && data['owners'].find { |_id, row| row['session_hash'] == digest(session) }
    raise WebError.new(401, '浏览器身份已失效，请恢复身份或重新打开我的订阅') unless entry

    entry
  end

  def identity(session)
    transaction(write: true) do |data|
      existing = session.to_s.match?(TOKEN) && data['owners'].values.any? { |row| row['session_hash'] == digest(session) }
      next [nil, nil] if existing
      raise WebError.new(409, '身份容量已满') if data['owners'].size >= MAX_OWNERS

      session, recovery = token, token
      data['owners'][token] = { 'session_hash' => digest(session), 'recovery_hash' => digest(recovery) }
      [session, recovery]
    end
  end

  def recover(code)
    raise WebError.new(404, '恢复码无效或已使用') unless code.is_a?(String) && code.match?(TOKEN)

    transaction(write: true) do |data|
      row = data['owners'].values.find { |item| item['recovery_hash'] == digest(code) }
      raise WebError.new(404, '恢复码无效或已使用') unless row

      session, recovery = token, token
      row.merge!('session_hash' => digest(session), 'recovery_hash' => digest(recovery))
      [session, recovery]
    end
  end

  def recovery(session)
    transaction(write: true) do |data|
      _id, row = owner(data, session)
      code = token
      row['recovery_hash'] = digest(code)
      code
    end
  end

  def list(session)
    transaction do |data|
      id, = owner(data, session)
      data['subscriptions'].filter_map { |key, row| summary(key, row) if row['owner'] == id }
    end
  end

  def summary(id, row)
    { 'id' => id, 'token' => row['token'], 'updated_at' => row['updated_at'],
      'name' => row.fetch('name', '未命名配置'), 'has_source' => !row['source'].nil? }
  end

  def validate_config(config)
    raise WebError.new(422, '需要有效的完整配置快照') unless config.is_a?(String) && config.bytesize.between?(1, MAX_CONFIG)

    parsed = parse_yaml(config)
    unless parsed.is_a?(Hash) && parsed['proxy-groups'].is_a?(Array) && parsed['rules'].is_a?(Array)
      raise WebError.new(422, '需要完整 Mihomo 配置，而非节点订阅')
    end
  end

  def source(session, id)
    transaction do |data|
      owner_id, = owner(data, session)
      row = data['subscriptions'][id]
      raise WebError.new(404, '订阅不存在') unless row && row['owner'] == owner_id

      { 'id' => id, 'name' => row.fetch('name', '未命名配置'), 'source' => row['source'] }
    end
  end

  def change(session, action, id = nil, config = nil, name: nil, source: nil)
    transaction(write: true) do |data|
      owner_id, = owner(data, session)
      rows = data['subscriptions']
      if action == :create
        if rows.size >= MAX_SUBSCRIPTIONS || rows.values.count { |row| row['owner'] == owner_id } >= MAX_PER_OWNER
          raise WebError.new(409, '订阅容量已满')
        end
        id = token
        row = { 'owner' => owner_id, 'token' => token, 'name' => '未命名配置' }
      else
        row = rows[id]
        raise WebError.new(404, '订阅不存在') unless row && row['owner'] == owner_id
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
        rows.delete(id)
        next({ 'deleted' => true })
      end
      row['updated_at'] = Time.now.utc.iso8601
      rows[id] = row
      summary(id, row)
    end
  end

  def read(token)
    transaction do |data|
      row = data['subscriptions'].values.find { |item| item['token'] == token }
      raise WebError.new(404, '订阅不存在') unless row

      row['config']
    end
  end

  private

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

  def load_data
    raise 'invalid store size' unless File.size(@path).between?(1, MAX_BYTES)

    data = JSON.parse(File.binread(@path))
    valid = data.is_a?(Hash) && data['version'] == 1 && data['owners'].is_a?(Hash) && data['subscriptions'].is_a?(Hash)
    raise 'invalid store' unless valid
    raise 'invalid store limits' if data['owners'].size > MAX_OWNERS || data['subscriptions'].size > MAX_SUBSCRIPTIONS

    data['owners'].each do |id, row|
      raise 'invalid owner' unless id.match?(TOKEN) && row.is_a?(Hash) && %w[session_hash recovery_hash].all? { |key| row[key].is_a?(String) && row[key].match?(TOKEN) }
    end
    data['subscriptions'].each do |id, row|
      unless id.match?(TOKEN) && row.is_a?(Hash) && data['owners'].key?(row['owner']) && row['token'].is_a?(String) && row['token'].match?(TOKEN) && row['config'].is_a?(String) && row['config'].bytesize.between?(1, MAX_CONFIG) && row['updated_at'].is_a?(String)
        raise 'invalid subscription'
      end
      validate_name(row['name']) if row.key?('name')
      unless row['source'].nil? || (row['source'].is_a?(String) && row['source'].bytesize.between?(1, MAX_SOURCE))
        raise 'invalid subscription source'
      end
    end
    data
  rescue StandardError
    raise WebError.new(503, '订阅存储不可用，请检查权限或从备份恢复')
  end

  def persist(data)
    bytes = JSON.generate(data)
    raise WebError.new(409, '存储容量已满') if bytes.bytesize > MAX_BYTES

    temporary = File.join(@directory, ".subscriptions-#{token}")
    begin
      File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write(bytes)
        file.flush
        file.fsync
      end
      File.rename(temporary, @path)
      File.open(@directory) { |directory| directory.fsync }
    ensure
      File.unlink(temporary) if File.exist?(temporary)
    end
  end
end
