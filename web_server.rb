#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'open3'
require 'psych'
require 'securerandom'
require 'socket'
require 'tmpdir'

ROOT = File.expand_path(__dir__)
WEB_ROOT = File.join(ROOT, 'web')
GENERATOR = File.join(ROOT, 'generate_mihomo_config.rb')
HOST = ENV.fetch('HOST', '127.0.0.1')
PORT = Integer(ENV.fetch('PORT', '4567'))
MAX_BODY = 1_048_576

def http_response(status, type, body, extra_headers = {})
  reason = { 200 => 'OK', 201 => 'Created', 400 => 'Bad Request', 404 => 'Not Found', 405 => 'Method Not Allowed',
             422 => 'Unprocessable Entity' }.fetch(status)
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
    raise "生成失败：#{stderr.empty? ? stdout : stderr}" unless status.success?

    { 'config' => File.read(output_path), 'message' => stdout.strip }
  end
end

generated_configs = {}

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
    request_line = socket.gets&.strip
    method, path, = request_line.to_s.split(' ')
    headers = {}
    while (line = socket.gets)
      line = line.strip
      break if line.empty?

      key, value = line.split(':', 2)
      headers[key.downcase] = value.to_s.strip if key
    end
    body = socket.read(Integer(headers.fetch('content-length', '0')))

    response = if method == 'GET' && path == '/'
                 http_response(200, 'text/html; charset=utf-8', File.read(File.join(WEB_ROOT, 'index.html')))
               elsif method == 'GET' && path == '/api/v1/health'
                 json_response.call(200, 'status' => 'ok', 'service' => 'mihomo-config-generator')
               elsif method == 'POST' && path == '/api/v1/configs'
                 result = generate_config(JSON.parse(body).fetch('values'))
                 id = SecureRandom.hex(12)
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
  rescue JSON::ParserError, KeyError, ArgumentError => e
    response = http_response(400, 'application/json; charset=utf-8', JSON.generate('error' => e.message))
  rescue StandardError => e
    response = http_response(422, 'application/json; charset=utf-8', JSON.generate('error' => e.message))
  ensure
    socket.write(response) if response
    socket.close
  end
end
