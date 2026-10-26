import * as monaco from 'monaco-editor/esm/vs/editor/editor.api';
import { configureMonacoYaml } from 'monaco-yaml';
import EditorWorker from 'monaco-editor/esm/vs/editor/editor.worker?worker';
import YamlWorker from 'monaco-yaml/yaml.worker?worker';
import mihomoSchema from '../meta-json-schema.json';

const VALUES_URI = 'inmemory://mihomo/values.yaml';
const MIHOMO_SCHEMA_URI = 'inmemory://mihomo/schema.json';

const valuesSchema = {
  $schema: 'http://json-schema.org/draft-07/schema#',
  type: 'object',
  additionalProperties: false,
  properties: {
    port: { type: 'integer', minimum: 1, maximum: 65535, description: '混合端口' },
    web_port: { type: 'integer', minimum: 1, maximum: 65535, description: 'Web 控制端口' },
    tun_device: { type: 'string' },
    dns_split_cn_foreign: { type: 'boolean' },
    group_mode: { enum: ['simple', 'detailed'] },
    'group-mode': { enum: ['simple', 'detailed'] },
    web_secret: { type: 'string' },
    external_ui: { type: 'string' },
    'external-ui': { type: 'string' },
    external_ui_url: { type: 'string' },
    'external-ui-url': { type: 'string' },
    proxy_providers: { type: 'array', items: { type: 'object' } },
    group_providers: { type: 'object', additionalProperties: { type: 'array', items: { type: 'string' } } },
    local_proxies: { type: 'array', items: { type: 'object' } },
    local_proxy_groups: { type: 'array', items: { type: 'object' } },
    failover: { type: ['object', 'null'] },
    wireguard: { type: 'array', items: { type: 'object' } },
    proxy_rules: { type: 'array', items: { type: 'string' } },
    direct_rules: { type: 'array', items: { type: 'string' } },
    group_rules: { type: 'object' },
    local_rules: { type: 'array', items: { type: 'string' } },
    custom_rule_providers: { type: 'array', items: { type: 'object' } },
    url_test: { type: 'object' },
    fake_ip_filter_mode: { enum: ['basic', 'compat'] },
    fake_ip_filter: { type: 'array', items: { type: 'string' } },
    'fake-ip-filter': { type: 'array', items: { type: 'string' } },
    config_overrides: { $ref: MIHOMO_SCHEMA_URI }
  }
};

window.MonacoEnvironment = {
  getWorker(_moduleId, label) {
    return label === 'yaml' ? new YamlWorker() : new EditorWorker();
  }
};

configureMonacoYaml(monaco, {
  completion: true,
  enableSchemaRequest: false,
  format: true,
  hover: true,
  validate: true,
  schemas: [
    { uri: VALUES_URI, fileMatch: [VALUES_URI], schema: valuesSchema },
    { uri: MIHOMO_SCHEMA_URI, schema: mihomoSchema }
  ]
});

let editor = null;
let model = null;
let theme = document.documentElement.classList.contains('light') ? 'vs' : 'vs-dark';

window.MihomoMonacoEditor = {
  create(host, value, onChange, onEscape) {
    if (!model) {
      model = monaco.editor.createModel(value || '', 'yaml', monaco.Uri.parse(VALUES_URI));
      model.onDidChangeContent(() => onChange?.(model.getValue()));
    } else if (model.getValue() !== value) {
      model.setValue(value || '');
    }
    if (!editor) {
      editor = monaco.editor.create(host, {
        model,
        automaticLayout: true,
        minimap: { enabled: false },
        lineNumbers: 'on',
        lineNumbersMinChars: 3,
        wordWrap: 'off',
        tabSize: 2,
        insertSpaces: true,
        detectIndentation: false,
        folding: true,
        renderWhitespace: 'selection',
        scrollBeyondLastLine: false,
        smoothScrolling: false,
        fontSize: 13,
        fontFamily: 'ui-monospace, SFMono-Regular, Consolas, monospace',
        theme
      });
      // Esc leaves the editor unless a Monaco widget (suggest/find/hints) should consume it.
      editor.addCommand(monaco.KeyCode.Escape, () => onEscape?.(),
        '!suggestWidgetVisible && !findWidgetVisible && !parameterHintsVisible && !renameInputVisible');
    }
    editor.layout();
    return this;
  },
  getValue() {
    return model ? model.getValue() : '';
  },
  setValue(value) {
    if (model && model.getValue() !== value) model.setValue(value || '');
  },
  focus() {
    editor?.focus();
  },
  layout() {
    editor?.layout();
  },
  setTheme(light) {
    theme = light ? 'vs' : 'vs-dark';
    monaco.editor.setTheme(theme);
  }
};
