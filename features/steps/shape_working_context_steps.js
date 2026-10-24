const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const zlib = require('node:zlib');
const H = require('./go_driver_support.js');
const { fn: f } = H;
const equal = (a, b) => { try { assert.deepEqual(a, b); return true; } catch { return false; } };
function replayCustody(d) {
  if (!d || !d.windows.length || !d.groups.length || !d.files.length) return false;
  for (const w of d.windows) {
    const pending = new Set();
    for (const i of w) {
      if (i.type === 'function_call') { if (pending.has(i.call_id)) return false; pending.add(i.call_id); }
      if (i.type === 'function_call_output' && !pending.delete(i.call_id)) return false;
    }
    if (pending.size) return false;
  }
  const firstSeen = [];
  for (const w of d.windows) for (const i of w) if (i.type === 'function_call' && !firstSeen.includes(i.call_id)) firstSeen.push(i.call_id);
  const ordered = d.groups.flatMap(g => g.filter(i => i.type === 'function_call').map(i => i.call_id));
  const observed = firstSeen.filter(id => ordered.includes(id));
  if (!equal(observed, ordered)) return false;
  return d.groups.every(g => d.windows.some(w => w.some((_, n) => equal(w.slice(n, n + g.length), g)))) && d.files.every(f => f.mode === 384 && f.dir_mode === 448 && crypto.createHash('sha256').update(Buffer.from(f.bytes, 'base64')).digest('hex') === f.sha256);
}

// ------------------------------------------------------------------ independent oracles (the specification, not the engine)

// The model-facing result bound: at most 16384 bytes, a 4096-byte valid prefix, an exact omitted-byte marker, a valid suffix.
const validUtf8 = b => { try { new TextDecoder('utf-8', { fatal: true }).decode(b); return true; } catch { return false; } };
function cutText(text) {
  const all = Buffer.from(text, 'utf8');
  if (all.length <= 16384) return text;
  const marker = n => `\n[... ${n} bytes omitted ...]\n`;
  let head = all.subarray(0, 4096); while (!validUtf8(head)) head = head.subarray(0, head.length - 1);
  const tailSize = 12288 - Buffer.byteLength(marker(all.length));
  let tail = all.subarray(all.length - tailSize); while (!validUtf8(tail)) tail = tail.subarray(1);
  return head.toString('utf8') + marker(all.length - head.length - tail.length) + tail.toString('utf8');
}
// read_file output: one-based numbered lines, a trailing newline not counted as a line.
function numbered(text, from, to) {
  let lines = text.split('\n'); if (lines[lines.length - 1] === '') lines = lines.slice(0, -1);
  from = Number.isInteger(from) && from > 0 ? from : 1; to = Number.isInteger(to) && to >= from ? to : lines.length;
  return lines.map((l, i) => [l, i + 1]).filter(([, i]) => i >= from && i <= to).map(([l, i]) => `${i}\t${l}`).join('\n');
}
const sha256 = b => crypto.createHash('sha256').update(b).digest('hex');
const crcTable = Array.from({ length: 256 }, (_, n) => { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; return c >>> 0; });
const crc32 = b => { let c = 0xffffffff; for (const x of b) c = crcTable[(c ^ x) & 0xff] ^ (c >>> 8); return (c ^ 0xffffffff) >>> 0; };
function png() {
  const chunk = (type, body) => { const len = Buffer.alloc(4); len.writeUInt32BE(body.length); const t = Buffer.from(type); const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(Buffer.concat([t, body]))); return Buffer.concat([len, t, body, crc]); };
  const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(1, 0); ihdr.writeUInt32BE(1, 4); ihdr[8] = 8; ihdr[9] = 2;
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', ihdr), chunk('IDAT', zlib.deflateSync(Buffer.from([0, 10, 20, 30]))), chunk('IEND', Buffer.alloc(0))]);
}

