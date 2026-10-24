const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const H = require('./go_driver_support.js');

// Transient stream retry, observed on the installed Go program. The Build entry runs the installed `kogen intent build`
// against a scripted local provider; the transport entry calls Kogen's provider client (provider.Client.Respond with the
// shaping evidence recorder) through a tiny Go driver, because the single-attempt flag, the absolute response budget and
// cancellation have no installed-command form.
const transportSource = String.raw`package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"kogen/project"
	"kogen/provider"
	"kogen/shape"
	"kogen/sys"
)

func must(err error) {
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func main() {
	home, url, configPath := os.Args[1], os.Args[2], os.Args[3]
	raw, err := os.ReadFile(configPath)
	must(err)
	var c struct {
		Provider string
		Single   bool
		Budget   int
		Cancel   bool
	}
	must(json.Unmarshal(raw, &c))
	s := sys.NewWith([]string{"HOME=" + home, "KOGEN_PROVIDER_URL=" + url, "KOGEN_AUTH_URL=" + url}, home)
	ev, err := shape.NewEvidence(filepath.Join(home, "evidence"), "fixture")
	must(err)
	time.AfterFunc(60*time.Second, func() { s.Interrupt("WATCHDOG") })
	if c.Cancel {
		time.AfterFunc(200*time.Millisecond, func() { s.Interrupt("SIGINT") })
	}
	role := provider.Role{Model: "gpt-6.1-sol", Effort: "medium"}
	if c.Provider == "supergrok" {
		role = provider.Role{Provider: "supergrok", Model: "grok-4.7", Effort: "low"}
	}
	budget := time.Duration(c.Budget) * time.Millisecond
	if c.Budget == 0 {
		budget = 15 * time.Second
	}
	started := time.Now()
	client := provider.NewClient("kogen test (driver)")
	call := ev.BeginCall("shape", "", "fixture", "", project.Role{Provider: role.Provider, Model: role.Model, Effort: role.Effort})
	resp, err := client.Respond(s.Context(), s, provider.Request{Role: role, Instructions: "retry authority", Input: []any{map[string]any{"role": "user", "content": "retry contract"}}, Tools: []any{}, Budget: budget, Single: c.Single, Scope: "retry"}, call)
	call.End(resp, err)
	result := map[string]any{}
	if err == nil {
		result["outcome"] = "ok"
		result["items"] = resp.Items
		result["usage"] = map[string]any{"input": resp.Usage.Input, "cached": resp.Usage.Cached, "output": resp.Usage.Output, "reasoning": resp.Usage.Reasoning}
	} else {
		var i *sys.Interrupted
		var e *sys.Error
		switch {
		case errors.As(err, &i):
			result["outcome"] = "cancel/" + i.Signal
		case errors.As(err, &e):
			result["outcome"], result["exit"], result["diagnostics"], result["detail"] = e.Class+"/"+e.Reason, e.Exit, e.ProviderFailure, e.Detail
		default:
			must(err)
		}
	}
	result["entry"] = "transport"
	result["elapsed"] = time.Since(started).Milliseconds()
	data, err := os.ReadFile(filepath.Join(home, "evidence", "events.ndjson"))
	must(err)
	rows := []any{}
	for _, line := range strings.Split(string(data), "\n") {
		if strings.TrimSpace(line) == "" {
			continue
		}
		var row any
		must(json.Unmarshal([]byte(line), &row))
		rows = append(rows, row)
	}
	result["rows"] = rows
	out, err := json.Marshal(result)
	must(err)
	fmt.Println("RETRY_RESULT=" + string(out))
}
`;

const readRows = file => fs.readFileSync(file, 'utf8').split('\n').filter(Boolean).map(l => JSON.parse(l));
function failureEvent(c) {
  const error = { ...c.error, private_payload: 'SECRET_RETRY_PAYLOAD' };
  switch (c.event) {
    case 'flat': return { ...error, type: 'error' };
    case 'response.failed': return { type: 'response.failed', response: { error } };
    case 'response.incomplete': return { type: 'response.incomplete', response: { incomplete_details: { reason: 'max_output_tokens' } } };
    default: return { type: 'error', error };
  }
}
function badAnswer(c) {
  const partial = { type: 'function_call', call_id: 'unconfirmed', name: 'shell', arguments: JSON.stringify({ command: 'touch .kogen/local/partial-tool' }) };
  return { events: [{ type: 'response.output_item.done', output_index: 0, item: partial }, failureEvent(c)] };
}

let sharedSuite;
const suite = async () => { if (!sharedSuite) sharedSuite = await H.setupSuite(); return sharedSuite; };

