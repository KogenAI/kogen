const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');
const { When, Then } = require('@cucumber/cucumber');
const H = require('./go_driver_support.js');
const REPO = H.ROOT;
const sha = s => crypto.createHash('sha256').update(s).digest('hex');
function run(program, args, opts = {}) {
  return H.run(program, args, { cwd: opts.cwd, env: opts.env, input: opts.input === undefined ? '' : opts.input, timeout: 90000 }).then(r => ({ code: r.code, stdout: r.out, stderr: '' }));
}

// The renderer scenarios call Kogen's own context packages (the index, its excerpts and the exact-range tools) from a tiny Go
// program; the scenarios that shape and refine drive the installed `kogen` with a scripted local provider.
const rendererSource = String.raw`package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"

	"kogen-loop/tools"
	"kogen/git"
	"kogen/project"
	"kogen/shape"
)

func must(err error) {
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

type input struct {
	Mode        string
	Root        string
	Source      string
	Original    string
	OriginalDir string
	Request     string
	Bytes       string
}

func main() {
	var in input
	must(json.NewDecoder(os.Stdin).Decode(&in))
	repo, err := git.Open(in.Root, os.Environ())
	must(err)
	cfg := &project.Config{Acceptance: &project.Acceptance{StepsDir: "features/steps"}, Protect: []string{"guard.txt"}}
	out := map[string]any{}
	switch in.Mode {
	case "corpus":
		originals := map[string][]byte{in.Source: []byte(in.Original)}
		opts := shape.ContextOptions{OriginalDir: in.OriginalDir}
		text, index, err := shape.BuildContextIndex(repo, cfg, "fixture", originals, opts)
		must(err)
		again, _, err := shape.BuildContextIndex(repo, cfg, "fixture", originals, opts)
		must(err)
		out["text"], out["deterministic"] = text, text == again
		var entries []any
		for _, e := range index.Entries {
			var sigs []any
			for _, s := range e.Signatures {
				sigs = append(sigs, map[string]any{"text": s.Text, "start_line": s.StartLine, "end_line": s.EndLine})
			}
			m := map[string]any{"path": e.Path, "sha256": e.SHA256, "bytes": e.Bytes, "ownership": e.Ownership, "signatures": sigs}
			if e.SignatureIndex != nil {
				m["signature_index"] = map[string]any{"count": e.SignatureIndex.Count, "source": e.SignatureIndex.Source, "sha256": e.SignatureIndex.SHA256}
			}
			entries = append(entries, m)
		}
		out["entries"] = entries
		var selection []any
		for _, s := range index.Measure.Selection {
			selection = append(selection, map[string]any{"path": s.Path, "included_body_bytes": s.IncludedBodyBytes})
		}
		out["selection"] = selection
		tl := &tools.Tools{Root: in.Root, Enabled: []string{"read_file", "list_files", "search_text"}}
		run := func(name string, args map[string]any) string {
			o, err := tl.Run(name, args)
			must(err)
			return o.Text
		}
		results := map[string]any{}
		for _, e := range index.Entries {
			if e.SignatureIndex != nil {
				results["signature_page:"+e.Path] = run("read_file", map[string]any{"path": e.SignatureIndex.Source, "start_line": 201, "end_line": 201})
			}
		}
		results["original_range"] = run("read_file", map[string]any{"path": filepath.Join(in.OriginalDir, in.Source), "start_line": 6, "end_line": 6})
		results["list_licences"] = run("list_files", map[string]any{"path": "licences"})
		results["search_signature"] = run("search_text", map[string]any{"pattern": "page 201 signature 201", "path": "features/steps"})
		out["tools"] = results
	case "excerpt":
		_, index, err := shape.BuildContextIndex(repo, cfg, "fixture", map[string][]byte{}, shape.ContextOptions{})
		must(err)
		for _, e := range index.Entries {
			if e.Path == "features/steps/window.js" {
				out["excerpt"] = shape.ExcerptOf(e, in.Bytes, []string{"needle"})
			}
		}
		rev, _ := json.Marshal(index.Revision.Map())
		var revision any
		json.Unmarshal(rev, &revision)
		out["root_ok"], out["revision"] = index.Root == in.Root, revision
		var shared []any
		for _, e := range index.Entries {
			shared = append(shared, map[string]any{"path": e.Path, "source": e.Source})
		}
		out["entries"] = shared
	}
	b, err := json.Marshal(out)
	must(err)
	fmt.Println(string(b))
}
`;

