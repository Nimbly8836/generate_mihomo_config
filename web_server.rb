#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'open3'
require 'psych'
require 'securerandom'
require 'socket'
require 'tmpdir'
require_relative 'lib/subscription_store'
require_relative 'lib/web_security'

File.umask(0o077)

ROOT = File.expand_path(__dir__)
WEB_ROOT = File.join(ROOT, 'web')
GENERATOR = File.join(ROOT, 'generate_mihomo_config.rb')
HOST = ENV.fetch('HOST', '127.0.0.1')
PORT = Integer(ENV.fetch('PORT', '4567'))
MAX_BODY = 1_048_576

# Exact public-file allowlist. Never resolve an arbitrary request path on disk.
PUBLIC_FILES = {
  '/favicon.svg' => ['image/svg+xml; charset=utf-8', File.join(WEB_ROOT, 'favicon.svg')],
  '/examples/values.yaml' => ['text/plain; charset=utf-8', File.join(ROOT, 'config-values.example.yaml')],
  '/assets/codemirror/codemirror.js' => ['text/javascript; charset=utf-8', File.join(WEB_ROOT, 'vendor/codemirror/codemirror.js')],
  '/assets/codemirror/yaml.js' => ['text/javascript; charset=utf-8', File.join(WEB_ROOT, 'vendor/codemirror/yaml.js')],
  '/assets/codemirror/codemirror.css' => ['text/css; charset=utf-8', File.join(WEB_ROOT, 'vendor/codemirror/codemirror.css')],
  '/assets/codemirror/LICENSE' => ['text/plain; charset=utf-8', File.join(WEB_ROOT, 'vendor/codemirror/LICENSE')]
}.freeze

def http_response(status, type, body, extra_headers = {})
  reason = { 200 => 'OK', 201 => 'Created', 400 => 'Bad Request', 401 => 'Unauthorized', 403 => 'Forbidden',
             404 => 'Not Found', 405 => 'Method Not Allowed', 408 => 'Request Timeout', 409 => 'Conflict',
             413 => 'Content Too Large', 422 => 'Unprocessable Entity', 429 => 'Too Many Requests',
             431 => 'Request Header Fields Too Large', 503 => 'Service Unavailable' }.fetch(status)
  extra_headers = { 'Cache-Control' => 'private, no-store', 'Referrer-Policy' => 'no-referrer',
                    'X-Content-Type-Options' => 'nosniff' }.merge(extra_headers)
  headers = extra_headers.map { |key, value| "#{key}: #{value}" }.join("\r\n")
  headers = "#{headers}\r\n" unless headers.empty?
  "HTTP/1.1 #{status} #{reason}\r\nContent-Type: #{type}\r\n#{headers}Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}"
end

def generate_config(values)
  values_yaml = if values.is_a?(Hash)
                  Psych.dump(values)
                elsif values.is_a?(String)
                  values
                else
                  raise ArgumentError, 'values must be a mapping or YAML string'
                end
  raise ArgumentError, 'values must not be empty' if values_yaml.strip.empty?
  raise ArgumentError, 'values is too large' if values_yaml.bytesize > MAX_BODY

  Dir.mktmpdir('mihomo-web') do |directory|
    values_path = File.join(directory, 'values.yaml')
    output_path = File.join(directory, 'config.yaml')
    File.write(values_path, values_yaml)
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, GENERATOR, '--values', values_path, '--output', output_path)
    raise WebError.new(422, '生成失败，请检查配置参数') unless status.success?
    raise WebError.new(422, '生成的配置过大') if File.size(output_path) > SubscriptionStore::MAX_CONFIG

    { 'config' => File.read(output_path), 'message' => '生成成功' }
  end
end

generated_configs = {}
security = WebSecurity.new(ENV.fetch('PUBLIC_BASE_URL', "http://127.0.0.1:#{PORT}"))
begin
  subscriptions = SubscriptionStore.new(ENV.fetch('DATA_DIR', File.join(ROOT, 'data')))
rescue StandardError
  abort '订阅存储不可用；请检查权限或从备份恢复（不会自动清空）。'
end
public_summary = lambda do |row|
  row.reject { |key, _| key == 'token' }.merge('url' => "#{security.base_url}/s/#{row.fetch('token')}")
end

server = TCPServer.new(HOST, PORT)
puts "Mihomo Web UI: http://#{HOST}:#{PORT}"
puts "REST API: http://#{HOST}:#{PORT}/api/v1"

json_response = lambda do |status, payload, headers = {}|
  http_response(status, 'application/json; charset=utf-8', JSON.generate(payload), headers)
end
trap('INT') do
  server.close
  exit
end
trap('TERM') do
  server.close
  exit
end