// The observer's own known-good sample, built from files on disk and the replay oracle (no engine involved).
function controlSample() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'shape-window-control-'));
  try {
    fs.chmodSync(root, 0o700);
    fs.writeFileSync(path.join(root, 'literal.txt'), '  Δ\u{1F642}\r\n/path with spaces/診断.txt\n  ');
    const literal = fs.readFileSync(path.join(root, 'literal.txt'), 'utf8');
    const calls = [1, 2].map(n => ({ type: 'function_call', id: `fc${n}`, call_id: `c${n}`, name: 'read_file', arguments: JSON.stringify({ path: 'literal.txt' }) }));
    const rs = { type: 'reasoning', id: 'r', encrypted_content: 'opaque+/==\nΔ', summary: [] };
    const msg = { type: 'message', id: 'm', role: 'assistant', phase: 'commentary', content: [{ type: 'output_text', text: 'Unfinished fixture observation' }] };
    const group = [...[rs, msg, ...calls].map(H.replayItem), ...calls.map(c => H.outputItem(c, cutText(numbered(literal))))];
    const bytes = JSON.stringify({ input: group }) + '\n';
    const p = path.join(root, 'archive.json'); fs.writeFileSync(p, bytes); fs.chmodSync(p, 0o600);
    return { windows: [JSON.parse(fs.readFileSync(p, 'utf8')).input], groups: [group], files: [{ mode: fs.statSync(p).mode & 0o777, dir_mode: fs.statSync(root).mode & 0o777, bytes: fs.readFileSync(p).toString('base64'), sha256: sha256(bytes) }] };
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
}
if (require.main === module && process.argv[2] === '--control') {
  try {
    const good = controlSample(); assert.equal(replayCustody(good), true);
    if (process.argv[3] === 'good') process.stdout.write('accepted\n');
    else if (process.argv[3] === 'bad') {
      for (const mutate of [d => d.windows[0].pop(), d => d.windows[0][0].encrypted_content += 'changed', d => d.windows[0][1].phase = 'final', d => d.windows[0][2].arguments += ' ', d => d.windows[0].reverse(), d => d.files[0].bytes += 'eA==', d => d.files[0].mode = 420, d => d.files[0].dir_mode = 493]) {
        const bad = structuredClone(good); mutate(bad); assert.equal(replayCustody(bad), false, 'counterexample accepted');
      }
      process.stdout.write('rejected\n'); process.exitCode = 1;
    } else throw new Error('unknown control');
  } catch (e) { process.stderr.write(String(e) + '\n'); process.exitCode = 2; }
} else {
  const { Given, When, Then } = require('@cucumber/cucumber');
  const lines = p => fs.existsSync(p) ? fs.readFileSync(p, 'utf8').split('\n').filter(Boolean).map(l => JSON.parse(l)) : [];
  const mode0 = p => fs.statSync(p).mode & 0o777;
  const same = (a, b) => { try { assert.deepEqual(a, b); return true; } catch { return false; } };
  const shapeRequests = c => c.server.providerRequests().filter(r => (r.json.tools || []).some(t => t.name === 'submit'));
  const put = (c, p, b) => { const full = path.join(c.repo, p); fs.mkdirSync(path.dirname(full), { recursive: true }); fs.writeFileSync(full, b); };
  const items = (n, inspect) => {
    const calls = [1, 2].map(j => ({ type: 'function_call', id: `fc-${n}-${j}`, call_id: `call-${n}-${j}`, name: inspect ? 'read_file' : 'probe',
      arguments: JSON.stringify(inspect ? { path: `pad${j}.txt` } : { command: `printf '%s' '${'x'.repeat(18000)}'` }) }));
    return [{ type: 'reasoning', id: `rs-${n}`, encrypted_content: `opaque+/==\n${n} Δ`, summary: [] },
      { type: 'message', id: `m-${n}`, role: 'assistant', phase: 'commentary', content: [{ type: 'output_text', text: `Unfinished native design observation ${n}; preserve whole scope, not a new approval.` }] }, ...calls];
  };
  const grow = (from, to, inspect) => Array.from({ length: to - from + 1 }, (_, i) => ({ items: items(from + i, inspect) }));

  async function exercise(spec, mode) {
    const suite = await H.setupSuite();
    let c;
    try {
      c = await H.project(suite, [], { stagedIntent: false });
      const slug = 'window-case', stateDir = path.join(c.repo, `.kogen/local/shaping/${slug}`);
      const trace = path.join(c.root, 'readiness-count');
      const yaml = fs.readFileSync(path.join(c.repo, '.kogen/project.yaml'), 'utf8');
      const stepsDir = /steps_dir: '?([^'\n]+)'?/.exec(yaml)[1];
      const acceptanceRun = /^    run: '((?:[^']|'')*)'$/m.exec(yaml)[1].replaceAll("''", "'");
      H.configure(c, { acceptance: { run: `if grep -q 'Scenario:' "$KOGEN_ACCEPTANCE_FEATURES"; then printf 'run\\n' >> '${trace}'; fi; ${acceptanceRun}`, stepsDir } });
      await H.gitBang(c, ['add', '.kogen/project.yaml']); await H.gitBang(c, ['commit', '-qm', 'Trace Shape readiness']);
      for (const j of [1, 2]) put(c, `pad${j}.txt`, `p${j}`.repeat(14000) + '\n');
      put(c, 'selected.png', png());
      // The discovery corpus is committed so the candidate is stable, including image metadata.
      await H.gitBang(c, ['add', 'pad1.txt', 'pad2.txt', 'selected.png']); await H.gitBang(c, ['commit', '-qm', 'Seed discovery corpus']);
      const snapshot = async () => ({ head: await H.git(c, ['rev-parse', 'HEAD']), index: fs.readFileSync(path.join(c.repo, '.git/index')).toString('base64'), config: fs.readFileSync(path.join(c.repo, '.kogen/project.yaml'), 'utf8'), app: fs.readFileSync(path.join(c.repo, 'app.txt'), 'utf8'),
        approval: fs.existsSync(H.approvalPath(c.repo, 'fixture')) ? fs.readFileSync(H.approvalPath(c.repo, 'fixture'), 'utf8') : null });
      const before = await snapshot();
      let input = path.join(c.root, 'request.txt');
      const request = JSON.stringify(spec) + (mode === 'irreducible' ? '\n' + 'M'.repeat(600000) : '');
      fs.writeFileSync(input, request);
      const mdpath = H.intentMd(slug), ftpath = H.featurePath(slug), helper = 'features/steps/window_case.js';
      const url = `http://127.0.0.1:${c.server.port}/docs/missing`;
      let md = `# Preserve whole fixture scope\n\nSlug: ${slug}\nModel: not applicable — fixture has no product state\nAcceptance:\n- ${ftpath}\n- ${helper}\n\nKeep the whole requested scope, without automatic splitting.\n\n## Decisions\n- Preserve the complete request. (source: request)\n\n## Source comparison\n- addressed: complete source packet remains the native request; this is only a plumbing fixture.\n\n## Tests\n- Missing product: actual scenario (regression)\n\n## Feasibility\n- none\n`;
      if (mode === 'growth') md += `- documentation-lookup: unsupported ${url}\n`;
      const ft = 'Feature: Whole fixture scope\n  Scenario: Observe real missing behavior\n    Then the whole window fixture is implemented\n';
      const js = "const { Then } = require('@cucumber/cucumber');\nThen('the whole window fixture is implemented', function () { throw new Error('legitimate whole-scope product red'); });\n";
      const all = [{ path: mdpath, content: md }, { path: ftpath, content: ft }, { path: helper, content: js }];
      const question = { question: spec.fixture_question, options: [{ label: 'Retained fixture label', recommended: true }] };
      // A real shaper reads the repository before it submits anything.
      const inspection = f('read_file', { path: 'README.md' });
      if (mode === 'growth') {
        c.server.setScript([inspection, f('submit', { questions: [question] })]);
        const first = await H.runKogen(c, ['intent', 'shape', slug, input]);
        assert.equal(first.code, 5, first.out);
        assert.ok(first.out.includes(spec.fixture_question), 'question fixture did not run');
        input = path.join(c.root, 'answers.txt'); fs.writeFileSync(input, spec.fixture_answer);
      }
      const startCount = shapeRequests(c).length;
      const base = `http://127.0.0.1:${c.server.port}/docs`;
      let actions;
      switch (mode) {
        case 'irreducible': actions = [f('submit', { questions: [question] })]; break;
        case 'growth': {
          const docs = [1, 2, 3, 4, 5, 6].map(n => n % 2 === 0 ? f('documentation', { operation: 'fetch', base, url }) : f('documentation', { operation: 'search', base, query: `local continuity ${n}` }));
          const probes = [1, 2, 3].map(n => f('probe', { command: `printf 'probe-${n}\\n'` }));
          actions = [f('read_file', { path: 'README.md' }), ...docs, ...probes, f('view_image', { path: 'selected.png' }), f('submit', { files: [all[0]] }), ...grow(1, 40, true),
            f('submit', { files: [{ path: helper, content: 'POISON' }, { path: '../escape', content: 'unsafe' }] }), f('submit', { files: all.slice(1) }), ...grow(41, 80, true), f('submit', { files: [{ path: ftpath, content: ft }] })];
          break;
        }
        case 'inspection': actions = [...grow(1, 40, false), ...Array(3).fill(f('submit', { files: all }))]; break;
        case 'documents': {
          const forged = all.map((x, i) => i === 0 ? { ...x, content: x.content + `- documentation-lookup: retrieved ${url}\n` } : x);
          actions = [...grow(1, 40, true), ...Array(3).fill(f('submit', { files: forged }))]; break;
        }
        case 'invalids': actions = [f('submit', { files: [] }), f('submit', { files: [] }), ...grow(1, 40, true), f('submit', { files: [] }), f('submit', { questions: [question] })]; break;
        default: actions = [...grow(1, 40, true), { pause: f('read_file', { path: 'README.md' }) }, f('submit', { questions: [question] })];
      }
      c.server.setScript(actions);
      let out, status, damagedCount = null;
      if (mode.startsWith('damage-')) {
        const k = H.startKogen(c, ['intent', 'shape', slug, input]);
        let paused = null;
        try { paused = await c.server.waitPaused(15000); } catch { paused = null; }
        if (paused) {
          const reset = lines(path.join(stateDir, 'events.ndjson')).find(e => e.event === 'working_context_reset');
          if (reset) {
            const p = reset.archive.path;
            if (mode === 'damage-changed') fs.appendFileSync(p, ' ');
            else if (mode === 'damage-missing') fs.rmSync(p);
            else if (mode === 'damage-symlink') { const bytes = fs.readFileSync(p); const replacement = path.join(c.root, 'replacement.json'); fs.writeFileSync(replacement, bytes); fs.rmSync(p); fs.symlinkSync(replacement, p); }
            else if (mode === 'damage-mode') fs.chmodSync(p, 0o644);
          }
          damagedCount = shapeRequests(c).length;
          paused.continue();
        }
        const r = await k.awaitExit(30000); out = r.out; status = r.code;
      } else {
        const r = await H.runKogen(c, ['intent', 'shape', slug, input]); out = r.out; status = r.code;
      }
      const requests = shapeRequests(c).slice(startCount);
      const events = lines(path.join(stateDir, 'events.ndjson'));
      const resets = events.filter(e => e.event === 'working_context_reset');
      const safeFiles = resets.flatMap(e => {
        const ref = e.archive || {}, p = ref.path;
        if (typeof p === 'string' && fs.existsSync(p) && fs.statSync(p).isFile()) {
          const bytes = fs.readFileSync(p);
          return [{ path: p, bytes: bytes.toString('base64'), sha256: ref.sha256, mode: mode0(p), dir_mode: mode0(path.dirname(p)), doc: JSON.parse(bytes.toString('utf8')) }];
        }
        return [];
      });
      // Damaged custody need not be parseable; only success exercises the archive observer.
      const windows = [...safeFiles.map(x => x.doc.input), ...requests.map(r => r.json.input)];
      const texts = requests.map(r => H.FakeProvider.inputText(r));
      const bounded = requests.every(r => Buffer.byteLength(r.body) <= 524288);
      const mdPresent = fs.existsSync(path.join(c.repo, mdpath));
      const docpath = path.join(c.repo, `.kogen/local/provenance/${slug}/current.json`);
      const absent = !mdPresent && !fs.existsSync(docpath);
      const after = await snapshot();
      const common = { reset_happened: resets.length > 0, bounded_requests: bounded, no_publication: absent, checkout_authority_unchanged: same(after, before) };
      let result;
      if (mode === 'growth') {
        const expected = [];
        for (let n = 1; n <= 80; n++) {
          const group = items(n, true);
          const calls = group.filter(i => i.type === 'function_call');
          expected.push([...group.map(H.replayItem), ...calls.map(call => H.outputItem(call, cutText(numbered(fs.readFileSync(path.join(c.repo, JSON.parse(call.arguments).path), 'utf8')))))]);
        }
        const archiveWindows = safeFiles.map(x => x.doc.input);
        const imageOutputs = ws => ws.flatMap(w => w.filter(i => i.type === 'function_call_output' && Array.isArray(i.output) && i.output.some(b => b.type === 'input_image')));
        const images = imageOutputs(requests.map(r => r.json.input));
        const source = fs.existsSync(docpath) ? JSON.parse(fs.readFileSync(docpath, 'utf8')) : {};
        const readyFile = path.join(c.repo, `.kogen/local/readiness/${slug}.json`);
        const ready = fs.existsSync(readyFile) ? JSON.parse(fs.readFileSync(readyFile, 'utf8')) : null;
        const head = await H.git(c, ['rev-parse', 'HEAD']);
        const readyOk = ready !== null && mdPresent && ready.sha256 === await H.baselineHash(c, slug) && ready.head === head && ready.candidate_tree === await H.candidateTree(c, head) && (ready.scenarios || []).length > 0;
        const count = fs.existsSync(trace) ? fs.readFileSync(trace, 'utf8').split('\n').filter(Boolean).length : 0;
        const outputs = windows.flatMap(w => w.filter(i => i.type === 'function_call_output' && typeof i.output === 'string').map(i => i.output));
        const authority = requests.length ? requests[0].json.input.find(i => i.role === 'user') : null;
        const eventContract = resets.every((e, i) => e.owner === 'shape' && e.generation === i + 1 && e.input_budget_bytes === 524288 && e.output_reserve_tokens === 131072 && Number.isInteger(e.before_bytes) && e.before_bytes > 524288 && e.after_bytes <= 524288 && e.after_bytes < e.before_bytes && requests.some(r => Buffer.byteLength(r.body) === e.after_bytes));
        const linked = safeFiles.every((x, i) => x.doc.version === 1 && x.doc.owner === 'shape' && same(x.doc.previous, i === 0 ? null : { path: safeFiles[i - 1].path, sha256: safeFiles[i - 1].sha256 }));
        const docs = lines(path.join(stateDir, 'documentation.ndjson'));
        result = { ...common, success: status === 0, at_least_three_resets: resets.length >= 3, event_contract: eventContract && linked,
          authority_exact: authority !== null && requests.every(r => r.json.input.some(i => same(i, authority))) && texts.some(t => t.includes('Local working-window reset')),
          source_exact: source.request?.text === request && source.request?.source_path === path.join(c.root, 'request.txt'),
          qa_exact: (source.rounds || []).some(r => same(r.questions, [question]) && r.input === spec.fixture_answer),
          complete_package: all.every(x => fs.existsSync(path.join(c.repo, x.path)) && fs.readFileSync(path.join(c.repo, x.path), 'utf8') === x.content) && readyOk,
          unsafe_not_retained: !fs.existsSync(path.join(c.root, 'escape')) && fs.readFileSync(path.join(c.repo, helper), 'utf8') === js,
          one_readiness_execution: count === 1,
          actual_red_observed: outputs.some(o => o.includes('Readiness observations') && o.includes('legitimate whole-scope product red')),
          documentation_retained: docs.length === 6 && docs.every(d => d.status === 'unsupported') && events.filter(e => e.event === 'documentation_lookup').length === 6 && (out.match(/kogen: documentation result:/g) || []).length === 6,
          three_probes: (out.match(/kogen: probe result:/g) || []).length === 3,
          archived_image_exact: images.length > 0 && images.every(i => imageOutputs(archiveWindows).some(a => same(a, i))),
          replay: { windows, groups: expected, files: safeFiles.map(({ doc, ...rest }) => rest) },
          no_shape_approval: !fs.existsSync(H.approvalPath(c.repo, slug)) };
      } else if (mode === 'irreducible') {
        const stop = events.find(e => e.event === 'working_context_stop');
        let custody = false;
        if (stop) {
          const p = stop.archive?.path;
          if (typeof p === 'string' && fs.existsSync(p) && fs.statSync(p).isFile()) {
            const b = fs.readFileSync(p), d = JSON.parse(b.toString('utf8'));
            custody = stop.owner === 'shape' && stop.input_budget_bytes === 524288 && stop.output_reserve_tokens === 131072 && stop.measured_bytes > 524288 && stop.mandatory_bytes > 524288 && stop.archive.sha256 === sha256(b) &&
              JSON.stringify(d.input).includes('M'.repeat(600000)) && mode0(p) === 0o600 && mode0(path.dirname(p)) === 0o700;
          }
        }
        result = { ...common, stopped_before_inference: status !== 0 && requests.length === 0 && out.includes('candidate/context_budget_exceeded'), stop_custody_exact: custody,
          actionable_nonresume: out.includes('working-context') && !out.includes('kogen intent resume') && /identical|unchanged/i.test(out) };
      } else if (['inspection', 'documents', 'invalids'].includes(mode)) {
        const expectedText = { inspection: 'shape/uninspected', documents: 'shape/undocumented', invalids: 'non-empty' }[mode];
        const seen = texts.some(t => t.includes(expectedText)) || out.includes(expectedText);
        const counter = mode === 'invalids' ? requests.length === 43 : true;
        result = { ...common, gate_preserved: status !== 0 && seen && counter };
      } else {
        result = { ...common, custody_refused: status !== 0 && out.includes('candidate/context_custody_invalid'), no_inference_after_damage: damagedCount !== null && shapeRequests(c).length === damagedCount };
      }
      return result;
    } finally {
      await H.cleanupCase(c);
      H.cleanupSuite(suite);
    }
  }

  Given('the Shape continuity source packet:', function (json) { this.shapeWindowSource = JSON.parse(json); });
  When('I exercise installed Shape windows {string}', { timeout: 300000 }, async function (mode) {
    const data = await exercise(this.shapeWindowSource, mode);
    if (data.replay) { data.replay_custody = replayCustody(data.replay); delete data.replay; }
    this.shapeWindowResult = data; await this.attach(JSON.stringify(data), 'application/json');
  });
  Then('the Shape window observations include:', function (json) {
    for (const [name, expected] of Object.entries(JSON.parse(json))) assert.deepEqual(this.shapeWindowResult[name], expected, `${name}: ${JSON.stringify(this.shapeWindowResult)}`);
  });
}
