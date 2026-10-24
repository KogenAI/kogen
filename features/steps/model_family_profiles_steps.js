'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const ROOT = path.resolve(__dirname, '../..');
let bins;
function command(bin, args, options = {}) {
  const r = spawnSync(bin, args, { cwd: ROOT, encoding: 'utf8', timeout: 60000, maxBuffer: 8 * 1024 * 1024, ...options });
  assert.ifError(r.error);
  assert.equal(r.signal, null, `process signal: ${r.signal}`);
  return r;
}
function build() {
  if (bins) return bins;
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-profile-acceptance-'));
  bins = { dir, cli: path.join(dir, 'kogen'), driver: path.join(dir, 'fixture') };
  try {
    for (const [dest, source] of [[bins.cli, '.'], [bins.driver, '../features/steps/model_family_profiles_driver.go']]) {
      const r = command('go', ['build', '-o', dest, source], { cwd: path.join(ROOT, 'cli') });
      assert.equal(r.status, 0, r.stdout + r.stderr);
    }
    return bins;
  } catch (e) { cleanup(); throw e; }
}
function cleanup() { if (bins) fs.rmSync(bins.dir, { recursive: true, force: true }); bins = undefined; }
function drive(s) {
  const r = command(build().driver, [], { input: JSON.stringify(s) });
  assert.equal(r.status, 0, `fixture/process diagnostics, not provider output:\n${r.stdout}${r.stderr}`);
  return JSON.parse(r.stdout);
}
function equal(a, b) { try { assert.deepEqual(a, b); return true; } catch { return false; } }
function subset(actual, expected, location = '$') {
  if (Array.isArray(expected)) {
    assert.ok(Array.isArray(actual), `${location} must be an array`);
    assert.equal(actual.length, expected.length, `${location} array length`);
    expected.forEach((v, i) => subset(actual[i], v, `${location}[${i}]`));
  } else if (expected !== null && typeof expected === 'object') {
    assert.ok(actual !== null && typeof actual === 'object' && !Array.isArray(actual), `${location} must be an object`);
    for (const [k, v] of Object.entries(expected)) {
      assert.ok(Object.hasOwn(actual, k), `${location}.${k} missing`);
      subset(actual[k], v, `${location}.${k}`);
    }
  } else assert.deepEqual(actual, expected, location);
}
const SCHEMA = { type: 'object', properties: { path: { type: 'string' } }, required: ['path'], additionalProperties: false };
const EPHEMERAL = { type: 'ephemeral' };
const ROUTES = {
  chatgpt: 'https://api.openai.com/v1/responses', supergrok: 'https://api.x.ai/v1/responses',
  'opencode-go': 'https://opencode.ai/inference/go/openai/v1/chat/completions',
  anthropic: 'https://api.anthropic.com/v1/messages', 'openai-compatible': 'http://127.0.0.1:11434/v1/chat/completions',
};
function transport(x) {
  const p = x.selection.Provider, chat = ['opencode-go', 'openai-compatible'].includes(p), anth = p === 'anthropic';
  const rs = x.records, bodies = rs.map(r => r.body), second = bodies[1];
  const effort = b => anth ? b.output_config?.effort : chat ? (b.reasoning_effort ?? 'default') : b.reasoning?.effort;
  const conv = b => b[chat || anth ? 'messages' : 'input'];
  const tool = b => anth ? b.tools?.[0] : chat ? b.tools?.[0]?.function : b.tools?.[0];
  const wire = rs.length === 2 && bodies.every(b => b.model === x.selection.Model && effort(b) === x.selection.Effort && b.stream === !chat && (anth ? b.max_tokens === 128000 && equal(b.thinking, { type: 'adaptive' }) : b.store === false)) && x.urls.every(u => u === ROUTES[p]) && (!anth ? bodies.every(b => !Object.hasOwn(b, 'max_output_tokens')) : true);
  let replay = false;
  if (second) {
    const c = conv(second);
    if (anth) replay = equal(c, [
      { role: 'user', content: 'profile fixture authority' },
      { role: 'assistant', content: [{ type: 'thinking', thinking: 'fixture thinking', signature: 'fixture-signature' }, { type: 'tool_use', id: 'tool_fixture', name: 'read_file', input: { path: 'app.txt' } }] },
      { role: 'user', content: [{ type: 'tool_result', tool_use_id: 'tool_fixture', content: 'fixture tool result', cache_control: EPHEMERAL }] },
    ]);
    else if (chat) replay = equal(c, [
      { role: 'system', content: 'profile fixture policy' }, { role: 'user', content: 'profile fixture authority' },
      { role: 'assistant', content: null, reasoning_content: 'fixture reasoning', tool_calls: [{ type: 'function', id: 'tool_fixture', function: { name: 'read_file', arguments: '{"path":"app.txt"}' } }] },
      { role: 'tool', tool_call_id: 'tool_fixture', content: 'fixture tool result' },
    ]);
    else replay = equal(c, [
      { role: 'user', content: 'profile fixture authority' },
      { type: 'reasoning', id: 'reasoning_fixture', encrypted_content: 'fixture-encrypted', summary: [] },
      { type: 'function_call', id: 'function_fixture', call_id: 'tool_fixture', name: 'read_file', arguments: '{"path":"app.txt"}' },
      { type: 'function_call_output', call_id: 'tool_fixture', output: 'fixture tool result' },
    ]) && equal(second.include, ['reasoning.encrypted_content']);
  }
  const schema = bodies.length === 2 && bodies.every(b => equal(tool(b)?.[anth ? 'input_schema' : 'parameters'], SCHEMA) && tool(b)?.name === 'read_file' && equal(b.tool_choice, anth ? { type: 'auto' } : 'auto'));
  const cache = bodies.length === 2 && bodies.every(b => !Object.hasOwn(b, 'prompt_cache_options') && (anth ? equal(b.system?.[0], { type: 'text', text: 'profile fixture policy', cache_control: EPHEMERAL }) && equal(b.tools?.[0]?.cache_control, EPHEMERAL) : chat ? !Object.hasOwn(b, 'prompt_cache_key') : b.prompt_cache_key === 'profile-fixture-conversation')) && rs.every(r => !r.headers['X-Session-Id'] && !r.headers['Chatgpt-Session-Id'] && (p === 'opencode-go' ? equal(r.headers['X-Opencode-Session'], ['profile-fixture-conversation']) : !r.headers['X-Opencode-Session']));
  const auth = rs.length === 2 && rs.every(r => anth ? equal(r.headers['X-Api-Key'], ['fixture-key']) && equal(r.headers['Anthropic-Version'], ['2026-10-21']) && !r.headers.Authorization : p === 'openai-compatible' ? !r.headers.Authorization && !r.headers['X-Api-Key'] : equal(r.headers.Authorization, [p === 'opencode-go' ? 'Bearer fixture-key' : 'Bearer fixture-token']) && !r.headers['X-Api-Key']);
  const usage = x.rows.length === 2 && x.rows.every(r => r.outcome === 'completed' && r.configured_model === x.selection.Model && r.configured_effort === x.selection.Effort && r.usage?.input === 12 && r.usage?.cached === 2 && r.usage?.output === 3 && r.usage?.write_30m === null && r.usage?.write_12h === null);
  return { wire, replay, schema, cache, auth, usage };
}
function report(x) {
  return { requests: x.records.length, calls: x.calls, sizes: x.sizes, errors: x.errors, compatibility: x.rows.map(r => r.compatibility ?? null), transport: transport(x) };
}
const ALL_TRUE = { wire: true, replay: true, schema: true, cache: true, auth: true, usage: true };
const clone = x => JSON.parse(JSON.stringify(x));

