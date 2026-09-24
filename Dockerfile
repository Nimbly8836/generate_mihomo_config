FROM ruby:4.0-slim

ENV HOST=0.0.0.0 \
    PORT=4567

WORKDIR /app

RUN groupadd --gid 10001 app \
    && useradd --uid 10001 --gid app --no-log-init --create-home app

# Explicitly copy application sources only, never private values or output YAML.
COPY generate_mihomo_config.rb config-template.yaml.erb web_server.rb ./
COPY lib/wireguard_config.rb ./lib/wireguard_config.rb
COPY web/index.html ./web/index.html

USER 10001:10001
EXPOSE 4567

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD ["ruby", "-rnet/http", "-e", "http = Net::HTTP.new('127.0.0.1', Integer(ENV.fetch('PORT', '4567')), nil); http.open_timeout = 2; http.read_timeout = 2; exit(http.get('/api/v1/health').code == '200' ? 0 : 1)"]

CMD ["ruby", "web_server.rb"]
