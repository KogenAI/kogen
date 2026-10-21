const assert = require('node:assert/strict');
const { isDeepStrictEqual } = require('node:util');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { When, Then } = require('@cucumber/cucumber');
const { FakeServers } = require('../../test/acceptance/support/fake-servers');
const ROOT = path.resolve(__dirname, '../..');
const driver = String.raw`
[home, url, configPath] = System.argv()
c = JSON.decode!(File.read!(configPath))
:persistent_term.put(:kogen_caller, %{env: %{"HOME" => home, "KOGEN_PROVIDER_URL" => url}})
Kogen.ShapeEvidence.start(Path.join(home, "evidence"))
model = %{model: "gpt-6.1-sol", effort: "high"}
policy = "DEVELOPER_AUTHORITY: preserve policy exactly"
base = [%{"role" => "user", "content" => Kogen.PromptCache.contract_blocks("CONTRACT_AUTHORITY", "dynamic suffix")},
 %{"type" => "reasoning", "id" => "r_old", "summary" => [], "encrypted_content" => "OPAQUE_REASONING"},
 %{"type" => "message", "id" => "m_old", "role" => "assistant", "phase" => "commentary", "content" => [%{"type" => "output_text", "text" => "prior text", "annotations" => []}]},
 %{"type" => "function_call", "id" => "f_old", "call_id" => "call_old", "name" => "read_file", "arguments" => "{\"path\":\"app.txt\"}"},
 %{"type" => "function_call_output", "call_id" => "call_old", "output" => "TOOL_RESULT"}]
tools = [%{"type" => "function", "name" => "read_file", "description" => "Read", "parameters" => %{"type" => "object", "properties" => %{"path" => %{"type" => "string"}}, "required" => ["path"], "additionalProperties" => false}, "strict" => true}]
parent = self()
canceller = if c["mode"] == "cancel", do: spawn(fn -> Process.sleep(400); send(parent, {:proto, %{"type" => "cancel", "signal" => "SIGINT"}}) end)
call = fn input ->
  started = System.monotonic_time(:millisecond)
  try do
    r = Kogen.ShapeEvidence.provider("shape", nil, "fixture", [], model, fn ->
      Process.put(:provider_conversation_scope, "builder-fixture")
      Kogen.ChatGPT.respond(model, policy, input, tools, single_attempt: c["single"] == "true", response_budget_ms: String.to_integer(c["budget"] || "15000"))
    end)
    %{outcome: "completed", items: r.items, elapsed: System.monotonic_time(:millisecond) - started}
  rescue
    e in Kogen.Error -> %{outcome: e.class <> "/" <> e.reason, items: nil, elapsed: System.monotonic_time(:millisecond) - started}
  catch
    {:cancel, signal} -> %{outcome: "cancel/" <> signal, items: nil, elapsed: System.monotonic_time(:millisecond) - started}
  end
end
first = call.(base)
results = if c["mode"] == "success" and first.outcome == "completed" do
  # Existing Build.save/resume owns checkpoint custody. Exercise the same cache-state
  # term serialization boundary here without synthesizing a Build approval/checkpoint.
  saved = :erlang.term_to_binary(Process.get(:prompt_cache_states, %{}))
  Process.delete(:prompt_cache_states)
  Process.put(:prompt_cache_states, :erlang.binary_to_term(saved, [:safe]))
  [first, call.(base ++ [%{"role" => "user", "content" => "next turn"}])]
else
  [first]
end
if canceller, do: Process.exit(canceller, :kill)
rows = File.read!(Path.join(home, "evidence/events.ndjson")) |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
Process.put(:provider_conversation_scope, "independent-reviewer-fixture")
fresh = Kogen.PromptCache.prepare(model.model, policy, base, tools)
File.write!(Path.join(home, "receipt.json"), JSON.encode!(%{results: results, rows: rows, fresh: fresh}))
`;
function frame(type, data) { return `data: ${JSON.stringify({ type, ...data })}\n\n`; }
function strip(p) {
  const b = structuredClone(p); delete b.prompt_cache_options;
  for (const m of b.input || []) if (Array.isArray(m.content)) for (const x of m.content) delete x.prompt_cache_breakpoint;
  return b;
}
function controlled(p) {
  const marks = (p.input || []).flatMap(m => Array.isArray(m.content) ? m.content : []).filter(b => b.prompt_cache_breakpoint);
  return p.prompt_cache_options?.mode === 'implicit' && p.prompt_cache_options?.ttl === '30m' && marks.length === 2;
}
function clean(p) { return !p.prompt_cache_options && !(p.input || []).some(m => Array.isArray(m.content) && m.content.some(b => b.prompt_cache_breakpoint)); }
When('I send a cache capability conversation with:', { timeout: 45000 }, async function(table) {
  const c = Object.fromEntries(table.raw());
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-capability-repair-'));
  const fake = new FakeServers();
  const bodies = [], timers = new Set(), held = new Set();
  const item = { type: 'message', id: 'm_complete', role: 'assistant', content: [{ type: 'output_text', text: 'compatible completion', annotations: [] }] };
  const error = { type: c.type, code: c.code, message: c.message };
  if (c.param !== 'absent') error.param = c.param === 'null' ? null : c.param;
  const later = (f, ms) => { const t = setTimeout(f, ms); timers.add(t); };
  fake.handleProvider = async (req, res) => {
    assert.equal(req.method, 'POST'); assert.equal(req.url, '/v1/responses');
    const chunks = []; for await (const chunk of req) chunks.push(chunk);
    bodies.push(JSON.parse(Buffer.concat(chunks).toString()));
    const n = bodies.length;
    if (c.mode === 'network') { req.socket.destroy(); return; }
    if (['failed-stream', 'cut-stream'].includes(c.mode)) {
      res.writeHead(200, { 'content-type': 'text/event-stream' });
      res.write(frame('response.output_item.done', { output_index: 0, item: { type: 'function_call', call_id: 'uncertain', name: 'read_file', arguments: '{}' } }));
      if (c.mode === 'failed-stream') res.write(frame('response.failed', { response: { error } }));
      res.end(); return;
    }
    if (['deadline', 'cancel'].includes(c.mode) && n > 1) {
      res.writeHead(200, { 'content-type': 'text/event-stream' }); res.flushHeaders();
      held.add(res); res.on('close', () => held.delete(res)); return;
    }
    if (n === 1 || c.mode === 'negative') {
      const refuse = () => { if (!res.destroyed) { res.writeHead(Number(c.status), { 'content-type': 'application/json', 'x-request-id': `req-local-${n}` }); res.end(JSON.stringify({ error })); } };
      if (['deadline', 'cancel'].includes(c.mode)) later(refuse, 200); else refuse();
      return;
    }
    res.writeHead(200, { 'content-type': 'text/event-stream', 'x-request-id': `req-local-${n}` });
    res.end(frame('response.completed', { response: { id: `resp-local-${n}`, status: 'completed', output: [item], usage: { input_tokens: 100, input_tokens_details: { cached_tokens: 0 }, output_tokens: 2, output_tokens_details: { reasoning_tokens: 0 } } } }));
  };
  let child;
  try {
    await fake.start();
    fs.mkdirSync(path.join(dir, '.kogen/credentials'), { recursive: true });
    fs.writeFileSync(path.join(dir, '.kogen/credentials/chatgpt.json'), JSON.stringify({ client_id: 'oaiapp_local_fixture', access_token: 'fake-access', refresh_token: 'fake-refresh', expires_at: Math.floor(Date.now() / 1000) + 3600 }));
    const script = path.join(dir, 'driver.exs'), config = path.join(dir, 'config.json');
    fs.writeFileSync(script, driver); fs.writeFileSync(config, JSON.stringify(c));
    let output = '';
    const code = await new Promise((resolve, reject) => {
      child = spawn('mix', ['run', '--no-deps-check', script, dir, fake.providerUrl, config], { cwd: ROOT, detached: true, env: { ...process.env, ERL_FLAGS: '+S 2:2 +SDcpu 1 +SDio 1' }, stdio: ['ignore','pipe','pipe'] });
      const timer = setTimeout(() => { try { process.kill(-child.pid, 'SIGKILL'); } catch {} }, 35000);
      child.stdout.on('data', b => { output += b; }); child.stderr.on('data', b => { output += b; });
      child.once('error', e => { clearTimeout(timer); reject(e); }); child.once('close', k => { clearTimeout(timer); resolve(k); });
    });
    assert.equal(code, 0, output); assert.deepEqual(fake.serverErrors, [], String(fake.serverErrors));
    const r = JSON.parse(fs.readFileSync(path.join(dir, 'receipt.json'), 'utf8'));
    await new Promise(resolve => setTimeout(resolve, 100));
    const ps = r.rows.filter(x => x.provider).map(x => x.provider);
    const failed = ps.filter(x => x.outcome !== 'completed');
    const unknown = p => p.usage_state === 'unknown' && Object.values(p.usage).every(v => v === null);
    const expectedLater = bodies[1] && structuredClone(bodies[1]);
    if (expectedLater) expectedLater.input.push({ role: 'user', content: 'next turn' });
    const honest = ps.length === 3 && ps[0].outcome === 'failed' && unknown(ps[0]) && ps[0].cache.status === 'unsupported' && ps[0].cache.boundaries.length === 2 && ps[0].provider_request_id === 'req-local-1' && ps[0].provider_response_id === null && ps[0].effective_model === null && ps[0].effective_effort === null && ps.every(p => p.cache.applied_mode === null && p.cache.applied_ttl === null) && ps.slice(1).every((p,i) => p.outcome === 'completed' && p.cache.status === 'unsupported' && p.cache.boundaries.length === 0 && p.provider_request_id === `req-local-${i+2}` && p.provider_response_id === `resp-local-${i+2}`) && new Set(ps.map(p => p.attempt_id)).size === 3 && new Set(ps.map(p => p.conversation_id)).size === 1 && ps[0].operation_id === ps[1].operation_id && ps[1].operation_id !== ps[2].operation_id;
    this.cacheCapability = {
      outcomes: r.results.map(x => x.outcome), requests: bodies.length,
      controls: bodies.map(p => controlled(p) ? true : clean(p) ? false : 'partial'),
      fallback_preserves_body: !!bodies[1] && JSON.stringify(strip(bodies[0])) === JSON.stringify(bodies[1]),
      later_preserves_replay: !!bodies[2] && isDeepStrictEqual(expectedLater, bodies[2]),
      exact_completed_items: r.results.length === 2 && r.results.every(x => isDeepStrictEqual(x.items, [item])),
      honest_attempts: honest,
      independent_fresh: !!r.fresh.prompt_cache_options && !r.fresh.prompt_cache_options.comparison_response_id,
      no_unsupported: ps.length === bodies.length && ps.every(p => p.cache.status !== 'unsupported'),
      failed_unknown: failed.length > 0 && failed.every(unknown),
      no_completed_items: r.results.every(x => x.items === null),
      bounded: r.results[0].elapsed >= 300 && r.results[0].elapsed < 1300,
      sockets_closed: held.size === 0,
    };
    // Common protocol requirements are checked independently of fallback outcomes.
    for (const p of bodies) {
      assert.equal(p.model, 'gpt-6.1-sol'); assert.deepEqual(p.reasoning, { effort: 'high' });
      assert.equal(p.stream, true); assert.equal(p.store, false); assert.deepEqual(p.include, ['reasoning.encrypted_content']);
      assert.ok(!('previous_response_id' in p) && !('conversation' in p));
    }
  } finally {
    for (const t of timers) clearTimeout(t);
    for (const res of held) res.destroy();
    if (child && child.exitCode === null) { try { process.kill(-child.pid, 'SIGKILL'); } catch {} }
    await fake.close(); fs.rmSync(dir, { recursive: true, force: true });
  }
});
Then('the cache capability observations are:', function(table) {
  const errors = [];
  for (const [key, value] of table.raw()) {
    try { assert.deepEqual(this.cacheCapability[key], JSON.parse(value), key); }
    catch (e) { errors.push(e.message); }
  }
  assert.deepEqual(errors, [], JSON.stringify(this.cacheCapability));
});
