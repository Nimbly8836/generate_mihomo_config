// Built-in Node test runner only; no Node dependency in the Web container.
const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const os = require("node:os");
const { spawnSync } = require("node:child_process");

const html = fs.readFileSync(path.join(__dirname, "../web/index.html"), "utf8");
const script = html.match(/<script>([\s\S]*?)<\/script>/)[1];

test("primary form guidance is concise and describes Clash subscriptions", () => {
  for (const text of [
    '直接填写参数，或编辑完整',
    '配置入口端口、分组模式与 Web 密钥。',
    '添加节点来源，支持多个订阅。',
  ]) assert.equal(html.includes(text), false, text);
  const providersHint = html.match(/<p id="providers-hint"[^>]*>(.*?)<\/p>/)[1];
  assert.match(providersHint, /Clash 类型的订阅链接/);
  assert.doesNotMatch(providersHint, /不是分流规则集/);
  assert.match(html, /id="group-mode-hint"[^>]*>simple：基础分类；detailed：增加具体服务分组。/);
});

test("IP4P lives only in the collapsed advanced settings", () => {
  const basic = html.match(/<section id="general"[\s\S]*?<\/section>/)[0];
  const advanced = html.slice(html.indexOf('<details id="advanced-settings"'), html.indexOf('<div id="file-editor"'));
  assert.doesNotMatch(basic, /name="ip4p"|实验功能/);
  assert.match(advanced, /<section id="experimental">/);
  assert.match(advanced, /name="ip4p"/);
  assert.doesNotMatch(advanced.match(/<details[^>]*>/)[0], /\bopen(?:\s|=|>)/);
  assert.equal((html.match(/name="ip4p"/g) || []).length, 1);
});

test("download is only offered in the result dialog with a concise label", () => {
  const form = html.match(/<form id="form"[\s\S]*?<\/form>/)[0];
  const dialog = html.match(/<dialog id="result-dialog"[\s\S]*?<\/dialog>/)[0];
  assert.equal(/id="download"/.test(form), false);
  assert.match(dialog, /<button id="download"[^>]*>下载配置<\/button>/);
  assert.equal((html.match(/id="download"/g) || []).length, 1);
});

test("advanced features start collapsed after the two primary sections", () => {
  const opening = html.match(/<details id="advanced-settings"[^>]*>/);
  assert.ok(opening, 'advanced settings disclosure is missing');
  assert.doesNotMatch(opening[0], /\bopen(?:\s|=|>)/);
  const advanced = html.indexOf(opening[0]);
  for (const id of ['general', 'subscriptions']) assert.ok(html.indexOf(`id="${id}"`) < advanced);
  for (const id of ['wireguard', 'custom-rules', 'external-rules']) assert.ok(html.indexOf(`id="${id}"`) > advanced);
  const nav = html.match(/<nav class="section-nav"[\s\S]*?<\/nav>/)[0];
  assert.match(nav, /href="#advanced-settings"/);
  assert.doesNotMatch(nav, /href="#(?:wireguard|custom-rules|external-rules)"/);
});

test("advanced navigation opens the optional controls", () => {
  const { element } = page(false);
  assert.equal(element('#advanced-settings').open, false);
  element('#advanced-link').onclick();
  assert.equal(element('#advanced-settings').open, true);
});

test("invalid advanced controls are revealed without expanding for basic errors", () => {
  const { element } = page(false);
  const invalidField = {};
  element('#advanced-settings').contains = target => target === invalidField;
  assert.equal(element('#form').capture, true);
  element('#form').listeners.invalid({ target: {} });
  assert.equal(element('#advanced-settings').open, false);
  element('#form').listeners.invalid({ target: invalidField });
  assert.equal(element('#advanced-settings').open, true);
});

test("collapsing advanced settings preserves submitted values", async () => {
  const { element, requests } = page(false, {
    ...wgFields(), proxy_rules: 'DOMAIN-SUFFIX,example.com',
    rule_name: ['extra'], rule_url: ['https://example.com/rules.mrs'],
    rule_behavior: ['domain'], rule_format: ['mrs'], rule_policy: ['proxy'],
  });
  element('#advanced-settings').open = false;
  await element('#form').onsubmit({ preventDefault() {} });
  assert.equal(requests[0].values.wireguard[0].name, 'office');
  assert.deepEqual(requests[0].values.proxy_rules, ['DOMAIN-SUFFIX,example.com']);
  assert.equal(requests[0].values.custom_rule_providers[0].name, 'extra');
});

