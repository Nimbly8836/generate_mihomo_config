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

test("reference dialog loads the public example without replacing edited YAML", async () => {
  const { context, element } = page(false);
  element("#file-values").value = "web_secret: user-owned\n";
  context.localStorage.setItem = () => {
    throw new Error("unexpected persistence");
  };
  context.fetch = async (url) => {
    assert.equal(url, "/examples/values.yaml");
    return { ok: true, text: async () => "# reference\nwireguard: []\n" };
  };
  await element("#open-reference").onclick();
  assert.equal(element("#reference-dialog").open, true);
  assert.equal(
    element("#reference-values").value,
    "# reference\nwireguard: []\n",
  );
  assert.equal(element("#file-values").value, "web_secret: user-owned\n");
  assert.equal(element("#copy-reference").disabled, false);
  assert.equal(element("#reference-message").hidden, true);
});

test("reference copy uses its own text and closing restores focus", async () => {
  const { context, element } = page(false);
  let copied;
  context.fetch = async () => ({ ok: true, text: async () => "port: 7890\n" });
  context.navigator.clipboard = {
    writeText: async (text) => {
      copied = text;
    },
  };
  await element("#open-reference").onclick();
  await element("#copy-reference").onclick();
  assert.equal(copied, "port: 7890\n");
  assert.equal(element("#reference-message").textContent, "已复制到剪贴板。");
  element("#close-reference").onclick();
  assert.equal(element("#reference-dialog").open, false);
  assert.equal(element("#open-reference").focused, true);
});

test("reference loading failure is visible and retry does not leave stale content", async () => {
  const { context, element } = page(false);
  context.fetch = async () => ({ ok: false });
  await element("#open-reference").onclick();
  assert.equal(element("#copy-reference").disabled, true);
  assert.equal(element("#reference-message").hidden, false);
  assert.match(element("#reference-message").textContent, /失败/);
  element("#reference-dialog").close();
  context.fetch = async () => ({
    ok: true,
    text: async () => "proxy_providers: []\n",
  });
  await element("#open-reference").onclick();
  assert.equal(element("#reference-values").value, "proxy_providers: []\n");
  assert.equal(element("#reference-message").hidden, true);
});

test("YAML editor is initialized once, preserves text and syncs edits to generation", async () => {
  const { context, element, requests } = page(false);
  let options,
    change,
    content,
    created = 0,
    refreshed = 0;
  context.CodeMirror = {
    fromTextArea(textarea, config) {
      created++;
      options = config;
      content = textarea.value;
      return {
        on(event, callback) {
          assert.equal(event, "change");
          change = callback;
        },
        refresh() {
          refreshed++;
        },
        save() {
          textarea.value = content;
        },
      };
    },
  };
  element("#file-values").value = "port: 8000\n";
  element("#file-mode").onclick();
  assert.equal(content, "port: 8000\n");
  assert.equal(options.mode, "yaml");
  assert.equal(options.indentUnit, 2);
  assert.equal(options.tabSize, 2);
  assert.equal(options.indentWithTabs, false);
  assert.equal(options.lineNumbers, true);
  assert.equal(options.lineWrapping, false);
  assert.equal(options.extraKeys.Tab, "indentMore");
  assert.equal(options.extraKeys["Shift-Tab"], "indentLess");
  options.extraKeys.Esc();
  assert.equal(element("#generate").focused, true);
  content = "port: 8001\n";
  change();
  await element("#form").onsubmit({ preventDefault() {} });
  assert.equal(requests[0].values, content);
  element("#form-mode").onclick();
  element("#file-mode").onclick();
  assert.equal(created, 1);
  assert.equal(refreshed, 2);
});

