// edcore.main = editor API + all editor contributions (hover, folding, suggest, find, format...).
// editor.api alone has none of them, so hints/folding silently do nothing.
import * as monaco from 'monaco-editor/esm/vs/editor/edcore.main';
// Monarch tokenizer for YAML; without it keys, values and comments share one color.
import 'monaco-editor/esm/vs/basic-languages/yaml/yaml.contribution';
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
  definitions: {
    quickRuleProvider: {
      type: 'object',
      required: ['name', 'behavior', 'format'],
      description: '规则源的策略由所在分区推断，无需填写 policy；兼容旧 policy，但与分区冲突时后端会拒绝。允许 Mihomo 原生规则源字段。',
      properties: {
        name: { type: 'string', minLength: 1, pattern: '^[A-Za-z0-9][A-Za-z0-9_-]*$' },
        behavior: { enum: ['domain', 'ipcidr', 'classical'] },
        format: { enum: ['mrs', 'yaml', 'text'] },
        type: { enum: ['http', 'file'], description: '省略时，有 url 推断为 http，否则由 path 推断为 file。' },
        url: { type: 'string', minLength: 1 },
        path: { type: 'string', minLength: 1 },
        interval: { type: 'integer', minimum: 0 },
        proxy: { type: 'string' },
        policy: { type: 'string', description: '可省略；若填写，必须与所在分区的策略一致（后端校验）。' },
        rule_options: { type: 'array', items: { type: 'string' } }
      },
      additionalProperties: true,
      anyOf: [
        { required: ['url'], properties: { type: { const: 'http' } } },
        {
          required: ['path'],
          properties: { type: { const: 'file' } },
          not: { required: ['url'] }
        }
      ],
      not: { properties: { format: { const: 'mrs' }, behavior: { const: 'classical' } }, required: ['format', 'behavior'] }
    },
    quickRules: {
      description: '兼容旧版规则字符串数组，或使用包含 rules 与 providers 的对象；两项均可省略。规则源策略由所在分区决定。',
      anyOf: [
        { type: 'array', items: { type: 'string' } },
        {
          type: 'object',
          additionalProperties: false,
          properties: {
            rules: { type: 'array', items: { type: 'string' } },
            providers: { type: 'array', items: { $ref: '#/definitions/quickRuleProvider' } }
          }
        }
      ]
    }
  },
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
    proxy_rules: { $ref: '#/definitions/quickRules' },
    direct_rules: { $ref: '#/definitions/quickRules' },
    group_rules: {
      type: 'object',
      description: '按策略组名称配置快捷规则。已有组直接复用；未知组自动创建 select 组，默认选择代理，并提供地区组和 DIRECT 选项。组名不能为空或包含逗号、换行。',
      propertyNames: { type: 'string', minLength: 1, pattern: '^(?![\\s\\S]*[,\\r\\n\\u0000])\\S(?:[\\s\\S]*\\S)?$' },
      additionalProperties: { $ref: '#/definitions/quickRules' }
    },
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