test("successful generation opens a read-only result dialog", async () => {
  const { context, element } = page(false);
  const config = '# 中文配置\n<script>not markup</script>\n';
  context.fetch = async () => ({ ok: true, json: async () => ({ config }) });
  await element('#form').onsubmit({ preventDefault() {} });
  assert.equal(element('#result-dialog').open, true);
  assert.equal(element('#result-config').value, config);
  assert.match(html, /<textarea id="result-config"[^>]*\breadonly\b/);
  assert.match(html, /<dialog id="result-dialog"[^>]*aria-labelledby="result-title"/);
  assert.equal(element('#status').hidden, true);
  assert.equal(typeof element('#download').onclick, 'function');
});

test("closing the preview returns focus to the generate button", async () => {
  const { element } = page(false);
  await element('#form').onsubmit({ preventDefault() {} });
  element('#close-result').onclick();
  assert.equal(element('#result-dialog').open, false);
  assert.equal(element('#generate').focused, true);
});

test("copy uses Clipboard API and gives explicit confirmation", async () => {
  const { context, element } = page(false);
  let copied;
  context.navigator.clipboard = { writeText: async text => { copied = text; } };
  await element('#form').onsubmit({ preventDefault() {} });
  await element('#copy-config').onclick();
  assert.equal(copied, 'test-config');
  assert.equal(element('#copy-message').textContent, '已复制到剪贴板。');
  assert.equal(element('#copy-message').hidden, false);
  assert.equal(element('#copy-config').disabled, false);
});

test("denied clipboard permission falls back to selected-text copy", async () => {
  const { context, element } = page(false);
  context.navigator.clipboard = { writeText: async () => { throw new Error('denied'); } };
  context.document.execCommand = command => { assert.equal(command, 'copy'); return true; };
  await element('#form').onsubmit({ preventDefault() {} });
  await element('#copy-config').onclick();
  assert.equal(element('#result-config').selected, true);
  assert.equal(element('#copy-message').textContent, '已复制到剪贴板。');
});

test("unavailable clipboard offers manual copying without false success", async () => {
  const { context, element } = page(false);
  context.document.execCommand = () => false;
  await element('#form').onsubmit({ preventDefault() {} });
  await element('#copy-config').onclick();
  assert.equal(element('#result-config').selected, true);
  assert.match(element('#copy-message').textContent, /手动复制/);
  assert.equal(element('#copy-config').disabled, false);
});

test("regeneration refreshes preview and clears prior copy feedback", async () => {
  const { context, element } = page(false);
  await element('#form').onsubmit({ preventDefault() {} });
  element('#copy-message').textContent = 'old feedback';
  element('#copy-message').hidden = false;
  element('#result-dialog').close();
  context.fetch = async () => ({ ok: true, json: async () => ({ config: 'new-config' }) });
  await element('#form').onsubmit({ preventDefault() {} });
  assert.equal(element('#result-dialog').open, true);
  assert.equal(element('#result-config').value, 'new-config');
  assert.equal(element('#copy-message').hidden, true);
  assert.equal(element('#copy-message').textContent, '');
});

test("failed generation does not open a success dialog", async () => {
  const { context, element } = page(false);
  context.fetch = async () => ({ ok: false, json: async () => ({ error: '生成失败' }) });
  await element('#form').onsubmit({ preventDefault() {} });
  assert.equal(element('#result-dialog').open, false);
  assert.equal(element('#status').hidden, false);
});

test("decorative numbering and idle status are absent", () => {
  assert.doesNotMatch(html, /section-index|result-label|生成状态|>就绪</);
  const nav = html.match(/<nav class="section-nav"[\s\S]*?<\/nav>/)[0];
  assert.doesNotMatch(nav, /\b0[1-5]\b/);
  assert.match(html, /<pre id="status"[^>]*\bhidden\b/);
});

