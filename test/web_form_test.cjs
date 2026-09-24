// Built-in Node test runner only; no Node dependency in the Web container.
const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const html = fs.readFileSync(path.join(__dirname, "../web/index.html"), "utf8");
const script = html.match(/<script>([\s\S]*?)<\/script>/)[1];

function page(ip4p) {
  const elements = new Map();
  const element = (key) => {
    if (!elements.has(key)) {
      elements.set(key, {
        value: "",
        classList: {
          toggle() {},
          contains() {
            return false;
          },
        },
        setAttribute() {},
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
  };
  const requests = [];
  const context = {
    document: { querySelector: element, documentElement: element("root") },
    localStorage: {
      getItem() {
        return null;
      },
      setItem() {},
    },
    FormData: class {
      get(key) {
        return fields[key];
      }
    },
    fetch: async (_url, options) => {
      requests.push(JSON.parse(options.body));
      return { ok: true, json: async () => ({ config: "test-config" }) };
    },
  };
  vm.runInNewContext(script, context);
  return { context, element, requests };
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