async function transport(c) {
  const item = { type: 'message', role: 'assistant', content: [{ type: 'output_text', text: 'recovered', annotations: [] }] };
  const usage = { input_tokens: 100, input_tokens_details: { cached_tokens: 5 }, output_tokens: 20, output_tokens_details: { reasoning_tokens: 10 } };
  const good = { events: [{ type: 'response.completed', response: { status: 'completed', output: [item], usage } }] };
  const server = await new H.FakeProvider([...Array(c.failures).fill(badAnswer(c)), good]).start();
  const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-stream-retry-')));
  try {
    const provider = c.provider || 'chatgpt';
    fs.mkdirSync(path.join(dir, '.kogen/credentials'), { recursive: true });
    fs.writeFileSync(path.join(dir, '.kogen/credentials', `${provider}.json`), JSON.stringify({ client_id: 'oaiapp_fixture', access_token: 'fake-access', refresh_token: 'fake-refresh', expires_at: Math.floor(Date.now() / 1000) + 3600, referrer: 'kogen' }));
    const config = path.join(dir, 'config.json'); fs.writeFileSync(config, JSON.stringify(c));
    const driver = await H.goDriver('transient-retry', transportSource);
    const r = await driver([dir, `http://127.0.0.1:${server.port}`, config]);
    assert.equal(r.code, 0, r.out);
    const line = r.out.split('\n').find(l => l.startsWith('RETRY_RESULT='));
    assert.ok(line, r.out);
    const result = JSON.parse(line.slice('RETRY_RESULT='.length));
    result.requests = server.providerRequests().map(x => x.json);
    return result;
  } finally { await server.stop(); fs.rmSync(dir, { recursive: true, force: true }); }
}

async function build(c) {
  const script = [H.fn('shell', { command: "printf 'verified edit\\n' > app.txt; printf x >> .kogen/local/tool-count" }), ...Array(c.failures).fill(badAnswer(c)), H.fn('finish', { summary: 'Ready' }), H.fn('submit_review', { verdict: 'approve', findings: [] })];
  const ctx = await H.project(await suite(), script, { stagedIntent: false });
  try {
    const approval = H.approvalPath(ctx.repo, 'fixture');
    const index = () => fs.readFileSync(path.join(ctx.repo, '.git/index')).toString('base64');
    const before = { head: await H.git(ctx, ['rev-parse', 'HEAD']), index: index(), approval: fs.readFileSync(approval, 'utf8') };
    const { out, code } = await H.runKogen(ctx, ['intent', 'build', 'fixture']);
    const [result] = H.wildcard(path.join(ctx.repo, '.kogen/local/runs/*/result.json'));
    const rows = readRows(H.runLog(ctx));
    const requests = ctx.server.providerRequests().slice(1).map(r => r.json);
    return {
      entry: 'build', output: out, exit: code, result: JSON.parse(fs.readFileSync(result, 'utf8')), rows, requests, before,
      after: { head: await H.git(ctx, ['rev-parse', 'HEAD']), index: index(), approval: fs.existsSync(approval) ? fs.readFileSync(approval, 'utf8') : null },
      app: fs.readFileSync(path.join(ctx.repo, 'app.txt'), 'utf8'), count: fs.readFileSync(path.join(ctx.repo, '.kogen/local/tool-count'), 'utf8'),
      partial: fs.existsSync(path.join(ctx.repo, '.kogen/local/partial-tool')),
      status: await H.gitBang(ctx, ['status', '--porcelain']),
      committed_app: await H.gitBang(ctx, ['show', 'HEAD:app.txt']),
    };
  } finally { await H.cleanupCase(ctx); }
}
const run = c => c.entry === 'build' ? build(c) : transport(c);

