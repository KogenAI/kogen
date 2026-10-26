const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { When, Then } = require('@cucumber/cucumber');
const ROOT = path.resolve(__dirname, '../..');
let transportExercise, nativeExercise;
// Independent assertions below consume only real respond results and installed CLI results. The shared fake and installer are
// reused, not the implementation tests. The transport cases call Kogen's provider and shaping-evidence packages from a tiny Go program.
const H = require('./go_driver_support.js');
const MARKER = 'PRIVATE_TERMINAL_PAYLOAD_9f71';
const USAGE = { input_tokens: 100, output_tokens: 20, input_tokens_details: { cached_tokens: 5 }, output_tokens_details: { reasoning_tokens: 10 } };
const tool = { type: 'function_call', status: 'completed', name: MARKER, call_id: MARKER, id: MARKER, arguments: JSON.stringify({ private: MARKER }) };
const message = { type: 'message', status: 'completed', role: 'assistant', content: [{ type: 'output_text', text: MARKER, annotations: [] }] };
const done = r => ({ type: 'response.completed', response: r });
const itemDone = (i, item) => ({ type: 'response.output_item.done', output_index: i, item });
const added = i => ({ type: 'response.output_item.added', output_index: i, item: tool });
const badArgs = { ...tool, arguments: `{"private":"${MARKER}"` };
const UNKNOWN = { input: null, cached: null, output: null, reasoning: null };
const sortKeys = x => Array.isArray(x) ? x.map(sortKeys) : x && typeof x === 'object' ? Object.fromEntries(Object.keys(x).sort().map(k => [k, sortKeys(x[k])])) : x;
const same = (a, b) => JSON.stringify(sortKeys(a)) === JSON.stringify(sortKeys(b));
const transportSource = String.raw`package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
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
	home, url, cases := os.Args[1], os.Args[2], os.Args[3]
	n, err := strconv.Atoi(cases)
	must(err)
	probe := len(os.Args) > 4 && os.Args[4] == "probe"
	s := sys.NewWith([]string{"HOME=" + home, "KOGEN_PROVIDER_URL=" + url}, home)
	ev, err := shape.NewEvidence(filepath.Join(home, "evidence"), "fixture")
	must(err)
	role := provider.Role{Provider: "chatgpt", Model: "fixture", Effort: "medium"}
	client := provider.NewClient("kogen test (driver)")
	call := func(single bool) (*provider.Response, error) {
		c := ev.BeginCall("shape", "", "fixture", "", project.Role{Provider: role.Provider, Model: role.Model, Effort: role.Effort})
		resp, err := client.Respond(s.Context(), s, provider.Request{Role: role, Instructions: "local fixture", Input: []any{}, Tools: []any{}, Budget: 1000 * time.Millisecond, Single: single, Scope: "fixture"}, c)
		c.End(resp, err)
		return resp, err
	}
	var errs []any
	if probe {
		// One rejected response on its own: the predicates the rejection reports.
		_, err := call(true)
		var e *sys.Error
		if !errors.As(err, &e) {
			must(fmt.Errorf("expected a rejection, got %v", err))
		}
		out, err := json.Marshal(map[string]any{"detail": e.Detail})
		must(err)
		fmt.Println("TERMINAL_RESULT=" + string(out))
		return
	}
	for i := 0; i < n; i++ {
		resp, err := call(true)
		row := map[string]any{"returned": err == nil}
		if err != nil {
			var e *sys.Error
			if !errors.As(err, &e) {
				must(err)
			}
			row["class"], row["reason"], row["detail"], row["exit"], row["rendered"], row["provider_failure"] = e.Class, e.Reason, e.Detail, e.Exit, e.Error(), e.ProviderFailure
		} else {
			_ = resp
		}
		errs = append(errs, row)
	}
	var results []any
	for _, single := range []bool{true, true, true, false} {
		resp, err := call(single)
		must(err)
		results = append(results, map[string]any{"items": resp.Items, "usage": map[string]any{"input": resp.Usage.Input, "cached": resp.Usage.Cached, "output": resp.Usage.Output, "reasoning": resp.Usage.Reasoning}, "known_usage": resp.Known.Map()})
	}
	must(ev.Finish())
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
	out, err := json.Marshal(map[string]any{"errors": errs, "results": results, "events": events})
	must(err)
	fmt.Println("TERMINAL_RESULT=" + string(out))
	time.Sleep(50 * time.Millisecond)
}
`;
async function transportRun() {
  const base = { output: [tool], status: 'completed', usage: USAGE };
  const cases = [
    ['status', [done({ ...base, status: MARKER })]],
    ['error', [done({ ...base, error: { message: MARKER, code: MARKER } })]],
    ['usage', [done({ ...base, usage: MARKER })]],
    ['output-shape', [itemDone(0, tool), done({ output: MARKER })]],
    ['event-shape', [itemDone(-1, tool), done(base)]],
    ['coverage', [added(1), done(base)]],
    ['gap', [itemDone(1, tool), done({})]],
    ['pending', [itemDone(0, tool), added(1), done({})]],
    ['arguments', [done({ ...base, output: [badArgs] })]],
    ['item-status', [done({ ...base, output: [{ ...tool, status: 'in_progress' }] })]],
    ['unknown-item', [done({ ...base, output: [{ type: MARKER, status: MARKER, body: MARKER }] })]],
    ['envelope', [{ type: 'response.completed', response: MARKER }]],
    ['empty', [done({ output: [] })]],
    ['replaced-invalid', [itemDone(0, tool), done({ ...base, output: [badArgs] })]],
    ['saturated', [done({ ...base, output: Array(1025).fill(badArgs) })]],
  ];
  // Documentation-shaped fixtures, not captured live provider responses.
  const stream = [added(0), { type: 'response.function_call_arguments.delta', output_index: 0, delta: tool.arguments }, { type: 'response.function_call_arguments.done', output_index: 0, arguments: tool.arguments }, itemDone(0, tool), done({ status: 'completed', usage: USAGE })];
  const terminal = [done({ status: 'completed', output: [message], usage: USAGE })];
  const replacement = [added(0), itemDone(0, badArgs), done(base)];
  const script = [...cases.map(([, events]) => ({ events })), ...[stream, terminal, replacement, [done({ ...base, usage: MARKER })], stream].map(events => ({ events }))];
  const server = await new H.FakeProvider(script).start();
  const home = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'terminal-evidence-')));
  try {
    fs.mkdirSync(path.join(home, '.kogen/credentials'), { recursive: true });
    fs.writeFileSync(path.join(home, '.kogen/credentials/chatgpt.json'), JSON.stringify({ client_id: 'oaiapp_fixture', access_token: 'fake-access', refresh_token: 'fake-refresh', expires_at: Math.floor(Date.now() / 1000) + 3600 }));
    const driver = await H.goDriver('terminal-evidence', transportSource);
    const r = await driver([home, `http://127.0.0.1:${server.port}`, String(cases.length)]);
    assert.equal(r.code, 0, r.out);
    const line = r.out.split('\n').find(l => l.startsWith('TERMINAL_RESULT=')); assert.ok(line, r.out);
    const result = JSON.parse(line.slice('TERMINAL_RESULT='.length));
    const errors = Object.fromEntries(cases.map(([name], i) => [name, result.errors[i]]));
    const [a, b, c, d] = result.results;
    // The usage a response carries names the categories the provider reported.
    for (const x of [a, b, c, d]) x.known_usage = Object.fromEntries(Object.entries(x.known_usage).filter(([, v]) => v !== null));
    const calls = result.events.filter(e => e.event === 'provider_call');
    const expectedUsage = { input: 100, cached: 5, output: 20, reasoning: 10 };
    const observations = {
      'documented stream exact output': same(a.items, [tool]), 'documented terminal exact output': same(b.items, [message]), 'terminal replacement exact output': same(c.items, [tool]),
      'valid usage preserved': [a, b, c, d].every(x => same(x.usage, expectedUsage) && same(x.known_usage, expectedUsage)), 'invalid retry exact output': same(d.items, [tool]),
      'retry attempt statuses': calls.slice(-2).map(e => e.status), 'retry attempts': server.providerRequests().length - cases.length - 3,
      'retry failure usage unknown': same(calls.at(-2).usage, UNKNOWN),
      'direct failures retain unknown usage': calls.slice(0, cases.length).every(e => e.status === 'failed' && same(e.usage, UNKNOWN)),
      'invalid items not returned': Object.values(errors).every(e => !e.returned && e.class === 'provider' && e.reason === 'invalid_response' && e.exit === 4),
    };
    return { errors, events: result.events, observations };
  } finally { await server.stop(); fs.rmSync(home, { recursive: true, force: true }); }
}
async function nativeRun() {
  const suite = await H.setupSuite(); let c;
  try {
    const first = done({ status: MARKER, output: [tool], usage: USAGE });
    const second = done({ status: 'completed', output: [badArgs], usage: USAGE });
    c = await H.project(suite, [{ events: [first] }, { events: [second] }], { stagedIntent: false });
    const authority = async () => [await H.git(c, ['rev-parse', 'HEAD']), fs.readFileSync(path.join(c.repo, '.git/index')).toString('latin1'), fs.readFileSync(H.approvalPath(c.repo, 'fixture'), 'latin1')];
    const before = await authority();
    const request = path.join(c.root, 'request.txt');
    fs.writeFileSync(request, 'Exercise safe terminal validation without publishing any files.');
    const { out, code: status } = await H.runKogen(c, ['intent', 'shape', 'diagnostic-next', request]);
    const eventsText = fs.readFileSync(path.join(c.repo, '.kogen/local/shaping/diagnostic-next/events.ndjson'), 'utf8');
    const events = eventsText.split('\n').filter(Boolean).map(l => JSON.parse(l));
    const calls = events.filter(e => e.event === 'provider_call');
    return { output: out, events, observations: {
      'native exit': status,
      'native prefix preserved': out.includes('provider/invalid_response: ChatGPT sent a response Kogen cannot read: the completed response has invalid or unfinished output'),
      'native attempt statuses': calls.map(e => e.status), 'native failure usage unknown': calls.length === 2 && calls.every(e => same(e.usage, UNKNOWN)),
      'native requests after init': c.server.providerRequests().length - 1, 'native tool outputs': c.server.toolOutputs().length,
      'native no Intent or helper': !fs.existsSync(path.join(c.repo, '.kogen/intents/diagnostic-next')) && !fs.existsSync(path.join(c.repo, MARKER)),
      'native authority unchanged': same(await authority(), before), 'native evidence and output private': !(out + eventsText).includes(MARKER),
    } };
  } finally { await H.cleanupCase(c); H.cleanupSuite(suite); }
}
function run(driver) {
  // Neither the output nor the evidence of a Kogen run may carry the adversarial string (the documented items it legitimately returns are not part of either).
  return driver().then(r => { r.observations['no adversarial strings in output or events'] = !JSON.stringify({ output: r.output, rendered: Object.values(r.errors || {}).map(e => e.rendered), events: r.events }).includes(MARKER); return r; });
}
// The predicates a single rejected response reports, observed by sending that response on its own.
async function rejectionOf(response) {
  const server = await new H.FakeProvider([{ events: [response] }]).start();
  const home = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'terminal-probe-')));
  try {
    fs.mkdirSync(path.join(home, '.kogen/credentials'), { recursive: true });
    fs.writeFileSync(path.join(home, '.kogen/credentials/chatgpt.json'), JSON.stringify({ client_id: 'oaiapp_fixture', access_token: 'fake-access', refresh_token: 'fake-refresh', expires_at: Math.floor(Date.now() / 1000) + 3600 }));
    const driver = await H.goDriver('terminal-evidence', transportSource);
    const r = await driver([home, `http://127.0.0.1:${server.port}`, '1', 'probe']);
    assert.equal(r.code, 0, r.out);
    const line = r.out.split('\n').find(l => l.startsWith('TERMINAL_RESULT=')); assert.ok(line, r.out);
    return evidence(JSON.parse(line.slice('TERMINAL_RESULT='.length)).detail).reasons;
  } finally { await server.stop(); fs.rmSync(home, { recursive: true, force: true }); }
}
function evidence(detail) {
  assert.equal(typeof detail, 'string');
  const prefix = 'the completed response has invalid or unfinished output; validation=';
  assert.ok(detail.startsWith(prefix), `missing safe terminal explanation: ${detail}`);
  const json = detail.slice(prefix.length);
  assert.ok(Buffer.byteLength(json) <= 2048, 'unbounded structural evidence');
  const e = JSON.parse(json);
  assert.deepEqual(Object.keys(e).sort(), ['facts', 'reasons']);
  const allowed = ['item_event_shape','terminal_envelope','response_status','response_error','usage_shape','terminal_output_shape','terminal_index_coverage','empty_output','noncontiguous_indexes','pending_items','item_status','item_shape'];
  assert.ok(e.reasons.length > 0 && e.reasons.every(x => allowed.includes(x)));
  assert.deepEqual(e.reasons, [...new Set(e.reasons)].sort());
  const f = e.facts;
  assert.deepEqual(Object.keys(f).sort(), ['event_kind','done','terminal_response_present','terminal_output_present','terminal_output_replaced','item_count','pending_count','observed_index_count','counts_capped','indexes_contiguous','item_types','item_statuses','arguments_object'].sort());
  assert.equal(f.event_kind, 'response.completed'); assert.equal(f.done, true);
  for (const k of ['terminal_response_present','terminal_output_present','terminal_output_replaced','counts_capped','indexes_contiguous']) assert.equal(typeof f[k], 'boolean');
  for (const k of ['item_count','pending_count','observed_index_count']) assert.ok(Number.isInteger(f[k]) && f[k] >= 0 && f[k] <= 1024);
  for (const [key, values] of Object.entries({ item_types: ['function_call','message','reasoning','other','unknown'], item_statuses: ['completed','in_progress','incomplete','failed','other','unknown'], arguments_object: ['yes','no','unknown'] })) {
    assert.ok(Array.isArray(f[key]) && f[key].every(v => values.includes(v)));
    assert.deepEqual(f[key], [...new Set(f[key])].sort());
  }
  return e;
}
When('I exercise terminal validation evidence through the real local transport', { timeout: 250000 }, async function () {
  if (!transportExercise) transportExercise = run(transportRun);
  this.terminalEvidence = await transportExercise;
});
When('I exercise terminal validation evidence through installed native Shape', { timeout: 250000 }, async function () {
  if (!nativeExercise) nativeExercise = run(nativeRun);
  this.terminalEvidence = await nativeExercise;
});
Then('the terminal rejection categories are:', function (table) {
  const r = this.terminalEvidence;
  const failures = [];
  for (const { fixture, reasons } of table.hashes()) {
    try { assert.deepEqual(evidence(r.errors[fixture].detail).reasons, reasons.split(',').sort()); }
    catch (e) { failures.push(`${fixture}: ${e.message}`); }
  }
  assert.deepEqual(failures, []);
});
Then('the terminal evidence observations are:', async function (table) {
  const r = this.terminalEvidence, obs = { ...r.observations };
  // Derive observations lazily so baseline red still reports each scenario once.
  for (const [key, text] of table.raw()) {
    if (key === 'safe bounded structural metadata') obs[key] = Object.values(r.errors).every(x => Boolean(evidence(x.detail)));
    if (key === 'saturated counts') { const f = evidence(r.errors.saturated.detail).facts; obs[key] = f.item_count === 1024 && f.counts_capped && f.arguments_object.join() === 'no'; }
    if (key === 'effective replacement facts') { const f = evidence(r.errors['replaced-invalid'].detail).facts; obs[key] = f.terminal_output_replaced && f.terminal_output_present && f.terminal_response_present && f.observed_index_count === 1 && f.item_count === 1 && f.pending_count === 0 && f.indexes_contiguous && f.arguments_object.join() === 'no'; }
    if (key === 'unknown type and status categorized') { const f = evidence(r.errors['unknown-item'].detail).facts; obs[key] = f.item_types.join() === 'other' && f.item_statuses.join() === 'other'; }
    // (A rejected attempt records only that it failed; its predicates are what the same response reports when it is the final one.)
    if (key === 'retry failed predicate') obs[key] = (await rejectionOf(done({ output: [tool], status: 'completed', usage: MARKER }))).join(',');
    if (key === 'native predicates') obs[key] = [await rejectionOf(done({ status: MARKER, output: [tool], usage: USAGE })), await rejectionOf(done({ status: 'completed', output: [badArgs], usage: USAGE }))];
    let expected; try { expected = JSON.parse(text); } catch { expected = text; }
    assert.deepEqual(obs[key], expected, key);
  }
});
