const assert = require('node:assert/strict');
const { isDeepStrictEqual } = require('node:util');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { When, Then } = require('@cucumber/cucumber');
const { FakeServers, message, functionCall, FAKE_ACCESS_TOKEN, FAKE_REFRESH_TOKEN } = require('../../test/acceptance/support/fake-servers');
const H = require('./go_driver_support.js');
// The driver is a tiny Go program calling Kogen's provider and shaping-evidence packages for one logical response wait.
const driver = String.raw`package main

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
	home, url, mode, budgetArg := os.Args[1], os.Args[2], os.Args[3], os.Args[4]
	budget, err := strconv.Atoi(budgetArg)
	must(err)
	s := sys.NewWith([]string{"HOME=" + home, "KOGEN_PROVIDER_URL=" + url, "KOGEN_AUTH_URL=" + url}, home)
	ev, err := shape.NewEvidence(filepath.Join(home, "evidence"), "fixture")
	must(err)
	time.AfterFunc(3500*time.Millisecond, func() { s.Interrupt("WATCHDOG") })
	if mode == "cancel" {
		time.AfterFunc(200*time.Millisecond, func() { s.Interrupt("SIGINT") })
	}
	lockPath := filepath.Join(home, ".kogen/credentials/chatgpt.lock")
	var lock *provider.Lock
	if mode == "credential-lock" {
		lock, err = provider.Locker{}.Acquire(lockPath)
		must(err)
	}
	role := provider.Role{Provider: "chatgpt", Model: "fixture-model", Effort: "medium"}
	single := false
	for _, m := range []string{"malformed-terminal", "malformed-tool", "unfinished-tool", "incomplete-tool"} {
		single = single || mode == m
	}
	started := time.Now()
	client := provider.NewClient("kogen test (driver)")
	call := ev.BeginCall("shape", "", "fixture", "", project.Role{Provider: role.Provider, Model: role.Model, Effort: role.Effort})
	resp, err := client.Respond(s.Context(), s, provider.Request{Role: role, Instructions: "boundary fixture", Input: []any{}, Tools: []any{}, Budget: time.Duration(budget) * time.Millisecond, Single: single, Scope: "boundary"}, call)
	call.End(resp, err)
	result := map[string]any{}
	if err == nil {
		result["outcome"] = "ok"
		result["response"] = map[string]any{
			"items":       resp.Items,
			"usage":       map[string]any{"input": resp.Usage.Input, "cached": resp.Usage.Cached, "output": resp.Usage.Output, "reasoning": resp.Usage.Reasoning},
			"known_usage": resp.Known.Map(),
		}
	} else {
		var i *sys.Interrupted
		var e *sys.Error
		switch {
		case errors.As(err, &i):
			result["outcome"] = "cancel/" + i.Signal
		case errors.As(err, &e):
			result["outcome"], result["detail"], result["exit"], result["diagnostics"] = e.Class+"/"+e.Reason, e.Detail, e.Exit, e.ProviderFailure
		default:
			must(err)
		}
	}
	result["elapsed"] = time.Since(started).Milliseconds()
	if lock != nil {
		lock.Release()
	}
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
	result["events"] = events
	out, err := json.Marshal(result)
	must(err)
	fmt.Println("BOUNDARY_RESULT=" + string(out))
	// Leave the connections to the fake a moment to be seen closing, as the old driver did.
	time.Sleep(200 * time.Millisecond)
}
`;
function frame(type, payload = {}) { return `event: ${type}\ndata: ${JSON.stringify({ type, ...payload })}\n\n`; }
const usage = { input_tokens: 100, input_tokens_details: { cached_tokens: 5 }, output_tokens: 20, output_tokens_details: { reasoning_tokens: 10 } };
When('I exercise the real provider wait in mode {string} with budget {int}', { timeout: 30000 }, async function (mode, budget) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-provider-boundary-'));
  const fake = new FakeServers();
  const timers = new Set();
  const open = new Set();
  let requests = 0, refreshes = 0;
  const expectedItems = [message('boundary-ok', 'boundary')];
  function later(fn, ms) { const t = setTimeout(fn, ms); timers.add(t); return t; }
  function headers(res) { res.writeHead(200, { 'content-type': 'text/event-stream' }); res.flushHeaders(); }
  function hold(res) { open.add(res); res.on('close', () => open.delete(res)); }
  function valid(res, close) {
    headers(res);
    res.write(frame('response.output_item.done', { output_index: 0, item: expectedItems[0] }));
    res.write(frame('response.completed', { response: { usage } }));
    if (close) res.end(); else hold(res);
  }
  fake.handleAuth = async (req, res) => {
    req.resume(); await new Promise(resolve => req.on('end', resolve)); refreshes++;
    if (mode === 'blocked-refresh') { hold(res); return; }
    const reply = () => { res.writeHead(200, { 'content-type': 'application/json' }); res.end(JSON.stringify({ access_token: FAKE_ACCESS_TOKEN, refresh_token: FAKE_REFRESH_TOKEN, expires_in: 3600 })); };
    if (mode === 'proactive-refresh') later(reply, 800); else reply();
  };
  fake.handleProvider = async (req, res) => {
    assert.equal(req.url, '/v1/responses');
    const parts = []; for await (const b of req) parts.push(b);
    const body = JSON.parse(Buffer.concat(parts).toString());
    assert.equal(body.stream, true); assert.equal(body.store, false);
    requests++;
    if (mode === 'normal' || mode === 'terminal-open') { valid(res, mode === 'normal'); return; }
    if (mode === 'backoff' || (mode === 'after-401' && requests === 1)) {
      const reply = () => { res.writeHead(mode === 'backoff' ? 500 : 401, { 'content-type': 'application/json' }); res.end(JSON.stringify({ error: { code: mode === 'backoff' ? 'server_error' : 'unauthorized', message: 'fixture failure' } })); };
      later(reply, mode === 'after-401' ? 800 : 100); return;
    }
    if (mode === 'invalid-retry' && requests === 1) {
      later(() => { headers(res); res.end('data: not-json\n\n'); }, 800); return;
    }
    if (mode === 'no-headers') { hold(res); return; }
    headers(res);
    if (mode === 'heartbeat') {
      res.write(': heartbeat\n\n');
      const t = setInterval(() => { if (!res.destroyed) res.write(frame('response.in_progress', { response: { id: 'pending' } }) + ': heartbeat\n\n'); }, 20);
      timers.add(t);
    }
    if (mode === 'malformed-terminal') res.write(frame('response.completed'));
    if (['malformed-tool', 'unfinished-tool', 'incomplete-tool'].includes(mode)) {
      const item = functionCall('write_file', { path: 'must-not-exist.txt', content: 'partial authority' }, 'boundary');
      if (mode === 'malformed-tool') item.arguments = '{"path":';
      res.write(frame(mode === 'unfinished-tool' ? 'response.output_item.added' : 'response.output_item.done', { output_index: 0, item }));
      res.write(mode === 'incomplete-tool' ? frame('response.incomplete', { response: { incomplete_details: { reason: 'max_output_tokens' } } }) : frame('response.completed', { response: { usage } }));
    }
    hold(res);
  };
  try {
    await fake.start();
    // The auth endpoint shares the provider listener in this isolated driver.
    const providerHandler = fake.handleProvider;
    fake.handleProvider = (req, res) => req.url === '/api/accounts/oauth/token' ? fake.handleAuth(req, res) : providerHandler(req, res);
    fs.mkdirSync(path.join(dir, '.kogen/credentials'), { recursive: true });
    fs.writeFileSync(path.join(dir, '.kogen/credentials/chatgpt.json'), JSON.stringify({ client_id: 'oaiapp_boundary_fixture', access_token: FAKE_ACCESS_TOKEN, refresh_token: FAKE_REFRESH_TOKEN, expires_at: Math.floor(Date.now() / 1000) + (['proactive-refresh', 'blocked-refresh', 'credential-lock'].includes(mode) ? -10 : 3600) }));
    const run = await H.goDriver('provider-wait', driver);
    const done = await run([dir, fake.providerUrl, mode, String(budget)]);
    const code = done.code, output = done.out;
    assert.equal(code, 0, output);
    assert.deepEqual(fake.serverErrors, [], fake.serverErrors.map(String).join('\n'));
    const line = output.split('\n').find(l => l.startsWith('BOUNDARY_RESULT='));
    assert.ok(line, output);
    const r = JSON.parse(line.slice('BOUNDARY_RESULT='.length));
    const failed = r.events.filter(e => ['failed', 'cancelled'].includes(e.status));
    const unknown = { input: null, cached: null, output: null, reasoning: null };
    this.providerWait = { r, observations: {
      requests: String(requests), refreshes: String(refreshes), detail: r.detail || '',
      text: r.response?.items?.[0]?.content?.[0]?.text || '',
      usage: r.response?.usage, known_usage: r.response?.known_usage && Object.fromEntries(Object.entries(r.response.known_usage).filter(([, v]) => v !== null)),
      exact_items: String(isDeepStrictEqual(r.response?.items, expectedItems)),
      returned_items: String(Boolean(r.response?.items)),
      leaked: String(output.includes(FAKE_ACCESS_TOKEN) || output.includes(FAKE_REFRESH_TOKEN) || JSON.stringify(r.events).includes('partial authority')),
      unknown_failure_usage: String(failed.length > 0 && failed.every(e => isDeepStrictEqual(e.usage, unknown))),
      held_open_closed: String(open.size === 0),
    } };
  } finally {
    for (const t of timers) { clearTimeout(t); clearInterval(t); }
    await fake.close(); fs.rmSync(dir, { recursive: true, force: true });
  }
});
Then('the provider wait outcome is {string} within {int} to {int} milliseconds', function (outcome, min, max) {
  const { r } = this.providerWait;
  assert.equal(r.outcome, outcome, JSON.stringify(r));
  assert.ok(r.elapsed >= min && r.elapsed <= max, JSON.stringify(r));
  if (outcome.startsWith('provider/')) assert.equal(r.exit, 4, JSON.stringify(r));
});
Then('the provider wait observations are:', function (table) {
  for (const [key, value] of table.raw()) {
    const actual = this.providerWait.observations[key];
    const detail = `${key}: ${JSON.stringify(this.providerWait)}`;
    if (['usage', 'known_usage'].includes(key)) assert.deepEqual(actual, JSON.parse(value), detail);
    else assert.equal(actual, value, detail);
  }
});
