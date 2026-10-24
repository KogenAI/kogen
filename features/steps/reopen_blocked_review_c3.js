'use strict';
// A genuine C3 (c3ee2a8e) blocked run, resumed by the candidate.
//
// The C3 producer is built from the provenance-bound fixture (reopen_blocked_review_producer.js, cached per run). It makes the same
// blocked run the reopen-blocked-review clear and red modes start from: a green final pass, then a red one, and the original
// reviewer's latest verdict `changes`. The candidate's `kogen intent resume <id>` is then observed against the checkpoint C3 wrote,
// together with the read-only `kogen intent inspect <id>`. The exercise runs in a child Cucumber process (the acceptance world
// and its local fake provider are Cucumber-bound); the parent reads the receipt it saves.
//
// Parent use:  const receipt = await c3ResumeObservations({ candidatePrefix, bin })   (bin: the C3 executable)
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');
const REPO = path.resolve(__dirname, '../..');
const PARENT_NODE = process.env.KOGEN_NODE || process.execPath, PARENT_CUCUMBER = process.env.KOGEN_CUCUMBER || path.join(REPO, 'test/acceptance/node_modules');

function run(file, args, opts = {}) {
  return new Promise((resolve, reject) => {
    const p = spawn(file, args, { ...opts, detached: true, stdio: ['ignore', 'pipe', 'pipe'] });
    let output = '';
    p.stdout.on('data', b => { output += b; }); p.stderr.on('data', b => { output += b; });
    const timer = setTimeout(() => { try { process.kill(-p.pid, 'SIGKILL'); } catch {} }, 300000);
    p.on('error', e => { clearTimeout(timer); reject(e); });
    p.on('close', code => { clearTimeout(timer); resolve({ code, output }); });
  });
}