// A corpus repository with the same files the renderer is asked about (outside any Kogen project).
function corpus(root) {
  const git = args => { const r = spawnSync('git', args, { cwd: root, encoding: 'utf8' }); assert.equal(r.status, 0, r.stdout + r.stderr); return r.stdout.trim(); };
  const put = (p, c) => { const f = path.join(root, p); fs.mkdirSync(path.dirname(f), { recursive: true }); fs.writeFileSync(f, c); };
  fs.mkdirSync(path.join(root, 'features/steps'), { recursive: true });
  git(['init', '-q']);
  for (const kv of [['user.name', 'Context Fixture'], ['user.email', 'context@example.invalid'], ['commit.gpgsign', 'false'], ['core.hooksPath', '/dev/null']]) git(['config', ...kv]);
  put('.gitignore', '.kogen/local/\n');
  put('README.md', `FULL_README_LITERAL\n${'this other only licence\n'.repeat(500)}`);
  put('guard.txt', 'PROTECTED_LITERAL\n');
  for (let n = 1; n <= 64; n++) put(`licences/notice-${n}.txt`, 'this other only licence copyright permission\n'.repeat(220));
  const source = 'features/steps/source.js';
  const original = "Then(\n  'the original literal is {string}',\n  function () {}\n);\nThen(/the regex [0-9]+/, function () {});\nORIGINAL_EXACT_LITERAL\n";
  put(source, 'PROPOSED_DIFFERENT_LITERAL\n');
  for (const n of [199, 200, 201]) put(`features/steps/page-${n}.js`, `${Array.from({ length: n }, (_, i) => `Then('page ${n} signature ${i + 1}', function () {});`).join('\n')}\n`);
  fs.writeFileSync(path.join(root, 'image.bin'), Buffer.from([0, 255, 42]));
  put('.kogen/intents/fixture/intent.md', `# Existing fixture\nAcceptance:\n- .kogen/intents/fixture/acceptance.feature\n- ${source}\n`);
  put('.kogen/intents/fixture/acceptance.feature', 'Feature: Existing\n Scenario: Existing\n  Then the original literal is x\n');
  git(['add', '.']); git(['commit', '-qm', 'corpus']);
  const originalDir = path.join(root, '.kogen/local/original');
  put(`.kogen/local/original/${source}`, original);
  return { git, put, source, original, originalDir, request: `${'this other only licence copyright permission '.repeat(100)}${source}` };
}
async function renderer(input) {
  const driver = await H.goDriver('compact-context', rendererSource);
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'compact-context-corpus-')));
  try {
    const c = corpus(root);
    const out = await driver([], { input: JSON.stringify({ Root: root, Source: c.source, Original: c.original, OriginalDir: c.originalDir, Request: c.request, ...input(c) }) });
    assert.equal(out.code, 0, out.out);
    return { c, root, result: JSON.parse(out.out) };
  } catch (e) { fs.rmSync(root, { recursive: true, force: true }); throw e; }
}
// The size of the conversation input as supplied to a shaping request: the wire adds cache breakpoints to the typed text
// blocks and carries the policy as a developer message, so the supplied input is the conversation items without those.
const sortKeys = x => Array.isArray(x) ? x.map(sortKeys) : x && typeof x === 'object' ? Object.fromEntries(Object.keys(x).sort().map(k => [k, sortKeys(x[k])])) : x;
const suppliedBytes = body => Buffer.byteLength(JSON.stringify(sortKeys((body.input || []).filter(i => i.role !== 'developer').map(i => Array.isArray(i.content) ? { ...i, content: i.content.map(({ prompt_cache_breakpoint, ...block }) => block) } : i))));
async function measuredNatively() {
  const suite = await H.setupSuite(); let c;
  try {
    c = await H.project(suite, [], { stagedIntent: false });
    const request = path.join(c.root, 'request.txt'); fs.writeFileSync(request, 'Measure the supplied input exactly.');
    c.server.setScript([]); const before = c.server.providerRequests().length;
    await H.runKogen(c, ['intent', 'shape', 'measure-fixture', request]);
    const bodies = c.server.providerRequests().slice(before).map(r => r.json);
    const events = H.listFiles(path.join(c.repo, '.kogen/local/shaping')).filter(f => f.endsWith('events.ndjson')).flatMap(f => fs.readFileSync(f, 'utf8').split('\n').filter(Boolean).map(l => JSON.parse(l)));
    const selections = events.filter(e => e.event === 'context_selection');
    return bodies.length > 0 && selections.length > 0 && selections[0].supplied_input_bytes === suppliedBytes(bodies[0]);
  } finally { await H.cleanupCase(c); H.cleanupSuite(suite); }
}
When('I inspect the compact context corpus through the native renderer', { timeout: 300000 }, async function () {
  const { c, root, result: r } = await renderer(() => ({ Mode: 'corpus' }));
  try {
    const { source, original } = c;
    const entries = r.entries;
    const expected = c.git(['ls-files', '-z']).split('\0').filter(Boolean).sort();
    const bytesOf = e => e.path === source ? Buffer.from(original) : fs.readFileSync(path.join(root, e.path));
    const all = JSON.stringify(entries.map(e => e.path)) === JSON.stringify(expected) && entries.every(e => { const b = bytesOf(e); return e.sha256 === sha(b) && e.bytes === b.length && typeof e.ownership === 'string'; });
    const entry = entries.find(e => e.path === source);
    const sigs = entry.signatures.some(x => x.text.includes('the original literal') && x.start_line === 1 && x.end_line === 2) && entry.signatures.some(x => x.text.includes('the regex [0-9]+'));
    const pages = [199, 200, 201].every(n => {
      const e = entries.find(x => x.path === `features/steps/page-${n}.js`);
      if (n <= 200) return e.signatures.length === n && e.signatures.at(-1).start_line === n;
      const p = e.signature_index, bytes = fs.readFileSync(p.source, 'utf8'), lines = bytes.split('\n').filter(Boolean);
      return p.count === n && lines.length === n && p.sha256 === sha(bytes) && JSON.parse(lines.at(-1)).text.includes('signature 201') && r.tools[`signature_page:${e.path}`].includes('signature 201');
    });
    const exact = r.tools.original_range === '6\tORIGINAL_EXACT_LITERAL';
    const discover = r.tools.list_licences.includes('licences/notice-64.txt') && r.tools.search_signature.includes('page-201.js:201:');
    const optional = r.selection.filter(x => x.path !== 'README.md').reduce((a, x) => a + x.included_body_bytes, 0);
    this.compact = { optional_excerpts: (r.text.match(/^Excerpt: /gm) || []).length, optional_body_bytes: optional, all_paths_hashes_sizes: all, signature_integrity: sigs && pages, exact_original_range: exact, discovery_works: discover, deterministic: r.deterministic, input_measurement_exact: await measuredNatively() };
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});
When('I render explicit compact context excerpts', { timeout: 300000 }, async function () {
  const bytes = `${'// unrelated prefix\n'.repeat(101)}Then('needle exact', function () {});\n${'// trailing content\n'.repeat(100)}`;
  const { c, root, result: r } = await (async () => {
    const driver = await H.goDriver('compact-context', rendererSource);
    const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'compact-context-corpus-')));
    try {
      const c = corpus(root); c.put('features/steps/window.js', bytes);
      const out = await driver([], { input: JSON.stringify({ Mode: 'excerpt', Root: root, Bytes: bytes }) });
      assert.equal(out.code, 0, out.out);
      return { c, root, result: JSON.parse(out.out) };
    } catch (e) { fs.rmSync(root, { recursive: true, force: true }); throw e; }
  })();
  try {
    const [header, body] = [r.excerpt.slice(0, r.excerpt.indexOf('\n')), r.excerpt.slice(r.excerpt.indexOf('\n') + 1)];
    const h = JSON.parse(header.replace(/^Excerpt: /, ''));
    const expected = bytes.split('\n').slice(96, 176).map(l => `${l}\n`).join('');
    this.compact = {
      header_keys: Object.keys(h).sort(), excerpt_path: h.path, start_line: h.start_line, end_line: h.end_line,
      body_lines: body.split('\n').filter(Boolean).length, body_bound: Buffer.byteLength(body) <= 8192, body_matches_source: body === expected,
      exact_hash: h.sha256 === sha(bytes),
      shared_root_revision: r.root_ok === true && r.revision !== null && typeof r.revision === 'object' && r.entries.every(e => !e.source || e.path === c.source),
      no_repeated_entry_fields: !['signatures', 'ownership', 'source', 'revision', 'bytes'].some(k => k in h),
    };
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
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
function textOf(b) { return (b.input || []).map(i => Array.isArray(i.content) ? i.content.map(block => block.text || '').join('') : i.content || i.output || '').filter(s => typeof s === 'string').join('\n'); }
function outputs(b) { return (b.input || []).filter(i => i.type === 'function_call_output'); }
const slug = 'compact-fixture', dir = '.kogen/intents/' + slug, steps = 'features/steps/compact_fixture.js';
const contractTail = '\nAUTHORITATIVE_END_LITERAL_031\n';
function files() {
  const intent = '# Preserve the exact note\n\nSlug: ' + slug + '\nModel: not applicable — a stateless note assertion\nAcceptance:\n- ' + dir + '/acceptance.feature\n- ' + steps + '\n\nKeep the exact literal second note.\n' + 'Authoritative this other only licence paragraph.\n'.repeat(220) + contractTail + '\n## Decisions\n- Keep the literal second note. (source: request)\n\n## Tests\n- Exact note: native note assertion (scenario)\n\n## Source comparison\n- addressed: exact second note from request.\n\n## Feasibility\n- none\n';
  return [
    { path: dir + '/intent.md', content: intent },
    { path: dir + '/acceptance.feature', content: 'Feature: Exact note\n Scenario: Literal note\n  Then the compact fixture note is "second note"\n' },
    { path: steps, content: "const {Then}=require('@cucumber/cucumber');\nconst fs=require('node:fs'),assert=require('node:assert/strict');\nThen('the compact fixture note is {string}', expected=>assert.equal(fs.readFileSync('notes.txt','utf8').trim(),expected));\n// ORIGINAL_STEP_EXACT\n" },
  ];
}
async function exercise(mode) {
  assert.ok(['shape', 'refine'].includes(mode));
  const suite = await H.setupSuite();
  const workspace = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'compact-native-case-')));
  const w = { project: path.join(workspace, 'project'), env: { ...process.env, HOME: path.join(workspace, 'home'), TMPDIR: path.join(workspace, 'tmp'), GIT_CONFIG_GLOBAL: path.join(workspace, 'gitconfig'), GIT_CONFIG_NOSYSTEM: '1' } };
  for (const p of [w.project, w.env.HOME, w.env.TMPDIR]) fs.mkdirSync(p, { recursive: true });
  fs.writeFileSync(w.env.GIT_CONFIG_GLOBAL, '[user]\n name = Context Fixture\n email = context@example.invalid\n[commit]\n gpgsign = false\n[core]\n hooksPath = /dev/null\n');
  const invoke = async (args, input) => { const r = await run(suite.release, args, { cwd: w.project, env: w.env, input }); return r; };
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
    assert.equal(result.code, 0, result.stdout + result.stderr);
    const initial = textOf(records[mode === 'shape' ? 1 : 0]);
    const ix = JSON.parse(initial.match(/^Context navigation: (.+)$/m)?.[1] || 'null'); assert.ok(ix, initial.slice(-2000));
    const eventsFile = mode === 'shape' ? path.join(w.project, '.kogen/local/shaping/' + slug + '/events.ndjson') : fs.readdirSync(path.join(w.project, '.kogen/local/refinements')).map(n => path.join(w.project, '.kogen/local/refinements', n, 'events.ndjson')).find(f => fs.existsSync(f));
    const events = fs.readFileSync(eventsFile, 'utf8').split('\n').filter(Boolean).map(s => JSON.parse(s));
    const selections = events.filter(e => e.event === 'context_selection');
    const optional = selections.flatMap(e => e.selection || []).filter(e => !['README.md', ...originals.map(f => f.path)].includes(e.path));
    const toolOutputs = records.flatMap(outputs);
    const originalResult = toolOutputs.find(i => i.call_id === 'c_original_contract');
    const proposedResult = toolOutputs.find(i => i.call_id === 'c_proposed_contract');
    const numbered = s => s.replace(/\n$/, '').split('\n').map((l, i) => (i + 1) + '\t' + l).join('\n');
    const laterManifestItems = records.flatMap(b => b.input).filter(i => typeof i.content === 'string' && i.content.startsWith('Cumulative proposal/original manifest: '));
    const manifests = laterManifestItems.flatMap(i => JSON.parse(i.content.split('manifest: ')[1]));
    const proposal = manifests.find(m => m.path === originals[0].path && m.proposed?.sha256 === sha(pending));
    const exactBoth = !!originalResult && !!proposedResult && originalResult.output === numbered(originals[0].content) && proposedResult.output === numbered(pending) && !!proposal && proposal.sha256 === sha(originals[0].content);
    const testing = fs.readFileSync(path.join(REPO, 'docs/testing-rules.md'), 'utf8');
    const full = initial.includes(request) && initial.includes(readme) && initial.includes(testing) && initial.includes('guard.txt') && (mode !== 'shape' || initial.includes('automatic')) && initial.includes('KOGEN_ACCEPTANCE_REPORT') && (mode === 'shape' ? initial.includes(answer) && initial.includes('Approval freezes this baseline') : initial.includes(originals[0].content) && initial.includes(originals[1].content));
    const nativeReady = result.code === 0 && fs.existsSync(path.join(w.project, '.kogen/local/readiness/' + slug + '.json')) && (mode === 'shape' ? result.stdout.includes('Scenarios: 1 (1 fail now') : result.stdout.includes('refined ' + slug) && fs.readFileSync(path.join(w.project, originals[0].path), 'utf8') === corrected);
    return {
      exit_code: result.code,
      optional_excerpts: (initial.match(/^Excerpt: /gm) || []).length,
      optional_body_bytes: optional.reduce((a, e) => a + e.included_body_bytes, 0),
      shared_root_revision: ix.root === w.project && !!ix.revision && JSON.stringify(Object.keys(ix).sort()) === JSON.stringify(['retrieval', 'revision', 'root']) && ix.retrieval === 'read_file exact bytes and line ranges; list_files directories; search_text exact signatures',
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
    H.cleanupSuite(suite);
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
