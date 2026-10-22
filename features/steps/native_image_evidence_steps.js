const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const zlib = require('node:zlib');
const { spawnSync } = require('node:child_process');
const ROOT = path.resolve(__dirname, '../..');
const sha = b => crypto.createHash('sha256').update(b).digest('hex');
const same = (a, b) => { try { assert.deepEqual(a, b); return true; } catch { return false; } };
// Synthetic fixture construction, not production image validation or a visual assessment.
function chunk(type, data) {
  const body = Buffer.concat([Buffer.from(type), data]);
  let crc = 0xffffffff;
  for (const byte of body) { crc ^= byte; for (let i = 0; i < 8; i++) crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0); }
  const head = Buffer.alloc(4), tail = Buffer.alloc(4);
  head.writeUInt32BE(data.length); tail.writeUInt32BE((crc ^ 0xffffffff) >>> 0);
  return Buffer.concat([head, body, tail]);
}
function png(width, height, target, color = 2) {
  const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(width); ihdr.writeUInt32BE(height, 4); ihdr[8] = 8; ihdr[9] = color;
  const raw = Buffer.alloc((width * (color === 6 ? 4 : 3) + 1) * height);
  const parts = [Buffer.from('89504e470d0a1a0a', 'hex'), chunk('IHDR', ihdr), chunk('IDAT', zlib.deflateSync(raw)), chunk('IEND', Buffer.alloc(0))];
  const size = parts.reduce((n, b) => n + b.length, 0);
  if (target) { assert.ok(target >= size + 20); parts.splice(3, 0, chunk('tEXt', Buffer.concat([Buffer.from('padding\0'), Buffer.alloc(target - size - 20, 120)]))); }
  const out = Buffer.concat(parts); if (target) assert.equal(out.length, target); return out;
}
function imageOutput(output, g) {
  try {
    assert.ok(Array.isArray(output)); assert.deepEqual(output.map(x => x.type), ['input_text', 'input_image']);
    const meta = JSON.parse(output[0].text), bytes = Buffer.from(g.base64, 'base64');
    assert.equal(output[1].image_url, 'data:image/png;base64,' + g.base64);
    assert.equal(meta.version, 1); assert.equal(meta.path, g.path); assert.equal(meta.sha256, sha(bytes));
    assert.equal(meta.bytes, bytes.length); assert.equal(meta.format, 'png'); assert.equal(meta.width, g.width); assert.equal(meta.height, g.height);
    for (const key of ['capture_candidate', 'route', 'viewport', 'fixture_state']) assert.equal(meta[key], 'UNKNOWN');
    assert.ok(meta.read_candidate === 'UNKNOWN' || /^[a-f0-9]{40,64}$/.test(meta.read_candidate));
    return true;
  } catch { return false; }
}
// Judge captured JSON objects semantically. Array order, exact strings and opaque/image bytes matter.
function replayObserver(d) {
  try {
    assert.ok(d.windows.length && d.groups.length);
    for (const window of d.windows) {
      const pending = new Set();
      for (const item of window) {
        if (item.type === 'function_call') { assert.ok(!pending.has(item.call_id)); pending.add(item.call_id); }
        if (item.type === 'function_call_output') assert.ok(pending.delete(item.call_id));
      }
      assert.equal(pending.size, 0);
    }
    for (const g of d.groups) {
      const found = [];
      for (const w of d.windows) for (let i = 0; i <= w.length - g.prefix.length - 1; i++) {
        if (same(w.slice(i, i + g.prefix.length), g.prefix)) {
          const o = w[i + g.prefix.length];
          if (o.type === 'function_call_output' && o.call_id === g.call_id) found.push(o.output);
        }
      }
      assert.ok(found.length); assert.ok(found.every(o => imageOutput(o, g)));
      const all = d.windows.flat().filter(i => i.type === 'function_call_output' && i.call_id === g.call_id);
      assert.ok(all.every(o => same(o.output, found[0])));
    }
    return true;
  } catch { return false; }
}
// Match ChatGPT.strip_cache's two shallow locations, never recursively erase payload data.
function fallbackObserver(enabled, compatible) {
  try {
    assert.ok(Object.hasOwn(enabled, 'prompt_cache_options'));
    assert.ok(!Object.hasOwn(compatible, 'prompt_cache_options'));
    const a = structuredClone(enabled), b = structuredClone(compatible);
    delete a.prompt_cache_options;
    let markers = 0;
    for (const item of a.input) if (Array.isArray(item.content)) {
      for (const block of item.content) if (Object.hasOwn(block, 'prompt_cache_breakpoint')) {
        markers++; delete block.prompt_cache_breakpoint;
      }
    }
    assert.ok(markers > 0, 'cache-enabled request must contain block markers');
    assert.ok(b.input.every(item => !Array.isArray(item.content) || item.content.every(block => !Object.hasOwn(block, 'prompt_cache_breakpoint'))));
    return same(a, b);
  } catch { return false; }
}
// Inspect original decoded strings and JSON string tokens in native diagnostic text.
// Never rewrite, redact or normalize the evidence under observation.
function containsOpaque(value, opaque) {
  if (typeof value === 'string') {
    if (value.includes(opaque)) return true;
    for (const token of value.matchAll(/"(?:[^"\\]|\\.)*"/g)) {
      try { if (JSON.parse(token[0]).includes(opaque)) return true; } catch { /* Not a JSON string token. */ }
    }
    return false;
  }
  if (Array.isArray(value)) return value.some(x => containsOpaque(x, opaque));
  return value !== null && typeof value === 'object' && Object.entries(value).some(([k, v]) => containsOpaque(k, opaque) || containsOpaque(v, opaque));
}
function logSafetyObserver(d, s) {
  const imageEvents = d.events.filter(e => ['image_read', 'image_delivery'].includes(e.event));
  const safeText = t => !t.includes('data:image/') && !t.includes('fake-integration-access-token') && !t.includes('fake-integration-refresh-token') && !t.includes(s.selected);
  return imageEvents.length > 0 && d.events.every(e => safeText(JSON.stringify(e)) && !containsOpaque(e, s.opaque)) && safeText(d.diagnostic || '') && !containsOpaque(d.diagnostic || '', s.opaque) && imageEvents.every(e => Buffer.byteLength(JSON.stringify(e)) <= 8192);
}
function reviewIndependentObserver(windows, s) {
  return windows.length > 0 && windows.every(w => !containsOpaque(w, s.opaque + '-build') && !w.some(i => i.type === 'function_call' && i.call_id === 'image-build'));
}
// Each checkpoint binds its captured owner to frozen groups, not final request groups.
function checkpointObserver(records) {
  try {
    assert.ok(Array.isArray(records) && records.length > 0);
    for (const c of records) {
      assert.ok(['build', 'review'].includes(c.owner));
      assert.equal(c.owner, c.expected_owner);
      assert.ok(Array.isArray(c.input) && Array.isArray(c.archives));
      assert.ok(c.groups.length > 0 && c.groups.some(g => g.owner === c.owner));
      for (const g of c.groups) {
        assert.ok(['build', 'review'].includes(g.owner));
        assert.equal(g.call_id, 'image-' + g.owner);
        const windows = [...(g.owner === c.owner ? [c.input] : []), ...c.archives.filter(a => a.owner === g.owner).map(a => a.input)];
        const found = [];
        for (const w of windows) for (let i = 0; i < w.length; i++) {
          const item = w[i];
          if (item.type === 'function_call_output' && item.call_id === g.call_id) {
            assert.ok(i >= g.prefix.length && same(w.slice(i - g.prefix.length, i), g.prefix));
            assert.ok(imageOutput(item.output, g)); found.push(item.output);
          }
        }
        assert.ok(found.length > 0 && found.every(o => same(o, found[0])));
      }
    }
    return true;
  } catch { return false; }
}
const checkpointCapture = String.raw`
defmodule NativeImageCheckpoint do
 def capture(saved, expected_owner, groups) do
  c = saved.continuation
  {owner,input} = cond do
   c.stage in [:review,:review_verify,:review_retry_verify] -> {"review",c.session.input}
   c.stage in [:builder,:builder_verify] -> {"build",c.input}
   c.stage == :tool and c[:owner] == :builder -> {"build",c.input}
   true -> {"UNKNOWN",[]}
  end
  archives = for {owner,state} <- saved.working_context, ref <- state.history do
   %{owner: owner, input: JSON.decode!(File.read!(ref["path"]))["input"]}
  end
  %{owner: owner, expected_owner: expected_owner, input: input, groups: groups, archives: archives}
 end
end
`;
const control = checkpointCapture + String.raw`
b = Base.decode64!(System.fetch_env!("IMAGE_CONTROL_BYTES"))
p = "synthetic.png"
call = %{"type" => "function_call", "id" => "control-item", "call_id" => "control-call", "name" => "view_image", "arguments" => JSON.encode!(%{"path" => p})}
r = %{"type" => "reasoning", "id" => "opaque-item", "encrypted_content" => "opaque+/==\nΔ🙂", "summary" => []}
m = %{"type" => "message", "id" => "message-item", "role" => "assistant", "phase" => "commentary", "content" => [%{"type" => "output_text", "text" => "UNFINISHED synthetic observation"}]}
prefix = Enum.map([r,m,call], &Kogen.Shape.replay_item/1)
meta = %{version: 1, path: p, sha256: Kogen.WorkingContext.hash(b), bytes: byte_size(b), format: "png", width: 1, height: 1, read_candidate: "UNKNOWN", capture_candidate: "UNKNOWN", route: "UNKNOWN", viewport: "UNKNOWN", fixture_state: "UNKNOWN"}
output = [%{"type" => "input_text", "text" => JSON.encode!(meta)}, %{"type" => "input_image", "image_url" => "data:image/png;base64," <> Base.encode64(b)}]
authority = %{"role" => "user", "content" => Kogen.PromptCache.contract_blocks("synthetic stable authority", "synthetic current progress")}
items = [authority] ++ prefix ++ [Kogen.Shape.output(call,output)]
tools = [%{"type" => "function", "name" => "view_image", "description" => "Synthetic read-only image control", "parameters" => %{"type" => "object", "properties" => %{"path" => %{"type" => "string"}}, "required" => ["path"], "additionalProperties" => false}}, %{"type" => "function", "name" => "cache_data", "description" => "Synthetic opaque-data schema, not cache controls", "parameters" => %{"type" => "object", "properties" => %{"prompt_cache_options" => %{"type" => "string"}, "prompt_cache_breakpoint" => %{"type" => "string"}}, "required" => ["prompt_cache_options", "prompt_cache_breakpoint"], "additionalProperties" => false}}]
body = Kogen.ChatGPT.request_body(%{model: "gpt-6.1-sol", effort: "high"}, "synthetic policy", items, tools)
Kogen.PromptCache.unsupported()
compatible = Kogen.ChatGPT.request_body(%{model: "gpt-6.1-sol", effort: "high"}, "synthetic policy", items, tools)
# Bounded synthetic controls use the current native JSON encoder/decoder, not a
# replacement observer. Opaque-only negatives carry no image bytes or credentials.
s = %{opaque: "synthetic opaque+/==\nΔ🙂", selected: Base.encode64(b)}
safe_event = Map.merge(meta, %{event: "image_read", owner: "review", call_id: "image-review", status: "read"})
safe_logs = %{events: [safe_event], diagnostic: "native diagnostic " <> JSON.encode!(safe_event)}
leaks = [s.opaque, Enum.at(output, 1)["image_url"], s.selected, "fake-integration-access-token", "fake-integration-refresh-token"]
bad_logs = Enum.flat_map(leaks, fn leak ->
  [%{safe_logs | events: [Map.put(safe_event, :payload, leak)]},
   %{safe_logs | diagnostic: "native diagnostic " <> leak},
   %{safe_logs | diagnostic: "native diagnostic " <> JSON.encode!(%{payload: leak})}]
end) ++ [%{safe_logs | events: [Map.put(safe_event, :padding, String.duplicate("Δ", 4096))]}]
review_reason = Kogen.Shape.replay_item(Map.put(r, "encrypted_content", s.opaque <> "-review"))
build_reason = Kogen.Shape.replay_item(Map.put(r, "encrypted_content", s.opaque <> "-build"))
review_call = Kogen.Shape.replay_item(Map.put(call, "call_id", "image-review"))
review_window = [review_reason, review_call, Kogen.Shape.output(review_call, output)]
roundtrip = fn value -> JSON.decode!(JSON.encode!(value)) end
safety = roundtrip.(%{inputs: s, good_logs: safe_logs, bad_logs: bad_logs, good_review: [review_window], bad_review: [[[build_reason]], [[Map.put(call, "call_id", "image-build")]], [[%{"role" => "assistant", "content" => JSON.encode!(build_reason)}]]], serialized_event: JSON.encode!(Map.put(safe_event, :payload, s.opaque))})
# Synthetic v3 custody only: no real Build checkpoint or provider is read.
root = Path.join(Path.dirname(System.fetch_env!("IMAGE_CONTROL_RECEIPT")), "custody")
run = Kogen.Run.start(root)
intent = %Kogen.Intent{root: root, slug: "synthetic", title: "Synthetic", text: "Synthetic", model: "not applicable — fixture"}
state = %{root: root, slug: intent.slug, start: "head", git_index: "index", start_tree: "tree", approval_bytes: Base.encode64("approval"), run: run, config: %Kogen.Config{}, intent: intent, model: :none, phase: :building, t0: 0, last_pass: nil, last_review: nil, blocker: nil, parent: nil, root_run: nil, baseline_digests: %{Kogen.Config.path() => "digest"}, baseline: [Kogen.Config.path()], excluded: [], round: 1, pass: 1, review: 1, repairs: 0, model_active_ms: 0, unknown_requests: 0, usage: Kogen.Usage.zero(), attempt_usage: Kogen.Usage.zero(), working_context: %{}, source_provenance: nil, continuation: %{stage: :builder, input: []}}
make_group = fn owner ->
 c = call |> Map.put("call_id", "image-" <> owner) |> Map.put("id", "item-" <> owner)
 prefix = Enum.map([Map.put(r,"encrypted_content",s.opaque <> "-" <> owner),m,c], &Kogen.Shape.replay_item/1)
 {prefix ++ [Kogen.Shape.output(c,output)], %{owner: owner, prefix: prefix, call_id: c["call_id"], path: p, width: 1, height: 1, base64: Base.encode64(b)}}
end
{build_input,bg} = make_group.("build")
{review_input,rg} = make_group.("review")
pass = %{n: 1, tree: "tree", green: false, clean: true, moved: [], failing: [], acceptance: :not_run, model: :none, checks: []}
session = %{input: review_input, attempts: [], role: %{model: "fixture", effort: "high"}, tools: [], usage: %{}}
build = %{state | continuation: %{stage: :builder, input: build_input}}
review = %{state | continuation: %{stage: :review, pass: pass, session: session}}
archive = fn owner, input ->
 dir = Path.join([run.dir,"working-context",owner])
 File.mkdir_p!(dir)
 File.chmod!(Path.dirname(dir),0o700)
 File.chmod!(dir,0o700)
 file = Path.join(dir,"1.json")
 bytes = JSON.encode!(%{input: input}) <> "\n"
 File.write!(file,bytes)
 File.chmod!(file,0o600)
 %{mandatory: [], observations: [], history: [%{"path" => file, "sha256" => Kogen.WorkingContext.hash(bytes)}]}
end
ba = archive.("build",build_input)
ra = archive.("review",review_input)
growing = %{review | continuation: %{review.continuation | session: %{session | input: []}}, working_context: %{"build" => ba,"review" => ra}}
capture = fn value, owner, groups ->
 Kogen.Run.checkpoint(run,%{"version" => 3,"state" => Base.encode64(:erlang.term_to_binary(value)),"identity" => "synthetic","candidate" => "tree","index" => Base.encode64("index"),"approval" => value.approval_bytes})
 {:ok,_,saved} = Kogen.Run.decode_checkpoint(File.read!(Path.join(run.dir,"checkpoint.json")))
 Kogen.WorkingContext.validate!(saved)
 NativeImageCheckpoint.capture(saved,owner,groups)
end
altered = List.update_at(build_input,-1,fn o -> Map.update!(o,"output",fn out -> List.update_at(out,1,&Map.update!(&1,"image_url",fn url -> url <> "changed" end)) end) end)
wrong_hash = List.update_at(build_input,-1,fn o -> Map.update!(o,"output",fn out -> List.update_at(out,0,fn meta -> Map.update!(meta,"text",fn text -> JSON.decode!(text) |> Map.put("sha256",String.duplicate("0",64)) |> JSON.encode!() end) end) end) end)
checkpoints = %{good: [[capture.(build,"build",[bg]),capture.(review,"review",[rg])], [capture.(growing,"review",[bg,rg])], [capture.(%{build | continuation: %{stage: :tool, owner: :builder, input: build_input}},"build",[bg])]], bad: [
 [capture.(review,"build",[bg])],
 [capture.(%{build | continuation: %{stage: :builder,input: review_input}},"build",[bg])],
 [capture.(%{build | continuation: %{stage: :builder,input: Enum.drop(build_input,-1)}},"build",[bg])],
 [capture.(%{build | continuation: %{stage: :builder,input: altered}},"build",[bg])],
 [capture.(%{build | continuation: %{stage: :builder,input: wrong_hash}},"build",[bg])],
 [capture.(%{build | continuation: %{stage: :builder,input: []},working_context: %{"review" => ba}},"build",[bg])],
 [capture.(%{growing | working_context: %{"build" => ba}},"review",[bg,rg])],
 [capture.(%{growing | working_context: %{"review" => ra}},"review",[bg,rg])],
 []
]}
# Native replay/output/request serialization, then an actual JSON custody round trip.
file = System.fetch_env!("IMAGE_CONTROL_RECEIPT")
File.write!(file, JSON.encode!(%{checkpoints: checkpoints, safety: safety, fallback: [body, compatible], windows: [body["input"]], groups: [%{prefix: prefix, call_id: call["call_id"], path: p, width: 1, height: 1, base64: Base.encode64(b)}]}))
`;
function retainedEvidence() {
  const dir = '/Users/almirsarajcic/Areas/Kogen/studio-work/kogen-repairs/native-image-evidence-20261021';
  const bytes = fs.readFileSync(path.join(dir, 'attempt-01/result.json'));
  assert.equal(sha(bytes), '3d1df30ef18bf31afa23024e75e36909a9ee3f2f53bf165ab2a5c73977ec8f55');
  const d = JSON.parse(bytes); assert.equal(d.status, 'content_discrimination_passed');
  assert.equal(d.endpoint, 'https://api.openai.com/v1/responses'); assert.equal(d.model, 'gpt-6.1-sol'); assert.equal(d.effort, 'high');
  assert.equal(d.requests.length, 2); assert.ok(d.requests.every(x => x.http_status === 200 && x.status === 'completed' && x.curl_exit === -15 && x.stopped_after_terminal_event));
  assert.equal(d.ground_truth_sent, false); assert.deepEqual(d.observations.map(x => [x.color, x.count]), [['red', 3], ['blue', 6]]);
  assert.ok(d.requests.every(x => x.usage.output_tokens_details.reasoning_tokens === 0));
  const provenance = JSON.parse(fs.readFileSync(path.join(dir, 'provenance.json')));
  for (const name of ['function-calling.md', 'images-vision.md']) {
    const ref = provenance.docs.find(x => x.path === 'docs/' + name); assert.ok(ref);
    const raw = fs.readFileSync(path.join(dir, ref.path)); assert.equal(sha(raw), ref.sha256); assert.equal(raw.length, ref.bytes);
  }
  assert.ok(fs.readFileSync(path.join(dir, 'docs/function-calling.md'), 'utf8').includes('array of image or file objects'));
  const redacted = JSON.parse(fs.readFileSync(path.join(dir, 'attempt-01/request-2-redacted.json')));
  const images = redacted.input.filter(x => x.type === 'function_call_output').flatMap(x => x.output);
  assert.equal(images.length, 2); assert.ok(images.every(x => x.type === 'input_image' && /^[a-f0-9]{64}$/.test(x.image_bytes_sha256)));
  process.stdout.write('verified retained two-request PNG capability; no inference\n');
}
if (require.main === module) {
  try {
    if (process.argv[2] === '--retained-evidence') retainedEvidence();
    else if (process.argv[2] === '--control') {
      const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-image-control-'));
      try {
        const script = path.join(dir, 'control.exs'), receipt = path.join(dir, 'receipt.json'); fs.writeFileSync(script, control);
        const r = spawnSync('mix', ['run', script], { cwd: ROOT, env: { ...process.env, IMAGE_CONTROL_BYTES: png(1, 1).toString('base64'), IMAGE_CONTROL_RECEIPT: receipt }, encoding: 'utf8', timeout: 60000 });
        assert.equal(r.status, 0, r.stdout + r.stderr); const good = JSON.parse(fs.readFileSync(receipt));
        assert.equal(replayObserver(good), true, 'native serialized control must be accepted');
        const [enabled, compatible] = good.fallback;
        assert.deepEqual(enabled.prompt_cache_options, { mode: 'implicit', ttl: '30m' });
        assert.deepEqual([enabled.input[0].content[0].prompt_cache_breakpoint, enabled.input[1].content[0].prompt_cache_breakpoint], [{ mode: 'explicit' }, { mode: 'explicit' }]);
        assert.equal(fallbackObserver(enabled, compatible), true, 'native cache removal must be accepted');
        const reordered = Object.fromEntries(Object.entries(compatible).reverse());
        reordered.input = compatible.input.map(item => Object.fromEntries(Object.entries(item).reverse()));
        assert.equal(fallbackObserver(enabled, reordered), true, 'JSON key order is immaterial');
        const safety = good.safety;
        assert.ok(safety.inputs.opaque.includes('\n') && safety.inputs.opaque.includes('Δ🙂'));
        assert.ok(safety.serialized_event.includes('\\n') && !safety.serialized_event.includes(safety.inputs.opaque));
        assert.equal(logSafetyObserver(safety.good_logs, safety.inputs), true, 'safe native metadata must be accepted');
        assert.equal(reviewIndependentObserver(safety.good_review, safety.inputs), true, 'fresh reviewer pixels/reasoning must be accepted');
        for (const records of good.checkpoints.good) assert.equal(checkpointObserver(records), true, 'owner-bound native checkpoint rejected');
        if (process.argv[3] === 'good') process.stdout.write('accepted\n');
        else {
          assert.equal(process.argv[3], 'bad');
          const mutations = [
            d => d.windows[0].pop(),
            d => { const w = d.windows[0]; w[w.length - 1].output = JSON.stringify(w[w.length - 1].output); },
            d => { const w = d.windows[0]; w[w.length - 1].output[1].image_url += 'changed'; },
            d => { const w = d.windows[0]; w[w.length - 1].call_id = 'wrong-call'; },
            d => { d.windows[0].find(x => x.type === 'reasoning').encrypted_content += 'changed'; },
            d => { d.windows[0].find(x => x.type === 'message').phase = 'final'; },
            d => d.windows[0].reverse(),
            d => { const w = d.windows[0]; const meta = JSON.parse(w[w.length - 1].output[0].text); meta.route = '/guessed-from-name'; w[w.length - 1].output[0].text = JSON.stringify(meta); },
          ];
          for (const mutate of mutations) { const bad = structuredClone(good); mutate(bad); assert.equal(replayObserver(bad), false, 'counterexample accepted'); }
          const fallbackMutations = [
            (a, b) => { b.prompt_cache_options = a.prompt_cache_options; },
            (a, b) => { b.input[0].content[0].prompt_cache_breakpoint = a.input[0].content[0].prompt_cache_breakpoint; },
            (a, b) => { b.input[1].content[0].prompt_cache_breakpoint = a.input[1].content[0].prompt_cache_breakpoint; },
            (a, b) => { delete a.prompt_cache_options; },
            (a, b) => { for (const item of a.input) for (const block of item.content || []) delete block.prompt_cache_breakpoint; },
            (a, b) => { b.input.at(-1).output[1].image_url += 'changed'; },
            (a, b) => { b.input.at(-1).output = JSON.stringify(b.input.at(-1).output); },
            (a, b) => { b.input.at(-1).output.reverse(); },
            (a, b) => { b.input.at(-1).output[0].text += ' '; },
            (a, b) => { b.input.at(-1).call_id = 'wrong-call'; },
            (a, b) => { b.input.find(x => x.type === 'function_call').call_id = 'wrong-call'; },
            (a, b) => { b.input.find(x => x.type === 'function_call').arguments += ' '; },
            (a, b) => { b.input.find(x => x.type === 'reasoning').encrypted_content += 'changed'; },
            (a, b) => { b.input.find(x => x.type === 'message').phase = 'final'; },
            (a, b) => { b.input.reverse(); },
            (a, b) => { b.input[0].content[0].text += 'changed'; },
            (a, b) => { b.input[1].content[0].text += 'changed'; },
            (a, b) => { b.input[1].content[1].text += 'changed'; },
            (a, b) => { b.model = 'different-model'; },
            (a, b) => { b.reasoning.effort = 'medium'; },
            (a, b) => { b.include = []; },
            (a, b) => { b.stream = false; },
            (a, b) => { b.store = true; },
            (a, b) => { b.tool_choice = 'none'; },
            (a, b) => { b.tools.reverse(); },
            (a, b) => { b.tools[0].parameters.required = []; },
            (a, b) => { delete b.tools[1].parameters.properties.prompt_cache_options; },
            (a, b) => { delete b.tools[1].parameters.properties.prompt_cache_breakpoint; },
            (a, b) => { b.prompt_cache_breakpoint = { user: 'not a top-level cache control' }; },
            (a, b) => { b.input.at(-1).output[0].prompt_cache_breakpoint = { user: 'not input content' }; },
          ];
          for (const mutate of fallbackMutations) {
            const [a, b] = structuredClone(good.fallback); mutate(a, b);
            assert.equal(fallbackObserver(a, b), false, 'fallback counterexample accepted');
          }
          for (const bad of safety.bad_logs) assert.equal(logSafetyObserver(bad, safety.inputs), false, 'log disclosure or oversized event accepted');
          for (const bad of safety.bad_review) assert.equal(reviewIndependentObserver(bad, safety.inputs), false, 'builder-only review import accepted');
          for (const records of good.checkpoints.bad) assert.equal(checkpointObserver(records), false, 'wrong-owner or missing/altered checkpoint pixels accepted');
          process.stdout.write('rejected\n'); process.exitCode = 1;
        }
      } finally { fs.rmSync(dir, { recursive: true, force: true }); }
    } else throw new Error('unknown control mode');
  } catch (e) { process.stderr.write(String(e) + '\n'); process.exitCode = 2; }
} else {
  const { Given, When, Then, AfterAll } = require('@cucumber/cucumber');
  let work, archive;
  const driver = String.raw`
Code.require_file(Path.expand("test/support/integration_helpers.ex", File.cwd!()))
${checkpointCapture}
defmodule NativeImageExercise do
 use ExUnit.Case
 alias Kogen.{Intent, Shape, Tools, WorkingContext}
 alias Kogen.Integration.{Helpers, FakeProvider}
 @tag timeout: 220_000
 test "capture native image evidence" do
  s = JSON.decode!(File.read!(System.fetch_env!("IMAGE_INPUT")))
  mode = System.fetch_env!("IMAGE_MODE")
  result = if mode == "validation", do: validation(s), else: installed(s,mode)
  File.write!(System.fetch_env!("IMAGE_RECEIPT"), JSON.encode!(result))
 end
 defp f(n,a), do: {:function,n,a}
 defp script(c,actions), do: Agent.update(c.server.state, fn s -> %{s | script: Enum.take(s.script,s.next) ++ List.duplicate(nil,max(s.next-length(s.script),0)) ++ actions} end)
 defp requests(c), do: FakeProvider.provider_requests(c.server)
 defp git(c,args) do
  {out,0} = Helpers.git!(c,args)
  String.trim(out)
 end
 defp approve(c) do
  {out,5} = Helpers.run_kogen(c,["intent","approve","fixture"])
  [_,hash] = Regex.run(~r/SHA-256: ([a-f0-9]{64})/,out)
  {out,0} = Helpers.run_kogen(c,["intent","approve","fixture",hash])
  out
 end
 defp files(p) do
  if File.dir?(p), do: Enum.flat_map(File.ls!(p), &files(Path.join(p,&1))), else: if(File.regular?(p), do: [p], else: [])
 end
 defp custody(c), do: %{head: git(c,["rev-parse","HEAD"]), index: File.read!(Path.join(c.repo,".git/index")), approval: File.read!(Intent.approval_path(c.repo,"fixture")), app: File.read!(Path.join(c.repo,"app.txt"))}
 defp protected(c), do: Map.new([".kogen/project.yaml",Intent.intent_md("fixture"),Intent.feature("fixture"),"features/steps/integration_steps.js"], fn p -> {p,File.read!(Path.join(c.repo,p))} end)
 defp validation(s) do
  tmp = Kogen.tmp_path("image-validation")
  File.mkdir_p!(tmp)
  try do
   ctx = %{root: tmp, protected: [], tools: ["view_image"]}
   advertised = try do Enum.any?(Tools.defs(["view_image"]), &(&1["name"] == "view_image")) rescue FunctionClauseError -> false end
   rows = Enum.map(s["images"], fn image ->
    p = Path.join(tmp,image["name"])
    cond do
     image["name"] == "missing" -> :ok
     image["name"] == "folder" -> File.mkdir_p!(p)
     true -> File.write!(p,Base.decode64!(image["base64"]))
    end
    output = if advertised, do: Tools.run("view_image",%{"path" => image["name"]},ctx), else: "native view_image not implemented"
    %{name: image["name"], output: output, uncut: (if is_list(output), do: apply(Tools,:cut,[output]) == output, else: false), framed: Shape.output(%{"call_id" => image["name"]},output)}
   end)
   body = Kogen.ChatGPT.request_body(%{model: "gpt-6.1-sol", effort: "high"},"synthetic Δ🙂 policy",[],[])
   measured = Enum.map([s["budget"]-1,s["budget"],s["budget"]+1], fn n ->
    base = Map.put(body,"padding","")
    WorkingContext.measure(Map.put(base,"padding",String.duplicate("x",n-byte_size(JSON.encode!(base)))))
   end)
   %{rows: rows, advertised: advertised, measured: measured}
  after
   File.rm_rf!(tmp)
  end
 end
 defp group(owner,p,s,serial \\ "") do
  id = owner <> serial
  call = %{"type" => "function_call", "id" => "item-"<>id, "call_id" => "image-"<>id, "name" => "view_image", "arguments" => JSON.encode!(%{"path" => p})}
  r = %{"type" => "reasoning", "id" => "reasoning-"<>id, "encrypted_content" => s["opaque"]<>"-"<>id, "summary" => []}
  m = %{"type" => "message", "id" => "message-"<>id, "role" => "assistant", "phase" => "commentary", "content" => [%{"type" => "output_text", "text" => s["unfinished"]<>" "<>id}]}
  prefix = Enum.map([r,m,call],&Shape.replay_item/1)
  {prefix,%{owner: owner, prefix: prefix, call_id: call["call_id"], path: p, base64: s["selected"], width: 1, height: 1}}
 end
 defp observation(owner,s,tool,args) do
  {:items,[%{"type" => "message", "id" => "observed-"<>owner, "role" => "assistant", "phase" => "commentary", "content" => [%{"type" => "output_text", "text" => s["observation"]}]},%{"type" => "function_call", "id" => "after-"<>owner, "call_id" => "after-"<>owner, "name" => tool, "arguments" => JSON.encode!(args)}]}
 end
 defp installed(s,mode) do
  suite = Helpers.setup_suite!()
  try do
   c = Helpers.project!(suite,[],staged_intent: false)
   try do
    # Cheap clean unrelated baseline BEFORE targeted second-slug Shape or renewed approval.
    git(c,["add",".kogen/intents/fixture","features/steps/integration_steps.js"])
    git(c,["commit","-qm","Commit unrelated native fixture baseline"])
    assert git(c,["status","--porcelain"]) == ""
    approve(c)
    before = custody(c)
    protection = protected(c)
    p = Path.join(c.root,"selected.png")
    File.write!(p,Base.decode64!(s["selected"]))
    q = Path.join(c.root,"review.png")
    File.write!(q,Base.decode64!(s["selected"]))
    n = length(requests(c))
    {items,g} = group(if(mode in ["shape","budget-shape"], do: "shape", else: "build"),p,s)
    {review_items,rg} = group("review",q,s)
    if mode in ["shape","budget-shape","budget-build"] do
     input = Path.join(c.root,"request.txt")
     File.write!(input,"Synthetic selected PNG evidence only: "<>p)
     actions = if mode == "shape" do
      [{:items,items},{:pause,self(),observation("shape",s,"read_file",%{"path" => "app.txt"})},f("submit",%{"questions" => [%{"question" => "Synthetic fixture stop", "options" => [%{"label" => "Keep", "recommended" => true},%{"label" => "Stop"}]}]})]
     else
      calls = for i <- 1..3 do
       {prefix,_} = group("budget",p,s,Integer.to_string(i))
       List.last(prefix)
      end
      [{:items,calls}]
     end
     script(c,actions)
     args = if mode == "budget-build", do: ["intent","build","fixture"], else: ["intent","shape","image-shape",input]
     {out,code} = if mode == "shape" do
      port = Helpers.start_kogen(c,args)
      receive do
       {:provider_paused,pid} -> File.rm!(p); send(pid,:continue)
      after
       15_000 -> flunk("native Shape never reached image-bearing response boundary")
      end
      Helpers.await_exit(port,"",30_000)
     else
      Helpers.run_kogen(c,args)
     end
     reqs = Enum.drop(requests(c),n)
     common(c,s,reqs,[g],protection) |> Map.merge(%{shape_completed: code == 5, path_deleted: not File.exists?(p), budget_refusal: code != 0 and out =~ "candidate/context_budget_exceeded", requests_after_init: length(reqs), no_oversized_request: Enum.all?(reqs, &(byte_size(&1.body) <= s["budget"])), custody_unchanged: custody(c) == before, actionable: out =~ "524288" and out =~ "131072" and Regex.match?(~r/prepar|Refine|approval/i,out), diagnostic: out})
    else
     grows = mode in ["windows","archive-drift"]
     growth = fn owner -> for i <- 1..s["turns"], do: f("write_file",%{"path" => "app.txt", "content" => owner<>Integer.to_string(i)<>String.duplicate("x",s["payload_bytes"])}) end
     finish = f("finish",%{"summary" => "Synthetic implementation finished, visual observations are not check approval"})
     cache_error = {:http,400,%{"error" => %{"type" => "invalid_request_error", "code" => "invalid_parameter", "message" => "prompt_cache_options is not supported on this model"}}}
     obs = observation("build",s,"write_file",%{"path" => "app.txt", "content" => "image journey\n"})
     actions = cond do
      grows -> [{:items,items},obs] ++ growth.("build") ++ [finish,{:items,review_items},observation("review",s,"read_file",%{"path" => "app.txt"})] ++ growth.("review")
      mode == "uncertain" -> [{:items,items},f("shell",%{"command" => "printf 'once\\n' >> .kogen/local/image-effects; touch .kogen/local/image-entered; sleep 60"})]
      mode == "delivery-failure" -> [{:items,items}]
      mode == "fallback" -> [{:items,items},cache_error,obs]
      true -> [{:items,items},obs]
     end
     script(c,actions)
     {out,code} = if mode == "uncertain" do
      port = Helpers.start_kogen(c,["intent","build","fixture"])
      Helpers.wait_for_file!(Path.join(c.repo,".kogen/local/image-entered"),20_000)
      Helpers.signal!(c,port,"TERM")
      Helpers.await_exit(port,"",20_000)
     else
      Helpers.run_kogen(c,["intent","build","fixture"])
     end
     first = Enum.drop(requests(c),n)
     [cp] = Path.wildcard(Path.join(c.repo,".kogen/local/runs/*/checkpoint.json"))
     {:ok,_,saved} = Kogen.Run.decode_checkpoint(File.read!(cp))
     id = Path.basename(Path.dirname(cp))
     old_result = File.read!(Path.join(Path.dirname(cp),"result.json"))
     old = custody(c)
     File.write!(p,"changed or expired original artifact")
     if mode == "resume-delete", do: File.rm!(p)
     ap = Path.wildcard(Path.join(c.repo,".kogen/local/runs/*/working-context/*/*.json"))
     archive_windows = Enum.map(ap, fn a -> JSON.decode!(File.read!(a))["input"] end)
     groups = if grows, do: [g,rg], else: [g]
     base = common(c,s,first,groups,protection)
     base = Map.merge(base,%{no_commit_on_failure: code != 0 and old.head == before.head, checkpoints: [NativeImageCheckpoint.capture(saved,if(grows, do: "review", else: "build"),groups)], archive_windows: archive_windows, build_archive: Enum.any?(ap,&String.contains?(&1,"/build/")), review_archive: Enum.any?(ap,&String.contains?(&1,"/review/")), archive_files: Enum.map(ap,&file_fact/1), private: private?([cp] ++ ap), diagnostic: out, fallback_requests: Enum.map(first,& &1.json)})
     cond do
      mode == "delivery-failure" -> base
      mode in ["archive-drift","uncertain"] ->
       if mode == "archive-drift" do
        assert ap != [], "fixture did not reach a working-window reset"
        File.write!(hd(ap),"{\"input\":[]}\n")
       end
       n2 = length(requests(c))
       {refusal,rk} = Helpers.run_kogen(c,["intent","resume",id])
       Map.merge(base,%{refused: rk != 0, no_inference_on_refusal: length(requests(c)) == n2, custody_unchanged: custody(c) == old, actionable: Regex.match?(~r/history|archive|uncertain|custody/i,refusal), effect_once: File.read(Path.join(c.repo,".kogen/local/image-effects")) == {:ok,"once\n"}, diagnostic: out<>refusal})
      true ->
       # First continuation is the exact saved owner. Ordinary modes then stop the fresh reviewer too.
       script(c,if(grows, do: [f("submit_review",%{"verdict" => "approve", "findings" => []})], else: [finish,{:items,review_items},observation("review",s,"read_file",%{"path" => "app.txt"})]))
       n2 = length(requests(c))
       {resume,rk} = Helpers.run_kogen(c,["intent","resume",id])
       second = Enum.drop(requests(c),n2)
       same_input = second != [] and hd(second).json["input"] == List.last(first).json["input"]
       {final_code,review_same,final_output,checkpoints} = if grows do
        {rk,true,resume,base.checkpoints}
       else
        assert rk != 0, resume
        newer = Path.wildcard(Path.join(c.repo,".kogen/local/runs/*/checkpoint.json")) -- [cp]
        [review_cp] = newer
        {:ok,_,review_saved} = Kogen.Run.decode_checkpoint(File.read!(review_cp))
        checkpoints = base.checkpoints ++ [NativeImageCheckpoint.capture(review_saved,"review",[rg])]
        File.rm!(q)
        script(c,[f("submit_review",%{"verdict" => "approve", "findings" => []})])
        nn = length(requests(c))
        {o,k} = Helpers.run_kogen(c,["intent","resume",Path.basename(Path.dirname(review_cp))])
        last = Enum.drop(requests(c),nn)
        {k,last != [] and hd(last).json["input"] == List.last(second).json["input"],resume<>o,checkpoints}
       end
       all = Enum.drop(requests(c),n)
       final = common(c,s,all,[g,rg],protection)
       Map.merge(base,final) |> Map.merge(%{checkpoints: checkpoints, resume_same_input: same_input and review_same, one_commit: final_code == 0 and git(c,["rev-list","--count",before.head<>"..HEAD"]) == "1", old_result_unchanged: File.read!(Path.join(Path.dirname(cp),"result.json")) == old_result, diagnostic: out<>final_output})
     end
    end
   after
    Helpers.cleanup_case(c)
   end
  after
   Helpers.cleanup_suite(suite)
  end
 end
 defp file_fact(p), do: %{file_mode: Bitwise.band(File.stat!(p).mode,0o777), dir_mode: Bitwise.band(File.stat!(Path.dirname(p)).mode,0o777)}
 defp private?(paths), do: paths != [] and Enum.all?(paths,fn p -> file_fact(p) == %{file_mode: 0o600, dir_mode: 0o700} end)
 defp common(c,s,reqs,groups,protection) do
  ap = Path.wildcard(Path.join(c.repo,".kogen/local/runs/*/working-context/*/*.json"))
  aw = Enum.map(ap,fn p -> JSON.decode!(File.read!(p))["input"] end)
  logs = files(Path.join(c.repo,".kogen/local")) |> Enum.filter(fn p -> Path.basename(p) in ["log.jsonl","events.ndjson"] end) |> Enum.flat_map(fn p -> File.read!(p) |> String.split("\n",trim: true) |> Enum.map(&JSON.decode!/1) end)
  reviews = Enum.filter(reqs,fn r -> r in FakeProvider.review_requests(c.server) end)
  advertised = reqs != [] and Enum.all?(reqs,fn r -> Enum.any?(r.json["tools"] || [],&(&1["name"] == "view_image")) end)
  %{advertised: advertised, windows: Enum.map(reqs,& &1.json["input"]) ++ aw, groups: groups, bounded: reqs != [] and Enum.all?(reqs,&(byte_size(&1.body) <= s["budget"])), events: logs, review_windows: Enum.map(reviews,& &1.json["input"]), protection_same: protected(c) == protection}
 end
end
`;
  function execute(file, args, options = {}) {
    const r = spawnSync(file, args, { cwd: ROOT, env: process.env, encoding: 'utf8', timeout: 240000, maxBuffer: 16 * 1024 * 1024, ...options });
    assert.equal(r.status, 0, (r.stdout || '') + (r.stderr || '') + (r.error || '')); return r.stdout;
  }
  function qualify(d, s) {
    if (d.rows) {
      d.accepted = d.rows.filter(x => Array.isArray(x.output)).map(x => x.name);
      d.rejected = d.rows.filter(x => typeof x.output === 'string' && x.output.startsWith('error:')).map(x => x.name);
      const good = d.rows.filter(x => Array.isArray(x.output));
      d.metadata_exact = good.length > 0 && good.every(x => { const image = s.images.find(i => i.name === x.name); return imageOutput(x.output, { ...image, path: image.name }); });
      d.typed_uncut = good.length > 0 && good.every(x => x.uncut && same(x.framed.output, x.output));
      d.boundary_bytes = d.measured.map(x => x.rendered_bytes); d.boundary_fits = d.measured.map(x => x.fits); d.reserve = d.measured[0].output_reserve_tokens;
      delete d.rows; return d;
    }
    d.typed_replay = replayObserver(d);
    const bytes = Buffer.from(s.selected, 'base64'), hash = sha(bytes);
    const imageEvents = d.events.filter(e => ['image_read', 'image_delivery'].includes(e.event));
    d.logs_safe = logSafetyObserver(d, s);
    const delivered = imageEvents.filter(e => e.event === 'image_delivery' && e.sha256 === hash);
    d.read_distinct_from_delivery = imageEvents.some(e => e.event === 'image_read' && e.status === 'read' && e.sha256 === hash) && delivered.some(e => e.status === 'completed') && imageEvents.every(e => e.event !== 'image_read' || e.status !== 'completed');
    d.delivery_failed = delivered.some(e => e.status === 'failed'); d.no_completed_delivery = !delivered.some(e => e.status === 'completed');
    const has = (windows, group) => windows.some(w => w.some(i => i.type === 'function_call_output' && i.call_id === group.call_id && imageOutput(i.output, group)));
    d.saved_pixels = checkpointObserver(d.checkpoints);
    d.archive_pixels = !!d.archive_windows && d.groups.every(g => has(d.archive_windows, g));
    d.review_own_pixels = d.groups.some(g => g.call_id === 'image-review' && has(d.review_windows, g));
    d.review_independent = reviewIndependentObserver(d.review_windows, s);
    d.explicit_observation = d.windows.some(w => w.some(i => i.role === 'assistant' && (i.content || []).some(x => x.text === s.observation)));
    d.fallback_exact = false;
    if (d.fallback_requests && d.fallback_requests.length >= 3) {
      d.fallback_exact = fallbackObserver(d.fallback_requests[1], d.fallback_requests[2]);
    }
    for (const k of ['windows','groups','events','review_windows','checkpoints','archive_windows','fallback_requests']) delete d[k];
    return d;
  }
  Given('the native image qualification inputs:', function (json) {
    const s = JSON.parse(json);
    const fixtures = [
      ['small', png(1, 1), 1, 1], ['bytes_minus', png(1, 1, s.max_bytes - 1), 1, 1], ['bytes_equal', png(1, 1, s.max_bytes), 1, 1],
      ['dimension_minus', png(s.max_dimension - 1, 1), s.max_dimension - 1, 1], ['dimension_equal', png(s.max_dimension, 1), s.max_dimension, 1],
      ['missing', Buffer.alloc(0), 0, 0], ['folder', Buffer.alloc(0), 0, 0], ['bad_crc', Buffer.from(png(1, 1)), 1, 1], ['truncated', png(1, 1).subarray(0, 45), 1, 1],
      ['unsupported', png(1, 1, undefined, 6), 1, 1], ['bytes_plus', png(1, 1, s.max_bytes + 1), 1, 1], ['dimension_zero', png(0, 1), 0, 1], ['dimension_plus', png(s.max_dimension + 1, 1), s.max_dimension + 1, 1],
    ];
    fixtures.find(x => x[0] === 'bad_crc')[1][29] ^= 1;
    s.images = fixtures.map(([name, b, width, height]) => ({ name, base64: b.toString('base64'), width, height }));
    s.selected = png(1, 1, s.max_bytes).toString('base64'); this.imageInputs = s;
  });
  When('I exercise native image evidence {string}', { timeout: 300000 }, function (mode) {
    if (!work) work = fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-native-images-'));
    if (!archive && mode !== 'validation') {
      const out = execute('/bin/sh', ['packaging/package.sh']); archive = out.split('\n').find(x => x.startsWith('/') && x.endsWith('.tar.gz')); assert.ok(archive && fs.existsSync(archive), out);
    }
    const dir = fs.mkdtempSync(path.join(work, 'case-'));
    try {
      const script = path.join(dir, 'native_image_test.exs'), input = path.join(dir, 'input.json'), receipt = path.join(dir, 'receipt.json');
      fs.writeFileSync(script, driver); fs.writeFileSync(input, JSON.stringify(this.imageInputs));
      const dirs = ['mix','erl','go','node','npm','python3'].map(n => path.dirname(execute('mise', ['which', n]).trim()));
      execute('mix', ['test', script], { env: { ...process.env, PATH: [...dirs, process.env.PATH].join(path.delimiter), ...(archive ? { KOGEN_ARCHIVE: archive } : {}), IMAGE_INPUT: input, IMAGE_MODE: mode, IMAGE_RECEIPT: receipt } });
      assert.ok(fs.existsSync(receipt)); this.imageObservations = qualify(JSON.parse(fs.readFileSync(receipt)), this.imageInputs);
      this.attach(JSON.stringify(this.imageObservations), 'application/json');
    } finally { fs.rmSync(dir, { recursive: true, force: true }); }
  });
  Then('the native image observations include:', function (json) {
    for (const [key, expected] of Object.entries(JSON.parse(json))) assert.deepEqual(this.imageObservations[key], expected, key + ': ' + JSON.stringify(this.imageObservations));
  });
  AfterAll(function () { if (work) fs.rmSync(work, { recursive: true, force: true }); });
}
