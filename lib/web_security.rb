# frozen_string_literal: true

require 'uri'
require 'time'

class WebSecurity
  MAX_BODY = 1_048_576
  MAX_HEADERS = 16_384
  READ_SECONDS = 5

  attr_reader :base_url

  def initialize(base_url)
    uri = URI.parse(base_url)
    loopback = %w[127.0.0.1 localhost [::1]].include?(uri.host)
    unless %w[https http].include?(uri.scheme) && uri.host && (uri.scheme == 'https' || loopback) &&
           !uri.userinfo && !uri.query && !uri.fragment && ['', '/'].include?(uri.path)
      raise ArgumentError, 'PUBLIC_BASE_URL must be an HTTPS origin or loopback HTTP origin'
    end
    @base_url = "#{uri.scheme}://#{uri.host}#{uri.port == uri.default_port ? '' : ":#{uri.port}"}"
    @secure = uri.scheme == 'https'
    @authority = @base_url.split('://', 2).last
    @buckets = {}
  end

  def cookie(session)
    "mihomo_session=#{session}; Path=/; HttpOnly; SameSite=Strict; Max-Age=31536000#{@secure ? '; Secure' : ''}"
  end

  def session(headers)
    headers.fetch('cookie', '').split(';').filter_map do |pair|
      key, value = pair.strip.split('=', 2)
      value if key == 'mihomo_session'
    end.first
  end

  def mutation!(headers)
    unless headers['origin'] == @base_url && headers['host'] == @authority &&
           headers['x-mihomo-request'] == '1' && headers['content-type'].to_s.match?(%r{\Aapplication/json(?:;\s*charset=utf-8)?\z}i) &&
           (!headers['sec-fetch-site'] || headers['sec-fetch-site'] == 'same-origin')
      raise WebError.new(403, '请求来源校验失败')
    end
  end

  # Direct peer only: forwarded addresses are never trusted. Fixed windows and a
  # global bucket bound both work and limiter memory, including unknown IPs.
  def rate!(peer)
    window = (Process.clock_gettime(Process::CLOCK_MONOTONIC) / 60).floor
    if @window != window
      @window = window
      @buckets.clear
      @global = 0
    end
    @global += 1
    raise WebError.new(429, '请求过于频繁，请稍后重试') if @global > 1200 || (!@buckets.key?(peer) && @buckets.size >= 1024)

    @buckets[peer] = @buckets.fetch(peer, 0) + 1
    raise WebError.new(429, '请求过于频繁，请稍后重试') if @buckets[peer] > 120
  end

  def read_request(socket)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + READ_SECONDS
    buffer = +''.b
    until buffer.include?("\r\n\r\n")
      raise WebError.new(431, '请求头过大') if buffer.bytesize >= MAX_HEADERS

      buffer << read_chunk(socket, [1024, MAX_HEADERS - buffer.bytesize].min, deadline)
    end
    head, body = buffer.split("\r\n\r\n", 2)
    lines = head.split("\r\n")
    method, path, version = lines.shift.to_s.split(' ')
    raise WebError.new(400, '请求无效') unless %w[HTTP/1.0 HTTP/1.1].include?(version) && path&.start_with?('/')

    headers = {}
    lines.each do |line|
      key, value = line.split(':', 2)
      key = key.downcase
      raise WebError.new(400, '请求头无效') unless value && key.match?(/\A[a-z0-9-]+\z/) && !headers.key?(key)

      headers[key] = value.strip
    end
    length = headers.fetch('content-length', '0')
    raise WebError.new(400, '请求长度无效') unless length.match?(/\A\d{1,10}\z/) && !headers.key?('transfer-encoding')
    raise WebError.new(413, '请求内容过大') if length.to_i > MAX_BODY

    # Reject unsafe management requests before reading or parsing their body.
    mutation!(headers) if path.start_with?('/api/subscriptions', '/api/identity') && method != 'GET'
    while body.bytesize < length.to_i
      body << read_chunk(socket, [16_384, length.to_i - body.bytesize].min, deadline)
    end
    [method, path, headers, body.byteslice(0, length.to_i)]
  end

  def write_response(socket, response)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + READ_SECONDS
    offset = 0
    while offset < response.bytesize
      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      break unless remaining.positive? && IO.select(nil, [socket], nil, remaining)

      written = socket.write_nonblock(response.byteslice(offset, 16_384), exception: false)
      offset += written if written.is_a?(Integer)
    end
  end

  private

  def read_chunk(socket, size, deadline)
    loop do
      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      raise WebError.new(408, '请求超时') unless remaining.positive? && IO.select([socket], nil, nil, remaining)

      chunk = socket.read_nonblock(size, exception: false)
      next if chunk == :wait_readable
      raise WebError.new(400, '请求不完整') unless chunk

      return chunk
    end
  end
end