test("generation progress stays on the button without a success status panel", async () => {
  const { context, element } = page(false);
  let finish;
  context.fetch = () => new Promise(resolve => { finish = resolve; });
  const submitting = element("#form").onsubmit({ preventDefault() {} });
  assert.equal(element("#generate").disabled, true);
  assert.equal(element("#generate").textContent, "生成中…");
  assert.equal(element("#status").hidden, true);
  finish({ ok: true, json: async () => ({ config: "test-config" }) });
  await submitting;
  assert.equal(element("#generate").disabled, false);
  assert.equal(element("#generate").textContent, "生成配置");
  assert.equal(element("#download").disabled, false);
  assert.equal(element("#status").hidden, true);
  assert.equal(element("#status").textContent, "");
});

test("validation errors remain visible and disappear after a successful retry", async () => {
  const { fields, element } = page(false, { proxy_rules: "https://example.com/rules.txt" });
  await element("#form").onsubmit({ preventDefault() {} });
  assert.equal(element("#status").hidden, false);
  assert.match(element("#status").textContent, /外部规则集/);
  assert.equal(element("#generate").textContent, "生成配置");
  fields.proxy_rules = "";
  await element("#form").onsubmit({ preventDefault() {} });
  assert.equal(element("#status").hidden, true);
  assert.equal(element("#status").textContent, "");
});

test("server and network errors are visible and restore the generate button", async () => {
  const failures = [
    async () => ({ ok: false, json: async () => ({ error: "服务错误" }) }),
    async () => { throw new Error("网络错误"); },
  ];
  for (const fail of failures) {
    const { context, element } = page(false);
    context.fetch = fail;
    await element("#form").onsubmit({ preventDefault() {} });
    assert.equal(element("#status").hidden, false);
    assert.match(element("#status").textContent, /错误/);
    assert.equal(element("#generate").disabled, false);
    assert.equal(element("#generate").textContent, "生成配置");
    assert.equal(element("#download").disabled, true);
  }
});

test('repository link and documentation hint appear above the form', () => {
  const header = html.slice(html.indexOf('<body>'), html.indexOf('<form'));
  assert.match(header, /href="https:\/\/github\.com\/Nimbly8836\/generate_mihomo_config"/);
  assert.match(header, /rel="noopener noreferrer"/);
  assert.match(header, /更多说明请参考仓库/);
});

function page(ip4p, extraFields = {}) {
  const elements = new Map();
  const element = (key) => {
    if (!elements.has(key)) {
      elements.set(key, {
        value: "",
        open: false,
        showModal() { this.open = true; },
        close() { this.open = false; this.onclose?.(); },
        focus() { this.focused = true; },
        select() { this.selected = true; },
        classList: {
          toggle() {},
          contains() {
            return false;
          },
        },
        setAttribute() {},
        addEventListener(type, handler, capture) {
          (this.listeners ||= {})[type] = handler;
          this.capture = capture;
        },
        replaceChildren(...children) { this.children = children; },
        append() {},
        content: { cloneNode() { return {}; } },
      });
    }
    return elements.get(key);
  };
  const fields = {
    port: "7890",
    web_port: "9090",
    group_mode: "simple",
    web_secret: "",
    providers: "",
    proxy_rules: "",
    direct_rules: "",
    group_rules: "",
    ip4p: ip4p ? "on" : null,
    ...extraFields,
  };
  const requests = [];
  const context = {
    URL,
    navigator: {},
    document: {
      querySelector: element, documentElement: element("root"),
      createElement() { return {}; }
    },
    localStorage: {
      getItem() {
        return null;
      },
      setItem() {},
    },
    FormData: class {
      get(key) {
        return fields[key] ?? "";
      }
      getAll(key) {
        const value = fields[key];
        return Array.isArray(value) ? value : value == null ? [] : [value];
      }
    },
    fetch: async (_url, options) => {
      requests.push(JSON.parse(options.body));
      return { ok: true, json: async () => ({ config: "test-config" }) };
    },
  };
  vm.runInNewContext(script, context);
  return { context, element, requests, fields };
}

