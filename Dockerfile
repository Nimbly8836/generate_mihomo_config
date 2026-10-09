FROM ruby:4.0-slim

ENV HOST=0.0.0.0 \
    PORT=4567 \
    DATA_DIR=/data

WORKDIR /app

# Build the pinned SQLite binding on both AMD64 and ARM64; keep only runtime libs.
RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential pkg-config libsqlite3-dev \
    && gem install sqlite3 --version 2.8.1 --platform ruby --no-document -- --enable-system-libraries \
    && apt-mark manual libsqlite3-0 \
    && apt-get purge -y --auto-remove build-essential pkg-config libsqlite3-dev \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd --gid 10001 app \
    && useradd --uid 10001 --gid app --no-log-init --create-home app \
    && install -d -m 0700 -o 10001 -g 10001 /data

# Explicitly copy application sources only, never private values or output YAML.
COPY generate_mihomo_config.rb config-template.yaml.erb web_server.rb ./
COPY lib/wireguard_config.rb lib/subscription_store.rb lib/web_security.rb ./lib/
COPY web/index.html ./web/index.html
COPY web/favicon.svg ./web/favicon.svg
COPY config-values.example.yaml ./config-values.example.yaml
COPY web/vendor/codemirror/codemirror.js \
     web/vendor/codemirror/codemirror.css \
     web/vendor/codemirror/yaml.js \
     web/vendor/codemirror/LICENSE \
     web/vendor/codemirror/README.md ./web/vendor/codemirror/

USER 10001:10001
EXPOSE 4567

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD ["ruby", "-rnet/http", "-e", "http = Net::HTTP.new('127.0.0.1', Integer(ENV.fetch('PORT', '4567')), nil); http.open_timeout = 2; http.read_timeout = 2; exit(http.get('/api/v1/health').code == '200' ? 0 : 1)"]

CMD ["ruby", "web_server.rb"]
