'use strict';
// Native Review and Refine working room, observed on the installed Go candidate (the one `kogen` program) with a scripted
// local provider (FakeProvider from go_driver_support). What has no user-visible form (how a received item is replayed,
// what a production tool delivers to the model, how the complete rendered request is measured) is observed through the
// Go driver at test/migration/drivers/review_refine_working_room, which imports kogen/agent and kogen/provider.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');
const H = require('./go_driver_support.js');
const { fn: f } = H;
const same = (a, b) => { try { assert.deepEqual(a, b); return true; } catch { return false; } };
const sha = x => crypto.createHash('sha256').update(x).digest('hex');
const DRIVER = 'review_refine_working_room';

// ------------------------------------------------------------------ the replay observer

function replayCustody(d) {
  if (!d || !d.expected.length || !d.files.length) return false;
  const windows = [];
  for (const f of d.files) {
    const bytes = Buffer.from(f.bytes, 'base64');
    if (f.mode !== 384 || f.dir_mode !== 448 || crypto.createHash('sha256').update(bytes).digest('hex') !== f.sha256) return false;
    try { windows.push(JSON.parse(bytes).input || []); } catch { return false; }
  }
  windows.push(...d.requests);
  for (const w of windows) {
    const pending = new Set();
    for (const i of w) {
      if (i.type === 'function_call') { if (pending.has(i.call_id)) return false; pending.add(i.call_id); }
      if (i.type === 'function_call_output' && !pending.delete(i.call_id)) return false;
    }
    if (pending.size) return false;
  }
  const seen = [];
  for (const w of windows) for (const i of w) if (i.type === 'function_call' && !seen.includes(i.call_id)) seen.push(i.call_id);
  const wanted = d.expected.flatMap(g => g.filter(i => i.type === 'function_call').map(i => i.call_id));
  if (!same(seen.filter(id => wanted.includes(id)), wanted)) return false;
  return d.expected.every(g => windows.some(w => w.some((_, n) => same(w.slice(n, n + g.length), g))));
}

// ------------------------------------------------------------------ the Go driver

async function driver() { return H.driverProgram(DRIVER); }
// The replayed form of each item (null where the item is not replayed): agent.ReplayItem.
async function replayAll(items) {
  const run = await driver();
  const r = await run(['replay'], { input: JSON.stringify(items) });
  assert.equal(r.code, 0, r.out);
  return JSON.parse(r.out);
}
// What the model receives for one production tool call in root: the tool's result through the shared bounded delivery.
async function delivered(root, name, args) {
  const run = await driver();
  const r = await run(['tool', root, name, JSON.stringify(args)]);
  assert.equal(r.code, 0, r.out);
  return r.out;
}
// A Go toolchain for the standalone controls (`node ... --control`), which run outside `mise exec`.
function ensureGo() {
  if (spawnSync('go', ['version'], { encoding: 'utf8' }).status === 0) return;
  const r = spawnSync('mise', ['which', 'go'], { encoding: 'utf8' });
  if (r.status === 0) process.env.PATH = [path.dirname(r.stdout.trim()), process.env.PATH].join(path.delimiter);
}

// The known-good receipt of the observer: one unfinished native exchange (opaque reasoning, a commentary message and two
// read calls that answer with the delivered result of the production read_file), replayed through the production
// functions and held as a private version-1 history file.
async function controlReceipt() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'working-room-control-'));
  try {
    fs.chmodSync(dir, 0o700);
    fs.writeFileSync(path.join(dir, 'literal.txt'), '  Δ🙂\r\n/path with spaces/診断.txt\n  ');
    const calls = [1, 2].map(n => ({ type: 'function_call', id: `fc${n}`, call_id: `c${n}`, name: 'read_file', arguments: JSON.stringify({ path: 'literal.txt' }) }));
    const items = [
      { type: 'reasoning', id: 'r', encrypted_content: 'opaque+/==\nDo not decode Δ', summary: [] },
      { type: 'message', id: 'm', role: 'assistant', phase: 'commentary', content: [{ type: 'output_text', text: 'Unfinished native observation' }] },
      ...calls,
    ];
    const text = await delivered(dir, 'read_file', { path: 'literal.txt' });
    const group = [...(await replayAll(items)), ...calls.map(c => H.outputItem(c, text))];
    const bytes = JSON.stringify({ version: 1, owner: 'refine', input: group, previous: null }) + '\n';
    const file = path.join(dir, '1.json');
    fs.writeFileSync(file, bytes); fs.chmodSync(file, 0o600);
    return { requests: [], expected: [group], files: [{ bytes: Buffer.from(fs.readFileSync(file)).toString('base64'), sha256: sha(bytes), mode: fs.statSync(file).mode & 0o777, dir_mode: fs.statSync(dir).mode & 0o777 }] };
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
}