if (process.env.KOGEN_C3_CHILD === '1') {
  const { Given, Then, Before, After } = require('@cucumber/cucumber');
  const support = process.env.KOGEN_C3_SUPPORT;
  require(path.join(support, 'world'));
  const { dispatch } = require(path.join(support, 'handlers'));
  Before(async function () { this.prefix = process.env.KOGEN_C3_PREFIX; await this.setup(); this.server.commandObserver = null; });
  After(async function () { await this.cleanup(); });
  const slug = 'reopen-fixture', dir = `.kogen/intents/${slug}`;
  const finding = 'Synthetic external host unavailable; final application checks not established';
  function put(w, name, value) { const p = path.join(w.project, name); fs.mkdirSync(path.dirname(p), { recursive: true }); fs.writeFileSync(p, value); }
  function git(w, args) { const r = w.git(w.project, args, { GIT_OPTIONAL_LOCKS: '0' }); assert.equal(r.status, 0, r.stdout + r.stderr); return r.stdout.trim(); }
  function call(name, args, id) { return { type: 'function_call', id: `item_${id}`, call_id: `call_${id}`, name, arguments: JSON.stringify(args) }; }
  function files(d) { return fs.existsSync(d) ? fs.readdirSync(d, { withFileTypes: true }).flatMap(e => e.isDirectory() ? files(path.join(d, e.name)) : [path.join(d, e.name)]) : []; }
  // path -> bytes (and mode) of every file under the roots, skipping the named directories
  function snapshot(roots, skip = []) {
    const m = new Map();
    const walk = d => { for (const e of fs.readdirSync(d, { withFileTypes: true })) { const p = path.join(d, e.name); if (skip.includes(p)) continue; if (e.isDirectory()) walk(p); else if (e.isSymbolicLink()) m.set(p, 'link:' + fs.readlinkSync(p)); else m.set(p, fs.readFileSync(p).toString('base64') + ':' + (fs.statSync(p).mode & 0o7777)); } };
    const one = p => m.set(p, fs.readFileSync(p).toString('base64') + ':' + (fs.statSync(p).mode & 0o7777));
    for (const r of roots) if (fs.existsSync(r)) { if (fs.statSync(r).isDirectory()) walk(r); else one(r); }
    return m;
  }
  const same = (a, b) => a.size === b.size && [...a].every(([k, v]) => b.get(k) === v);

  Given('a genuine C3 blocked review is resumed by the candidate', { timeout: 280000 }, async function () {
    await this.createProject('notes'); await dispatch(this, '^the caller is signed in to ChatGPT$', []);
    const trace = path.join(this.workspace, 'trace'), host = path.join(this.workspace, 'host');
    fs.writeFileSync(trace, ''); fs.writeFileSync(host, 'green');
    this.extraEnv = { RB_TRACE: trace, RB_HOST: host, RB_MARKER: path.join(this.workspace, 'paused') };
    put(this, '.gitignore', '.kogen/local/\n'); put(this, 'app.txt', 'baseline\n');
    put(this, 'gate.cjs', `const fs=require('node:fs'); const name=process.argv[2], host=fs.readFileSync(process.env.RB_HOST,'utf8'); fs.appendFileSync(process.env.RB_TRACE,JSON.stringify([fs.realpathSync('.'),fs.readFileSync('app.txt','utf8').trim(),name])+'\\n'); if((host==='setup-red'&&name==='setup')||(host==='red'&&name==='project')){console.log('synthetic-'+host+'-failure');process.exit(19);}\n`);
    put(this, '.kogen/project.yaml', `version: 1
commands:
  setup: ['"$KOGEN_NODE" gate.cjs setup']
  fix: []
  checks:
    - name: fixture-check
      run: '"$KOGEN_NODE" gate.cjs project'
  acceptance:
    run: 'NODE_PATH="$KOGEN_CUCUMBER" "$KOGEN_NODE" "$KOGEN_CUCUMBER/@cucumber/cucumber/bin/cucumber.js" --strict --require "features/steps/*.js" --format "message:$KOGEN_ACCEPTANCE_REPORT" "$KOGEN_ACCEPTANCE_FEATURES"'
    steps_dir: features/steps
protect: [gate.cjs]
models:
  shape: {model: gpt-6.1-sol, effort: high}
  build: {model: gpt-6.1-sol, effort: medium}
  review: {model: gpt-6.1-sol, effort: high}
`);
    git(this, ['add', '-A']); git(this, ['commit', '-qm', 'Configure synthetic blocked review']);
    put(this, `${dir}/intent.md`, `# Preserve reviewer candidate\n\nSlug: ${slug}\nModel: ${dir}/model.qnt invariants=Valid seed=31 samples=2 steps=2\nAcceptance:\n- ${dir}/acceptance.feature\n- features/steps/app_steps.js\n\nReplace baseline with builder preserved or reviewer repaired; targeted review may write cleared repair.\n\n## Decisions\n- Preserve candidate work. (source: request)\n\n## Tests\n- Text replacement: fixture scenario (scenario)\n\n## Feasibility\n- none\n`);
    put(this, `${dir}/model.qnt`, 'module fixture {\n var n: int\n action init = n\' = 0\n action step = n\' = n + 1\n val Valid = n >= 0\n}\n');
    put(this, `${dir}/acceptance.feature`, 'Feature: Candidate\n  Scenario: Candidate implementation\n    Then the reopened candidate is implemented\n');
    put(this, 'features/steps/app_steps.js', `const {Then}=require('@cucumber/cucumber');const fs=require('node:fs');const assert=require('node:assert/strict');Then('the reopened candidate is implemented',()=>{const app=fs.readFileSync('app.txt','utf8').trim();fs.appendFileSync(process.env.RB_TRACE,JSON.stringify([fs.realpathSync('.'),app,'acceptance'])+'\\n');assert.ok(['builder preserved','reviewer repaired','cleared repair'].includes(app));});\n`);
    const c3 = process.env.KOGEN_C3_BIN, newBin = path.join(this.prefix, 'bin/kogen');
    this.commandOverride = c3;
    const c3Version = await this.invoke('kogen version');
    const card = await this.invoke(`kogen intent approve ${slug}`); assert.equal(card.code, 5, card.stdout + card.stderr);
    const hash = card.stdout.match(/^SHA-256: ([a-f0-9]{64})$/m)?.[1]; assert.ok(hash, card.stdout);
    const approved = await this.invoke(`kogen intent approve ${slug} ${hash}`); assert.equal(approved.code, 0, approved.stdout + approved.stderr);
    git(this, ['add', dir, 'features/steps/app_steps.js']);
    await dispatch(this, '^commit signing is configured with a test SSH key$', []);
    const hook = path.join(this.gitDir(), 'hooks/pre-commit'); fs.writeFileSync(hook, '#!/bin/sh\nprintf "hook\\n" >> .kogen/local/hooks\n', { mode: 0o755 });
    this.server.configure('native-reopen');
    // C3 builds once, its reviewer approves a candidate after the final application check turns red, then the original reviewer keeps `changes`.
    this.server.scriptResponse = (record, ordinal) => {
      if (record.kind === 'build') {
        if (ordinal === 1) return { items: [call('shell', { command: "printf 'builder preserved\\n' > app.txt; printf 'once\\n' >> .kogen/local/effects" }, 'builder_once')] };
        assert.ok(ordinal <= 2, 'bounded builder fixture');
        return { items: [call('finish', { summary: 'candidate ready' }, 'finish')] };
      }
      assert.equal(record.kind, 'review');
      if (ordinal === 1) return { items: [call('read_file', { path: 'app.txt' }, 'independent_memory')] };
      if (ordinal === 2) {
        fs.writeFileSync(host, 'setup-red');
        return { items: [call('write_file', { path: 'app.txt', content: 'reviewer repaired\n' }, 'reviewer_edit'), call('submit_review', { verdict: 'approve', findings: [] }, 'old_approval')] };
      }
      assert.equal(ordinal, 3, 'final failure must reach the original reviewer');
      return { items: [call('submit_review', { verdict: 'changes', findings: [{ path: 'gate.cjs', line: 1, severity: 'blocking', message: finding }] }, 'original_blocker')] };
    };
    const first = await this.invoke(`kogen intent build ${slug}`);
    assert.equal(first.code, 1, first.stdout + first.stderr); assert.match(first.stdout, /candidate\/review_blocked/);
    const runs = path.join(this.project, '.kogen/local/runs');
    const ids = () => fs.readdirSync(runs).filter(n => /^[a-f0-9]{8}$/.test(n)); assert.equal(ids().length, 1);
    const id = ids()[0], runDir = path.join(runs, id);
    const readLog = () => fs.readFileSync(path.join(runDir, 'log.jsonl'), 'utf8').trim().split('\n').map(JSON.parse);
    const passes = readLog().filter(e => e.event === 'pass'), reviews = readLog().filter(e => e.event === 'review');
    const blocked = passes.some(p => p.green) && passes.some(p => !p.green) && reviews.some(e => e.verdict === 'approve') && reviews.at(-1).verdict === 'changes';
    const checkpoints = files(runDir).filter(f => /checkpoint/i.test(path.basename(f)));
    assert.equal(checkpoints.length, 1, 'one checkpoint expected: ' + files(runDir).join(', '));
    const checkpointVersion = JSON.parse(fs.readFileSync(checkpoints[0], 'utf8')).version;

    // Everything the resume must leave alone.
    const gitDir = this.gitDir(), approvals = path.join(this.project, '.kogen/local/approvals'), local = path.join(this.project, '.kogen/local');
    const state = () => ({
      head: this.head(), index: fs.readFileSync(path.join(gitDir, 'index')), approvals: snapshot([approvals]), run: snapshot([runDir]),
      checkpoint: fs.readFileSync(checkpoints[0]).toString('base64'), results: snapshot(files(runDir).filter(f => /result\.json$/.test(f))),
      tree: snapshot([this.project], [path.join(this.project, '.git'), local]), status: git(this, ['status', '--porcelain', '--untracked-files=all']),
      runDirs: ids().join(','), allLocal: [...snapshot([local]).keys()].filter(k => !k.startsWith(runDir) && !k.startsWith(approvals)).sort().join('\n'),
    });
    const before = state();
    this.commandOverride = newBin;
    const newVersion = await this.invoke('kogen version');
    const requestsBefore = this.server.requests.length;
    const resumed = await this.invoke(`kogen intent resume ${id}`);
    const afterResume = state(), requestsAfterResume = this.server.requests.length;
    const inspected = await this.invoke(`kogen intent inspect ${id}`);
    const afterInspect = state();
    const eq = (a, b) => a.head === b.head && a.index.equals(b.index) && same(a.approvals, b.approvals) && same(a.run, b.run) && a.checkpoint === b.checkpoint && same(a.results, b.results) && same(a.tree, b.tree) && a.status === b.status && a.runDirs === b.runDirs && a.allLocal === b.allLocal;
    this.c3Receipt = {
      id, blocked, checkpointVersion, c3Version: c3Version.stdout.trim(), c3VersionCode: c3Version.code, candidateVersion: newVersion.stdout.trim(),
      resume: { code: resumed.code, stdout: resumed.stdout, stderr: resumed.stderr },
      inspect: { code: inspected.code, stdout: inspected.stdout, stderr: inspected.stderr },
      resumeRequests: requestsAfterResume - requestsBefore, totalRequests: this.server.requests.length,
      unchangedAfterResume: eq(before, afterResume), unchangedAfterInspect: eq(before, afterInspect),
      newRunDirs: afterInspect.runDirs.split(',').filter(n => n && n !== id).length,
    };
  });
  Then('the genuine C3 resume observations are saved', function () { fs.writeFileSync(process.env.KOGEN_C3_RECEIPT, JSON.stringify(this.c3Receipt)); });
}

