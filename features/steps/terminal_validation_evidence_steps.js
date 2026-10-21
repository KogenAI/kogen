const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { When, Then } = require('@cucumber/cucumber');
const ROOT = path.resolve(__dirname, '../..');
let transportExercise, nativeExercise;
// Independent assertions below consume only real respond/5 / installed CLI results.
// The shared fake and installer are reused, not the implementation tests.
const common = String.raw`
ExUnit.start(autorun: false)
Code.require_file("test/support/integration_helpers.ex")
alias Kogen.{ChatGPT, Error, ShapeEvidence, Integration.FakeProvider, Integration.Helpers}
marker = "PRIVATE_TERMINAL_PAYLOAD_9f71"
usage = %{"input_tokens" => 100, "output_tokens" => 20, "input_tokens_details" => %{"cached_tokens" => 5}, "output_tokens_details" => %{"reasoning_tokens" => 10}}
tool = %{"type" => "function_call", "status" => "completed", "name" => marker, "call_id" => marker, "id" => marker, "arguments" => JSON.encode!(%{"private" => marker})}
message = %{"type" => "message", "status" => "completed", "role" => "assistant", "content" => [%{"type" => "output_text", "text" => marker, "annotations" => []}]}
done = fn r -> %{"type" => "response.completed", "response" => r} end
item_done = fn i, item -> %{"type" => "response.output_item.done", "output_index" => i, "item" => item} end
added = fn i -> %{"type" => "response.output_item.added", "output_index" => i, "item" => tool} end
bad_args = Map.put(tool, "arguments", "{\"private\":\"#{marker}\"")
unknown = %{"input" => nil, "cached" => nil, "output" => nil, "reasoning" => nil}
`;
const transportDriver = common + String.raw`
home = hd(System.argv())
File.mkdir_p!(Path.join(home, ".kogen/credentials"))
File.write!(Path.join(home, ".kogen/credentials/chatgpt.json"), JSON.encode!(%{client_id: "oaiapp_fixture", access_token: "fake-access", refresh_token: "fake-refresh", expires_at: System.system_time(:second) + 3600}))
base = %{"output" => [tool], "status" => "completed", "usage" => usage}
cases = [
 {"status", [done.(Map.put(base, "status", marker))]},
 {"error", [done.(Map.put(base, "error", %{"message" => marker, "code" => marker}))]},
 {"usage", [done.(Map.put(base, "usage", marker))]},
 {"output-shape", [item_done.(0, tool), done.(%{"output" => marker})]},
 {"event-shape", [item_done.(-1, tool), done.(base)]},
 {"coverage", [added.(1), done.(base)]},
 {"gap", [item_done.(1, tool), done.(%{})]},
 {"pending", [item_done.(0, tool), added.(1), done.(%{})]},
 {"arguments", [done.(Map.put(base, "output", [bad_args]))]},
 {"item-status", [done.(Map.put(base, "output", [Map.put(tool, "status", "in_progress")]))]},
 {"unknown-item", [done.(Map.put(base, "output", [%{"type" => marker, "status" => marker, "body" => marker}]))]},
 {"envelope", [%{"type" => "response.completed", "response" => marker}]},
 {"empty", [done.(%{"output" => []})]},
 {"replaced-invalid", [item_done.(0, tool), done.(Map.put(base, "output", [bad_args]))]},
 {"saturated", [done.(Map.put(base, "output", List.duplicate(bad_args, 1025)))]}
]
# Documentation-shaped fixtures, not captured live provider responses.
stream = [added.(0), %{"type" => "response.function_call_arguments.delta", "output_index" => 0, "delta" => tool["arguments"]}, %{"type" => "response.function_call_arguments.done", "output_index" => 0, "arguments" => tool["arguments"]}, item_done.(0, tool), done.(%{"status" => "completed", "usage" => usage})]
terminal = [done.(%{"status" => "completed", "output" => [message], "usage" => usage})]
replacement = [added.(0), item_done.(0, bad_args), done.(base)]
script = Enum.map(cases, fn {_, events} -> {:events, events} end) ++ Enum.map([stream, terminal, replacement, [done.(Map.put(base, "usage", marker))], stream], &{:events, &1})
server = FakeProvider.start(script)
:persistent_term.put(:kogen_caller, %{env: %{"HOME" => home, "KOGEN_PROVIDER_URL" => "http://127.0.0.1:#{server.port}"}})
ShapeEvidence.start(Path.join(home, "evidence"))
model = %{model: "fixture", effort: "medium"}
call = fn single ->
 ShapeEvidence.provider("shape", nil, "fixture", [], model, fn -> ChatGPT.respond(model, "local fixture", [], [], single_attempt: single, response_budget_ms: 1000) end)
end
try do
 errors = for {name, _} <- cases, into: %{} do
  value = try do
   _ = call.(true)
   %{returned: true}
  rescue
   e in Error -> %{returned: false, class: e.class, reason: e.reason, detail: e.detail, exit: e.exit, rendered: Error.render(e), provider_failure: e.provider_failure}
  end
  {name, value}
 end
 a = call.(true)
 b = call.(true)
 c = call.(true)
 d = call.(false)
 ShapeEvidence.finish()
 events = Path.join(home, "evidence/events.ndjson") |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
 calls = Enum.filter(events, &(&1["event"] == "provider_call"))
 expected_usage = %{input: 100, cached: 5, output: 20, reasoning: 10}
 result = %{errors: errors, events: events, observations: %{
  "documented stream exact output" => a.items == [tool],
  "documented terminal exact output" => b.items == [message],
  "terminal replacement exact output" => c.items == [tool],
  "valid usage preserved" => Enum.all?([a,b,c,d], &(&1.usage == expected_usage and &1.known_usage == expected_usage)),
  "invalid retry exact output" => d.items == [tool],
  "retry attempt statuses" => Enum.map(Enum.take(calls, -2), & &1["status"]),
  "retry attempts" => length(FakeProvider.provider_requests(server)) - length(cases) - 3,
  "retry failure usage unknown" => Enum.at(calls, -2)["usage"] == unknown,
  "direct failures retain unknown usage" => Enum.all?(Enum.take(calls, length(cases)), &(&1["status"] == "failed" and &1["usage"] == unknown)),
  "invalid items not returned" => Enum.all?(errors, fn {_, e} -> not e.returned and e.class == "provider" and e.reason == "invalid_response" and e.exit == 4 end)
 }}
 IO.puts("TERMINAL_RESULT=" <> JSON.encode!(result))
after
 FakeProvider.stop(server)
end
ExUnit.run()
`;
const nativeDriver = common + String.raw`
suite = Helpers.setup_suite!()
try do
 first = done.(%{"status" => marker, "output" => [tool], "usage" => usage})
 second = done.(%{"status" => "completed", "output" => [bad_args], "usage" => usage})
 c = Helpers.project!(suite, [{:events, [first]}, {:events, [second]}], staged_intent: false)
 try do
  authority = fn -> {Kogen.Git.head(c.repo), File.read!(Path.join(c.repo, ".git/index")), File.read!(Kogen.Intent.approval_path(c.repo, "fixture"))} end
  before = authority.()
  request = Path.join(c.root, "request.txt")
  File.write!(request, "Exercise safe terminal validation without publishing any files.")
  {out, status} = Helpers.run_kogen(c, ["intent", "shape", "diagnostic-next", request])
  events_text = File.read!(Path.join(c.repo, ".kogen/local/shaping/diagnostic-next/events.ndjson"))
  events = events_text |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
  calls = Enum.filter(events, &(&1["event"] == "provider_call"))
  IO.puts("TERMINAL_RESULT=" <> JSON.encode!(%{output: out, events: events, observations: %{
   "native exit" => status,
   "native prefix preserved" => String.contains?(out, "provider/invalid_response: ChatGPT sent a response Kogen cannot read: the completed response has invalid or unfinished output"),
   "native attempt statuses" => Enum.map(calls, & &1["status"]),
   "native failure usage unknown" => length(calls) == 2 and Enum.all?(calls, &(&1["usage"] == unknown)),
   "native requests after init" => length(FakeProvider.provider_requests(c.server)) - 1,
   "native tool outputs" => length(FakeProvider.tool_outputs(c.server)),
   "native no Intent or helper" => not File.exists?(Path.join(c.repo, ".kogen/intents/diagnostic-next")) and not File.exists?(Path.join(c.repo, marker)),
   "native authority unchanged" => authority.() == before,
   "native evidence and output private" => not String.contains?(out <> events_text, marker)
  }}))
 after
  Helpers.cleanup_case(c)
 end
after
 Helpers.cleanup_suite(suite)
end
ExUnit.run()
`;
function run(driver) {
  return new Promise((resolve, reject) => {
    const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'terminal-evidence-'));
    const file = path.join(temp, 'driver.exs'); fs.writeFileSync(file, driver);
    const child = spawn('mix', ['run', '--no-deps-check', file, temp], { cwd: ROOT, detached: true,
      env: { ...process.env, ERL_FLAGS: process.env.ERL_FLAGS || '+S 2:2 +SDcpu 1 +SDio 1' }, stdio: ['ignore', 'pipe', 'pipe'] });
    let output = '';
    child.stdout.on('data', b => { output += b; }); child.stderr.on('data', b => { output += b; });
    const timer = setTimeout(() => { try { process.kill(-child.pid, 'SIGKILL'); } catch {} }, 240000);
    child.on('error', reject);
    child.on('close', code => {
      clearTimeout(timer); fs.rmSync(temp, { recursive: true, force: true });
      try {
        assert.equal(code, 0, output);
        const line = output.split('\n').find(l => l.startsWith('TERMINAL_RESULT=')); assert.ok(line, output);
        const r = JSON.parse(line.slice('TERMINAL_RESULT='.length));
        r.observations['no adversarial strings in output or events'] = !output.includes('PRIVATE_TERMINAL_PAYLOAD_9f71');
        resolve(r);
      } catch (e) { reject(e); }
    });
  });
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
function attemptDetail(call) { assert.equal(call.error.reason, 'invalid'); return call.error.detail; }
When('I exercise terminal validation evidence through the real local transport', { timeout: 250000 }, async function () {
  if (!transportExercise) transportExercise = run(transportDriver);
  this.terminalEvidence = await transportExercise;
});
When('I exercise terminal validation evidence through installed native Shape', { timeout: 250000 }, async function () {
  if (!nativeExercise) nativeExercise = run(nativeDriver);
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
Then('the terminal evidence observations are:', function (table) {
  const r = this.terminalEvidence, obs = { ...r.observations };
  // Derive observations lazily so baseline red still reports each scenario once.
  for (const [key, text] of table.raw()) {
    if (key === 'safe bounded structural metadata') obs[key] = Object.values(r.errors).every(x => Boolean(evidence(x.detail)));
    if (key === 'saturated counts') { const f = evidence(r.errors.saturated.detail).facts; obs[key] = f.item_count === 1024 && f.counts_capped && f.arguments_object.join() === 'no'; }
    if (key === 'effective replacement facts') { const f = evidence(r.errors['replaced-invalid'].detail).facts; obs[key] = f.terminal_output_replaced && f.terminal_output_present && f.terminal_response_present && f.observed_index_count === 1 && f.item_count === 1 && f.pending_count === 0 && f.indexes_contiguous && f.arguments_object.join() === 'no'; }
    if (key === 'unknown type and status categorized') { const f = evidence(r.errors['unknown-item'].detail).facts; obs[key] = f.item_types.join() === 'other' && f.item_statuses.join() === 'other'; }
    if (key === 'retry failed predicate') { const calls = r.events.filter(e => e.event === 'provider_call'); obs[key] = evidence(attemptDetail(calls.at(-2))).reasons.join(','); }
    if (key === 'native predicates') obs[key] = r.events.filter(e => e.event === 'provider_call').map(c => evidence(attemptDetail(c)).reasons);
    let expected; try { expected = JSON.parse(text); } catch { expected = text; }
    assert.deepEqual(obs[key], expected, key);
  }
});