loop do
  socket = server.accept
  begin
    response = nil
    security.rate!(socket.peeraddr[3])
    method, path, headers, body = security.read_request(socket)
    session = security.session(headers)
    payload = lambda do
      value = JSON.parse(body)
      raise WebError.new(400, '需要 JSON 对象') unless value.is_a?(Hash)

      value
    end

    response = if method == 'POST' && path == '/api/identity'
                 payload.call
                 new_session, recovery = subscriptions.identity(session)
                 cookie = new_session ? { 'Set-Cookie' => security.cookie(new_session) } : {}
                 json_response.call(200, { 'recovery_code' => recovery }, cookie)
               elsif method == 'POST' && path == '/api/identity/recover'
                 new_session, recovery = subscriptions.recover(payload.call['recovery_code'])
                 json_response.call(200, { 'recovery_code' => recovery }, 'Set-Cookie' => security.cookie(new_session))
               elsif method == 'POST' && path == '/api/identity/recovery'
                 payload.call
                 json_response.call(200, 'recovery_code' => subscriptions.recovery(session))
               elsif method == 'GET' && path == '/api/subscriptions'
                 json_response.call(200, 'subscriptions' => subscriptions.list(session).map { |row| public_summary.call(row) })
               elsif method == 'POST' && path == '/api/subscriptions'
                 row = subscriptions.change(session, :create, nil, payload.call['config'])
                 json_response.call(201, public_summary.call(row))
               elsif (match = %r{\A/api/subscriptions/([a-f0-9]{64})(/reset)?\z}.match(path))
                 action = { ['PUT', nil] => :update, ['DELETE', nil] => :delete, ['POST', '/reset'] => :reset }[[method, match[2]]]
                 raise WebError.new(405, '请求方法不支持') unless action

                 row = subscriptions.change(session, action, match[1], payload.call['config'])
                 json_response.call(200, action == :delete ? row : public_summary.call(row))
               elsif method == 'GET' && (match = %r{\A/s/([a-f0-9]{64})\z}.match(path))
                 http_response(200, 'application/yaml; charset=utf-8', subscriptions.read(match[1]),
                               'Content-Disposition' => 'attachment; filename="config.yaml"')
               elsif method == 'GET' && path == '/'
                 http_response(200, 'text/html; charset=utf-8', File.read(File.join(WEB_ROOT, 'index.html')))
               elsif method == 'GET' && PUBLIC_FILES.key?(path)
                 type, file = PUBLIC_FILES.fetch(path)
                 http_response(200, type, File.read(file), 'X-Content-Type-Options' => 'nosniff')
               elsif method == 'GET' && path == '/api/v1/health'
                 json_response.call(200, 'status' => 'ok', 'service' => 'mihomo-config-generator')
               elsif method == 'POST' && path == '/api/v1/configs'
                 result = generate_config(JSON.parse(body).fetch('values'))
                 id = SecureRandom.hex(12)
                 generated_configs.shift while generated_configs.size >= 32
                 generated_configs[id] = result
                 json_response.call(201, result.merge('id' => id, 'download_url' => "/api/v1/configs/#{id}/download"),
                                    'Location' => "/api/v1/configs/#{id}")
               elsif method == 'GET' && (match = %r{\A/api/v1/configs/([a-f0-9]+)/download\z}.match(path))
                 result = generated_configs.fetch(match[1]) { raise KeyError, '配置不存在或已过期' }
                 http_response(200, 'application/yaml; charset=utf-8', result.fetch('config'),
                               'Content-Disposition' => 'attachment; filename="config.yaml"')
               elsif method == 'GET' && (match = %r{\A/api/v1/configs/([a-f0-9]+)\z}.match(path))
                 result = generated_configs.fetch(match[1]) { raise KeyError, '配置不存在或已过期' }
                 json_response.call(200,
                                    result.merge('id' => match[1],
                                                 'download_url' => "/api/v1/configs/#{match[1]}/download"))
               elsif method == 'POST' && path == '/api/generate'
                 result = generate_config(JSON.parse(body).fetch('values'))
                 json_response.call(200, result)
               elsif path == '/api/generate'
                 json_response.call(405, 'error' => '只支持 POST')
               else
                 http_response(404, 'text/plain; charset=utf-8', 'Not Found')
               end
  rescue WebError => e
    response = json_response.call(e.status, 'error' => e.message)
  rescue JSON::ParserError, KeyError, ArgumentError
    response = json_response.call(400, 'error' => '请求参数无效')
  rescue StandardError
    response = json_response.call(503, 'error' => '服务暂不可用，请检查存储或稍后重试')
  ensure
    begin
      security.write_response(socket, response) if response
    rescue IOError, SystemCallError
      # Disconnected clients do not affect the next request; never log secrets.
    ensure
      socket.close
    end
  end
end