function verify(r, expected) {
  const ps = r.rows.filter(x => x.provider).map(x => x.provider);
  const failed = ps.filter(p => p.outcome !== 'completed');
  assert.equal(r.requests.length, expected.requests, 'requests');
  assert.equal(ps.length, r.requests.length, 'one retained row per request');
  assert.equal(failed.length, expected.failed, 'failed rows');
  assert.ok(failed.every(p => p.usage_state === 'unknown' && Object.values(p.usage).every(x => x === null)), 'unknown failed usage');
  assert.equal(new Set(ps.map(p => p.attempt_id)).size, ps.length, 'distinct attempts');
  assert.ok(!JSON.stringify(r.rows).includes('SECRET_RETRY_PAYLOAD'), 'safe retained diagnostics');
  const retryRequests = r.entry === 'build' ? r.requests.slice(1, 4) : r.requests;
  for (const body of retryRequests) assert.deepEqual(body, retryRequests[0], 'retry must preserve complete request');
  const retryPs = r.entry === 'build' ? ps.slice(1, 4) : ps;
  assert.equal(new Set(retryPs.map(p => p.operation_id)).size, 1, 'one logical retry operation');
  for (let i = 0; i < (expected.waits || []).length; i++) {
    const gap = Date.parse(retryPs[i + 1].timestamp) - Date.parse(retryPs[i].timestamp) - retryPs[i].wall_ms;
    assert.ok(gap >= expected.waits[i] * 1000 - 100 && gap < expected.waits[i] * 1000 + 8000, `backoff ${i}: ${gap}`);
  }
  if (r.entry === 'build') {
    assert.equal(r.exit, expected.exit, 'Build exit');
    assert.equal(r.app, 'verified edit\n', 'candidate retained');
    assert.equal(r.count, 'x', 'completed tool runs exactly once');
    assert.equal(r.partial, false, 'failed partial tool never runs');
    assert.equal(r.rows.filter(x => x.event === 'tool_call' && x.name === 'shell').length, 1, 'one executed shell');
    if (expected.exit === 0) {
      assert.notEqual(r.after.head, r.before.head, 'landed commit');
      assert.equal(r.committed_app, r.app, 'verified committed app');
      assert.equal(r.after.approval, null, 'landing consumes approval');
      assert.equal(r.status, '', 'clean landing');
      assert.equal(r.result.reviews, 1, 'fresh review');
      assert.ok(r.result.passes >= 1, 'verification ran');
    } else {
      assert.equal(r.after.head, r.before.head, 'no commit');
      assert.equal(r.after.index, r.before.index, 'index retained');
      assert.equal(r.after.approval, r.before.approval, 'unlanded approval retained');
      assert.equal(r.committed_app, 'baseline\n', 'baseline remains committed');
      assert.equal(r.result.passes, 0, 'not verified after failure');
      assert.ok(r.output.includes('provider/unavailable'), 'honest exhausted failure');
      assert.deepEqual(r.result.provider_failure, expected.diagnostics, 'Build final diagnostics');
    }
  } else {
    assert.equal(r.outcome, expected.outcome, 'transport outcome');
    if (r.outcome === 'ok') {
      assert.deepEqual(r.items, [{ type: 'message', role: 'assistant', content: [{ type: 'output_text', text: 'recovered', annotations: [] }] }], 'only completed output');
      assert.deepEqual(r.usage, { input: 100, cached: 5, output: 20, reasoning: 10 }, 'completed usage');
    } else {
      assert.ok(!r.items, 'no failed output returned');
      if (r.outcome.startsWith('provider/')) assert.equal(r.exit, 4, 'provider exit');
      if (expected.diagnostics) assert.deepEqual(r.diagnostics, expected.diagnostics, 'last diagnostics');
    }
    if (expected.elapsed) assert.ok(r.elapsed >= expected.elapsed[0] && r.elapsed <= expected.elapsed[1], `elapsed ${r.elapsed}`);
  }
}
async function controls(mode) {
  // Exercise deeper assertions with existing known transients, not the missing feature.
  const c = { entry: 'transport', provider: 'chatgpt', event: 'error', error: { code: 'server_error', type: 'capacity', message: 'known transient' }, failures: 2 };
  const good = [
    [await run(c), { outcome: 'ok', requests: 3, failed: 2, waits: [2, 8] }],
    [await run({ ...c, entry: 'build' }), { exit: 0, requests: 5, failed: 2, waits: [2, 8] }],
    [await run({ ...c, entry: 'build', failures: 3 }), { exit: 4, requests: 4, failed: 3, waits: [2, 8], diagnostics: { code: 'server_error', type: 'capacity', event_kind: 'error' } }],
  ];
  for (const [r, e] of good) verify(r, e);
  if (mode === 'good') { console.log('retry observer good'); return; }
  const mutations = [
    [0, r => { r.outcome = 'provider/refused'; }],
    [0, r => { r.items[0].content[0].text = 'partial'; }],
    [0, r => { r.usage.input = 0; }],
    [0, r => { r.requests.pop(); }],
    [0, r => { r.requests[1].input = []; }],
    [0, r => { r.rows.find(x => x.provider).provider.usage_state = 'known'; }],
    [0, r => { r.rows.find(x => x.provider).provider.usage.input = 0; }],
    [0, r => { const ps = r.rows.filter(x => x.provider).map(x => x.provider); ps[1].attempt_id = ps[0].attempt_id; }],
    [0, r => { r.rows.find(x => x.provider).provider.operation_id = 'wrong'; }],
    [0, r => { const ps = r.rows.filter(x => x.provider).map(x => x.provider); ps[2].timestamp = ps[1].timestamp; }],
    [1, r => { r.count = 'xx'; }], [1, r => { r.partial = true; }],
    [1, r => { r.after.head = r.before.head; }], [1, r => { r.after.approval = r.before.approval; }],
    [1, r => { r.committed_app = 'baseline\n'; }], [1, r => { r.result.reviews = 0; }],
    [1, r => { r.result.passes = 0; }], [1, r => { r.status = ' M app.txt'; }],
    [2, r => { r.after.head = 'wrong'; }], [2, r => { r.after.index = 'wrong'; }],
    [2, r => { r.after.approval = null; }], [2, r => { r.result.provider_failure = {}; }],
  ];
  for (const [i, mutate] of mutations) {
    const r = structuredClone(good[i][0]); mutate(r);
    assert.throws(() => verify(r, good[i][1]), 'observer accepted a known-bad mutation');
  }
  console.log('retry observer rejected 22 mutations'); process.exitCode = 1;
}
if (require.main === module) {
  controls(process.argv[3]).catch(e => { console.error(e.stack); process.exitCode = 2; });
} else {
  const { When, Then } = require('@cucumber/cucumber');
  When('I exercise transient stream retry with:', { timeout: 200000 }, async function (text) { this.streamRetry = await run(JSON.parse(text)); });
  Then('the transient stream retry result is:', function (text) { verify(this.streamRetry, JSON.parse(text)); });
}