// Colors follow the page's --editor-* palette so the editor matches both page themes.
const yamlRules = palette => [
  { token: 'type', foreground: palette.key },            // mapping keys
  { token: 'string', foreground: palette.string },
  { token: 'number', foreground: palette.number },
  { token: 'keyword', foreground: palette.keyword },     // true / false / null
  { token: 'comment', foreground: palette.comment, fontStyle: 'italic' },
  { token: 'namespace', foreground: palette.keyword },   // &anchor / *alias
  { token: 'tag', foreground: palette.keyword },
  { token: 'operators', foreground: palette.muted },
  { token: 'delimiter', foreground: palette.muted }
];
monaco.editor.defineTheme('mihomo-dark', {
  base: 'vs-dark',
  inherit: true,
  rules: yamlRules({ key: '93c5fd', string: '86efac', number: 'fdba74', keyword: 'd8b4fe', comment: '71717a', muted: 'a1a1aa' }),
  colors: {
    'editor.background': '#18181b',
    'editorGutter.background': '#18181b',
    'editorLineNumber.foreground': '#52525b',
    'editorLineNumber.activeForeground': '#d4d4d8',
    'editor.lineHighlightBackground': '#ffffff08',
    'editor.lineHighlightBorder': '#00000000',
    'editorIndentGuide.background1': '#27272a',
    'editorIndentGuide.activeBackground1': '#3f3f46',
    'scrollbarSlider.background': '#ffffff1f',
    'scrollbarSlider.hoverBackground': '#ffffff33',
    'scrollbarSlider.activeBackground': '#ffffff47',
    'editorOverviewRuler.border': '#00000000'
  }
});
monaco.editor.defineTheme('mihomo-light', {
  base: 'vs',
  inherit: true,
  rules: yamlRules({ key: '1d4ed8', string: '15803d', number: '9a3412', keyword: '7e22ce', comment: '71717a', muted: '52525b' }),
  colors: {
    'editor.background': '#ffffff',
    'editorGutter.background': '#ffffff',
    'editorLineNumber.foreground': '#a1a1aa',
    'editorLineNumber.activeForeground': '#18181b',
    'editor.lineHighlightBackground': '#18181b08',
    'editor.lineHighlightBorder': '#00000000',
    'editorIndentGuide.background1': '#ececf0',
    'editorIndentGuide.activeBackground1': '#d4d4d8',
    'scrollbarSlider.background': '#18181b1f',
    'scrollbarSlider.hoverBackground': '#18181b33',
    'scrollbarSlider.activeBackground': '#18181b47',
    'editorOverviewRuler.border': '#00000000'
  }
});

let editor = null;
let model = null;
let theme = document.documentElement.classList.contains('light') ? 'mihomo-light' : 'mihomo-dark';

// Diagnostics for the values model, sorted by position; severity 8 = error, 4 = warning.
const problems = () => (model ? monaco.editor.getModelMarkers({ resource: model.uri }) : [])
  .filter(marker => marker.severity >= monaco.MarkerSeverity.Warning)
  .sort((a, b) => a.startLineNumber - b.startLineNumber || a.startColumn - b.startColumn)
  .map(marker => ({
    line: marker.startLineNumber,
    column: marker.startColumn,
    severity: marker.severity === monaco.MarkerSeverity.Error ? 'error' : 'warning',
    message: marker.message
  }));

window.MihomoMonacoEditor = {
  create(host, value, onChange, onEscape, onProblems) {
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
        foldingStrategy: 'indentation',
        showFoldingControls: 'always',
        renderWhitespace: 'selection',
        scrollBeyondLastLine: false,
        smoothScrolling: true,
        fontSize: 13,
        lineHeight: 20,
        fontFamily: 'ui-monospace, SFMono-Regular, Consolas, monospace',
        padding: { top: 8, bottom: 8 },
        // Hover / suggest widgets would be clipped by the host's overflow:hidden otherwise.
        fixedOverflowWidgets: true,
        hover: { enabled: true, delay: 300 },
        quickSuggestions: { other: true, comments: false, strings: true },
        suggestOnTriggerCharacters: true,
        // Slim, overlay-style scrollbars instead of the default 14px tracks.
        scrollbar: {
          verticalScrollbarSize: 8,
          horizontalScrollbarSize: 8,
          useShadows: false,
          alwaysConsumeMouseWheel: false
        },
        overviewRulerBorder: false,
        hideCursorInOverviewRuler: true,
        overviewRulerLanes: 2,
        theme
      });
      monaco.editor.onDidChangeMarkers(uris => {
        if (uris.some(uri => uri.toString() === model.uri.toString())) onProblems?.(problems());
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
    theme = light ? 'mihomo-light' : 'mihomo-dark';
    monaco.editor.setTheme(theme);
  },
  foldAll() {
    editor?.getAction('editor.foldAll')?.run();
  },
  unfoldAll() {
    editor?.getAction('editor.unfoldAll')?.run();
  },
  // Fold everything below the top-level keys, leaving the section list visible.
  foldToTopLevel() {
    editor?.getAction('editor.unfoldAll')?.run().then(() => editor.getAction('editor.foldLevel1')?.run());
  },
  format() {
    editor?.getAction('editor.action.formatDocument')?.run();
  },
  revealProblem(line, column) {
    if (!editor) return;
    editor.revealLineInCenter(line);
    editor.setPosition({ lineNumber: line, column });
    editor.focus();
  },
  problems
};
