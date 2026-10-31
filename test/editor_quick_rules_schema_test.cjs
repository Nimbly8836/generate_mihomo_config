const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');

// Extract the data constant without importing Monaco or requiring a browser.
const source = fs.readFileSync(path.join(__dirname, '../web/editor/main.js'), 'utf8');
const match = source.match(/const valuesSchema = ([\s\S]*?);\s*\nwindow\.MonacoEnvironment/);
assert.ok(match, 'valuesSchema extraction boundary must exist');
const schema = JSON.parse(JSON.stringify(vm.runInNewContext(`(${match[1]})`, {
  MIHOMO_SCHEMA_URI: 'inmemory://mihomo/schema.json'
})));
const quick = schema.definitions.quickRules;
const provider = schema.definitions.quickRuleProvider;

// No validator dependency is added. These assertions inspect schema structure,
// not arbitrary instance validity; the optional Ajv test below validates instances.
test('all quick-rule sections reference the shared legacy/new union', () => {
  for (const name of ['proxy_rules', 'direct_rules']) {
    assert.equal(schema.properties[name].$ref, '#/definitions/quickRules');
  }
  assert.equal(schema.properties.group_rules.additionalProperties.$ref, '#/definitions/quickRules');
  assert.deepEqual(quick.anyOf[0], { type: 'array', items: { type: 'string' } });
  const mapping = quick.anyOf[1];
  assert.equal(mapping.type, 'object');
  assert.equal(mapping.additionalProperties, false);
  assert.equal(mapping.required, undefined, 'rules and providers are optional');
  assert.deepEqual(mapping.properties.rules, { type: 'array', items: { type: 'string' } });
  assert.deepEqual(mapping.properties.providers, {
    type: 'array', items: { $ref: '#/definitions/quickRuleProvider' }
  });
});

test('arbitrary nonempty group names are accepted, separators and blank names are not', () => {
  const names = schema.properties.group_rules.propertyNames;
  assert.equal(names.minLength, 1);
  const pattern = new RegExp(names.pattern);
  for (const name of ['AI', '自定义组', 'My Group', 'DIRECT']) assert.ok(pattern.test(name), name);
  for (const name of ['', '  ', '\t', 'a,b', 'a\nb', 'a\rb', ' a', 'a ', 'a\0b']) assert.ok(!pattern.test(name), JSON.stringify(name));
  assert.match(schema.properties.group_rules.description, /select/);
  assert.match(schema.properties.group_rules.description, /DIRECT/);
});

test('providers require identity and supported behavior/format, but allow native extras', () => {
  assert.equal(provider.type, 'object');
  assert.deepEqual(provider.required, ['name', 'behavior', 'format']);
  assert.deepEqual(provider.properties.behavior.enum, ['domain', 'ipcidr', 'classical']);
  assert.deepEqual(provider.properties.format.enum, ['mrs', 'yaml', 'text']);
  assert.deepEqual(provider.properties.type.enum, ['http', 'file']);
  assert.equal(provider.additionalProperties, true);
  const namePattern = new RegExp(provider.properties.name.pattern);
  assert.ok(namePattern.test('sports_rules-1'));
  for (const name of ['bad name', 'bad,name', '', '../cache']) assert.equal(namePattern.test(name), false);
  assert.equal(provider.properties.policy.type, 'string');
  assert.equal(provider.properties.interval.type, 'integer');
  for (const field of ['path', 'url', 'proxy']) assert.equal(provider.properties[field].type, 'string');
  assert.deepEqual(provider.properties.rule_options, { type: 'array', items: { type: 'string' } });
});

test('transport inference requires url or path and mrs/classical is forbidden', () => {
  assert.deepEqual(provider.anyOf, [
    { required: ['url'], properties: { type: { const: 'http' } } },
    {
      required: ['path'], properties: { type: { const: 'file' } },
      not: { required: ['url'] }
    }
  ]);
  assert.deepEqual(provider.not, {
    properties: { format: { const: 'mrs' }, behavior: { const: 'classical' } },
    required: ['format', 'behavior']
  });
});

let Ajv;
try { Ajv = require('ajv'); } catch (error) {
  if (error.code !== 'MODULE_NOT_FOUND') throw error;
}
test('valid/invalid instances (optional installed Ajv validator)', {
  skip: !Ajv && 'Ajv is not installed; preceding tests are structural assertions only'
}, () => {
  const ajv = new Ajv({ strict: false });
  ajv.addSchema({}, 'inmemory://mihomo/schema.json');
  const validate = ajv.compile(schema);
  const base = { name: 'example', behavior: 'domain', format: 'mrs', url: 'https://example.com/rules.mrs' };
  const valid = [
    { proxy_rules: ['DOMAIN,example.com'], direct_rules: [] },
    { group_rules: { AI: ['DOMAIN,example.com'], '新组': {} } },
    { proxy_rules: { rules: [], providers: [base] } },
    { direct_rules: { providers: [{ ...base, type: 'http', policy: 'DIRECT', interval: 3600, proxy: 'DIRECT', path: './cache.mrs', rule_options: ['no-resolve'], 'size-limit': 1024 }] } },
    { group_rules: { AI: { providers: [{ name: 'local', behavior: 'classical', format: 'yaml', path: './rules.yaml' }] } } },
    { proxy_rules: { providers: [{ name: 'local', behavior: 'ipcidr', format: 'text', type: 'file', path: './rules.txt' }] } }
  ];
  const invalid = [
    { proxy_rules: 'DOMAIN,example.com' }, { direct_rules: [1] },
    { group_rules: [] }, { group_rules: { '': [] } }, { group_rules: { 'a,b': [] } },
    { group_rules: { AI: { rules: [false] } } },
    { proxy_rules: { providers: {} } }, { proxy_rules: { unknown: [] } },
    ...[
      {}, { ...base, name: '' }, { ...base, behavior: 'unknown' },
      { ...base, format: 'json' }, { ...base, type: 'inline' },
      { ...base, behavior: 'classical' }, { ...base, rule_options: 'no-resolve' },
      { ...base, rule_options: [1] }, { ...base, type: 'file' },
      { ...base, type: 'file', path: './file.mrs' }, { ...base, name: 'bad name' },
      { name: 'missing-source', behavior: 'domain', format: 'yaml' },
      { name: 'http-needs-url', behavior: 'domain', format: 'yaml', type: 'http', path: './rules.yaml' }
    ].map(item => ({ proxy_rules: { providers: [item] } }))
  ];
  for (const value of valid) assert.ok(validate(value), JSON.stringify({ value, errors: validate.errors }));
  for (const value of invalid) assert.equal(validate(value), false, JSON.stringify(value));
});
