Generated browser assets for Monaco Editor + monaco-yaml.

Versions:
- monaco-editor 0.52.2
- monaco-yaml 5.2.0
- meta-json-schema 1.19.32

Build from the repository root with:

    npm ci
    npm run build:web

The Mihomo schema is copied to web/meta-json-schema.json and served locally; the editor does not request a CDN at runtime.