if (require.main === module && process.argv[2] === '--control') {
  (async () => {
    ensureGo();
    const good = await controlReceipt(); assert.equal(replayCustody(good), true);
    if (process.argv[3] === 'good') process.stdout.write('accepted\n');
    else if (process.argv[3] === 'bad') {
      const rewrite = (d, edit) => { const doc = JSON.parse(Buffer.from(d.files[0].bytes, 'base64')); edit(doc.input); d.files[0].bytes = Buffer.from(JSON.stringify(doc)).toString('base64'); d.files[0].sha256 = crypto.createHash('sha256').update(Buffer.from(d.files[0].bytes, 'base64')).digest('hex'); };
      for (const mutate of [d => rewrite(d, w => w.pop()), d => rewrite(d, w => { w[0].encrypted_content += 'changed'; }), d => rewrite(d, w => { w[1].phase = 'final'; }), d => rewrite(d, w => { w[2].arguments += ' '; }), d => rewrite(d, w => w.reverse()), d => { d.files[0].sha256 = '0'.repeat(64); }, d => { d.files[0].mode = 420; }, d => { d.files[0].dir_mode = 493; }]) {
        const bad = structuredClone(good); mutate(bad); assert.equal(replayCustody(bad), false, 'counterexample accepted');
      }
      process.stdout.write('rejected\n'); process.exitCode = 1;
    } else throw new Error('unknown control');
  })().catch(e => { process.stderr.write(String(e && e.stack || e) + '\n'); process.exitCode = 2; });
} else {
  const { Given, When, Then } = require('@cucumber/cucumber');

  // ---------------------------------------------------------------- the exercise (the old WorkingRoomExercise)

  // Replace the answers not yet consumed. A retried request may have advanced the cursor past the end of the script
  // (the transport's default refusal); the appended answers then start right after the retained prefix.
  function script(c, actions) { const s = c.server; s.next = Math.min(s.next, s.script.length); s.setScript(actions); }
  function put(c, p, bytes) { const full = path.join(c.repo, p); fs.mkdirSync(path.dirname(full), { recursive: true }); fs.writeFileSync(full, bytes); }
  const git = async (c, args) => H.git(c, args);
  const readOrNull = p => { try { return fs.readFileSync(p); } catch { return null; } };
  const package_ = c => Object.fromEntries([H.intentMd('fixture'), H.featurePath('fixture'), 'features/steps/integration_steps.js'].map(p => [p, fs.readFileSync(path.join(c.repo, p), 'utf8')]));
  async function custody(c) {
    return { head: await git(c, ['rev-parse', 'HEAD']), index: fs.readFileSync(path.join(c.repo, '.git/index')), approval: readOrNull(H.approvalPath(c.repo, 'fixture')), package: package_(c) };
  }
  const lines = p => { const b = readOrNull(p); return b ? b.toString('utf8').split('\n').filter(Boolean).map(l => JSON.parse(l)) : []; };
  const events = c => H.wildcard(path.join(c.repo, '.kogen/local/refinements/*/events.ndjson')).flatMap(lines);
  // The ordered history files a run keeps: the Review's checkpoint (the Go engine's version 4 keeps its state as JSON)
  // and the archives named by refinement events.
  function refs(c) {
    const cp = H.wildcard(path.join(c.repo, '.kogen/local/runs/*/checkpoint.json')).flatMap(p => {
      try { const d = JSON.parse(fs.readFileSync(p, 'utf8')); return d.version === 4 && d.state ? ((d.state.working_context || {}).review || {}).history || [] : []; } catch { return []; }
    });
    const es = events(c).filter(e => e.archive && typeof e.archive === 'object').map(e => e.archive);
    const seen = new Set();
    return [...cp, ...es].filter(r => { if (seen.has(r.path)) return false; seen.add(r.path); return true; });
  }
  const files = rs => rs.flatMap(ref => {
    const b = readOrNull(ref.path);
    if (!b) return [];
    return [{ path: ref.path, bytes: b.toString('base64'), sha256: ref.sha256, mode: fs.statSync(ref.path).mode & 0o777, dir_mode: fs.statSync(path.dirname(ref.path)).mode & 0o777 }];
  });
  // Unfinished native exchanges with growing tool results: the scripted answers and the exact replay each must leave.
  async function growth(c, spec, owner, range) {
    const result = await delivered(c.repo, 'read_file', { path: 'pad.txt' });
    const groups = [];
    for (const n of range) {
      const calls = Array.from({ length: spec.read_batch }, (_, j) => ({ type: 'function_call', id: `fc-${owner}-${n}-${j + 1}`, call_id: `call-${owner}-${n}-${j + 1}`, name: 'read_file', arguments: JSON.stringify({ path: 'pad.txt' }) }));
      const items = [
        { type: 'reasoning', id: `rs-${owner}-${n}`, encrypted_content: spec.opaque + String(n), summary: [] },
        { type: 'message', id: `m-${owner}-${n}`, role: 'assistant', phase: 'commentary', content: [{ type: 'output_text', text: `Unfinished ${owner} observation ${n}; unresolved findings and exact authority remain, not a new approval.` }] },
        ...calls,
      ];
      groups.push({ items, calls, result });
    }
    const replayed = await replayAll(groups.flatMap(g => g.items));
    let at = 0;
    return groups.map(g => {
      const mine = replayed.slice(at, at += g.items.length);
      return { action: { items: g.items }, expected: [...mine, ...g.calls.map(call => H.outputItem(call, g.result))] };
    });
  }
  // The run is at the scripted pause, or has ended.
  function either(k, fake, ms = 25000) {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('fixture timed out before paused provider')), ms);
      fake.waitPaused(ms).then(p => { clearTimeout(timer); resolve({ paused: p }); }, () => {});
      k.awaitExit(ms).then(r => { clearTimeout(timer); resolve({ done: r }); }, () => {});
    });
  }
  function damage(p, mode, c) {
    if (mode.endsWith('missing')) fs.rmSync(p);
    else if (mode.endsWith('symlink')) { const b = fs.readFileSync(p); const q = path.join(c.root, 'replacement.json'); fs.writeFileSync(q, b); fs.rmSync(p); fs.symlinkSync(q, p); }
    else if (mode.endsWith('mode')) fs.chmodSync(p, 0o644);
    else fs.appendFileSync(p, ' ');
  }
  const bounded = (rs, s) => rs.length > 0 && rs.every(r => Buffer.byteLength(r.body) <= s.budget);
  function authority(rs, phase = 'refine') {
    const stable = r => {
      const message = r.json.input.find(i => i.role === 'user');
      return phase === 'review' && message && Array.isArray(message.content) && message.content.length ? message.content[0] : message;
    };
    if (!rs.length) return false;
    const a = stable(rs[0]);
    return a != null && rs.every(r => same(stable(r), a));
  }
  const outputText = rs => rs.flatMap(r => r.json.input.filter(i => i.type === 'function_call_output' && typeof i.output === 'string').map(i => i.output)).join('\n');
  const countTrace = p => { const b = readOrNull(p); return b ? b.toString('utf8').split('\n').filter(Boolean).length : 0; };

  async function review(c, s, packet, mode) {
    const fake = c.server;
    put(c, 'README.md', '# Fixture project\n' + 'r'.repeat(s.review_readme_bytes) + '\n');
    put(c, 'docs/development.md', 'd'.repeat(s.review_docs_bytes) + '\n');
    put(c, 'seed-knowledge.txt', 'k'.repeat(s.review_added_bytes) + '\n');
    await git(c, ['add', 'README.md', 'docs/development.md', 'seed-knowledge.txt', 'pad.txt']); await git(c, ['commit', '-qm', 'Seed maintained documents']);
    const p = H.intentMd('fixture'); put(c, p, fs.readFileSync(path.join(c.repo, p), 'utf8') + '\nReported source packet (diagnostic, no migration scope):\n' + packet + '\nExact literal:\n' + s.literal);
    await H.approve(c); const before = await custody(c);
    const edit = "printf '\\nreview-edit\\n' >> README.md; printf '\\nreview-edit\\n' >> docs/development.md; cp seed-knowledge.txt knowledge_live.ex";
    script(c, [f('shell', { command: edit }), f('finish', { summary: 'builder-only-sentinel; candidate complete' }), { http: [503, { error: { message: 'local scripted overload', code: 'server_error' } }] }]);
    const built = await H.runKogen(c, ['intent', 'build', 'fixture']);
    const cps = H.wildcard(path.join(c.repo, '.kogen/local/runs/*/checkpoint.json'));
    assert.equal(cps.length, 1, `expected one checkpoint: ${cps}\n${built.out}`);
    const cp = cps[0], id = path.basename(path.dirname(cp)), oldResult = fs.readFileSync(path.join(path.dirname(cp), 'result.json'));
    const first = fake.reviewRequests().at(-1);
    const inline = first != null && Buffer.byteLength(first.body) <= s.budget && H.FakeProvider.inputText(first).includes('# Full text of every changed or added file') && !H.FakeProvider.inputText(first).includes('# Pinned complete candidate source evidence');
    const groups = await growth(c, s, 'review', Array.from({ length: 8 }, (_, i) => i + 1));
    script(c, [...groups.map(g => g.action), { pause: f('read_file', { path: 'pad.txt' }) }]);
    const n = fake.providerRequests().length;
    const k = H.startKogen(c, ['intent', 'resume', id]);
    let resume, code, delivered_ = false, damageCount = null;
    const waited = await either(k, fake);
    if (waited.done) { resume = waited.done.out; code = waited.done.code; }
    else {
      const rs = refs(c);
      if (mode === 'review-damage') {
        const target = rs.find(r => r.path.includes('working-context')) || rs[0];
        if (target) damage(target.path, mode, c);
        damageCount = fake.providerRequests().length; waited.paused.continue();
        const r = await k.awaitExit(30000); resume = r.out; code = r.code;
      } else {
        const parts = rs.filter(r => { try { const d = JSON.parse(fs.readFileSync(r.path, 'utf8')); return d && typeof d.review_source === 'object' && d.review_source !== null && !Array.isArray(d.review_source); } catch { return false; } });
        script(c, [...parts.map(r => f('read_file', { path: r.path })), f('write_file', { path: 'app.txt', content: 'reviewer repaired\n' }), f('submit_review', { verdict: 'approve', findings: [] })]);
        waited.paused.continue();
        const r = await k.awaitExit(40000); resume = r.out; code = r.code;
        const rr = fake.reviewRequests();
        const originalSource = first.json.input.find(i => i.role === 'user').content[1].text;
        const recovered = parts.map(ref => JSON.parse(fs.readFileSync(ref.path, 'utf8')).review_source.text).join('');
        delivered_ = parts.length > 0 && recovered === originalSource && parts.every(ref => {
          const expected = '1\t' + fs.readFileSync(ref.path, 'utf8').replace(/\n+$/, '');
          return rr.some(q => q.json.input.some(i => i.type === 'function_call_output' && i.output === expected));
        });
      }
    }
    const rr = fake.reviewRequests(), resumed = fake.providerRequests().slice(n), afterState = await custody(c);
    const results = H.wildcard(path.join(c.repo, '.kogen/local/runs/*/result.json'));
    const result = {
      initial_inline_fit: inline,
      resumed_saved_review: built.code !== 0 && first != null && resumed.length > 0 && same(resumed[0].json.input, first.json.input),
      success: code === 0,
      source_relocated: refs(c).some(r => r.path.includes('review-source')),
      all_source_delivered: delivered_,
      authority_exact: authority(rr, 'review'),
      bounded: bounded(rr, s),
      independent: rr.length > 0 && rr.every(r => !JSON.stringify(r.json.input).includes('builder-only-sentinel')),
      old_result_unchanged: fs.readFileSync(path.join(path.dirname(cp), 'result.json')).equals(oldResult),
      one_commit: (await git(c, ['rev-list', '--count', before.head + '..HEAD'])) === '1',
      final_repair_verified: code === 0 && fs.readFileSync(path.join(c.repo, 'app.txt'), 'utf8') === 'reviewer repaired\n' && results.some(p => { const d = JSON.parse(fs.readFileSync(p, 'utf8')); return d.outcome === 'landed' && d.passes >= 2 && d.reviews === 1; }),
      custody_refused: code !== 0 && /custody|resume_refused/.test(resume),
      no_inference_after_damage: damageCount !== null && fake.providerRequests().length === damageCount,
      no_commit: afterState.head === before.head,
      approval_unchanged: same(afterState.approval, before.approval),
      output: built.out + resume,
    };
    if (mode === 'review-resume') result.replay = { files: files(refs(c)), requests: rr.map(r => r.json.input), expected: groups.map(g => g.expected) };
    return result;
  }

  async function refine(c, s, packet, mode) {
    const fake = c.server;
    put(c, 'README.md', '# Fixture project\n' + 'R'.repeat(s.refine_readme_bytes) + '\n' + s.literal);
    const trace = path.join(c.root, 'readiness-count');
    const yaml = fs.readFileSync(path.join(c.repo, '.kogen/project.yaml'), 'utf8');
    const stepsDir = /steps_dir: '?([^'\n]+)'?/.exec(yaml)[1];
    const acceptanceRun = /^    run: '((?:[^']|'')*)'$/m.exec(yaml)[1].replaceAll("''", "'");
    assert.match(yaml, /^protect: \[\]/m);
    const command = `if grep -q 'Scenario:' "$KOGEN_ACCEPTANCE_FEATURES"; then printf 'run\\n' >> '${trace}'; fi; ` + acceptanceRun;
    H.configure(c, { setup: [], fix: [], checks: [], protect: [], acceptance: { run: command, stepsDir } });
    put(c, 'pad.txt', 'p'.repeat(s.read_bytes));
    await git(c, ['add', 'README.md', 'pad.txt', '.kogen/project.yaml']); await git(c, ['commit', '-qm', 'Seed Refine authority and readiness trace']);
    const approved = await H.approve(c); const before = await custody(c); const beforeTrace = countTrace(trace);
    const md = H.intentMd('fixture'), ft = H.featurePath('fixture'), js = 'features/steps/integration_steps.js';
    const bad = before.package[md] + '\n## Decisions\n- Keep retained correction.\n';
    const good = bad.replace('- Keep retained correction.', '- Keep retained correction. (source: request)');
    const feature = before.package[ft].replace('Feature: Integration fixture', 'Feature: Retained native correction');
    const step = before.package[js].replace('if (!this.fixtureAvailable)', "throw new Error('working-room legitimate product red');\n  if (!this.fixtureAvailable)");
    const submit = fs_ => f('submit_refinement', { files: fs_ });
    const proposed = submit([{ path: md, content: bad }, { path: ft, content: feature }, { path: js, content: step }]);
    const correction = packet + '\nKeep exact correction literal:\n' + s.literal + (mode === 'refine-irreducible' ? 'M'.repeat(600000) : '');
    const request = path.join(c.root, 'correction.md'); fs.writeFileSync(request, correction);
    const groups = await growth(c, s, 'refine', Array.from({ length: s.turns }, (_, i) => i + 1));
    const more = await growth(c, s, 'refine', Array.from({ length: 8 }, (_, i) => s.turns + i + 1));
    const finish = submit([{ path: md, content: good }]);
    const acts = gs => gs.map(g => g.action);
    let actions;
    if (mode === 'refine-irreducible') actions = [finish];
    else if (mode === 'refine-invalids') actions = [submit([]), submit([]), ...acts(groups), submit([]), finish];
    else if (mode.startsWith('refine-damage')) actions = [proposed, ...acts(groups), { pause: finish }];
    else actions = [proposed, ...acts(groups), submit([{ path: md, content: 'POISON' }, { path: 'app.txt', content: 'unsafe' }]), finish, ...acts(more), finish];
    script(c, actions);
    const n = fake.providerRequests().length;
    let out, k, damageCount = null;
    if (mode.startsWith('refine-damage')) {
      const proc = H.startKogen(c, ['intent', 'refine', 'fixture', approved.hash, request]);
      const waited = await either(proc, fake);
      if (waited.done) { out = waited.done.out; k = waited.done.code; }
      else {
        const target = refs(c)[0]; if (target) damage(target.path, mode, c);
        damageCount = fake.providerRequests().length; waited.paused.continue();
        const r = await proc.awaitExit(30000); out = r.out; k = r.code;
      }
    } else { const r = await H.runKogen(c, ['intent', 'refine', 'fixture', approved.hash, request]); out = r.out; k = r.code; }
    const rs = fake.providerRequests().slice(n), es = events(c), resets = es.filter(e => e.event === 'working_context_reset'), afterState = await custody(c), text = outputText(rs);
    const stop = es.find(e => e.event === 'working_context_stop');
    let unsent = false;
    if (stop && stop.archive && typeof stop.archive === 'object' && fs.existsSync(stop.archive.path) && fs.statSync(stop.archive.path).isFile()) {
      const ref = stop.archive, b = fs.readFileSync(ref.path), d = JSON.parse(b);
      unsent = stop.owner === 'refine' && stop.input_budget_bytes === s.budget && stop.output_reserve_tokens === s.reserve && stop.measured_bytes > s.budget && sha(b) === ref.sha256 && (fs.statSync(ref.path).mode & 0o777) === 0o600 && (fs.statSync(path.dirname(ref.path)).mode & 0o777) === 0o700 && JSON.stringify(d.input).includes('M'.repeat(600000));
    }
    const validEvents = resets.length > 0 && resets.every((e, i) => e.owner === 'refine' && e.generation === i + 1 && e.before_bytes > s.budget && e.after_bytes <= s.budget && e.after_bytes < e.before_bytes && e.input_budget_bytes === s.budget && e.output_reserve_tokens === s.reserve && rs.some(r => Buffer.byteLength(r.body) === e.after_bytes));
    const revoked = H.wildcard(path.join(c.repo, '.kogen/local/refinements/*/revoked-approval.json'));
    const result = {
      success: k === 0,
      reset_happened: resets.length > 0,
      at_least_three_resets: resets.length >= 3,
      authority_exact: authority(rs),
      bounded: bounded(rs, s),
      complete_package: same(afterState.package, { ...before.package, [md]: good, [ft]: feature, [js]: step }),
      unsafe_not_retained: fs.readFileSync(path.join(c.repo, 'app.txt'), 'utf8') === 'baseline\n' && !afterState.package[md].includes('POISON'),
      red_observed: text.includes('Readiness observations') && text.includes('working-room legitimate product red'),
      one_candidate_readiness: countTrace(trace) - beforeTrace === 1,
      approval_revoked: !fs.existsSync(H.approvalPath(c.repo, 'fixture')) && before.approval !== null && revoked.some(p => fs.readFileSync(p).equals(before.approval)),
      head_index_unchanged: afterState.head === before.head && afterState.index.equals(before.index),
      package_unchanged: same(afterState.package, before.package),
      approval_unchanged: same(afterState.approval, before.approval),
      invalid_limit_preserved: k !== 0 && out.includes('shape/refinement_invalid') && rs.length === s.turns + 3,
      custody_refused: k !== 0 && out.includes('candidate/context_custody_invalid'),
      no_inference_after_damage: damageCount !== null && fake.providerRequests().length === damageCount,
      irreducible_refused: k !== 0 && out.includes('candidate/context_budget_exceeded'),
      no_inference: rs.length === 0,
      unsent_retained: unsent,
      actionable_nonresume: out.includes('working-context') && !out.includes('kogen intent resume') && /identical|unchanged/i.test(out),
      reset_events_valid: validEvents,
      output: out,
    };
    if (mode === 'refine-growth') result.replay = { files: files(refs(c)), requests: rs.map(r => r.json.input), expected: [...groups, ...more].map(g => g.expected) };
    return result;
  }

  async function measure(s) {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'working-room-measure-'));
    try {
      const spec = path.join(dir, 'spec.json'); fs.writeFileSync(spec, JSON.stringify(s));
      const run = await driver(); const r = await run(['measure', spec]);
      assert.equal(r.code, 0, r.out);
      return JSON.parse(r.out);
    } finally { fs.rmSync(dir, { recursive: true, force: true }); }
  }

  // ---------------------------------------------------------------- the steps

  Given('the working-room source packet:', function (packet) { this.roomPacket = packet; });
  Given('the working-room local fixture parameters:', function (json) { this.roomSpec = JSON.parse(json); });
  When('I exercise native working room {string}', { timeout: 300000 }, async function (mode) {
    let data;
    if (mode === 'measure') data = await measure(this.roomSpec);
    else {
      const suite = await H.setupSuite();
      try {
        const c = await H.project(suite, [], { stagedIntent: false });
        try {
          put(c, 'pad.txt', 'p'.repeat(this.roomSpec.read_bytes));
          data = mode.startsWith('review') ? await review(c, this.roomSpec, this.roomPacket, mode) : await refine(c, this.roomSpec, this.roomPacket, mode);
        } finally { await H.cleanupCase(c); }
      } finally { H.cleanupSuite(suite); }
    }
    if (data.replay) { data.replay_custody = replayCustody(data.replay); delete data.replay; }
    this.roomResult = data; await this.attach(JSON.stringify(data), 'application/json');
  });
  Then('the native working-room observations include:', function (json) {
    for (const [name, expected] of Object.entries(JSON.parse(json))) assert.deepEqual(this.roomResult[name], expected, `${name}: ${JSON.stringify(this.roomResult)}`);
  });
}
