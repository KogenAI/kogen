const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');
const ROOT = path.resolve(__dirname, '../..');
const driver = String.raw`
ExUnit.start(autorun: false)
Code.require_file("test/support/integration_helpers.ex")
alias Kogen.{ChatGPT, Error, ShapeEvidence, Integration.FakeProvider, Integration.Helpers}
[home, config] = System.argv()
c = JSON.decode!(File.read!(config))
error = Map.put(c["error"], "private_payload", "SECRET_RETRY_PAYLOAD")
partial = %{"type" => "function_call", "call_id" => "unconfirmed", "name" => "shell", "arguments" => JSON.encode!(%{"command" => "touch .kogen/local/partial-tool"})}
failure = case c["event"] do
  "flat" -> Map.merge(error, %{"type" => "error"})
  "response.failed" -> %{"type" => "response.failed", "response" => %{"error" => error}}
  "response.incomplete" -> %{"type" => "response.incomplete", "response" => %{"incomplete_details" => %{"reason" => "max_output_tokens"}}}
  _ -> %{"type" => "error", "error" => error}
end
bad = {:events, [%{"type" => "response.output_item.done", "output_index" => 0, "item" => partial}, failure]}
read_rows = fn file -> File.read!(file) |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1) end
r = if c["entry"] == "build" do
  suite = Helpers.setup_suite!()
  script = [{:function, "shell", %{"command" => "printf 'verified edit\\n' > app.txt; printf x >> .kogen/local/tool-count"}}] ++ List.duplicate(bad, c["failures"]) ++ [{:function, "finish", %{"summary" => "Ready"}}, {:function, "submit_review", %{"verdict" => "approve", "findings" => []}}]
  ctx = Helpers.project!(suite, script, staged_intent: false)
  try do
    approval = Kogen.Intent.approval_path(ctx.repo, "fixture")
    before = %{head: Kogen.Git.head(ctx.repo), index: Base.encode64(File.read!(Path.join(ctx.repo, ".git/index"))), approval: File.read!(approval)}
    {out, status} = Helpers.run_kogen(ctx, ["intent", "build", "fixture"])
    [result] = Path.wildcard(Path.join(ctx.repo, ".kogen/local/runs/*/result.json"))
    rows = read_rows.(Helpers.run_log(ctx))
    requests = FakeProvider.provider_requests(ctx.server) |> Enum.drop(1) |> Enum.map(& &1.json)
    %{entry: "build", output: out, exit: status, result: JSON.decode!(File.read!(result)), rows: rows,
      requests: requests, before: before,
      after: %{head: Kogen.Git.head(ctx.repo), index: Base.encode64(File.read!(Path.join(ctx.repo, ".git/index"))), approval: if(File.exists?(approval), do: File.read!(approval))},
      app: File.read!(Path.join(ctx.repo, "app.txt")), count: File.read!(Path.join(ctx.repo, ".kogen/local/tool-count")),
      partial: File.exists?(Path.join(ctx.repo, ".kogen/local/partial-tool")),
      status: elem(Helpers.git!(ctx, ["status", "--porcelain"]), 0),
      committed_app: elem(Helpers.git!(ctx, ["show", "HEAD:app.txt"]), 0)}
  after
    Helpers.cleanup_case(ctx)
    Helpers.cleanup_suite(suite)
  end
else
  File.mkdir_p!(Path.join(home, ".kogen/credentials"))
  provider = c["provider"] || "chatgpt"
  creds = %{client_id: "oaiapp_fixture", access_token: "fake-access", refresh_token: "fake-refresh", expires_at: System.system_time(:second) + 3600, referrer: "kogen"}
  File.write!(Path.join(home, ".kogen/credentials/#{provider}.json"), JSON.encode!(creds))
  item = %{"type" => "message", "role" => "assistant", "content" => [%{"type" => "output_text", "text" => "recovered", "annotations" => []}]}
  usage = %{"input_tokens" => 100, "input_tokens_details" => %{"cached_tokens" => 5}, "output_tokens" => 20, "output_tokens_details" => %{"reasoning_tokens" => 10}}
  good = {:events, [%{"type" => "response.completed", "response" => %{"status" => "completed", "output" => [item], "usage" => usage}}]}
  server = FakeProvider.start(List.duplicate(bad, c["failures"]) ++ [good])
  :persistent_term.put(:kogen_caller, %{env: %{"HOME" => home, "KOGEN_PROVIDER_URL" => "http://127.0.0.1:#{server.port}"}})
  ShapeEvidence.start(Path.join(home, "evidence"))
  role = if provider == "supergrok", do: %{provider: "supergrok", model: "grok-4.7", effort: "low"}, else: %{model: "gpt-6.1-sol", effort: "medium"}
  parent = self()
  canceller = if c["cancel"], do: spawn(fn -> Process.sleep(200); send(parent, {:proto, %{"type" => "cancel", "signal" => "SIGINT"}}) end)
  started = System.monotonic_time(:millisecond)
  try do
    result = try do
      response = ShapeEvidence.provider("shape", nil, "fixture", [], role, fn ->
        ChatGPT.respond(role, "retry authority", [%{"role" => "user", "content" => "retry contract"}], [], single_attempt: c["single"] || false, response_budget_ms: c["budget"] || 15000)
      end)
      %{outcome: "ok", items: response.items, usage: response.usage}
    rescue
      e in Error -> %{outcome: e.class <> "/" <> e.reason, exit: e.exit, diagnostics: e.provider_failure, detail: e.detail}
    catch
      {:cancel, signal} -> %{outcome: "cancel/" <> signal}
    end
    Map.merge(result, %{entry: "transport", elapsed: System.monotonic_time(:millisecond) - started,
      requests: Enum.map(FakeProvider.provider_requests(server), & &1.json), rows: read_rows.(Path.join(home, "evidence/events.ndjson"))})
  after
    if canceller, do: Process.exit(canceller, :kill)
    FakeProvider.stop(server)
  end
end
File.write!(Path.join(home, "receipt.json"), JSON.encode!(r))
ExUnit.run()
`;
function run(c) {
  return new Promise((resolve, reject) => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-stream-retry-'));
    const script = path.join(dir, 'driver.exs'), config = path.join(dir, 'config.json');
    fs.writeFileSync(script, driver); fs.writeFileSync(config, JSON.stringify(c));
    // Direct mix callers need the same version source used by SuperGrok's user-agent.
    fs.writeFileSync(path.join(dir, 'VERSION'), 'kogen fixture\n');
    const env = { ...process.env, RELEASE_ROOT: dir, ERL_FLAGS: '+S 2:2 +SDcpu 1 +SDio 1' };
    // Configured setup has just packaged the candidate. Never select an old private candidate.
    const archives = fs.readdirSync(path.join(ROOT, 'dist')).filter(x => x.endsWith('.tar.gz')).map(x => path.join(ROOT, 'dist', x));
    archives.sort((a, b) => fs.statSync(b).mtimeMs - fs.statSync(a).mtimeMs);
    if (archives[0]) env.KOGEN_ARCHIVE = archives[0];
    const child = spawn('mix', ['run', '--no-deps-check', script, dir, config], { cwd: ROOT, detached: true, env, stdio: ['ignore', 'pipe', 'pipe'] });
    let output = '';
    child.stdout.on('data', b => { output += b; }); child.stderr.on('data', b => { output += b; });
    const timer = setTimeout(() => { try { process.kill(-child.pid, 'SIGKILL'); } catch {} }, 180000);
    child.once('error', e => { clearTimeout(timer); fs.rmSync(dir, { recursive: true, force: true }); reject(e); });
    child.once('close', code => {
      clearTimeout(timer);
      try {
        assert.equal(code, 0, output);
        const r = JSON.parse(fs.readFileSync(path.join(dir, 'receipt.json'), 'utf8'));
        resolve(r);
      } catch (e) { reject(e); }
      finally { fs.rmSync(dir, { recursive: true, force: true }); }
    });
  });
}
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