// Controls exercise final observer bytes independently of missing profile metadata on the
// baseline. Transport known-goods come from the real local driver, not invented green rows.
// Synthetic metadata controls qualify comparison only; they do not qualify a model.
function controls(mode) {
  const known = [];
  for (const [provider, model, effort, role] of [
    ['chatgpt', 'gpt-6.1-sol', 'medium', 'build'], ['supergrok', 'grok-4.7', 'high', 'review'],
    ['opencode-go', 'kimi-k3.1-pro', 'high', 'build'], ['openai-compatible', 'qwen-coder', 'default', 'build'],
    ['anthropic', 'claude-sonnet-5-5', 'medium', 'review'],
  ]) {
    const x = drive({ provider, model, effort, role });
    subset(report(x), { requests: 2, calls: [1, 0], errors: [], transport: ALL_TRUE });
    known.push(x);
  }
  const budget = drive({ provider: 'chatgpt', model: 'gpt-6.1-sol', effort: 'medium', role: 'build', mode: 'budget' });
  const budgetExpected = { requests: 2, sizes: [524287, 524288, 524289], errors: [{ code: 'candidate/context_budget_exceeded', exit: 1 }] };
  subset(report(budget), budgetExpected);
  const rejected = drive({ provider: 'supergrok', model: 'no-such-model', effort: 'high', role: 'review', mode: 'reject' });
  subset(report(rejected), { requests: 1, calls: [] });
  assert.match(rejected.errors[0].message, /model not found/);
  const image = drive({ provider: 'anthropic', model: 'claude-sonnet-5-5', effort: 'medium', role: 'review', image: true });
  subset(report(image), { requests: 0, calls: [], errors: [{ code: 'provider/unsupported_capability', exit: 4 }] });
  const metadata = { compatibility: [{ status: 'supported', profile: 'chatgpt-sol-6-1', role: 'build', provider: 'chatgpt', model: 'gpt-6.1-sol', effort: 'medium' }] };
  subset(metadata, clone(metadata));
  const catalog = { schema_version: 1, profiles: [{ id: 'control', limits: { context_tokens: 1000000, max_input_tokens: null }, qualifications: [{ role: 'review', effort: 'medium' }] }] };
  subset(catalog, clone(catalog));
  if (mode === 'good') { process.stdout.write('observer good\n'); return 0; }
  assert.equal(mode, 'bad');
  // Each corruption is checked independently so a first failure cannot mask the deeper
  // schema/cache/replay/usage/auth and metadata comparison assertions.
  for (const x of known) {
    for (const [field, mutate] of [
      ['wire', z => { z.records[1].body.model = 'silently-replaced'; }],
      ['replay', z => { const b = z.records[1].body; (b.messages || b.input).splice(1, 1); }],
      ['schema', z => { const t = z.records[1].body.tools[0]; const f = t.function || t; (f.input_schema || f.parameters).properties.path.type = 'number'; }],
      ['cache', z => { z.records[1].body.prompt_cache_options = { ttl: 'invented' }; }],
      ['auth', z => { z.records[1].headers.Authorization = ['Bearer leaked-foreign-key']; z.records[1].headers['X-Api-Key'] = ['leaked-foreign-key']; }],
      ['usage', z => { z.rows[1].usage.cached = 999; }],
    ]) {
      const bad = clone(x); mutate(bad);
      assert.equal(transport(bad)[field], false, `accepted ${field} corruption on ${x.selection.Provider}`);
      assert.throws(() => subset(report(bad), { transport: ALL_TRUE }));
    }
  }
  const badBudget = report(clone(budget)); badBudget.sizes[2] = 524288;
  assert.throws(() => subset(badBudget, budgetExpected));
  for (const k of ['status', 'profile', 'role', 'provider', 'model', 'effort']) {
    const bad = clone(metadata); bad.compatibility[0][k] = 'wrong';
    assert.throws(() => subset(bad, metadata));
  }
  const missing = clone(metadata); delete missing.compatibility[0].profile;
  assert.throws(() => subset(missing, metadata));
  const extra = clone(catalog); extra.profiles.push(clone(extra.profiles[0]));
  assert.throws(() => subset(extra, catalog));
  const wrongNull = clone(catalog); wrongNull.profiles[0].limits.max_input_tokens = 0;
  assert.throws(() => subset(wrongNull, catalog));
  process.stdout.write('observer bad rejected\n'); return 1;
}