test("YAML editor scripts and styling are served locally without a CDN", () => {
  assert.match(html, /src="\/assets\/codemirror\/codemirror.js"/);
  assert.match(html, /src="\/assets\/codemirror\/yaml.js"/);
  assert.match(html, /href="\/assets\/codemirror\/codemirror.css"/);
  assert.doesNotMatch(html, /<(?:script|link)[^>]*(?:src|href)="https?:/);
});

test("primary form guidance is concise and describes Clash subscriptions", () => {
  for (const text of [
    "直接填写参数，或编辑完整",
    "配置入口端口、分组模式与 Web 密钥。",
    "添加节点来源，支持多个订阅。",
  ])
    assert.equal(html.includes(text), false, text);
  const providersHint = html.match(/<p id="providers-hint"[^>]*>(.*?)<\/p>/)[1];
  assert.match(providersHint, /Clash 类型的订阅链接/);
  assert.doesNotMatch(providersHint, /不是分流规则集/);
  assert.match(
    html,
    /id="group-mode-hint"[^>]*>simple：基础分类；detailed：增加具体服务分组。/,
  );
});

test("IP4P lives only in the collapsed advanced settings", () => {
  const basic = html.match(/<section id="general"[\s\S]*?<\/section>/)[0];
  const advanced = html.slice(
    html.indexOf('<details id="advanced-settings"'),
    html.indexOf('<div id="file-editor"'),
  );
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
  assert.ok(opening, "advanced settings disclosure is missing");
  assert.doesNotMatch(opening[0], /\bopen(?:\s|=|>)/);
  const advanced = html.indexOf(opening[0]);
  for (const id of ["general", "subscriptions"])
    assert.ok(html.indexOf(`id="${id}"`) < advanced);
  for (const id of ["wireguard", "custom-rules", "external-rules"])
    assert.ok(html.indexOf(`id="${id}"`) > advanced);
  const nav = html.match(/<nav class="section-nav"[\s\S]*?<\/nav>/)[0];
  assert.match(nav, /href="#advanced-settings"/);
  assert.doesNotMatch(nav, /href="#(?:wireguard|custom-rules|external-rules)"/);
});

test("advanced navigation opens the optional controls", () => {
  const { element } = page(false);
  assert.equal(element("#advanced-settings").open, false);
  element("#advanced-link").onclick();
  assert.equal(element("#advanced-settings").open, true);
});

test("invalid advanced controls are revealed without expanding for basic errors", () => {
  const { element } = page(false);
  const invalidField = {};
  element("#advanced-settings").contains = (target) => target === invalidField;
  assert.equal(element("#form").capture, true);
  element("#form").listeners.invalid({ target: {} });
  assert.equal(element("#advanced-settings").open, false);
  element("#form").listeners.invalid({ target: invalidField });
  assert.equal(element("#advanced-settings").open, true);
});

test("collapsing advanced settings preserves submitted values", async () => {
  const { element, requests } = page(false, {
    ...wgFields(),
    proxy_rules: "DOMAIN-SUFFIX,example.com",
    rule_name: ["extra"],
    rule_url: ["https://example.com/rules.mrs"],
    rule_behavior: ["domain"],
    rule_format: ["mrs"],
    rule_policy: ["proxy"],
  });
  element("#advanced-settings").open = false;
  await element("#form").onsubmit({ preventDefault() {} });
  assert.equal(requests[0].values.wireguard[0].name, "office");
  assert.deepEqual(requests[0].values.proxy_rules, [
    "DOMAIN-SUFFIX,example.com",
  ]);
  assert.equal(requests[0].values.custom_rule_providers[0].name, "extra");
});

test("successful generation opens a read-only result dialog", async () => {
  const { context, element } = page(false);
  const config = "# 中文配置\n<script>not markup</script>\n";
  context.fetch = async () => ({ ok: true, json: async () => ({ config }) });
  await element("#form").onsubmit({ preventDefault() {} });
  assert.equal(element("#result-dialog").open, true);
  assert.equal(element("#result-config").value, config);
  assert.match(html, /<textarea id="result-config"[^>]*\breadonly\b/);
  assert.match(
    html,
    /<dialog id="result-dialog"[^>]*aria-labelledby="result-title"/,
  );
  assert.equal(element("#status").hidden, true);
  assert.equal(typeof element("#download").onclick, "function");
});

test("closing the preview returns focus to the generate button", async () => {
  const { element } = page(false);
  await element("#form").onsubmit({ preventDefault() {} });
  element("#close-result").onclick();
  assert.equal(element("#result-dialog").open, false);
  assert.equal(element("#generate").focused, true);
});

test("copy uses Clipboard API and gives explicit confirmation", async () => {
  const { context, element } = page(false);
  let copied;
  context.navigator.clipboard = {
    writeText: async (text) => {
      copied = text;
    },
  };
  await element("#form").onsubmit({ preventDefault() {} });
  await element("#copy-config").onclick();
  assert.equal(copied, "test-config");
  assert.equal(element("#copy-message").textContent, "已复制到剪贴板。");
  assert.equal(element("#copy-message").hidden, false);
  assert.equal(element("#copy-config").disabled, false);
});

test("denied clipboard permission falls back to selected-text copy", async () => {
  const { context, element } = page(false);
  context.navigator.clipboard = {
    writeText: async () => {
      throw new Error("denied");
    },
  };
  context.document.execCommand = (command) => {
    assert.equal(command, "copy");
    return true;
  };
  await element("#form").onsubmit({ preventDefault() {} });
  await element("#copy-config").onclick();
  assert.equal(element("#result-config").selected, true);
  assert.equal(element("#copy-message").textContent, "已复制到剪贴板。");
});

test("unavailable clipboard offers manual copying without false success", async () => {
  const { context, element } = page(false);
  context.document.execCommand = () => false;
  await element("#form").onsubmit({ preventDefault() {} });
  await element("#copy-config").onclick();
  assert.equal(element("#result-config").selected, true);
  assert.match(element("#copy-message").textContent, /手动复制/);
  assert.equal(element("#copy-config").disabled, false);
});

test("regeneration refreshes preview and clears prior copy feedback", async () => {
  const { context, element } = page(false);
  await element("#form").onsubmit({ preventDefault() {} });
  element("#copy-message").textContent = "old feedback";
  element("#copy-message").hidden = false;
  element("#result-dialog").close();
  context.fetch = async () => ({
    ok: true,
    json: async () => ({ config: "new-config" }),
  });
  await element("#form").onsubmit({ preventDefault() {} });
  assert.equal(element("#result-dialog").open, true);
  assert.equal(element("#result-config").value, "new-config");
  assert.equal(element("#copy-message").hidden, true);
  assert.equal(element("#copy-message").textContent, "");
});

test("failed generation does not open a success dialog", async () => {
  const { context, element } = page(false);
  context.fetch = async () => ({
    ok: false,
    json: async () => ({ error: "生成失败" }),
  });
  await element("#form").onsubmit({ preventDefault() {} });
  assert.equal(element("#result-dialog").open, false);
  assert.equal(element("#status").hidden, false);
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
  context.fetch = () =>
    new Promise((resolve) => {
      finish = resolve;
    });
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
  const { fields, element } = page(false, {
    proxy_rules: "https://example.com/rules.txt",
  });
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
    async () => {
      throw new Error("网络错误");
    },
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

test("repository link and documentation hint appear above the form", () => {
  const header = html.slice(html.indexOf("<body>"), html.indexOf("<form"));
  assert.match(
    header,
    /href="https:\/\/github\.com\/Nimbly8836\/generate_mihomo_config"/,
  );
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
        dataset: {},
        showModal() {
          this.open = true;
        },
        close() {
          this.open = false;
          this.onclose?.();
        },
        focus() {
          this.focused = true;
        },
        select() {
          this.selected = true;
        },
        classList: {
          toggle() {},
          contains() {
            return false;
          },
        },
        setAttribute() {},
        contains() {
          return false;
        },
        querySelectorAll() {
          return [];
        },
        addEventListener(type, handler, capture) {
          (this.listeners ||= {})[type] = handler;
          this.capture = capture;
        },
        replaceChildren(...children) {
          this.children = children;
        },
        append() {},
        content: {
          cloneNode() {
            return {};
          },
        },
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
      querySelector: element,
      documentElement: element("root"),
      createElement() {
        return {
          append(...children) {
            this.children = children;
          },
        };
      },
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

test("publishing is explicit and sends the exact last preview with CSRF headers", async () => {
  const { context, element, requests } = page(false);
  assert.equal(element("#publish").disabled, true);
  await element("#form").onsubmit({ preventDefault() {} });
  assert.equal(requests.length, 1);
  assert.equal(element("#publish").disabled, false);
  const calls = [];
  context.localStorage.setItem = () => {
    throw new Error("unexpected persistence");
  };
  context.fetch = async (url, options) => {
    calls.push(url);
    assert.equal(options.headers["X-Mihomo-Request"], "1");
    assert.equal(options.headers["Content-Type"], "application/json");
    assert.equal(options.credentials, "same-origin");
    if (url === "/api/identity")
      return {
        ok: true,
        json: async () => ({ recovery_code: "test-recovery" }),
      };
    assert.equal(url, "/api/subscriptions");
    assert.deepEqual(JSON.parse(options.body), {
      config: "test-config",
      source: JSON.stringify(requests[0].values, null, 2),
      name: "我的配置",
    });
    return {
      ok: true,
      json: async () => ({ url: "https://example.com/s/test-token" }),
    };
  };
  element("#result-config").value = "not the generated snapshot";
  await element("#publish").onclick();
  assert.deepEqual(calls, ["/api/identity", "/api/subscriptions"]);
  assert.equal(
    element("#published-url").value,
    "https://example.com/s/test-token",
  );
  assert.equal(element("#recovery-code").value, "test-recovery");
  assert.equal(element("#published").hidden, false);
  let copied;
  context.navigator.clipboard = {
    writeText: async (text) => {
      copied = text;
    },
  };
  await element("#copy-published").onclick();
  assert.equal(copied, "https://example.com/s/test-token");
});

test("regeneration and errors clear stale publication and disable snapshot actions", async () => {
  const { context, element } = page(false);
  await element("#form").onsubmit({ preventDefault() {} });
  element("#published-url").value = "old-link";
  context.fetch = async () => {
    throw new Error("offline");
  };
  await element("#form").onsubmit({ preventDefault() {} });
  assert.equal(element("#published-url").value, "");
  assert.equal(element("#published").hidden, true);
  assert.equal(element("#publish").disabled, true);
  assert.equal(element("#update-subscription").disabled, true);
  assert.equal(element("#result-config").value, "");
  context.fetch = async () => ({
    ok: true,
    json: async () => ({ config: "new-config" }),
  });
  await element("#form").onsubmit({ preventDefault() {} });
  assert.equal(element("#publish").disabled, false);
  context.fetch = async () => ({
    ok: false,
    json: async () => ({ error: "<img src=x onerror=bad>" }),
  });
  await element("#publish").onclick();
  assert.match(element("#publish-message").textContent, /<img/);
  assert.equal(element("#publish-message").innerHTML, undefined);
  assert.equal(element("#published-url").value, "");
  assert.equal(element("#publish").disabled, false);
});

test("late publish and generation responses cannot restore stale preview links", async () => {
  const { context, element } = page(false);
  await element("#form").onsubmit({ preventDefault() {} });
  let finishPublish;
  context.fetch = async (url) =>
    url === "/api/identity"
      ? { ok: true, json: async () => ({}) }
      : new Promise((resolve) => {
          finishPublish = resolve;
        });
  const pending = element("#publish").onclick();
  while (!finishPublish) await Promise.resolve();
  context.fetch = async () => ({
    ok: true,
    json: async () => ({ config: "new-snapshot" }),
  });
  await element("#form").onsubmit({ preventDefault() {} });
  finishPublish({ ok: true, json: async () => ({ url: "old-snapshot-link" }) });
  await pending;
  assert.equal(element("#published-url").value, "");
  assert.equal(element("#result-config").value, "new-snapshot");
  let finishGenerate;
  context.fetch = () =>
    new Promise((resolve) => {
      finishGenerate = resolve;
    });
  const older = element("#form").onsubmit({ preventDefault() {} });
  context.fetch = async () => ({
    ok: true,
    json: async () => ({ config: "newest" }),
  });
  await element("#form").onsubmit({ preventDefault() {} });
  finishGenerate({ ok: true, json: async () => ({ config: "out-of-order" }) });
  await older;
  assert.equal(element("#result-config").value, "newest");
});

test("my subscriptions uses safe text and confirms snapshot updates, reset and delete", async () => {
  const { context, element, requests } = page(false);
  await element("#form").onsubmit({ preventDefault() {} });
  const row = {
    id: "id",
    url: "https://example.com/s/token",
    updated_at: "<script>bad</script>",
  };
  const mutations = [];
  context.fetch = async (url, options) => {
    if (url === "/api/identity") return { ok: true, json: async () => ({}) };
    if (options.method === "GET")
      return { ok: true, json: async () => ({ subscriptions: [row] }) };
    mutations.push([url, options.method, JSON.parse(options.body)]);
    return { ok: true, json: async () => ({}) };
  };
  await element("#my-subscriptions").onclick();
  assert.equal(element("#subscription-dialog").open, true);
  assert.equal(element("#result-dialog").open, false);
  assert.match(
    element("#subscription-list").children[0].textContent,
    /<script>/,
  );
  assert.equal(element("#subscription-list").children[0].innerHTML, undefined);
  assert.equal(element("#subscription-url").value, row.url);
  assert.equal(element("#update-subscription").disabled, false);
  context.confirm = () => false;
  await element("#delete-subscription").onclick();
  assert.equal(mutations.length, 0);
  context.confirm = () => true;
  await element("#update-subscription").onclick();
  await element("#reset-subscription").onclick();
  await element("#delete-subscription").onclick();
  assert.deepEqual(mutations, [
    [
      "/api/subscriptions/id",
      "PUT",
      {
        config: "test-config",
        source: JSON.stringify(requests[0].values, null, 2),
      },
    ],
    ["/api/subscriptions/id/reset", "POST", {}],
    ["/api/subscriptions/id", "DELETE", {}],
  ]);
  context.fetch = async () => {
    throw new Error("offline");
  };
  await element("#my-subscriptions").onclick();
  // Identity request failed: no replacement credentials or HTML are displayed.
  assert.match(element("#subscription-message").textContent, /offline/);
});

test("reusable recovery import and explicit reset clear inputs and support manual export", async () => {
  const { context, element } = page(false);
  await element("#form").onsubmit({ preventDefault() {} });
  assert.equal(element("#publish").disabled, false);
  const calls = [];
  context.confirm = () => true;
  context.localStorage.setItem = () => {
    throw new Error("unexpected persistence");
  };
  context.fetch = async (url, options) => {
    calls.push([url, options.body && JSON.parse(options.body)]);
    if (url === "/api/subscriptions")
      return { ok: true, json: async () => ({ subscriptions: [] }) };
    return {
      ok: true,
      json: async () => ({
        recovery_code: url.endsWith("/recover") ? null : "new-recovery",
      }),
    };
  };
  await element("#my-subscriptions").onclick();
  assert.equal(element("#update-subscription").disabled, true);
  element("#import-code").value = "reusable-recovery";
  await element("#import-recovery").onclick();
  assert.equal(element("#import-code").value, "");
  assert.equal(element("#recovery-code").value, "reusable-recovery");
  assert.match(element("#subscription-message").textContent, /原恢复码仍有效/);
  assert.equal(element("#publish").disabled, true);
  assert.equal(element("#file-values").value, "");
  assert.deepEqual(calls.find(([url]) => url.endsWith("/recover"))[1], {
    recovery_code: "reusable-recovery",
  });
  await element("#rotate-recovery").onclick();
  assert.equal(element("#recovery-code").value, "new-recovery");
  context.document.execCommand = () => false;
  await element("#copy-recovery").onclick();
  assert.equal(element("#recovery-code").selected, true);
  assert.match(element("#subscription-message").textContent, /手动复制/);
  context.fetch = async () => ({
    ok: false,
    json: async () => ({ error: "恢复码无效" }),
  });
  element("#import-code").value = "bad-code";
  await element("#import-recovery").onclick();
  assert.equal(element("#import-code").value, "");
  assert.equal(element("#recovery-code").value, "new-recovery");
  assert.match(element("#subscription-message").textContent, /恢复码无效/);
});

test("editing a published source only saves on explicit update or save-as-new", async () => {
  const { context, element } = page(false);
  const original = "# exact source\nport: 7890\nproxy_providers: []\n";
  const row = {
    id: "existing",
    name: "家里电脑",
    url: "/s/original",
    updated_at: "now",
    has_source: true,
  };
  const calls = [],
    writes = [];
  let savedSource = original;
  context.confirm = () => true;
  context.localStorage.setItem = (key, value) => writes.push([key, value]);
  context.fetch = async (url, options) => {
    const body = options.body && JSON.parse(options.body);
    calls.push([url, options.method, body]);
    let result;
    if (url === "/api/identity") result = {};
    else if (url.endsWith("/source"))
      result = { id: row.id, name: row.name, source: savedSource };
    else if (url === "/api/subscriptions" && options.method === "GET")
      result = { subscriptions: [row] };
    else if (url === "/api/generate")
      result = { config: "last-generated-config", source: body.values };
    else if (options.method === "PUT") {
      savedSource = body.source;
      row.name = body.name;
      result = { ...row };
    } else if (options.method === "POST")
      result = { ...row, id: "new", name: body.name, url: "/s/new" };
    return { ok: true, json: async () => result };
  };
  await element("#my-subscriptions").onclick();
  await element("#edit-subscription").onclick();
  assert.equal(element("#file-values").value, original);
  assert.equal(element("#editing-name").textContent, row.name);
  assert.equal(element("#editing-state").hidden, false);
  assert.equal(element("#form-editor").disabled, true);
  const updated = original + "# next published source\n";
  element("#file-values").value = updated;
  await element("#form").onsubmit({ preventDefault() {} });
  assert.equal(savedSource, original, "generation is not publication");
  assert.equal(element("#publish").textContent, "更新原订阅");
  assert.equal(element("#publish-new").hidden, false);
  element("#file-values").value = "un-generated editor changes";
  element("#publish-name").value = "更新的名称";
  await element("#publish").onclick();
  assert.equal(
    savedSource,
    updated,
    "source must match the generated preview, not current editor",
  );
  assert.equal(element("#published-url").value, "/s/original");
  assert.deepEqual(
    calls.find(([, method]) => method === "PUT"),
    [
      "/api/subscriptions/existing",
      "PUT",
      { config: "last-generated-config", source: updated, name: "更新的名称" },
    ],
  );
  element("#publish-name").value = "副本";
  await element("#publish-new").onclick();
  assert.equal(element("#published-url").value, "/s/new");
  assert.equal(element("#editing-name").textContent, "副本");
  assert.equal(
    savedSource,
    updated,
    "save-as-new leaves original source untouched",
  );
  assert.ok(
    writes.every(([key]) => ["mihomo-mode", "mihomo-theme"].includes(key)),
  );
  assert.doesNotMatch(
    script,
    /localStorage\.(getItem|setItem)\(['"]mihomo-values/,
  );
  await element("#exit-editing").onclick();
  assert.equal(element("#editing-state").hidden, true);
  assert.equal(element("#publish").disabled, true);
});

test("legacy subscriptions without source enter explicit source-entry mode, never reverse-convert config", async () => {
  const { context, element } = page(false);
  const row = {
    id: "legacy",
    name: "旧配置",
    url: "/s/legacy",
    has_source: false,
    updated_at: "old",
  };
  context.confirm = () => true;
  context.fetch = async (url) => ({
    ok: true,
    json: async () =>
      url.endsWith("/source")
        ? { id: row.id, name: row.name, source: null }
        : url === "/api/subscriptions"
          ? { subscriptions: [row] }
          : {},
  });
  await element("#my-subscriptions").onclick();
  assert.match(
    element("#subscription-list").children[0].textContent,
    /未保存源文件/,
  );
  await element("#edit-subscription").onclick();
  assert.equal(element("#file-values").value, "");
  assert.equal(element("#editing-name").textContent, "旧配置");
  assert.match(element("#status").textContent, /不能由成品配置反推/);
  assert.equal(element("#publish").disabled, true);
});

test("late source loads cannot overwrite a newer generation", async () => {
  const { context, element } = page(false);
  const row = { id: "old", name: "old", url: "/s/old", updated_at: "now" };
  context.confirm = () => true;
  let finish;
  context.fetch = async (url) =>
    url.endsWith("/source")
      ? new Promise((resolve) => {
          finish = resolve;
        })
      : {
          ok: true,
          json: async () =>
            url === "/api/subscriptions" ? { subscriptions: [row] } : {},
        };
  await element("#my-subscriptions").onclick();
  const editing = element("#edit-subscription").onclick();
  context.fetch = async () => ({
    ok: true,
    json: async () => ({ config: "new preview", source: "port: 7888" }),
  });
  await element("#form").onsubmit({ preventDefault() {} });
  finish({
    ok: true,
    json: async () => ({ id: row.id, name: row.name, source: "stale source" }),
  });
  await editing;
  assert.equal(element("#result-config").value, "new preview");
  assert.notEqual(element("#file-values").value, "stale source");
  assert.equal(element("#publish").textContent, "发布订阅");
});

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
    wg_name: ["office"],
    wg_server: ["192.0.2.10"],
    wg_port: ["51820"],
    wg_ip: ["10.7.0.2"],
    wg_ipv6: [""],
    wg_private_key: [Buffer.alloc(32, 1).toString("base64")],
    wg_public_key: [Buffer.alloc(32, 2).toString("base64")],
    wg_preshared_key: [""],
    wg_allowed_ips: ["10.7.0.0/24\n192.168.50.0/24"],
    wg_routes_mode: ["auto"],
    wg_routes: [""],
    wg_domains: ["office.internal"],
    wg_ip_version: ["ipv6-prefer"],
    wg_mtu: ["1420"],
    wg_keepalive: ["25"],
    ...extra,
  };
}

test("WG form emits quick configuration, not a generic local proxy", async () => {
  const { element, requests } = page(true, wgFields());
  await element("#form").onsubmit({ preventDefault() {} });
  const values = requests[0].values;
  assert.equal(values.wireguard.length, 1);
  assert.equal(values.wireguard[0].name, "office");
  assert.equal(values.wireguard[0].port, 51820);
  assert.deepEqual(values.wireguard[0]["allowed-ips"], [
    "10.7.0.0/24",
    "192.168.50.0/24",
  ]);
  assert.deepEqual(values.wireguard[0].domains, ["office.internal"]);
  assert.equal(values.wireguard[0]["ip-version"], "ipv6-prefer");
  assert.equal(values.wireguard[0].mtu, 1420);
  assert.equal(values.wireguard[0]["persistent-keepalive"], 25);
  assert.equal(values.wireguard[0].routes, undefined);
  assert.equal(values.wireguard[0]["pre-shared-key"], undefined);
  assert.deepEqual(values.local_proxies, []);
  assert.equal(
    values.config_overrides.experimental["dialer-ip4p-convert"],
    true,
  );
});

test("domain-only WG explicitly sends an empty routes list", async () => {
  const { element, requests } = page(
    false,
    wgFields({
      wg_routes_mode: ["domains"],
      wg_allowed_ips: ["0.0.0.0/0"],
    }),
  );
  await element("#form").onsubmit({ preventDefault() {} });
  assert.deepEqual(requests[0].values.wireguard[0].routes, []);
});

test("external rule provider URLs use a separate values field", async () => {
  const { element, requests } = page(false, {
    rule_name: ["custom_media"],
    rule_url: ["https://example.com/media.mrs"],
    rule_behavior: ["domain"],
    rule_format: ["mrs"],
    rule_policy: ["media"],
    rule_no_resolve: [""],
  });
  await element("#form").onsubmit({ preventDefault() {} });
  assert.deepEqual(requests[0].values.custom_rule_providers, [
    {
      name: "custom_media",
      type: "http",
      url: "https://example.com/media.mrs",
      behavior: "domain",
      format: "mrs",
      policy: "media",
    },
  ]);
  assert.deepEqual(requests[0].values.proxy_rules, []);
});

test("a URL pasted into proxy_rules is rejected and the form recovers", async () => {
  const { element, requests } = page(false, {
    proxy_rules: "https://example.com/list.yaml",
  });
  await element("#form").onsubmit({ preventDefault() {} });
  assert.equal(requests.length, 0);
  assert.match(element("#status").textContent, /外部规则集/);
  assert.equal(element("#generate").disabled, false);
  assert.equal(element("#download").disabled, true);
});

test("group hint and validation follow simple versus detailed mode", async () => {
  const simple = page(false, { group_rules: "telegram: DOMAIN-SUFFIX,t.me" });
  assert.match(simple.element("#group-help").textContent, /chat/);
  await simple.element("#form").onsubmit({ preventDefault() {} });
  assert.equal(simple.requests.length, 0);
  assert.match(simple.element("#status").textContent, /分组/);
  const detailed = page(false, {
    group_mode: "detailed",
    group_rules: "telegram: DOMAIN-SUFFIX,t.me",
  });
  assert.match(detailed.element("#group-help").textContent, /telegram/);
  await detailed.element("#form").onsubmit({ preventDefault() {} });
  assert.deepEqual(detailed.requests[0].values.group_rules, {
    telegram: ["DOMAIN-SUFFIX,t.me"],
  });
});

test("Apple is offered and accepted as a rule target in both modes", async () => {
  for (const group_mode of ["simple", "detailed"]) {
    const { element, requests } = page(false, {
      group_mode,
      group_rules: "apple: DOMAIN-SUFFIX,example.com",
      rule_name: ["custom_apple"],
      rule_url: ["https://example.com/apple.mrs"],
      rule_behavior: ["domain"],
      rule_format: ["mrs"],
      rule_policy: ["apple"],
    });
    assert.match(element("#group-help").textContent, /apple/);
    const targets = element("#policy-targets").children.map(
      (option) => option.value,
    );
    assert.equal(targets.filter((name) => name === "apple").length, 1);
    await element("#form").onsubmit({ preventDefault() {} });
    assert.equal(requests.length, 1);
    assert.deepEqual(requests[0].values.group_rules, {
      apple: ["DOMAIN-SUFFIX,example.com"],
    });
    assert.equal(requests[0].values.custom_rule_providers[0].policy, "apple");
  }
});

test("hidden auto groups have separate help and are valid rule targets", async () => {
  const { element, requests } = page(false, {
    group_rules: "hk_auto: DOMAIN-SUFFIX,example.com",
  });
  const targets = element("#policy-targets").children.map(
    (option) => option.value,
  );
  for (const region of ["hk", "jp", "tw", "sg", "us", "kr", "eu", "others"]) {
    assert.ok(targets.includes(region));
    assert.ok(targets.includes(`${region}_auto`));
    assert.ok(
      element("#auto-group-help").textContent.includes(`${region}_auto`),
    );
  }
  assert.doesNotMatch(element("#group-help").textContent, /_auto/);
  await element("#form").onsubmit({ preventDefault() {} });
  assert.equal(requests.length, 1);
  assert.deepEqual(requests[0].values.group_rules, {
    hk_auto: ["DOMAIN-SUFFIX,example.com"],
  });
});

test("HTML name patterns compile with the browser Unicode-sets flag", () => {
  for (const name of ["wg_name", "rule_name"]) {
    const input = html.match(new RegExp(`name="${name}"[^>]*`))[0];
    const pattern = new RegExp(
      `^(?:${input.match(/pattern="([^"]+)"/)[1]})$`,
      "v",
    );
    assert.ok(pattern.test("office-lan_1"));
    assert.ok(!pattern.test("../invalid"));
  }
});

test("without cards no WG nodes or external providers are submitted", async () => {
  const { element, requests } = page(false);
  await element("#form").onsubmit({ preventDefault() {} });
  assert.deepEqual(requests[0].values.wireguard, []);
  assert.deepEqual(requests[0].values.custom_rule_providers, []);
});

test("multiple WG cards retain independent optional fields and route modes", async () => {
  const fields = Object.fromEntries(
    Object.entries(wgFields()).map(([key, values]) => [
      key,
      [...values, ...values],
    ]),
  );
  fields.wg_name = ["office", "home"];
  fields.wg_ip = ["10.7.0.2", ""];
  fields.wg_ipv6 = ["", "fd00:8::2"];
  fields.wg_allowed_ips = ["10.7.0.0/24", "fd00:8::/64"];
  fields.wg_routes_mode = ["auto", "custom"];
  fields.wg_routes = ["", "fd00:8::1/128"];
  fields.wg_preshared_key = ["", Buffer.alloc(32, 3).toString("base64")];
  fields.wg_keepalive = ["25", "0"];
  const { element, requests } = page(false, fields);
  await element("#form").onsubmit({ preventDefault() {} });
  const [office, home] = requests[0].values.wireguard;
  assert.equal(office.routes, undefined);
  assert.deepEqual(home.routes, ["fd00:8::1/128"]);
  assert.equal(home.ip, undefined);
  assert.equal(home.ipv6, "fd00:8::2");
  assert.equal(home["persistent-keepalive"], 0);
  assert.equal(office["pre-shared-key"], undefined);
  assert.equal(home["pre-shared-key"], fields.wg_preshared_key[1]);
});

test("YAML mode disables hidden required controls and bypasses form validation", async () => {
  const { element, requests } = page(
    false,
    wgFields({ wg_name: [""], wg_server: [""] }),
  );
  element("#file-values").value = "wireguard: []\n";
  element("#file-mode").onclick();
  assert.equal(element("#form-editor").disabled, true);
  await element("#form").onsubmit({ preventDefault() {} });
  assert.equal(requests[0].values, "wireguard: []\n");
  element("#form-mode").onclick();
  assert.equal(element("#form-editor").disabled, false);
});

test("changing group mode updates both hints and policy suggestions", () => {
  const { fields, element } = page(false);
  assert.doesNotMatch(element("#group-help").textContent, /telegram/);
  fields.group_mode = "detailed";
  element("#form-editor").onchange();
  assert.match(element("#group-help").textContent, /telegram/);
  assert.ok(
    element("#policy-targets").children.some(
      (option) => option.value === "telegram",
    ),
  );
  fields.group_mode = "simple";
  element("#form-editor").oninput();
  assert.ok(
    !element("#policy-targets").children.some(
      (option) => option.value === "telegram",
    ),
  );
});

test("invalid MRS/classical combination is rejected before a request", async () => {
  const { element, requests } = page(false, {
    rule_name: ["custom_rules"],
    rule_url: ["https://example.com/rules.mrs"],
    rule_behavior: ["classical"],
    rule_format: ["mrs"],
    rule_policy: ["proxy"],
  });
  await element("#form").onsubmit({ preventDefault() {} });
  assert.equal(requests.length, 0);
  assert.match(element("#status").textContent, /不支持 classical/);
});

test("invalid failover probe controls reveal both collapsed settings panels", () => {
  const { element } = page(false);
  const target = {};
  for (const id of ["#failover-settings", "#failover-probe-settings"])
    element(id).contains = (item) => item === target;
  element("#form").listeners.invalid({ target });
  assert.equal(element("#failover-settings").open, true);
  assert.equal(element("#failover-probe-settings").open, true);
  assert.equal(element("#advanced-settings").open, false);
});

test("failover is opt-in and only an enabled group appears in rule targets", async () => {
  const { element, requests } = page(false, { failover_interval: "invalid" });
  assert.equal(element("#failover-options").disabled, true);
  await element("#form").onsubmit({ preventDefault() {} });
  assert.equal(requests[0].values.failover, undefined);
  assert.ok(
    !element("#policy-targets").children.some(
      (option) => option.value === "failover",
    ),
  );
});

test("failover form renders separate airport and self-hosted pools end to end", async () => {
  const { element, requests } = page(false, {
    providers:
      "airport | https://example.com/a.yaml\nairport | https://example.com/b.yaml\nown | https://example.com/own.yaml",
    failover_enabled: "on",
    failover_primary: ["airport"],
    failover_backup: ["own"],
    group_rules: "failover: DOMAIN-SUFFIX,example.net",
  });
  assert.equal(element("#failover-options").disabled, false);
  assert.equal(element("#failover-primary-sources").children.length, 2);
  assert.ok(
    element("#policy-targets").children.some(
      (option) => option.value === "failover",
    ),
  );
  assert.ok(
    !element("#subscription-group-targets").children.some(
      (option) => option.value === "failover",
    ),
  );
  await element("#form").onsubmit({ preventDefault() {} });
  assert.equal(requests.length, 1);
  const values = requests[0].values;
  assert.deepEqual(values.failover.primary, ["airport"]);
  assert.deepEqual(values.failover.backup, ["own"]);
  assert.equal(values.failover.interval, 30);
  assert.equal(values.failover.expected_status, 204);
  const config = renderConfig(values);
  const groups = Object.fromEntries(
    config["proxy-groups"].map((group) => [group.name, group]),
  );
  assert.deepEqual(groups.failover.proxies, [
    "failover_primary",
    "failover_backup",
  ]);
  assert.deepEqual(groups.failover_primary.use, ["airport", "airport__2"]);
  assert.deepEqual(groups.failover_backup.use, ["own"]);
  assert.ok(config.rules.includes("DOMAIN-SUFFIX,example.net,failover"));
});

test("invalid failover choices fail before sending a generation request", async () => {
  const base = {
    providers: "airport | https://example.com/a\nown | https://example.com/b",
    failover_enabled: "on",
    failover_primary: ["airport"],
    failover_backup: ["own"],
  };
  for (const invalid of [
    { failover_primary: [] },
    { failover_backup: [] },
    { failover_backup: ["airport"] },
    { failover_backup: ["missing"] },
    { failover_interval: "0" },
    { failover_status: "600" },
    { failover_url: "file:///bad" },
    {
      subscription_group_name: ["failover"],
      subscription_group_id: ["1"],
      subscription_group_sources_1: ["airport"],
    },
  ]) {
    const { element, requests } = page(false, { ...base, ...invalid });
    await element("#form").onsubmit({ preventDefault() {} });
    assert.equal(requests.length, 0);
    assert.equal(element("#status").hidden, false);
  }
});

test("failover source labels are safe and refresh preserves independent selections", () => {
  const { element, fields } = page(false, {
    providers:
      "airport | https://example.com/a\n<img src=x> | https://example.com/b",
  });
  const primary = element("#failover-primary-sources"),
    backup = element("#failover-backup-sources");
  assert.equal(backup.children[1].children[1].textContent, "<img src=x>");
  assert.equal(backup.children[1].innerHTML, undefined);
  primary.children[0].children[0].checked = true;
  backup.children[1].children[0].checked = true;
  primary.querySelectorAll = () =>
    primary.children
      .map((label) => label.children[0])
      .filter((input) => input.checked);
  backup.querySelectorAll = () =>
    backup.children
      .map((label) => label.children[0])
      .filter((input) => input.checked);
  const previous = primary.children;
  element("#form-editor").oninput();
  assert.equal(primary.children, previous);
  fields.providers += "\nnew | https://example.com/c";
  element("#form-editor").oninput();
  assert.equal(primary.children[0].children[0].checked, true);
  assert.equal(backup.children[1].children[0].checked, true);
  assert.equal(primary.children[1].children[0].checked, false);
});

function renderConfig(values) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "mihomo-form-test-"));
  try {
    const input = path.join(directory, "values.json");
    const output = path.join(directory, "config.yaml");
    fs.writeFileSync(
      input,
      JSON.stringify({ ...values, web_secret: "form-test-only" }),
    );
    const rendered = spawnSync(
      "ruby",
      ["generate_mihomo_config.rb", "--values", input, "--output", output],
      {
        cwd: path.join(__dirname, ".."),
        encoding: "utf8",
        timeout: 15000,
      },
    );
    assert.equal(rendered.status, 0, rendered.stderr);
    const parsed = spawnSync(
      "ruby",
      [
        "-rpsych",
        "-rjson",
        "-e",
        "puts JSON.generate(Psych.safe_load(File.read(ARGV[0]), aliases: true))",
        output,
      ],
      { encoding: "utf8", timeout: 15000 },
    );
    assert.equal(parsed.status, 0, parsed.stderr);
    return JSON.parse(parsed.stdout);
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
}

test("suggested built-in groups exactly match generated groups in both modes", async () => {
  for (const group_mode of ["simple", "detailed"]) {
    const { element, requests } = page(false, { group_mode });
    await element("#form").onsubmit({ preventDefault() {} });
    const config = renderConfig(requests[0].values);
    const suggested = element("#policy-targets")
      .children.map((option) => option.value)
      .filter((name) => !["DIRECT", "REJECT"].includes(name));
    assert.deepEqual(
      suggested.sort(),
      config["proxy-groups"].map((group) => group.name).sort(),
    );
  }
});

test("subscription checkbox choices deduplicate names, render safe text and preserve selections", () => {
  const { context, element, fields } = page(false, {
    providers:
      "main | https://example.com/one\nmain | https://example.com/two\n<img src=x> | https://example.com/safe",
  });
  const sources = {
    children: [],
    replaceChildren(...children) {
      this.children = children;
    },
  };
  const card = {
    dataset: {},
    querySelector(selector) {
      return selector === '[name="subscription_group_id"]'
        ? { value: "7" }
        : sources;
    },
    querySelectorAll() {
      return sources.children
        .map((label) => label.children[0])
        .filter((input) => input.checked);
    },
  };
  element("#subscription-group-entries").querySelectorAll = () => [card];
  context.document.createElement = (tag) => ({
    tag,
    children: [],
    append(...children) {
      this.children.push(...children);
    },
  });
  const refresh = () =>
    context.updateSubscriptionSources(new context.FormData());
  refresh();
  assert.deepEqual(
    sources.children.map((label) => label.children[0].value),
    ["main", "<img src=x>"],
  );
  assert.equal(sources.children[1].children[1].textContent, "<img src=x>");
  assert.equal(
    sources.children[0].children[0].name,
    "subscription_group_sources_7",
  );
  assert.ok(
    sources.children.every((label) => !Object.hasOwn(label, "innerHTML")),
  );
  const original = sources.children[0];
  original.children[0].checked = true;
  refresh();
  assert.equal(
    sources.children[0],
    original,
    "unchanged sources must not replace focused checkbox DOM",
  );
  fields.providers += "\nbackup | https://example.com/backup";
  refresh();
  assert.equal(sources.children[0].children[0].checked, true);
  assert.equal(sources.children[2].children[0].checked, false);
  fields.providers = "backup | https://example.com/backup";
  refresh();
  assert.deepEqual(
    sources.children.map((label) => label.children[0].value),
    ["backup"],
  );
});

test("checked subscription sources join my_proxy or a new group without editing YAML", async () => {
  const { element, requests } = page(false, {
    providers:
      "main | https://example.com/one.yaml\nmain | https://example.com/two.yaml\nbackup | https://example.com/backup.yaml",
    subscription_group_id: ["1", "2"],
    subscription_group_name: ["my_proxy", "combined"],
    subscription_group_sources_1: ["main"],
    subscription_group_sources_2: ["main", "backup"],
    group_rules: "combined: DOMAIN-SUFFIX,group.example",
  });
  assert.match(html, /把订阅节点加入分组/);
  assert.match(html, /data-select-all/);
  assert.ok(
    element("#subscription-group-targets").children.some(
      (option) => option.value === "my_proxy",
    ),
  );
  assert.ok(
    element("#policy-targets").children.some(
      (option) => option.value === "combined",
    ),
  );
  await element("#form").onsubmit({ preventDefault() {} });
  assert.deepEqual(requests[0].values.group_providers, {
    my_proxy: ["main"],
    combined: ["main", "backup"],
  });
  const config = renderConfig(requests[0].values);
  const mine = config["proxy-groups"].find(
    (group) => group.name === "my_proxy",
  );
  assert.deepEqual(mine.use, ["main", "main__2"]);
  assert.deepEqual(mine.proxies, []);
  assert.deepEqual(
    config["proxy-groups"].find((group) => group.name === "combined").use,
    ["main", "main__2", "backup"],
  );
  assert.ok(
    config["proxy-groups"]
      .find((group) => group.name === "final")
      .proxies.includes("combined"),
  );
  assert.ok(config.rules.includes("DOMAIN-SUFFIX,group.example,combined"));
});

test("subscription cards targeting the same group combine their checkbox selections", async () => {
  const { element, requests } = page(false, {
    providers: "a | https://example.com/a\nb | https://example.com/b",
    subscription_group_id: ["1", "3"],
    subscription_group_name: ["my_proxy", "my_proxy"],
    subscription_group_sources_1: ["a"],
    subscription_group_sources_3: ["a", "b"],
  });
  await element("#form").onsubmit({ preventDefault() {} });
  assert.deepEqual(requests[0].values.group_providers, {
    my_proxy: ["a", "b"],
  });
});

test("empty or stale subscription selections fail before sending a request", async () => {
  for (const selected of [[], ["removed"]]) {
    const { element, requests } = page(false, {
      providers: "main | https://example.com/a",
      subscription_group_id: ["1"],
      subscription_group_name: ["my_proxy"],
      subscription_group_sources_1: selected,
    });
    await element("#form").onsubmit({ preventDefault() {} });
    assert.equal(requests.length, 0);
    assert.match(element("#status").textContent, /勾选至少一个当前订阅/);
  }
});

test("custom group names are dictionary keys rather than JavaScript prototypes", async () => {
  const { element, requests } = page(false, {
    providers: "main | https://example.com/a",
    subscription_group_id: ["1"],
    subscription_group_name: ["__proto__"],
    subscription_group_sources_1: ["main"],
    group_rules: "__proto__: DOMAIN-SUFFIX,safe.example",
  });
  await element("#form").onsubmit({ preventDefault() {} });
  assert.equal(requests.length, 1);
  assert.equal(
    Object.hasOwn(requests[0].values.group_providers, "__proto__"),
    true,
  );
  assert.deepEqual(requests[0].values.group_rules.__proto__, [
    "DOMAIN-SUFFIX,safe.example",
  ]);
});

test("same-name subscription rows merge every source and deduplicate exact repeats end to end", async () => {
  const { element, requests } = page(false, {
    providers: [
      "main | https://example.com/one.yaml",
      "main | https://example.com/two.yaml | Second",
      "main | https://example.com/one.yaml",
    ].join("\n"),
  });
  assert.match(html, /同名订阅自动合并来源/);
  await element("#form").onsubmit({ preventDefault() {} });
  assert.equal(requests.length, 1);
  // Keep form and YAML/API semantics in the shared generator, not in the UI.
  assert.equal(requests[0].values.proxy_providers.length, 3);
  const config = renderConfig(requests[0].values);
  assert.deepEqual(Object.keys(config["proxy-providers"]), ["main", "main__2"]);
  assert.deepEqual(
    Object.values(config["proxy-providers"]).map((provider) => provider.url),
    ["https://example.com/one.yaml", "https://example.com/two.yaml"],
  );
  for (const name of ["all_nodes", "hk", "hk_auto", "others", "others_auto"]) {
    assert.deepEqual(
      config["proxy-groups"].find((group) => group.name === name).use,
      ["main", "main__2"],
    );
  }
  assert.equal(
    config["proxy-providers"].main.override["additional-prefix"],
    "main | ",
  );
  assert.equal(
    config["proxy-providers"].main__2.override["additional-prefix"],
    "Second | ",
  );
});

test("combined form values render WG, external provider and selected rules end to end", async () => {
  const { element, requests } = page(true, {
    ...wgFields(),
    group_rules: "wg_office: DOMAIN-SUFFIX,files.office.internal",
    proxy_rules: "DOMAIN-SUFFIX,proxy.example",
    direct_rules: "DOMAIN-SUFFIX,direct.example",
    rule_name: ["custom_lan"],
    rule_url: ["https://example.com/lan.txt"],
    rule_behavior: ["ipcidr"],
    rule_format: ["text"],
    rule_policy: ["wg_office"],
    rule_no_resolve: ["no-resolve"],
  });
  await element("#form").onsubmit({ preventDefault() {} });
  const config = renderConfig(requests[0].values);
  const node = config.proxies.find((proxy) => proxy.name === "wg_office_node");
  assert.equal(node["ip-version"], "ipv6-prefer");
  assert.equal(node["persistent-keepalive"], 25);
  assert.equal(config.experimental["dialer-ip4p-convert"], true);
  assert.deepEqual(
    config["proxy-groups"].find((group) => group.name === "wg_office").proxies,
    ["wg_office_node", "REJECT"],
  );
  assert.ok(
    !config["proxy-groups"]
      .find((group) => group.name === "my_proxy")
      .proxies.includes("wg_office_node"),
  );
  assert.equal(
    config["rule-providers"].custom_lan.url,
    "https://example.com/lan.txt",
  );
  assert.equal(config["rule-providers"].custom_lan.proxy, "DIRECT");
  assert.equal(config["rule-providers"].custom_lan.interval, 86400);
  for (const rule of [
    "DOMAIN-SUFFIX,proxy.example,proxy",
    "DOMAIN-SUFFIX,direct.example,DIRECT",
    "DOMAIN-SUFFIX,files.office.internal,wg_office",
    "IP-CIDR,10.7.0.0/24,wg_office,no-resolve",
    "RULE-SET,custom_lan,wg_office,no-resolve",
  ])
    assert.ok(config.rules.includes(rule), rule);
});