test("IP4P is an opt-in checkbox with a core compatibility notice", () => {
  assert.match(
    html,
    /name="ip4p" type="checkbox" aria-describedby="ip4p-hint"/,
  );
  assert.doesNotMatch(html.match(/<input name="ip4p"[^>]*>/)[0], /\bchecked\b/);
  assert.match(html, /需要支持 dialer-ip4p-convert/);
});

test("checked IP4P is submitted as a final configuration override", async () => {
  const { element, requests } = page(true);
  await element("#form").onsubmit({ preventDefault() {} });
  assert.deepEqual(requests[0].values.config_overrides, {
    experimental: { "dialer-ip4p-convert": true },
  });
  assert.equal(requests[0].values.ipv6, undefined);
  assert.deepEqual(requests[0].values.local_proxies, []);
});

test("unchecked IP4P leaves template defaults untouched", async () => {
  const { element, requests } = page(false);
  await element("#form").onsubmit({ preventDefault() {} });
  assert.equal(requests[0].values.config_overrides, undefined);
});

test("YAML input is not overwritten by the form IP4P checkbox", async () => {
  const { element, requests } = page(true);
  const yaml =
    "config_overrides:\n  experimental:\n    dialer-ip4p-convert: false\n";
  element("#file-values").value = yaml;
  element("#file-mode").onclick();
  await element("#form").onsubmit({ preventDefault() {} });
  assert.equal(requests[0].values, yaml);
});

function wgFields(extra = {}) {
  return {
    wg_name: ['office'], wg_server: ['192.0.2.10'], wg_port: ['51820'],
    wg_ip: ['10.7.0.2'], wg_ipv6: [''],
    wg_private_key: [Buffer.alloc(32, 1).toString('base64')],
    wg_public_key: [Buffer.alloc(32, 2).toString('base64')],
    wg_preshared_key: [''], wg_allowed_ips: ['10.7.0.0/24\n192.168.50.0/24'],
    wg_routes_mode: ['auto'], wg_routes: [''], wg_domains: ['office.internal'],
    wg_ip_version: ['ipv6-prefer'], wg_mtu: ['1420'], wg_keepalive: ['25'],
    ...extra,
  };
}

test('WG form emits quick configuration, not a generic local proxy', async () => {
  const { element, requests } = page(true, wgFields());
  await element('#form').onsubmit({ preventDefault() {} });
  const values = requests[0].values;
  assert.equal(values.wireguard.length, 1);
  assert.equal(values.wireguard[0].name, 'office');
  assert.equal(values.wireguard[0].port, 51820);
  assert.deepEqual(values.wireguard[0]['allowed-ips'], ['10.7.0.0/24', '192.168.50.0/24']);
  assert.deepEqual(values.wireguard[0].domains, ['office.internal']);
  assert.equal(values.wireguard[0]['ip-version'], 'ipv6-prefer');
  assert.equal(values.wireguard[0].mtu, 1420);
  assert.equal(values.wireguard[0]['persistent-keepalive'], 25);
  assert.equal(values.wireguard[0].routes, undefined);
  assert.equal(values.wireguard[0]['pre-shared-key'], undefined);
  assert.deepEqual(values.local_proxies, []);
  assert.equal(values.config_overrides.experimental['dialer-ip4p-convert'], true);
});

test('domain-only WG explicitly sends an empty routes list', async () => {
  const { element, requests } = page(false, wgFields({
    wg_routes_mode: ['domains'], wg_allowed_ips: ['0.0.0.0/0'],
  }));
  await element('#form').onsubmit({ preventDefault() {} });
  assert.deepEqual(requests[0].values.wireguard[0].routes, []);
});

test('external rule provider URLs use a separate values field', async () => {
  const { element, requests } = page(false, {
    rule_name: ['custom_media'], rule_url: ['https://example.com/media.mrs'],
    rule_behavior: ['domain'], rule_format: ['mrs'], rule_policy: ['media'],
    rule_no_resolve: [''],
  });
  await element('#form').onsubmit({ preventDefault() {} });
  assert.deepEqual(requests[0].values.custom_rule_providers, [{
    name: 'custom_media', type: 'http', url: 'https://example.com/media.mrs',
    behavior: 'domain', format: 'mrs', policy: 'media',
  }]);
  assert.deepEqual(requests[0].values.proxy_rules, []);
});

