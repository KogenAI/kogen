const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { Given, When, Then } = require('@cucumber/cucumber');
const ROOT = path.resolve(__dirname, '../..');
// Independent harness: reuse real HTTP fake/installer, never implementation test assertions.
const common = String.raw`
ExUnit.start(autorun: false)
Code.require_file("test/support/integration_helpers.ex")
alias Kogen.{ChatGPT, Error, ShapeEvidence, Integration.FakeProvider, Integration.Helpers}
[home, mode, boundary] = System.argv()
items = home |> Path.join("items.json") |> File.read!() |> JSON.decode!()
usage = %{"input_tokens" => 100, "output_tokens" => 20, "input_tokens_details" => %{"cached_tokens" => 5}, "output_tokens_details" => %{"reasoning_tokens" => 10}}
unknown = %{"input" => nil, "cached" => nil, "output" => nil, "reasoning" => nil}
complete = fn r -> %{"type" => "response.completed", "response" => r} end
done = fn i, item -> %{"type" => "response.output_item.done", "output_index" => i, "item" => item} end
added = fn i, item -> %{"type" => "response.output_item.added", "output_index" => i, "item" => item} end
frames = fn values ->
 values |> Enum.with_index() |> Enum.flat_map(fn {item, i} ->
   partial = if item["type"] == "function_call", do: Map.put(item, "arguments", ""), else: item
   delta = if item["type"] == "function_call", do: [%{"type" => "response.function_call_arguments.delta", "output_index" => i, "item_id" => item["id"], "delta" => item["arguments"]}], else: []
   [added.(i, partial)] ++ delta
 end) |> Kernel.++(values |> Enum.with_index() |> Enum.reverse() |> Enum.map(fn {item, i} -> done.(i, item) end))
end
`;
const driver = common + String.raw`
if boundary == "http" do
 File.mkdir_p!(Path.join(home, ".kogen/credentials"))
 File.write!(Path.join(home, ".kogen/credentials/chatgpt.json"), JSON.encode!(%{client_id: "oaiapp_fixture", access_token: "fake-access", refresh_token: "fake-refresh", expires_at: System.system_time(:second) + 3600}))
 values = if mode == "malformed", do: List.update_at(items, 2, &Map.put(&1, "arguments", "{\"path\":")), else: items
 stream = frames.(values)
 stream = case mode do
  "empty" -> []
  "gap" -> Enum.reject(stream, &(&1["output_index"] == 0))
  "pending" -> stream ++ [added.(4, Enum.at(items, 2)), %{"type" => "response.function_call_arguments.delta", "output_index" => 4, "delta" => "{\"path\":"}]
  "sticky" -> [done.(-1, hd(items)) | stream]
  _ -> stream
 end
 terminal = %{"status" => "completed", "output" => [], "usage" => usage}
 terminal = case mode do
  "usage" -> Map.put(terminal, "usage", %{"input_tokens_details" => 42})
  "status" -> Map.put(terminal, "status", "incomplete")
  "response-error" -> Map.put(terminal, "error", %{"code" => "fixture_error"})
  _ -> terminal
 end
 failure = case mode do
  "failed" -> [%{"type" => "response.failed", "response" => %{"error" => %{}}}]
  "incomplete" -> [%{"type" => "response.incomplete", "response" => %{"incomplete_details" => %{}}}]
  "error" -> [%{"type" => "error", "error" => %{}}]
  _ -> []
 end
 events = stream ++ failure ++ [complete.(terminal)]
 action = if mode == "complete", do: {:open_events, self(), events}, else: {:events, events}
 server = FakeProvider.start([action])
 try do
  :persistent_term.put(:kogen_caller, %{env: %{"HOME" => home, "KOGEN_PROVIDER_URL" => "http://127.0.0.1:#{server.port}"}})
  ShapeEvidence.start(Path.join(home, "evidence"))
  model = %{model: "fixture", effort: "medium"}
  start = System.monotonic_time(:millisecond)
  result = try do
   value = ShapeEvidence.provider("shape", nil, "fixture", [], model, fn -> ChatGPT.respond(model, "local compatibility fixture", [], [], single_attempt: true, response_budget_ms: 1500) end)
   %{outcome: "ok", items: value.items, usage: value.usage, known_usage: value.known_usage}
  rescue
   e in Error -> %{outcome: e.class <> "/" <> e.reason, detail: e.detail, failure_event: e.provider_failure["event_kind"]}
  end
  elapsed = System.monotonic_time(:millisecond) - start
  opened = if mode == "complete", do: (receive do {:provider_open, _} -> true after 1000 -> false end), else: false
  closed = if mode == "complete", do: (receive do {:provider_closed, {:error, :closed}} -> true after 1500 -> false end), else: false
  evidence = Path.join(home, "evidence/events.ndjson") |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
  calls = Enum.filter(evidence, &(&1["event"] == "provider_call"))
  result = Map.merge(result, %{requests: length(FakeProvider.provider_requests(server)), socket_open_seen: opened, socket_closed: closed, returned_before_hold: elapsed < 1500, failed_usage_unknown: length(calls) == 1 and Enum.all?(calls, &(&1["status"] == "failed" and &1["usage"] == unknown))})
  IO.puts("COMPAT_RESULT=" <> JSON.encode!(result))
 after
  FakeProvider.stop(server)
 end
else
 suite = Helpers.setup_suite!()
 try do
  tool = %{"type" => "function_call", "id" => "read-compat", "call_id" => "read-compat", "status" => "completed", "name" => "read_file", "arguments" => JSON.encode!(%{"path" => "app.txt"})}
  prefix = Enum.take(items, 2)
  stream = case mode do
   "pending" -> frames.(prefix) ++ [added.(2, Map.put(tool, "arguments", "")), %{"type" => "response.function_call_arguments.delta", "output_index" => 2, "delta" => "{\"path\":"}]
   "malformed" -> frames.(prefix ++ [Map.put(tool, "arguments", "{\"path\":")])
   _ -> frames.(prefix ++ [tool])
  end
  first = {:events, stream ++ [complete.(%{"status" => "completed", "output" => [], "usage" => usage})]}
  question = {:function, "submit", %{"questions" => [%{"question" => "Fixture tool reached?", "options" => [%{"label" => "Yes", "recommended" => true}]}]}}
  script = if mode == "complete", do: [first, question], else: [first, first]
  c = Helpers.project!(suite, script, staged_intent: false)
  try do
   authority = fn -> {Kogen.Git.head(c.repo), File.read!(Path.join(c.repo, ".git/index")), File.read!(Kogen.Intent.approval_path(c.repo, "fixture"))} end
   before = authority.()
   helpers = fn -> File.ls!(Path.join(c.repo, "features/steps")) |> Enum.sort() end
   helpers_before = helpers.()
   request = Path.join(c.root, "request.txt")
   File.write!(request, "Read app.txt then ask the fixture question; publish no files.")
   {output, status} = Helpers.run_kogen(c, ["intent", "shape", "compat-next", request])
   IO.puts("COMPAT_RESULT=" <> JSON.encode!(%{exit: status, question_displayed: String.contains?(output, "Fixture tool reached?"), read_effect: FakeProvider.tool_outputs(c.server), requests_after_init: length(FakeProvider.provider_requests(c.server)) - 1, authority_unchanged: authority.() == before, no_intent_or_helper: not File.exists?(Path.join(c.repo, ".kogen/intents/compat-next")) and helpers.() == helpers_before}))
  after
   Helpers.cleanup_case(c)
  end
 after
  Helpers.cleanup_suite(suite)
 end
end
ExUnit.run()
`;
function run(items, mode, boundary) {
  return new Promise((resolve, reject) => {
    const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'terminal-compat-'));
    const file = path.join(temp, 'driver.exs');
    fs.writeFileSync(file, driver);
    fs.writeFileSync(path.join(temp, 'items.json'), JSON.stringify(items));
    const child = spawn('mix', ['run', '--no-deps-check', file, temp, mode, boundary], {
      cwd: ROOT, detached: true, stdio: ['ignore', 'pipe', 'pipe'],
      env: { ...process.env, ERL_FLAGS: process.env.ERL_FLAGS || '+S 2:2 +SDcpu 1 +SDio 1' },
    });
    let output = '';
    child.stdout.on('data', b => { output += b; });
    child.stderr.on('data', b => { output += b; });
    const timer = setTimeout(() => { try { process.kill(-child.pid, 'SIGKILL'); } catch {} }, 240000);
    child.once('error', e => { clearTimeout(timer); fs.rmSync(temp, { recursive: true, force: true }); reject(e); });
    child.once('close', code => {
      clearTimeout(timer); fs.rmSync(temp, { recursive: true, force: true });
      try {
        assert.equal(code, 0, output);
        const line = output.split('\n').find(l => l.startsWith('COMPAT_RESULT='));
        assert.ok(line, output);
        resolve(JSON.parse(line.slice('COMPAT_RESULT='.length)));
      } catch (e) { reject(e); }
    });
  });
}
Given('these documented compatibility items:', function (text) {
  this.compatItems = JSON.parse(text);
  assert.ok(Array.isArray(this.compatItems) && this.compatItems.length > 1);
});
When('I run the compatibility HTTP stream {string}', { timeout: 250000 }, async function (mode) {
  assert.ok(['complete','pending','malformed','empty','sticky','usage','status','response-error','gap','failed','incomplete','error'].includes(mode));
  this.compatResult = await run(this.compatItems, mode, 'http');
});
When('I run installed compatibility Shape in mode {string}', { timeout: 250000 }, async function (mode) {
  assert.ok(['complete','pending','malformed'].includes(mode));
  this.compatResult = await run(this.compatItems, mode, 'native');
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
