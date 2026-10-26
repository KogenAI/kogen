const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { Given, When, Then } = require('@cucumber/cucumber');
const ROOT = path.resolve(__dirname, '../..');
// Independent harness: reuse real HTTP fake/installer, never implementation test assertions. The stream scenarios call
// Kogen's provider and shaping-evidence packages from a tiny Go program; the native scenarios drive the installed `kogen`.
const H = require('./go_driver_support.js');
const httpSource = String.raw`package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"kogen-loop/provider"
	"kogen-loop/sys"
	"kogen/project"
	"kogen/shape"
)

func must(err error) {
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func main() {
	home, url := os.Args[1], os.Args[2]
	s := sys.NewWith([]string{"HOME=" + home, "KOGEN_PROVIDER_URL=" + url}, home)
	ev, err := shape.NewEvidence(filepath.Join(home, "evidence"), "fixture")
	must(err)
	role := provider.Role{Provider: "chatgpt", Model: "fixture", Effort: "medium"}
	client := provider.NewClient("kogen test (driver)")
	start := time.Now()
	call := ev.BeginCall("shape", "", "fixture", "", project.Role{Provider: role.Provider, Model: role.Model, Effort: role.Effort})
	resp, err := client.Respond(s.Context(), s, provider.Request{Role: role, Instructions: "local compatibility fixture", Input: []any{}, Tools: []any{}, Budget: 1500 * time.Millisecond, Single: true, Scope: "fixture"}, call)
	call.End(resp, err)
	result := map[string]any{}
	if err == nil {
		result["outcome"] = "ok"
		result["items"] = resp.Items
		result["usage"] = map[string]any{"input": resp.Usage.Input, "cached": resp.Usage.Cached, "output": resp.Usage.Output, "reasoning": resp.Usage.Reasoning}
		result["known_usage"] = resp.Known.Map()
	} else {
		var e *sys.Error
		if !errors.As(err, &e) {
			must(err)
		}
		result["outcome"], result["detail"] = e.Class+"/"+e.Reason, e.Detail
		if k, ok := e.ProviderFailure["event_kind"]; ok {
			result["failure_event"] = k
		}
	}
	result["elapsed"] = time.Since(start).Milliseconds()
	raw, err := os.ReadFile(filepath.Join(home, "evidence", "events.ndjson"))
	must(err)
	events := []any{}
	for _, line := range strings.Split(string(raw), "\n") {
		if strings.TrimSpace(line) == "" {
			continue
		}
		var row any
		must(json.Unmarshal([]byte(line), &row))
		events = append(events, row)
	}
	result["evidence"] = events
	out, err := json.Marshal(result)
	must(err)
	fmt.Println("COMPAT_RESULT=" + string(out))
	time.Sleep(50 * time.Millisecond)
}
`;
const USAGE = { input_tokens: 100, output_tokens: 20, input_tokens_details: { cached_tokens: 5 }, output_tokens_details: { reasoning_tokens: 10 } };
const UNKNOWN = { input: null, cached: null, output: null, reasoning: null };
const complete = r => ({ type: 'response.completed', response: r });
const done = (i, item) => ({ type: 'response.output_item.done', output_index: i, item });
const added = (i, item) => ({ type: 'response.output_item.added', output_index: i, item });
const frames = values => [
  ...values.flatMap((item, i) => {
    const partial = item.type === 'function_call' ? { ...item, arguments: '' } : item;
    const delta = item.type === 'function_call' ? [{ type: 'response.function_call_arguments.delta', output_index: i, item_id: item.id, delta: item.arguments }] : [];
    return [added(i, partial), ...delta];
  }),
  ...values.map((item, i) => [item, i]).reverse().map(([item, i]) => done(i, item)),
];
async function httpRun(items, mode) {
  const values = mode === 'malformed' ? items.map((x, i) => i === 2 ? { ...x, arguments: '{"path":' } : x) : items;
  let stream = frames(values);
  stream = { empty: () => [], gap: () => stream.filter(e => e.output_index !== 0), pending: () => [...stream, added(4, items[2]), { type: 'response.function_call_arguments.delta', output_index: 4, delta: '{"path":' }], sticky: () => [done(-1, items[0]), ...stream] }[mode]?.() ?? stream;
  let terminal = { status: 'completed', output: [], usage: USAGE };
  if (mode === 'usage') terminal = { ...terminal, usage: { input_tokens_details: 42 } };
  if (mode === 'status') terminal = { ...terminal, status: 'incomplete' };
  if (mode === 'response-error') terminal = { ...terminal, error: { code: 'fixture_error' } };
  const failure = { failed: [{ type: 'response.failed', response: { error: {} } }], incomplete: [{ type: 'response.incomplete', response: { incomplete_details: {} } }], error: [{ type: 'error', error: {} }] }[mode] || [];
  const events = [...stream, ...failure, complete(terminal)];
  const server = await new H.FakeProvider([mode === 'complete' ? { openEvents: events } : { events }]).start();
  const home = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'terminal-compat-')));
  try {
    fs.mkdirSync(path.join(home, '.kogen/credentials'), { recursive: true });
    fs.writeFileSync(path.join(home, '.kogen/credentials/chatgpt.json'), JSON.stringify({ client_id: 'oaiapp_fixture', access_token: 'fake-access', refresh_token: 'fake-refresh', expires_at: Math.floor(Date.now() / 1000) + 3600 }));
    const driver = await H.goDriver('terminal-compat', httpSource);
    const r = await driver([home, `http://127.0.0.1:${server.port}`]);
    assert.equal(r.code, 0, r.out);
    const line = r.out.split('\n').find(l => l.startsWith('COMPAT_RESULT='));
    assert.ok(line, r.out);
    const result = JSON.parse(line.slice('COMPAT_RESULT='.length));
    const opened = mode === 'complete' ? await server.waitOpen(1000).then(() => true, () => false) : false;
    const closed = mode === 'complete' ? await server.waitClosed(1500).then(x => x === 'closed', () => false) : false;
    const calls = result.evidence.filter(e => e.event === 'provider_call');
    // A provider that reports the categories it knows: the unreported ones are not part of the usage the response carries.
    if (result.known_usage) result.known_usage = Object.fromEntries(Object.entries(result.known_usage).filter(([, v]) => v !== null));
    delete result.evidence;
    return { ...result, requests: server.providerRequests().length, socket_open_seen: opened, socket_closed: closed, returned_before_hold: result.elapsed < 1500, failed_usage_unknown: calls.length === 1 && calls.every(e => e.status === 'failed' && same(e.usage, UNKNOWN)) };
  } finally { await server.stop(); fs.rmSync(home, { recursive: true, force: true }); }
}
const sortKeys = x => Array.isArray(x) ? x.map(sortKeys) : x && typeof x === 'object' ? Object.fromEntries(Object.keys(x).sort().map(k => [k, sortKeys(x[k])])) : x;
const same = (a, b) => JSON.stringify(sortKeys(a)) === JSON.stringify(sortKeys(b));
async function nativeRun(items, mode) {
  const suite = await H.setupSuite(); let c;
  try {
    const tool = { type: 'function_call', id: 'read-compat', call_id: 'read-compat', status: 'completed', name: 'read_file', arguments: JSON.stringify({ path: 'app.txt' }) };
    const prefix = items.slice(0, 2);
    let stream;
    if (mode === 'pending') stream = [...frames(prefix), added(2, { ...tool, arguments: '' }), { type: 'response.function_call_arguments.delta', output_index: 2, delta: '{"path":' }];
    else if (mode === 'malformed') stream = frames([...prefix, { ...tool, arguments: '{"path":' }]);
    else stream = frames([...prefix, tool]);
    const first = { events: [...stream, complete({ status: 'completed', output: [], usage: USAGE })] };
    const question = H.fn('submit', { questions: [{ question: 'Fixture tool reached?', options: [{ label: 'Yes', recommended: true }] }] });
    c = await H.project(suite, mode === 'complete' ? [first, question] : [first, first], { stagedIntent: false });
    const authority = async () => [await H.git(c, ['rev-parse', 'HEAD']), fs.readFileSync(path.join(c.repo, '.git/index')).toString('latin1'), fs.readFileSync(H.approvalPath(c.repo, 'fixture'), 'latin1')];
    const before = await authority();
    const helpers = () => fs.readdirSync(path.join(c.repo, 'features/steps')).sort();
    const helpersBefore = helpers();
    const request = path.join(c.root, 'request.txt');
    fs.writeFileSync(request, 'Read app.txt then ask the fixture question; publish no files.');
    const { out, code } = await H.runKogen(c, ['intent', 'shape', 'compat-next', request]);
    return { exit: code, question_displayed: out.includes('Fixture tool reached?'), read_effect: c.server.toolOutputs(), requests_after_init: c.server.providerRequests().length - 1, authority_unchanged: same(await authority(), before), no_intent_or_helper: !fs.existsSync(path.join(c.repo, '.kogen/intents/compat-next')) && same(helpers(), helpersBefore) };
  } finally { await H.cleanupCase(c); H.cleanupSuite(suite); }
}
Given('these documented compatibility items:', function (text) {
  this.compatItems = JSON.parse(text);
  assert.ok(Array.isArray(this.compatItems) && this.compatItems.length > 1);
});
When('I run the compatibility HTTP stream {string}', { timeout: 250000 }, async function (mode) {
  assert.ok(['complete','pending','malformed','empty','sticky','usage','status','response-error','gap','failed','incomplete','error'].includes(mode));
  this.compatResult = await httpRun(this.compatItems, mode);
});
When('I run installed compatibility Shape in mode {string}', { timeout: 250000 }, async function (mode) {
  assert.ok(['complete','pending','malformed'].includes(mode));
  this.compatResult = await nativeRun(this.compatItems, mode);
});
Then('the compatibility response contains exactly the documented items', function () {
  assert.deepEqual(this.compatResult.items, this.compatItems, JSON.stringify(this.compatResult));
});
function structural(result) {
  const prefix = 'the completed response has invalid or unfinished output; validation=';
  assert.ok(result.detail?.startsWith(prefix), JSON.stringify(result));
  const bytes = result.detail.slice(prefix.length);
  assert.ok(Buffer.byteLength(bytes) <= 2048);
  const data = JSON.parse(bytes);
  assert.deepEqual(Object.keys(data).sort(), ['facts', 'reasons']);
  const allowed = ['item_event_shape','terminal_envelope','response_status','response_error','usage_shape','terminal_output_shape','terminal_index_coverage','empty_output','noncontiguous_indexes','pending_items','item_status','item_shape'];
  assert.ok(data.reasons.length > 0 && data.reasons.every(x => allowed.includes(x)));
  assert.deepEqual(data.reasons, [...new Set(data.reasons)].sort());
  const f = data.facts;
  assert.deepEqual(Object.keys(f).sort(), ['event_kind','done','terminal_response_present','terminal_output_present','terminal_output_replaced','item_count','pending_count','observed_index_count','counts_capped','indexes_contiguous','item_types','item_statuses','arguments_object'].sort());
  assert.equal(f.event_kind, 'response.completed'); assert.equal(f.done, true);
  for (const k of ['terminal_response_present','terminal_output_present','terminal_output_replaced','counts_capped','indexes_contiguous']) assert.equal(typeof f[k], 'boolean');
  for (const k of ['item_count','pending_count','observed_index_count']) assert.ok(Number.isInteger(f[k]) && f[k] >= 0 && f[k] <= 1024);
  for (const [key, values] of Object.entries({ item_types: ['function_call','message','reasoning','other','unknown'], item_statuses: ['completed','in_progress','incomplete','failed','other','unknown'], arguments_object: ['yes','no','unknown'] })) {
    assert.ok(Array.isArray(f[key]) && f[key].every(x => values.includes(x)));
    assert.deepEqual(f[key], [...new Set(f[key])].sort());
  }
  // Schema and finite categories above prohibit raw payload/name/ID/argument fields.
  return data;
}
Then('the compatibility observations are:', function (table) {
  const result = this.compatResult;
  const obs = { ...result, returned_items: Object.hasOwn(result, 'items') };
  if (table.raw().some(([key]) => key === 'safe_bounded_evidence')) {
    const data = structural(result);
    Object.assign(obs, data.facts, { reasons: data.reasons, safe_bounded_evidence: true });
  }
  const failures = [];
  for (const [key, text] of table.raw()) {
    try { assert.deepEqual(obs[key], JSON.parse(text), key); }
    catch (e) { failures.push(e.message); }
  }
  assert.deepEqual(failures, [], JSON.stringify(result));
});