// Runs the exercise in a child Cucumber process; resolves to its receipt.
async function c3ResumeObservations({ candidatePrefix, bin }) {
  assert.ok(fs.existsSync(bin), 'C3 producer executable missing: ' + bin);
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-c3-resume-'));
  try {
    const support = path.join(temp, 'test/acceptance/support'); fs.mkdirSync(support, { recursive: true });
    for (const name of ['world.js', 'fake-servers.js', 'handlers.js']) fs.copyFileSync(path.join(REPO, 'test/acceptance/support', name), path.join(support, name));
    fs.symlinkSync(path.join(REPO, 'test/acceptance/fixtures'), path.join(temp, 'test/acceptance/fixtures'), 'dir');
    fs.symlinkSync(PARENT_CUCUMBER, path.join(temp, 'test/acceptance/node_modules'), 'dir');
    const feature = path.join(temp, 'exercise.feature'), receipt = path.join(temp, 'receipt.json');
    fs.writeFileSync(feature, 'Feature: Genuine C3 checkpoint\n  Scenario: Exercise\n    Given a genuine C3 blocked review is resumed by the candidate\n    Then the genuine C3 resume observations are saved\n');
    const child = await run(PARENT_NODE, [path.join(PARENT_CUCUMBER, '@cucumber/cucumber/bin/cucumber.js'), '--strict', '--require', __filename, '--format', 'progress', feature],
      { cwd: REPO, env: { ...process.env, NODE_PATH: PARENT_CUCUMBER, KOGEN_C3_CHILD: '1', KOGEN_C3_SUPPORT: support, KOGEN_C3_PREFIX: candidatePrefix, KOGEN_C3_BIN: bin, KOGEN_C3_RECEIPT: receipt } });
    assert.equal(child.code, 0, child.output);
    return JSON.parse(fs.readFileSync(receipt, 'utf8'));
  } finally { fs.rmSync(temp, { recursive: true, force: true }); }
}
module.exports = { c3ResumeObservations };
