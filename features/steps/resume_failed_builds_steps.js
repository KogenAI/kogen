const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { Given, When, Then, Before, After, AfterAll } = require('@cucumber/cucumber');
const H = require('./go_driver_support.js');
const REPO = path.resolve(__dirname, '../..');
// The parent acceptance environment names the Node and Cucumber of the running suite; outside a Kogen acceptance run they are this process and the repository's own.
const PARENT_NODE = process.env.KOGEN_NODE || process.execPath, PARENT_CUCUMBER = process.env.KOGEN_CUCUMBER || path.join(REPO, 'test/acceptance/node_modules');
function run(program, args, options = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(program, args, { ...options, detached: true, stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '', stderr = '';
    child.stdout.on('data', b => { stdout += b; }); child.stderr.on('data', b => { stderr += b; });
    const timer = setTimeout(() => { try { process.kill(-child.pid, 'SIGKILL'); } catch {} }, 240000);
    child.on('error', e => { clearTimeout(timer); reject(e); });
    child.on('close', code => { clearTimeout(timer); resolve({ code, stdout, stderr }); });
  });
}
if (process.env.KOGEN_RESUME_CHILD === '1') {
  // Scratch copies of maintained fixtures resolve the real installed parent
  // Cucumber, not the separate test/acceptance/node_modules instance.
  const support = process.env.KOGEN_RESUME_SUPPORT;
  require(path.join(support, 'world'));
  const { dispatch } = require(path.join(support, 'handlers'));
  Before(async function () { this.prefix = process.env.KOGEN_RESUME_PREFIX; await this.setup(); this.server.commandObserver = null; });
  After(async function () { await this.cleanup(); });
  const slug = 'resume-fixture', dir = `.kogen/intents/${slug}`;
  function put(w, name, value) { const f = path.join(w.project, name); fs.mkdirSync(path.dirname(f), { recursive: true }); fs.writeFileSync(f, value); }
  function git(w, args) { const r = w.git(w.project, args, { GIT_OPTIONAL_LOCKS: '0' }); assert.equal(r.status, 0, r.stdout + r.stderr); return r.stdout.trim(); }
  function call(name, args, id) { return { type: 'function_call', id: `item_${id}`, call_id: `call_${id}`, name, arguments: JSON.stringify(args) }; }
  function custody(w) {
    const names = git(w, ['ls-files', '--cached', '--others', '--exclude-standard', '-z']).split('\0').filter(Boolean).sort();
    const files = names.map(n => { const p = path.join(w.project, n); return fs.existsSync(p) ? [n, fs.lstatSync(p).mode, fs.readFileSync(p).toString('base64')] : [n, null]; });
    return JSON.stringify([w.head(), fs.readFileSync(path.join(w.gitDir(), 'index')).toString('base64'), files]);
  }
  async function waitFile(file) { const until = Date.now() + 30000; while (!fs.existsSync(file)) { assert.ok(Date.now() < until, 'not reached: ' + file); await new Promise(r => setTimeout(r, 20)); } }
  function allFiles(folder) { return fs.existsSync(folder) ? fs.readdirSync(folder, { withFileTypes: true }).flatMap(e => e.isDirectory() ? allFiles(path.join(folder, e.name)) : [path.join(folder, e.name)]) : []; }
  Given('the native resume fixture has run', { timeout: 240000 }, async function () {
    const mode = process.env.KOGEN_RESUME_MODE;
    await this.createProject('notes'); await dispatch(this, '^the caller is signed in to ChatGPT$', []);
    put(this, '.gitignore', '.kogen/local/\n'); put(this, 'app.txt', 'baseline\n');
    // Checks run in a clean copy of the candidate, so the check keeps its record outside the checkout. Acceptance runs
    // before the checks and a failed acceptance stops the pass, so the acceptance step also accepts the repair that the
    // check itself rejects (`broken`); the check then runs on every candidate state.
    this.checkLog = path.join(this.workspace, 'check-log');
    put(this, 'validate.cjs', "const fs=require('node:fs'); const s=fs.readFileSync('app.txt','utf8').trim(); fs.appendFileSync(" + JSON.stringify(this.checkLog) + ",s+'\\n'); process.exit(s==='broken'?1:0);\n");
    put(this, '.kogen/project.yaml', `version: 1
commands:
  setup: []
  fix: []
  checks:
    - name: fixture-check
      run: '"$KOGEN_NODE" validate.cjs'
  acceptance:
    run: 'NODE_PATH="$KOGEN_CUCUMBER" "$KOGEN_NODE" "$KOGEN_CUCUMBER/@cucumber/cucumber/bin/cucumber.js" --strict --require "features/steps/*.js" --format "message:$KOGEN_ACCEPTANCE_REPORT" "$KOGEN_ACCEPTANCE_FEATURES"'
    steps_dir: features/steps
protect:
  - validate.cjs
models:
  shape: {model: gpt-6.1-sol, effort: high}
  build: {model: gpt-6.1-sol, effort: medium}
  review: {model: gpt-6.1-sol, effort: high}
`);
    git(this, ['add', '-A']); git(this, ['commit', '-qm', 'Configure native resume fixture']);
    put(this, `${dir}/intent.md`, `# Preserve candidate work

Slug: ${slug}
Model: not applicable — fixture file replacement has no state
Acceptance:
- ${dir}/acceptance.feature
- features/steps/app_steps.js

Replace baseline text with builder preserved; the reviewer may repair it to reviewer repaired.

## Decisions
- Preserve the candidate. (source: request)

## Tests
- Candidate text: fixture scenario (scenario)

## Feasibility
- none
`);
    put(this, `${dir}/acceptance.feature`, 'Feature: Candidate\n  Scenario: Candidate implementation\n    Then the fixture candidate is implemented\n');
    put(this, 'features/steps/app_steps.js', "const {Then}=require('@cucumber/cucumber'); const fs=require('node:fs'); const assert=require('node:assert/strict'); Then('the fixture candidate is implemented',()=>assert.match(fs.readFileSync('app.txt','utf8'),/^(builder preserved|reviewer repaired|broken)\\n$/));\n");
    const card = await this.invoke(`kogen intent approve ${slug}`); assert.equal(card.code, 5, card.stdout + card.stderr);
    assert.match(card.stdout, /Candidate implementation \(fails now\)/, 'readiness must report real missing-feature red');
    const hash = card.stdout.match(/^SHA-256: ([a-f0-9]{64})$/m)?.[1]; assert.ok(hash, card.stdout);
    const approved = await this.invoke(`kogen intent approve ${slug} ${hash}`); assert.equal(approved.code, 0, approved.stdout + approved.stderr);
    // Existing staged owned acceptance files are legal at Build start.
    git(this, ['add', dir, 'features/steps/app_steps.js']); const originalIndex = fs.readFileSync(path.join(this.gitDir(), 'index'));
    await dispatch(this, '^commit signing is configured with a test SSH key$', []);
    const hooks = path.join(this.gitDir(), 'hooks'); fs.mkdirSync(hooks, { recursive: true });
    fs.writeFileSync(path.join(hooks, 'pre-commit'), '#!/bin/sh\nprintf "hook\\n" >> .kogen/local/hooks\n', { mode: 0o755 });
    if (mode === 'uncertain-commit') fs.writeFileSync(path.join(hooks, 'post-commit'), '#!/bin/sh\nprintf "ready\\n" > .kogen/local/inside-commit\nsleep 600\n', { mode: 0o755 });
    const start = this.head(); this.server.configure('native-resume');
    let resuming = false, failedInput = null, nextInput = null, repairFeedback = false, repairTurns = 0;
    const reviewFailure = !['builder', 'interrupt', 'crash', 'uncertain-tool', 'landed', 'uncertain-commit'].includes(mode);
    const builderShell = "printf 'builder preserved\\n' > app.txt; printf 'once\\n' >> .kogen/local/effects" + (mode === 'uncertain-tool' ? '; printf ready > .kogen/local/inside-tool; sleep 600' : '');
    const overload = { status: 503, error: { code: 'server_error', message: 'Provider overloaded for native resume qualification' } };
    this.server.scriptResponse = (record, ordinal) => {
      if (resuming && !nextInput) nextInput = record;
      if (record.kind === 'build') {
        if (resuming && reviewFailure) throw new Error('Resume incorrectly restarted the builder');
        if (ordinal === 1) return { items: [call('shell', { command: builderShell }, 'builder_once')] };
        if (!resuming && ['interrupt', 'crash'].includes(mode)) { failedInput = record; return { hang: 'resume-request' }; }
        if (!resuming && mode === 'builder') { failedInput = record; return overload; }
        return { items: [call('finish', { summary: 'Preserved existing candidate' }, `finish_${ordinal}`)] };
      }
      if (record.kind === 'review') {
        if (reviewFailure && ordinal === 1) return { items: [call('read_file', { path: 'app.txt' }, 'independent_review_memory')] };
        if (reviewFailure && !resuming) { failedInput = record; return overload; }
        if (mode === 'repair') {
          repairTurns++;
          if (repairTurns > 1) repairFeedback = record.text.includes('Final verification') && record.text.includes('independent_review_memory');
          return { items: [call('write_file', { path: 'app.txt', content: repairTurns === 1 ? 'broken\n' : 'reviewer repaired\n' }, `repair_${ordinal}`), call('submit_review', { verdict: 'approve', findings: [] }, `approve_${ordinal}`)] };
        }
        return { items: [call('submit_review', { verdict: 'approve', findings: [] }, `approve_${ordinal}`)] };
      }
      throw new Error('Unexpected request ' + record.kind);
    };
    const background = ['interrupt', 'crash', 'uncertain-tool', 'uncertain-commit'].includes(mode);
    const first = await this.invoke(`kogen intent build ${slug}`, { background });
    if (background) {
      if (['interrupt', 'crash'].includes(mode)) await this.server.waitReached('resume-request');
      else await waitFile(path.join(this.project, '.kogen/local', mode === 'uncertain-tool' ? 'inside-tool' : 'inside-commit'));
      if (mode === 'interrupt') this.sendSignal(first, 'SIGINT');
      else process.kill(-first.child.pid, 'SIGKILL'); // the one program and everything it started stop at once
      await this.waitFor(first);
    }
    if (mode === 'landed') assert.equal(first.code, 0, first.stdout + first.stderr); else assert.notEqual(first.code, 0, 'fixture must actually stop');
    if (!background && mode !== 'landed') assert.match(first.stdout, /provider\/unavailable:.*HTTP 503/, first.stdout + first.stderr);
    assert.equal(fs.readFileSync(path.join(this.project, 'app.txt'), 'utf8'), 'builder preserved\n');
    if ((!background || mode === 'interrupt') && mode !== 'landed') assert.deepEqual(fs.readFileSync(path.join(this.gitDir(), 'index')), originalIndex, 'user index not restored');
    const runs = path.join(this.project, '.kogen/local/runs'); const entries = fs.readdirSync(runs).filter(n => /^[a-f0-9]{8}$/.test(n)); assert.equal(entries.length, 1);
    const id = entries[0], runDir = path.join(runs, id), checkpoint = path.join(runDir, 'checkpoint.json');
    const checkpointed = fs.existsSync(checkpoint);
    const history = new Map(fs.readdirSync(runDir).filter(n => n !== 'checkpoint.json').map(n => [n, fs.readFileSync(path.join(runDir, n))]));
    if (mode === 'candidate-drift') put(this, 'unrelated.txt', 'operator work\n');
    if (mode === 'staged-drift') git(this, ['add', 'app.txt']);
    if (mode === 'helper-drift') put(this, 'validate.cjs', '// changed approved check\n');
    if (mode === 'config-drift') fs.appendFileSync(path.join(this.project, '.kogen/project.yaml'), '# changed configuration\n');
    if (mode === 'approval-drift') { const p = path.join(this.project, `.kogen/local/approvals/${slug}.json`); const a = JSON.parse(fs.readFileSync(p)); a.approver = 'Different authority'; fs.writeFileSync(p, JSON.stringify(a)); }
    if (mode === 'head-drift') git(this, ['commit', '--allow-empty', '-qm', 'Move original HEAD']);
    if (mode === 'malformed') fs.writeFileSync(checkpoint, '{broken');
    if (mode === 'incompatible') { const c = checkpointed ? JSON.parse(fs.readFileSync(checkpoint)) : {}; c.version = 999; fs.writeFileSync(checkpoint, JSON.stringify(c)); }
    if (['missing', 'legacy'].includes(mode)) fs.rmSync(checkpoint, { force: true });
    if (mode === 'legacy') fs.writeFileSync(path.join(runDir, 'result.json'), JSON.stringify({ build: id, slug, outcome: 'unavailable', start_head: start }));
    if (mode === 'other-checkout') { const other = path.join(this.workspace, 'other-checkout'); fs.cpSync(this.project, other, { recursive: true }); this.project = fs.realpathSync(other); }
    let lock;
    if (mode === 'live-lock') { lock = path.join(this.project, '.kogen/local/build.lock'); fs.rmSync(lock, { recursive: true, force: true }); fs.mkdirSync(lock); fs.writeFileSync(path.join(lock, 'fixture-owner'), String(process.pid) + '\n'); }
    const before = custody(this), requestCount = this.server.requests.length; resuming = true;
    const result = await this.invoke(`kogen intent resume ${id}`); const text = result.stdout + result.stderr;
    const nativeResume = !text.includes("unknown command 'resume'") && result.code !== 2;
    const unchanged = custody(this) === before, landed = result.code === 0 && this.head() !== start, rejected = result.code !== 0 && nativeResume;
    const resumedRequests = this.server.requests.slice(requestCount);
    const expectedRefusal = /-drift$/.test(mode) || ['other-checkout', 'malformed', 'incompatible', 'missing', 'legacy', 'live-lock'].includes(mode);
    const diagnostic = /(?:resume_refused|resume_unsupported|build_running|already.landed|uncertain)/i.test(text);
    const finalContents = fs.readFileSync(path.join(this.project, 'app.txt'), 'utf8');
    const commitCount = Number(git(this, ['rev-list', '--count', `${start}..HEAD`]));
    const signed = commitCount === 1 && this.git(this.project, ['-c', `gpg.ssh.allowedSignersFile=${this.allowedSignersFile}`, 'verify-commit', 'HEAD']).status === 0;
    const sameConversation = !!failedInput && !!nextInput && nextInput.kind === failedInput.kind && JSON.stringify(nextInput.body.input.slice(0, failedInput.body.input.length)) === JSON.stringify(failedInput.body.input);
    const historyPreserved = [...history].every(([n, bytes]) => { const p = path.join(runDir, n); if (!fs.existsSync(p)) return false; const now = fs.readFileSync(p); return n === 'log.jsonl' ? now.subarray(0, bytes.length).equals(bytes) : now.equals(bytes); });
    const localFiles = allFiles(path.join(this.project, '.kogen/local/runs'));
    const results = localFiles.filter(p => p.endsWith('/result.json')).map(p => JSON.parse(fs.readFileSync(p, 'utf8')));
    const known = this.server.responses.length; // Completed responses: 100 input + 20 output each.
    const allLocal = localFiles.map(p => fs.readFileSync(p, 'utf8')).join('\n');
    this.resumeReceipt = {
      nativeResume, checkpointed, landed, sameConversation, noBuilderRestart: !resumedRequests.some(r => r.kind === 'build'), repairFeedback,
      effects: fs.readFileSync(path.join(this.project, '.kogen/local/effects'), 'utf8').trim().split('\n').length,
      commitCount, signed, finalContents, historyPreserved,
      cumulativeUsage: results.some(r => r.outcome === 'landed' && r.usage?.input === known * 100 && r.usage?.output === known * 20),
      secretsAbsent: !/KOGEN_ACCEPTANCE_(?:FAKE_ACCESS_TOKEN|FAKE_REFRESH_TOKEN|ROTATED_REFRESH_TOKEN)/.test(allLocal) && !/"authorization"\s*:/i.test(allLocal),
      checkContents: fs.readFileSync(this.checkLog, 'utf8').trim().split('\n'), hooksRan: fs.existsSync(path.join(this.project, '.kogen/local/hooks')),
      lineageVisible: text.includes(id) && /resum/i.test(text) && /resum/.test(allLocal),
      refused: expectedRefusal && rejected, untouched: unchanged, noModelOnRefusal: resumedRequests.length === 0,
      actionable: diagnostic && (mode === 'live-lock' ? /pid|running/i.test(text) : /checkpoint|approval|baseline|HEAD|index|staged|checkout|unrelated|candidate|legacy|unsupported/i.test(text)),
      alreadyLanded: result.code === 0 && /already.landed/i.test(text),
      safeBoundary: nativeResume && (mode === 'uncertain-tool' ? (landed && commitCount === 1 && signed && finalContents === 'builder preserved\n') || (rejected && unchanged && resumedRequests.length === 0 && /uncertain/i.test(text)) : commitCount === 1 && resumedRequests.length === 0 && ((result.code === 0 && /landed/i.test(text)) || (rejected && unchanged && /commit|uncertain/i.test(text)))),
      command: { code: result.code, stdout: result.stdout, stderr: result.stderr }, first: { code: first.code, stdout: first.stdout, stderr: first.stderr },
    };
    if (lock) fs.rmSync(lock, { recursive: true, force: true });
  });
  Then('the native resume fixture records observations', function () { fs.writeFileSync(process.env.KOGEN_RESUME_RECEIPT, JSON.stringify(this.resumeReceipt)); });
} else {
  let installation, installRoot;
  async function candidate() {
    if (!installation) installation = (async () => {
      // The installed candidate: the one Go program, packaged from the changed worktree (KOGEN_ARCHIVE may name a package).
      const suite = await H.setupSuite(); installRoot = suite.root; const prefix = suite.prefix;
      return prefix;
    })(); return installation;
  }
  AfterAll(function () { if (installRoot) fs.rmSync(installRoot, { recursive: true, force: true }); });
  When('I qualify native Build resume in mode {string}', { timeout: 300000 }, async function (mode) {
    const prefix = await candidate(), temp = fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-resume-harness-'));
    try {
      const support = path.join(temp, 'test/acceptance/support'); fs.mkdirSync(support, { recursive: true });
      for (const name of ['world.js', 'fake-servers.js', 'handlers.js']) fs.copyFileSync(path.join(REPO, 'test/acceptance/support', name), path.join(support, name));
      fs.symlinkSync(path.join(REPO, 'test/acceptance/fixtures'), path.join(temp, 'test/acceptance/fixtures'), 'dir');
      fs.symlinkSync(PARENT_CUCUMBER, path.join(temp, 'test/acceptance/node_modules'), 'dir');
      const feature = path.join(temp, 'exercise.feature'), receipt = path.join(temp, 'receipt.json');
      fs.writeFileSync(feature, 'Feature: Installed native resume\n  Scenario: Exercise\n    Given the native resume fixture has run\n    Then the native resume fixture records observations\n');
      const child = await run(PARENT_NODE, [path.join(PARENT_CUCUMBER, '@cucumber/cucumber/bin/cucumber.js'), '--strict', '--require', __filename, '--format', 'progress', feature], { cwd: REPO, env: { ...process.env, NODE_PATH: PARENT_CUCUMBER, KOGEN_RESUME_CHILD: '1', KOGEN_RESUME_SUPPORT: support, KOGEN_RESUME_PREFIX: prefix, KOGEN_RESUME_MODE: mode, KOGEN_RESUME_RECEIPT: receipt } });
      assert.equal(child.code, 0, child.stdout + child.stderr); this.resumeReceipt = JSON.parse(fs.readFileSync(receipt, 'utf8'));
    } finally { fs.rmSync(temp, { recursive: true, force: true }); }
  });
  Then('the native resume observations are:', function (table) {
    assert.ok(this.resumeReceipt, 'no installed observations');
    for (const [key, raw] of table.raw()) { let expected; try { expected = JSON.parse(raw); } catch { expected = raw; } assert.deepEqual(this.resumeReceipt[key], expected, `${key}: ${JSON.stringify(this.resumeReceipt)}`); }
  });
}