test('a URL pasted into proxy_rules is rejected and the form recovers', async () => {
  const { element, requests } = page(false, { proxy_rules: 'https://example.com/list.yaml' });
  await element('#form').onsubmit({ preventDefault() {} });
  assert.equal(requests.length, 0);
  assert.match(element('#status').textContent, /外部规则集/);
  assert.equal(element('#generate').disabled, false);
  assert.equal(element('#download').disabled, true);
});

test('group hint and validation follow simple versus detailed mode', async () => {
  const simple = page(false, { group_rules: 'telegram: DOMAIN-SUFFIX,t.me' });
  assert.match(simple.element('#group-help').textContent, /chat/);
  await simple.element('#form').onsubmit({ preventDefault() {} });
  assert.equal(simple.requests.length, 0);
  assert.match(simple.element('#status').textContent, /分组/);
  const detailed = page(false, { group_mode: 'detailed', group_rules: 'telegram: DOMAIN-SUFFIX,t.me' });
  assert.match(detailed.element('#group-help').textContent, /telegram/);
  await detailed.element('#form').onsubmit({ preventDefault() {} });
  assert.deepEqual(detailed.requests[0].values.group_rules, { telegram: ['DOMAIN-SUFFIX,t.me'] });
});

test('HTML name patterns compile with the browser Unicode-sets flag', () => {
  for (const name of ['wg_name', 'rule_name']) {
    const input = html.match(new RegExp(`name="${name}"[^>]*`))[0];
    const pattern = new RegExp(`^(?:${input.match(/pattern="([^"]+)"/)[1]})$`, 'v');
    assert.ok(pattern.test('office-lan_1'));
    assert.ok(!pattern.test('../invalid'));
  }
});

test('without cards no WG nodes or external providers are submitted', async () => {
  const { element, requests } = page(false);
  await element('#form').onsubmit({ preventDefault() {} });
  assert.deepEqual(requests[0].values.wireguard, []);
  assert.deepEqual(requests[0].values.custom_rule_providers, []);
});

test('multiple WG cards retain independent optional fields and route modes', async () => {
  const fields = Object.fromEntries(Object.entries(wgFields()).map(([key, values]) => [key, [...values, ...values]]));
  fields.wg_name = ['office', 'home'];
  fields.wg_ip = ['10.7.0.2', ''];
  fields.wg_ipv6 = ['', 'fd00:8::2'];
  fields.wg_allowed_ips = ['10.7.0.0/24', 'fd00:8::/64'];
  fields.wg_routes_mode = ['auto', 'custom'];
  fields.wg_routes = ['', 'fd00:8::1/128'];
  fields.wg_preshared_key = ['', Buffer.alloc(32, 3).toString('base64')];
  fields.wg_keepalive = ['25', '0'];
  const { element, requests } = page(false, fields);
  await element('#form').onsubmit({ preventDefault() {} });
  const [office, home] = requests[0].values.wireguard;
  assert.equal(office.routes, undefined);
  assert.deepEqual(home.routes, ['fd00:8::1/128']);
  assert.equal(home.ip, undefined);
  assert.equal(home.ipv6, 'fd00:8::2');
  assert.equal(home['persistent-keepalive'], 0);
  assert.equal(office['pre-shared-key'], undefined);
  assert.equal(home['pre-shared-key'], fields.wg_preshared_key[1]);
});

test('YAML mode disables hidden required controls and bypasses form validation', async () => {
  const { element, requests } = page(false, wgFields({ wg_name: [''], wg_server: [''] }));
  element('#file-values').value = 'wireguard: []\n';
  element('#file-mode').onclick();
  assert.equal(element('#form-editor').disabled, true);
  await element('#form').onsubmit({ preventDefault() {} });
  assert.equal(requests[0].values, 'wireguard: []\n');
  element('#form-mode').onclick();
  assert.equal(element('#form-editor').disabled, false);
});

