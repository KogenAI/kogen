const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const crypto = require('node:crypto');
const { spawn, spawnSync } = require('node:child_process');
const { When, Then, AfterAll } = require('@cucumber/cucumber');
const REPO = path.resolve(__dirname, '../..');
const sha = s => crypto.createHash('sha256').update(s).digest('hex');
const quote = s => "'" + s.replaceAll("'", "'\\''") + "'";
const env = { ...process.env, ERL_FLAGS: process.env.ERL_FLAGS || '+S 2:2 +SDcpu 1 +SDio 1' };
let adapterPromise, adapterRoot;
function run(program, args, opts = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(program, args, { ...opts, detached: true, stdio: ['pipe', 'pipe', 'pipe'] });
    let stdout = '', stderr = '';
    child.stdout.on('data', b => { stdout += b; }); child.stderr.on('data', b => { stderr += b; });
    child.stdin.on('error', e => { if (e.code !== 'EPIPE') reject(e); }); child.stdin.end(opts.input || '');
    const timer = setTimeout(() => { try { process.kill(-child.pid, 'SIGKILL'); } catch {} }, 90000);
    child.on('error', e => { clearTimeout(timer); reject(e); });
    child.on('close', code => { clearTimeout(timer); resolve({ code, stdout, stderr }); });
  });
}
async function adapter() {
  if (!adapterPromise) adapterPromise = (async () => {
    adapterRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'compact-native-adapter-'));
    const r = await run('mix', ['compile', '--warnings-as-errors'], { cwd: REPO, env });
    assert.equal(r.code, 0, r.stdout + r.stderr);
    for (const d of ['bin', 'lib/release/bin', 'lib/cucumber']) fs.mkdirSync(path.join(adapterRoot, d), { recursive: true });
    const g = await run('go', ['build', '-o', path.join(adapterRoot, 'bin/kogen'), '.'], { cwd: path.join(REPO, 'cli'), env });
    assert.equal(g.code, 0, g.stdout + g.stderr);
    const mix = spawnSync('/bin/sh', ['-c', 'command -v mix'], { encoding: 'utf8', env }).stdout.trim();
    assert.ok(path.isAbsolute(mix));
    // Locate fresh compiled source only. Main, CLI, bridge, tools and readiness are real.
    fs.writeFileSync(path.join(adapterRoot, 'lib/release/bin/kogen'), '#!/bin/sh\ncd ' + quote(REPO) + '\nexec ' + quote(mix) + " run --no-compile -e 'Kogen.Main.main()'\n", { mode: 0o755 });
    fs.writeFileSync(path.join(adapterRoot, 'node-path'), process.execPath + '\n');
    fs.symlinkSync(path.join(REPO, 'test/acceptance/node_modules'), path.join(adapterRoot, 'lib/cucumber/node_modules'));
    fs.symlinkSync(path.join(REPO, 'docs'), path.join(adapterRoot, 'docs'));
    return adapterRoot;
  })();
  return adapterPromise;
}
async function elixir(source) {
  const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'compact-render-driver-'));
  try {
    const file = path.join(scratch, 'driver.exs'); fs.writeFileSync(file, source);
    const r = await run('mix', ['run', file], { cwd: REPO, env });
    assert.equal(r.code, 0, r.stdout + r.stderr);
    const line = r.stdout.split('\n').find(s => s.startsWith('COMPACT_RESULT='));
    assert.ok(line, r.stdout + r.stderr); return JSON.parse(line.slice('COMPACT_RESULT='.length));
  } finally { fs.rmSync(scratch, { recursive: true, force: true }); }
}
const renderSetup = String.raw`
root = Kogen.tmp_path("compact-context-corpus")
File.mkdir_p!(Path.join(root, "features/steps"))
git = fn args -> {out, 0} = System.cmd("git", args, cd: root, stderr_to_stdout: true); String.trim(out) end
git.(["init", "-q"])
git.(["config", "user.name", "Context Fixture"])
git.(["config", "user.email", "context@example.invalid"])
git.(["config", "commit.gpgsign", "false"])
git.(["config", "core.hooksPath", "/dev/null"])
put = fn p, c -> f = Path.join(root, p); File.mkdir_p!(Path.dirname(f)); File.write!(f, c) end
put.(".gitignore", ".kogen/local/\n")
put.("README.md", "FULL_README_LITERAL\n" <> String.duplicate("this other only licence\n", 500))
put.("guard.txt", "PROTECTED_LITERAL\n")
for n <- 1..64 do
 put.("licences/notice-#{n}.txt", String.duplicate("this other only licence copyright permission\n", 220))
end
source = "features/steps/source.js"
original = "Then(\n  'the original literal is {string}',\n  function () {}\n);\nThen(/the regex [0-9]+/, function () {});\nORIGINAL_EXACT_LITERAL\n"
put.(source, "PROPOSED_DIFFERENT_LITERAL\n")
for n <- [199, 200, 201] do
 put.("features/steps/page-#{n}.js", Enum.map_join(1..n, "\n", fn i -> "Then('page #{n} signature #{i}', function () {});" end) <> "\n")
end
put.("image.bin", <<0, 255, 42>>)
put.(".kogen/intents/fixture/intent.md", "# Existing fixture\nAcceptance:\n- .kogen/intents/fixture/acceptance.feature\n- #{source}\n")
put.(".kogen/intents/fixture/acceptance.feature", "Feature: Existing\n Scenario: Existing\n  Then the original literal is x\n")
git.(["add", "."])
git.(["commit", "-qm", "corpus"])
config = %Kogen.Config{steps_dir: "features/steps", protect: ["guard.txt"]}
original_dir = Path.join(root, ".kogen/local/original")
put.(".kogen/local/original/" <> source, original)
request = String.duplicate("this other only licence copyright permission ", 100) <> source
ctx = %{root: root, tools: ~w(read_file list_files search_text), protected: []}
`;
When('I inspect the compact context corpus through the native renderer', { timeout: 120000 }, async function () {
  this.compact = await elixir(renderSetup + String.raw`
try do
 {text, index} = Kogen.ShapeContext.index(root, "fixture", config, request, %{source => original}, original_dir: original_dir)
 {again, _} = Kogen.ShapeContext.index(root, "fixture", config, request, %{source => original}, original_dir: original_dir)
 expected = git.(["ls-files", "-z"]) |> String.split(<<0>>, trim: true) |> Enum.sort()
 all = Enum.map(index.entries, & &1.path) == expected and Enum.all?(index.entries, fn e ->
  bytes = if e.path == source, do: original, else: File.read!(Path.join(root, e.path))
  e.sha256 == Kogen.ShapeContext.hash(bytes) and e.bytes == byte_size(bytes) and is_binary(e.ownership)
 end)
 entry = Enum.find(index.entries, &(&1.path == source))
 sigs = Enum.any?(entry.signatures, &(&1.text =~ "the original literal" and &1.start_line == 1 and &1.end_line == 2)) and Enum.any?(entry.signatures, &(&1.text =~ "the regex [0-9]+"))
 pages = Enum.all?([199, 200, 201], fn n ->
  e = Enum.find(index.entries, &(&1.path == "features/steps/page-#{n}.js"))
  if n <= 200 do
   length(e.signatures) == n and List.last(e.signatures).start_line == n
  else
   p = e.signature_index
   bytes = File.read!(p.source)
   lines = String.split(bytes, "\n", trim: true)
   p.count == n and length(lines) == n and p.sha256 == Kogen.ShapeContext.hash(bytes) and
    JSON.decode!(List.last(lines))["text"] =~ "signature 201" and
    Kogen.Tools.run("read_file", %{"path" => p.source, "start_line" => 201, "end_line" => 201}, ctx) =~ "signature 201"
  end
 end)
 exact = Kogen.Tools.run("read_file", %{"path" => Path.join(original_dir, source), "start_line" => 6, "end_line" => 6}, ctx) == "6\tORIGINAL_EXACT_LITERAL"
 discover = Kogen.Tools.run("list_files", %{"path" => "licences"}, ctx) =~ "licences/notice-64.txt" and Kogen.Tools.run("search_text", %{"pattern" => "page 201 signature 201", "path" => "features/steps"}, ctx) =~ "page-201.js:201:"
 measure = Process.get(:context_body_measurement)
 optional = measure.selection |> Enum.reject(&(&1.path == "README.md")) |> Enum.map(& &1.included_body_bytes) |> Enum.sum()
 evidence = Path.join(root, ".kogen/local/measure")
 Kogen.ShapeEvidence.start(evidence)
 input = [%{"role" => "user", "content" => text}]
 Kogen.ShapeContext.measure(input)
 events = File.read!(Path.join(evidence, "events.ndjson")) |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
 event = Enum.find(events, &(&1["event"] == "context_selection"))
 result = %{optional_excerpts: length(Regex.scan(~r/^Excerpt: /m, text)), optional_body_bytes: optional, all_paths_hashes_sizes: all, signature_integrity: sigs and pages, exact_original_range: exact, discovery_works: discover, deterministic: again == text, input_measurement_exact: event["supplied_input_bytes"] == byte_size(JSON.encode!(input))}
 IO.puts("COMPACT_RESULT=" <> JSON.encode!(result))
after
 File.rm_rf!(root)
end
`);
});
When('I render explicit compact context excerpts', { timeout: 120000 }, async function () {
  this.compact = await elixir(renderSetup + String.raw`
try do
 bytes = String.duplicate("// unrelated prefix\n", 101) <> "Then('needle exact', function () {});\n" <> String.duplicate("// trailing content\n", 100)
 put.("features/steps/window.js", bytes)
 {_, index} = Kogen.ShapeContext.index(root, "fixture", config, "needle")
 entry = Enum.find(index.entries, &(&1.path == "features/steps/window.js"))
 excerpt = Kogen.ShapeContext.excerpt(entry, bytes, ["needle"])
 [header, body] = String.split(excerpt, "\n", parts: 2)
 h = header |> String.replace_prefix("Excerpt: ", "") |> JSON.decode!()
 fields = Enum.sort(Map.keys(h))
 expected = bytes |> String.split("\n") |> Enum.drop(96) |> Enum.take(80) |> Enum.map_join("", &(&1 <> "\n"))
 result = %{header_keys: fields, excerpt_path: h["path"], start_line: h["start_line"], end_line: h["end_line"], body_lines: length(String.split(body, "\n", trim: true)), body_bound: byte_size(body) <= 8192, body_matches_source: body == expected, exact_hash: h["sha256"] == Kogen.ShapeContext.hash(bytes), shared_root_revision: Map.get(index, :root) == root and is_map(index.revision) and Enum.all?(index.entries, fn e -> not Map.has_key?(e, :revision) and (not Map.has_key?(e, :source) or e.path == source) end), no_repeated_entry_fields: not Enum.any?(~w(signatures ownership source revision bytes), &Map.has_key?(h, &1))}
 IO.puts("COMPACT_RESULT=" <> JSON.encode!(result))
after
 File.rm_rf!(root)
end
`);
});
function put(w, p, c) { const f = path.join(w.project, p); fs.mkdirSync(path.dirname(f), { recursive: true }); fs.writeFileSync(f, c); }
function git(w, args) {
  const r = spawnSync('git', args, { cwd: w.project, env: w.env, encoding: 'utf8' });
  assert.equal(r.status, 0, r.stdout + r.stderr); return r.stdout.trim();
}
function call(name, args, id) { return { type: 'function_call', id: 'i_' + id, call_id: 'c_' + id, name, arguments: JSON.stringify(args) }; }
function reply(res, items) {
  res.writeHead(200, { 'content-type': 'text/event-stream', connection: 'close' });
  items.forEach((item, i) => res.write('data: ' + JSON.stringify({ type: 'response.output_item.done', output_index: i, item }) + '\n\n'));
  res.end('data: ' + JSON.stringify({ type: 'response.completed', response: { usage: { input_tokens: 17, output_tokens: 3 } } }) + '\n\n');
}
function textOf(b) { return (b.input || []).map(i => i.content || i.output || '').filter(s => typeof s === 'string').join('\n'); }
function outputs(b) { return (b.input || []).filter(i => i.type === 'function_call_output'); }
const slug = 'compact-fixture', dir = '.kogen/intents/' + slug, steps = 'features/steps/compact_fixture.js';
const contractTail = '\nAUTHORITATIVE_END_LITERAL_031\n';
function files() {
  const intent = '# Preserve the exact note\n\nSlug: ' + slug + '\nModel: not applicable — a stateless note assertion\nAcceptance:\n- ' + dir + '/acceptance.feature\n- ' + steps + '\n\nKeep the exact literal second note.\n' + 'Authoritative this other only licence paragraph.\n'.repeat(220) + contractTail + '\n## Decisions\n- Keep the literal second note. (source: request)\n\n## Tests\n- Exact note: native note assertion (scenario)\n\n## Feasibility\n- none\n';
  return [
    { path: dir + '/intent.md', content: intent },
    { path: dir + '/acceptance.feature', content: 'Feature: Exact note\n Scenario: Literal note\n  Then the compact fixture note is "second note"\n' },
    { path: steps, content: "const {Then}=require('@cucumber/cucumber');\nconst fs=require('node:fs'),assert=require('node:assert/strict');\nThen('the compact fixture note is {string}', expected=>assert.equal(fs.readFileSync('notes.txt','utf8').trim(),expected));\n// ORIGINAL_STEP_EXACT\n" },
  ];
}
async function exercise(mode) {
  assert.ok(['shape', 'refine'].includes(mode));
  const install = await adapter();
  const workspace = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'compact-native-case-')));
  const w = { project: path.join(workspace, 'project'), env: { ...env, HOME: path.join(workspace, 'home'), TMPDIR: path.join(workspace, 'tmp'), GIT_CONFIG_GLOBAL: path.join(workspace, 'gitconfig'), GIT_CONFIG_NOSYSTEM: '1' } };
  for (const p of [w.project, w.env.HOME, w.env.TMPDIR]) fs.mkdirSync(p, { recursive: true });
  fs.writeFileSync(w.env.GIT_CONFIG_GLOBAL, '[user]\n name = Context Fixture\n email = context@example.invalid\n[commit]\n gpgsign = false\n[core]\n hooksPath = /dev/null\n');
  const invoke = (args, input) => run(path.join(install, 'bin/kogen'), args, { cwd: w.project, env: w.env, input });
  const originals = files();
  const corrected = originals[0].content.replace('# Preserve the exact note', '# Clarify the exact note');
  const pending = corrected.replace('- Keep the literal second note. (source: request)', '- Keep the literal second note.');
  const request = 'Keep this exact literal second note and src/named.txt; guard.txt must stay protected.\n' + 'this other only licence permission copyright\n'.repeat(230) + 'REQUEST_END_LITERAL_031';
  const answer = 'SETTLED_ANSWER_EXACT_031';
  const readme = '# Native context fixture\n' + 'Readme authoritative licence only other this\n'.repeat(230) + 'README_END_LITERAL_031\n';
  const records = [], wire = [], errors = []; let phase = 0, active = 0, maximum = 0;
  let server;
  try {
    git(w, ['init', '-q', '--initial-branch', 'main']);
    put(w, '.gitignore', '.kogen/local/\n'); put(w, 'README.md', readme); put(w, 'notes.txt', 'first note\n'); put(w, 'guard.txt', 'GUARD_EXACT_031\n');
    put(w, 'src/named.txt', 'this other only licence\nEXPLICIT_RANGE_EXACT_031\n');
    for (let i = 0; i < 24; i++) put(w, 'licences/text-' + i + '.txt', ('this other only licence permission copyright\n').repeat(240));
    const config = 'version: 1\ncommands:\n  setup: []\n  fix: []\n  checks: []\n  acceptance:\n    run: \'NODE_PATH="$KOGEN_CUCUMBER" "$KOGEN_NODE" "$KOGEN_CUCUMBER/@cucumber/cucumber/bin/cucumber.js" --strict --require "features/steps/*.js" --format "message:$KOGEN_ACCEPTANCE_REPORT" "$KOGEN_ACCEPTANCE_FEATURES"\'\n    steps_dir: features/steps\nprotect: [guard.txt]\nmodels:\n  shape: {model: gpt-6.1-sol, effort: high}\n';
    put(w, '.kogen/project.yaml', config);
    git(w, ['add', '-A']); git(w, ['commit', '-qm', 'native fixture']);
    fs.mkdirSync(path.join(w.env.HOME, '.kogen/credentials'), { recursive: true });
    fs.writeFileSync(path.join(w.env.HOME, '.kogen/credentials/chatgpt.json'), JSON.stringify({ client_id: 'oaiapp_test', access_token: 'compact-fixture-token', refresh_token: 'compact-fixture-refresh', expires_at: Math.floor(Date.now() / 1000) + 3600 }));
    let hash;
    if (mode === 'refine') {
      for (const f of originals) put(w, f.path, f.content);
      const card = await invoke(['intent', 'approve', slug]);
      assert.equal(card.code, 5, card.stdout + card.stderr);
      hash = card.stdout.match(/^SHA-256: ([0-9a-f]{64})$/m)?.[1]; assert.ok(hash, card.stdout + card.stderr);
    }
    const head = git(w, ['rev-parse', 'HEAD']);
    const indexPath = git(w, ['rev-parse', '--path-format=absolute', '--git-path', 'index']);
    const beforeIndex = fs.readFileSync(indexPath);
    server = http.createServer((req, res) => {
      const chunks = []; req.on('data', b => chunks.push(b));
      req.on('end', () => {
        active++; maximum = Math.max(maximum, active); res.on('finish', () => active--);
        try {
          assert.equal(req.url, '/v1/responses');
          const raw = Buffer.concat(chunks); const b = JSON.parse(raw.toString('utf8')); wire.push(raw); records.push(b);
          assert.ok(records.length <= 7, 'unexpected provider continuation');
          if (mode === 'shape') {
            if (phase++ === 0) return reply(res, [call('submit', { questions: [{ question: 'Which exact fixture wording?' }] }, 'question')]);
            if (phase === 2) return reply(res, [call('read_file', { path: 'src/named.txt', start_line: 2, end_line: 2 }, 'range')]);
            return reply(res, [call('submit', { files: originals }, 'package')]);
          }
          if (phase++ === 0) return reply(res, [call('read_file', { path: 'src/named.txt', start_line: 2, end_line: 2 }, 'range'), call('read_file', { path: steps, start_line: 4, end_line: 4 }, 'original_step')]);
          if (phase === 2) return reply(res, [call('submit_refinement', { files: [{ path: originals[0].path, content: pending }] }, 'invalid')]);
          if (phase === 3) {
            const manifests = b.input.filter(i => typeof i.content === 'string' && i.content.startsWith('Cumulative proposal/original manifest: '));
            const manifest = JSON.parse(manifests.at(-1).content.split('manifest: ')[1]);
            const m = manifest.find(m => m.path === originals[0].path); assert.ok(m?.proposed?.source && m.source);
            return reply(res, [call('read_file', { path: m.source }, 'original_contract'), call('read_file', { path: m.proposed.source }, 'proposed_contract')]);
          }
          return reply(res, [call('submit_refinement', { files: [{ path: originals[0].path, content: corrected }] }, 'correct')]);
        } catch (e) {
          errors.push(e.stack); reply(res, [call(mode === 'shape' ? 'submit' : 'submit_refinement', mode === 'shape' ? { questions: [{ question: 'Harness failed' }] } : { constraint: 'Harness failed' }, 'stop')]);
        }
      });
    });
    await new Promise(r => server.listen(0, '127.0.0.1', r));
    w.env.KOGEN_PROVIDER_URL = 'http://127.0.0.1:' + server.address().port;
    let result;
    if (mode === 'shape') {
      const question = await invoke(['intent', 'shape', slug, '-'], request);
      assert.equal(question.code, 5, question.stdout + question.stderr);
      result = await invoke(['intent', 'shape', slug, '-'], '1: ' + answer);
    } else result = await invoke(['intent', 'refine', slug, hash, '-'], request);
    assert.deepEqual(errors, [], errors.join('\n'));
    const initial = textOf(records[mode === 'shape' ? 1 : 0]);
    const ix = JSON.parse(initial.match(/^Context index: (.+)$/m)?.[1] || 'null'); assert.ok(ix, initial.slice(-2000));
    const eventsFile = mode === 'shape' ? path.join(w.project, '.kogen/local/shaping/' + slug + '/events.ndjson') : fs.readdirSync(path.join(w.project, '.kogen/local/refinements')).map(n => path.join(w.project, '.kogen/local/refinements', n, 'events.ndjson')).find(f => fs.existsSync(f));
    const events = fs.readFileSync(eventsFile, 'utf8').split('\n').filter(Boolean).map(s => JSON.parse(s));
    const selections = events.filter(e => e.event === 'context_selection');
    const optional = selections.flatMap(e => e.selection || []).filter(e => !['README.md', ...originals.filter(f => f.path.startsWith(dir + '/')).map(f => f.path)].includes(e.path));
    const toolOutputs = records.flatMap(outputs);
    const originalResult = toolOutputs.find(i => i.call_id === 'c_original_contract');
    const proposedResult = toolOutputs.find(i => i.call_id === 'c_proposed_contract');
    const numbered = s => s.replace(/\n$/, '').split('\n').map((l, i) => (i + 1) + '\t' + l).join('\n');
    const laterManifestItems = records.flatMap(b => b.input).filter(i => typeof i.content === 'string' && i.content.startsWith('Cumulative proposal/original manifest: '));
    const manifests = laterManifestItems.flatMap(i => JSON.parse(i.content.split('manifest: ')[1]));
    const proposal = manifests.find(m => m.path === originals[0].path && m.proposed?.sha256 === sha(pending));
    const exactBoth = !!originalResult && !!proposedResult && originalResult.output === numbered(originals[0].content) && proposedResult.output === numbered(pending) && !!proposal && proposal.sha256 === sha(originals[0].content);
    const testing = fs.readFileSync(path.join(REPO, 'docs/testing-rules.md'), 'utf8');
    const full = initial.includes(request) && initial.includes(readme) && initial.includes(testing) && initial.includes('guard.txt') && initial.includes('automatic') === (mode === 'shape') && initial.includes('KOGEN_ACCEPTANCE_REPORT') && (mode === 'shape' ? initial.includes(answer) && initial.includes('Approval freezes this baseline') : initial.includes(originals[0].content) && initial.includes(originals[1].content));
    const nativeReady = result.code === 0 && fs.existsSync(path.join(w.project, '.kogen/local/readiness/' + slug + '.json')) && (mode === 'shape' ? result.stdout.includes('Scenarios: 1 (1 fail now') : result.stdout.includes('refined ' + slug) && fs.readFileSync(path.join(w.project, originals[0].path), 'utf8') === corrected);
    return {
      exit_code: result.code,
      optional_excerpts: (initial.match(/^Excerpt: /gm) || []).length,
      optional_body_bytes: optional.reduce((a, e) => a + e.included_body_bytes, 0),
      shared_root_revision: ix.root === w.project && !!ix.revision && ix.entries.every(e => !e.revision && (!e.source || (mode === 'refine' && e.source.includes('/original/')))),
      mandatory_exact: full,
      exact_tool_range: toolOutputs.some(i => i.call_id === 'c_range' && i.output === '2\tEXPLICIT_RANGE_EXACT_031') && (mode === 'shape' || toolOutputs.some(i => i.call_id === 'c_original_step' && i.output === '4\t// ORIGINAL_STEP_EXACT')),
      original_proposed_exact: exactBoth,
      default_sequential: maximum === 1 && records.every(b => !(b.tools || []).some(t => t.name === 'shape_batch')),
      native_readiness: nativeReady,
      no_approval: !fs.existsSync(path.join(w.project, '.kogen/local/approvals/' + slug + '.json')),
      head_index_unchanged: git(w, ['rev-parse', 'HEAD']) === head && fs.readFileSync(indexPath).equals(beforeIndex),
      serialized_bytes_captured: wire.length === records.length && wire.every((b, i) => b.length > Buffer.byteLength(JSON.stringify(records[i].input)) && JSON.parse(b).input.length > 0),
    };
  } finally {
    if (server) await new Promise(r => server.close(r));
    fs.rmSync(workspace, { recursive: true, force: true });
  }
}
When('I exercise compact context through native {string}', { timeout: 180000 }, async function (mode) { this.compact = await exercise(mode); });
Then('the compact context observations are:', function (table) {
  assert.ok(this.compact);
  for (const [key, text] of table.raw()) {
    let value; try { value = JSON.parse(text); } catch { value = text; }
    assert.deepEqual(this.compact[key], value, key + ': ' + JSON.stringify(this.compact));
  }
});
AfterAll(function () { if (adapterRoot) fs.rmSync(adapterRoot, { recursive: true, force: true }); });
