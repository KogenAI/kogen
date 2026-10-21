const assert = require('node:assert/strict');
const { isDeepStrictEqual } = require('node:util');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { When, Then } = require('@cucumber/cucumber');
const { FakeServers, message, functionCall, FAKE_ACCESS_TOKEN, FAKE_REFRESH_TOKEN } = require('../../test/acceptance/support/fake-servers');
const ROOT = path.resolve(__dirname, '../..');
const driver = String.raw`
[home, url, mode, budget] = System.argv()
:persistent_term.put(:kogen_caller, %{env: %{"HOME" => home, "KOGEN_PROVIDER_URL" => url, "KOGEN_AUTH_URL" => url}})
Kogen.ShapeEvidence.start(Path.join(home, "evidence"))
parent = self()
watchdog = spawn(fn -> Process.sleep(3500); send(parent, :boundary_watchdog); send(parent, {:proto, %{"type" => "cancel", "signal" => "WATCHDOG"}}) end)
if mode == "cancel", do: spawn(fn -> Process.sleep(200); send(parent, {:proto, %{"type" => "cancel", "signal" => "SIGINT"}}) end)
lock = Path.join(home, ".kogen/credentials/chatgpt.lock")
if mode == "credential-lock", do: :ok = Kogen.Lock.acquire(lock)
started = System.monotonic_time(:millisecond)
result = try do
  response = Kogen.ShapeEvidence.provider("shape", nil, "fixture", [], %{model: "fixture-model", effort: "medium"}, fn ->
    Kogen.ChatGPT.respond(%{model: "fixture-model", effort: "medium"}, "boundary fixture", [], [], response_budget_ms: String.to_integer(budget), single_attempt: mode in ["malformed-terminal", "malformed-tool", "unfinished-tool", "incomplete-tool"])
  end)
  %{outcome: "ok", response: response}
rescue
  e in Kogen.Error -> %{outcome: e.class <> "/" <> e.reason, detail: e.detail, exit: e.exit, diagnostics: e.provider_failure}
catch
  {:cancel, signal} -> %{outcome: "cancel/" <> signal}
end
elapsed = System.monotonic_time(:millisecond) - started
Process.exit(watchdog, :kill)
if mode == "credential-lock", do: Kogen.Lock.release(lock)
events = File.read!(Path.join(home, "evidence/events.ndjson")) |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
IO.puts("BOUNDARY_RESULT=" <> JSON.encode!(Map.merge(result, %{elapsed: elapsed, events: events})))
Process.sleep(200)
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
  let child;
  try {
    await fake.start();
    // The auth endpoint shares the provider listener in this isolated driver.
    const providerHandler = fake.handleProvider;
    fake.handleProvider = (req, res) => req.url === '/api/accounts/oauth/token' ? fake.handleAuth(req, res) : providerHandler(req, res);
    fs.mkdirSync(path.join(dir, '.kogen/credentials'), { recursive: true });
    fs.writeFileSync(path.join(dir, '.kogen/credentials/chatgpt.json'), JSON.stringify({ client_id: 'oaiapp_boundary_fixture', access_token: FAKE_ACCESS_TOKEN, refresh_token: FAKE_REFRESH_TOKEN, expires_at: Math.floor(Date.now() / 1000) + (['proactive-refresh', 'blocked-refresh', 'credential-lock'].includes(mode) ? -10 : 3600) }));
    const file = path.join(dir, 'driver.exs'); fs.writeFileSync(file, driver);
    let output = '';
    const execution = new Promise((resolve, reject) => {
      child = spawn('mix', ['run', '--no-deps-check', file, dir, fake.providerUrl, mode, String(budget)], { cwd: ROOT, detached: true, stdio: ['ignore', 'pipe', 'pipe'] });
      child.stdout.on('data', b => { output += b; }); child.stderr.on('data', b => { output += b; });
      child.once('error', reject); child.once('close', code => resolve(code));
    });
    const kill = setTimeout(() => { try { process.kill(-child.pid, 'SIGKILL'); } catch {} }, 20000);
    let code; try { code = await execution; } finally { clearTimeout(kill); }
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
      usage: r.response?.usage, known_usage: r.response?.known_usage,
      exact_items: String(isDeepStrictEqual(r.response?.items, expectedItems)),
      returned_items: String(Boolean(r.response?.items)),
      leaked: String(output.includes(FAKE_ACCESS_TOKEN) || output.includes(FAKE_REFRESH_TOKEN) || JSON.stringify(r.events).includes('partial authority')),
      unknown_failure_usage: String(failed.length > 0 && failed.every(e => isDeepStrictEqual(e.usage, unknown))),
      held_open_closed: String(open.size === 0),
    } };
  } finally {
    for (const t of timers) { clearTimeout(t); clearInterval(t); }
    if (child && child.exitCode === null) { try { process.kill(-child.pid, 'SIGKILL'); } catch {} }
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