test('changing group mode updates both hints and policy suggestions', () => {
  const { fields, element } = page(false);
  assert.doesNotMatch(element('#group-help').textContent, /telegram/);
  fields.group_mode = 'detailed';
  element('#form-editor').onchange();
  assert.match(element('#group-help').textContent, /telegram/);
  assert.ok(element('#policy-targets').children.some(option => option.value === 'telegram'));
  fields.group_mode = 'simple';
  element('#form-editor').oninput();
  assert.ok(!element('#policy-targets').children.some(option => option.value === 'telegram'));
});

test('invalid MRS/classical combination is rejected before a request', async () => {
  const { element, requests } = page(false, {
    rule_name: ['custom_rules'], rule_url: ['https://example.com/rules.mrs'],
    rule_behavior: ['classical'], rule_format: ['mrs'], rule_policy: ['proxy'],
  });
  await element('#form').onsubmit({ preventDefault() {} });
  assert.equal(requests.length, 0);
  assert.match(element('#status').textContent, /不支持 classical/);
});

function renderConfig(values) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'mihomo-form-test-'));
  try {
    const input = path.join(directory, 'values.json');
    const output = path.join(directory, 'config.yaml');
    fs.writeFileSync(input, JSON.stringify({ ...values, web_secret: 'form-test-only' }));
    const rendered = spawnSync('ruby', ['generate_mihomo_config.rb', '--values', input, '--output', output], {
      cwd: path.join(__dirname, '..'), encoding: 'utf8', timeout: 15000,
    });
    assert.equal(rendered.status, 0, rendered.stderr);
    const parsed = spawnSync('ruby', ['-rpsych', '-rjson', '-e',
      'puts JSON.generate(Psych.safe_load(File.read(ARGV[0]), aliases: true))', output],
    { encoding: 'utf8', timeout: 15000 });
    assert.equal(parsed.status, 0, parsed.stderr);
    return JSON.parse(parsed.stdout);
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
}

test('suggested built-in groups exactly match generated groups in both modes', async () => {
  for (const group_mode of ['simple', 'detailed']) {
    const { element, requests } = page(false, { group_mode });
    await element('#form').onsubmit({ preventDefault() {} });
    const config = renderConfig(requests[0].values);
    const suggested = element('#policy-targets').children.map(option => option.value).filter(name => !['DIRECT', 'REJECT'].includes(name));
    assert.deepEqual(suggested.sort(), config['proxy-groups'].map(group => group.name).sort());
  }
});

test('combined form values render WG, external provider and selected rules end to end', async () => {
  const { element, requests } = page(true, {
    ...wgFields(), group_rules: 'wg_office: DOMAIN-SUFFIX,files.office.internal',
    proxy_rules: 'DOMAIN-SUFFIX,proxy.example', direct_rules: 'DOMAIN-SUFFIX,direct.example',
    rule_name: ['custom_lan'], rule_url: ['https://example.com/lan.txt'],
    rule_behavior: ['ipcidr'], rule_format: ['text'], rule_policy: ['wg_office'],
    rule_no_resolve: ['no-resolve'],
  });
  await element('#form').onsubmit({ preventDefault() {} });
  const config = renderConfig(requests[0].values);
  const node = config.proxies.find(proxy => proxy.name === 'wg_office_node');
  assert.equal(node['ip-version'], 'ipv6-prefer');
  assert.equal(node['persistent-keepalive'], 25);
  assert.equal(config.experimental['dialer-ip4p-convert'], true);
  assert.deepEqual(config['proxy-groups'].find(group => group.name === 'wg_office').proxies, ['wg_office_node', 'REJECT']);
  assert.ok(!config['proxy-groups'].find(group => group.name === 'my_proxy').proxies.includes('wg_office_node'));
  assert.equal(config['rule-providers'].custom_lan.url, 'https://example.com/lan.txt');
  assert.equal(config['rule-providers'].custom_lan.proxy, 'DIRECT');
  assert.equal(config['rule-providers'].custom_lan.interval, 86400);
  for (const rule of ['DOMAIN-SUFFIX,proxy.example,proxy', 'DOMAIN-SUFFIX,direct.example,DIRECT',
    'DOMAIN-SUFFIX,files.office.internal,wg_office', 'IP-CIDR,10.7.0.0/24,wg_office,no-resolve',
    'RULE-SET,custom_lan,wg_office,no-resolve']) assert.ok(config.rules.includes(rule), rule);
});