if (require.main === module) {
  let code = 2;
  try { assert.equal(process.argv[2], '--control'); code = controls(process.argv[3]); }
  catch (e) { process.stderr.write(String(e.stack || e) + '\n'); }
  finally { cleanup(); }
  process.exitCode = code;
} else {
  const { When, Then, AfterAll } = require('@cucumber/cucumber');
  AfterAll(cleanup);
  When('I inspect the model family catalog as JSON', function () {
    const b = build(), home = path.join(b.dir, 'catalog-home'); fs.mkdirSync(home, { recursive: true });
    const r = command(b.cli, ['provider', 'list', '--json'], { env: { HOME: home, PATH: process.env.PATH }, cwd: home });
    assert.equal(r.status, 0, r.stdout + r.stderr);
    this.familyJSON = JSON.parse(r.stdout);
  });
  When('I inspect the model family catalog as text', function () {
    const b = build(), home = path.join(b.dir, 'catalog-home'); fs.mkdirSync(home, { recursive: true });
    const r = command(b.cli, ['provider', 'list'], { env: { HOME: home, PATH: process.env.PATH }, cwd: home });
    assert.equal(r.status, 0, r.stdout + r.stderr); this.familyText = r.stdout;
  });
  Then('the model family JSON contains:', function (text) { subset(this.familyJSON, JSON.parse(text)); });
  Then('the model family text includes:', function (table) { for (const [s] of table.raw()) assert.ok(this.familyText.includes(s), `missing text ${s}: ${this.familyText}`); });
  When('I exercise the model family selection:', function (text) { this.familyRaw = drive(JSON.parse(text)); });
  Then('the model family report contains:', function (text) { subset(report(this.familyRaw), JSON.parse(text)); });
  Then('the model family error includes:', function (table) {
    const text = this.familyRaw.errors.map(e => e.message).join('\n');
    for (const [s] of table.raw()) assert.ok(text.includes(s), `missing error ${s}: ${text}`);
  });
}
