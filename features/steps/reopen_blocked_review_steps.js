const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { Given, When, Then, Before, After, AfterAll } = require('@cucumber/cucumber');
const REPO = path.resolve(__dirname, '../..');
function run(file, args, opts = {}) {
  return new Promise((resolve, reject) => {
    const p = spawn(file, args, { ...opts, detached: true, stdio: ['ignore', 'pipe', 'pipe'] });
    let output = '';
    p.stdout.on('data', b => { output += b; }); p.stderr.on('data', b => { output += b; });
    const timer = setTimeout(() => { try { process.kill(-p.pid, 'SIGKILL'); } catch {} }, 240000);
    p.on('error', e => { clearTimeout(timer); reject(e); });
    p.on('close', code => { clearTimeout(timer); resolve({ code, output }); });
  });
}
if (process.env.KOGEN_REOPEN_CHILD === '1') {
  const support = process.env.KOGEN_REOPEN_SUPPORT;
  require(path.join(support, 'world'));
  const { dispatch } = require(path.join(support, 'handlers'));
  Before(async function () { this.prefix = process.env.KOGEN_REOPEN_PREFIX; await this.setup(); this.server.commandObserver = null; });
  After(async function () { await this.cleanup(); });
  const slug = 'reopen-fixture', dir = `.kogen/intents/${slug}`;
  const finding = 'Synthetic external host unavailable; final application checks not established';
  function put(w, name, value) { const p = path.join(w.project, name); fs.mkdirSync(path.dirname(p), { recursive: true }); fs.writeFileSync(p, value); }
  function git(w, args) { const r = w.git(w.project, args, { GIT_OPTIONAL_LOCKS: '0' }); assert.equal(r.status, 0, r.stdout + r.stderr); return r.stdout.trim(); }
  function call(name, args, id) { return { type: 'function_call', id: `item_${id}`, call_id: `call_${id}`, name, arguments: JSON.stringify(args) }; }
  function files(dir) { return fs.existsSync(dir) ? fs.readdirSync(dir, { withFileTypes: true }).flatMap(e => e.isDirectory() ? files(path.join(dir, e.name)) : [path.join(dir, e.name)]) : []; }
  function history(dir) { return new Map(files(dir).map(p => [p, fs.readFileSync(p)])); }
  function preserved(h) { return [...h].every(([p, b]) => fs.existsSync(p) && fs.readFileSync(p).equals(b)); }
  async function reachedOrEnded(record, test) {
    const until = Date.now() + 20000;
    while (!test() && record.code === null && Date.now() < until) await new Promise(r => setTimeout(r, 20));
    return test();
  }
  Given('the synthetic blocked reviewer exercise runs', { timeout: 240000 }, async function () {
    const mode = process.env.KOGEN_REOPEN_MODE, cross = process.env.KOGEN_REOPEN_SOURCE === 'retained';
    await this.createProject('notes'); await dispatch(this, '^the caller is signed in to ChatGPT$', []);
    const trace = path.join(this.workspace, 'trace'), host = path.join(this.workspace, 'host'), marker = path.join(this.workspace, 'paused');
    fs.writeFileSync(trace, ''); fs.writeFileSync(host, 'green');
    this.extraEnv = { RB_TRACE: trace, RB_HOST: host, RB_MARKER: marker };
    put(this, '.gitignore', '.kogen/local/\n'); put(this, 'app.txt', 'baseline\n');
    put(this, 'gate.cjs', `const fs=require('node:fs'); const name=process.argv[2], host=fs.readFileSync(process.env.RB_HOST,'utf8'); fs.appendFileSync(process.env.RB_TRACE,JSON.stringify([fs.realpathSync('.'),fs.readFileSync('app.txt','utf8').trim(),name])+'\\n'); if(host==='pause'&&name==='setup'){fs.writeFileSync(process.env.RB_MARKER,'ready');setInterval(()=>{},1000);} else if((host==='setup-red'&&name==='setup')||(host==='red'&&name==='project')){console.log('synthetic-'+host+'-failure');process.exit(19);}\n`);
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
    const originalPaths = ['gate.cjs', '.kogen/project.yaml', `${dir}/intent.md`, `${dir}/acceptance.feature`, `${dir}/model.qnt`, 'features/steps/app_steps.js'];
    const baseline = new Map(originalPaths.map(p => [path.join(this.project, p), fs.readFileSync(path.join(this.project, p))]));
    const newBin = path.join(this.prefix, 'bin/kogen');
    this.commandOverride = cross ? process.env.KOGEN_REOPEN_OLD_BIN : newBin;
    const oldVersion = await this.invoke('kogen version');
    if (cross) assert.match(oldVersion.stdout, /kogen c3ee2a8e /);
    const card = await this.invoke(`kogen intent approve ${slug}`); assert.equal(card.code, 5, card.stdout + card.stderr);
    assert.match(card.stdout, /Candidate implementation \(fails now\)/);
    const hash = card.stdout.match(/^SHA-256: ([a-f0-9]{64})$/m)?.[1]; assert.ok(hash, card.stdout);
    const approved = await this.invoke(`kogen intent approve ${slug} ${hash}`); assert.equal(approved.code, 0, approved.stdout + approved.stderr);
    git(this, ['add', dir, 'features/steps/app_steps.js']);
    const index = fs.readFileSync(path.join(this.gitDir(), 'index')), approvalPath = path.join(this.project, `.kogen/local/approvals/${slug}.json`), approvalBytes = fs.readFileSync(approvalPath);
    await dispatch(this, '^commit signing is configured with a test SSH key$', []);
    const hook = path.join(this.gitDir(), 'hooks/pre-commit'); fs.writeFileSync(hook, '#!/bin/sh\nprintf "hook\\n" >> .kogen/local/hooks\n', { mode: 0o755 });
    const start = this.head(); this.server.configure('native-reopen');
    let resuming = false, blockedInput, firstResumeInput, hangReview = false, hangReached = false;
    let resumedReviews = [], decisions = 0;
    this.server.scriptResponse = (record, ordinal) => {
      if (record.kind === 'build') {
        assert.ok(!resuming, 'must not restart builder');
        if (ordinal === 1) return { items: [call('shell', { command: "printf 'builder preserved\\n' > app.txt; printf 'once\\n' >> .kogen/local/effects" }, 'builder_once')] };
        assert.ok(ordinal <= 2, 'bounded builder fixture');
        return { items: [call('finish', { summary: 'candidate ready' }, 'finish')] };
      }
      assert.equal(record.kind, 'review');
      if (!resuming) {
        if (ordinal === 1) return { items: [call('read_file', { path: 'app.txt' }, 'independent_memory')] };
        if (ordinal === 2) {
          fs.writeFileSync(host, 'setup-red');
          return { items: [call('write_file', { path: 'app.txt', content: 'reviewer repaired\n' }, 'reviewer_edit'), call('submit_review', { verdict: 'approve', findings: [] }, 'old_approval')] };
        }
        assert.equal(ordinal, 3, 'final failure must reach the original reviewer');
        assert.match(record.text, /synthetic-setup-red-failure/); blockedInput = record.body.input;
        return { items: [call('submit_review', { verdict: 'changes', findings: [{ path: 'gate.cjs', line: 1, severity: 'blocking', message: finding }] }, 'original_blocker')] };
      }
      firstResumeInput ||= record.body.input; resumedReviews.push(record);
      if (hangReview) { hangReached = true; return { hang: 'reopened-review-request' }; }
      decisions++;
      assert.ok(decisions <= 3, 'bounded continued reviewer fixture');
      const negative = ['keep', 'red', 'setup-red'].includes(mode);
      return { items: (mode === 'repair' ? [call('write_file', { path: 'app.txt', content: 'cleared repair\n' }, 'targeted_repair')] : []).concat([call('submit_review', { verdict: negative ? 'changes' : 'approve', findings: negative ? [{ path: 'gate.cjs', line: 1, severity: 'blocking', message: finding }] : [] }, `new_decision_${decisions}`)]) };
    };
    const first = await this.invoke(`kogen intent build ${slug}`);
    assert.equal(first.code, 1, first.stdout + first.stderr); assert.match(first.stdout, /candidate\/review_blocked/);
    assert.equal(this.head(), start); assert.deepEqual(fs.readFileSync(path.join(this.gitDir(), 'index')), index);
    assert.equal(fs.readFileSync(path.join(this.project, 'app.txt'), 'utf8'), 'reviewer repaired\n');
    const runs = path.join(this.project, '.kogen/local/runs');
    const ids = () => fs.readdirSync(runs).filter(n => /^[a-f0-9]{8}$/.test(n)); assert.equal(ids().length, 1);
    const rootId = ids()[0], initialHistory = history(path.join(runs, rootId));
    const readLogs = id => fs.readFileSync(path.join(runs, id, 'log.jsonl'), 'utf8').trim().split('\n').map(JSON.parse);
    const initialLogs = readLogs(rootId), initialPasses = initialLogs.filter(e => e.event === 'pass');
    assert.ok(initialPasses.some(p => p.green) && initialPasses.some(p => !p.green), 'must reproduce green then failed final verification');
    assert.ok(initialLogs.some(e => e.event === 'review' && e.verdict === 'approve') && initialLogs.some(e => e.event === 'review' && e.verdict === 'changes'));
    this.commandOverride = newBin;
    const newVersion = await this.invoke('kogen version');
    const modelAt = this.server.requests.length; resuming = true;
    fs.writeFileSync(trace, ''); fs.writeFileSync(host, mode === 'red' ? 'red' : mode === 'setup-red' ? 'setup-red' : mode === 'interrupt-verify' ? 'pause' : 'green');
    hangReview = mode === 'interrupt-review';
    let interruptionReached = false, interruptionSafe = false, interruptedHistory = new Map();
    let current = rootId;
    const invokeResume = async background => this.invoke(`kogen intent resume ${current}`, { background });
    let result;
    if (mode.startsWith('interrupt-')) {
      const p = await invokeResume(true);
      interruptionReached = await reachedOrEnded(p, () => mode === 'interrupt-verify' ? fs.existsSync(marker) : hangReached);
      if (interruptionReached) this.sendSignal(p, 'SIGINT');
      await this.waitFor(p);
      interruptionSafe = interruptionReached && p.code !== 0 && this.head() === start && fs.readFileSync(path.join(this.gitDir(), 'index')).equals(index) && fs.readFileSync(approvalPath).equals(approvalBytes);
      const next = ids().filter(n => n !== rootId); assert.equal(next.length, 1); current = next[0];
      interruptedHistory = history(path.join(runs, current));
      fs.writeFileSync(host, 'green'); hangReview = false;
      result = await invokeResume(false);
    } else result = await invokeResume(false);
    const firstRetryIds = ids().filter(n => n !== rootId);
    const traceRows = () => fs.readFileSync(trace, 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse);
    const firstRows = traceRows();
    let repeatedSafe = false;
    const negative = ['keep', 'red', 'setup-red'].includes(mode);
    let repeatedHistory = new Map();
    if (negative) {
      const beforeCount = firstRows.length;
      assert.equal(firstRetryIds.length, 1); current = firstRetryIds[0]; repeatedHistory = history(path.join(runs, current));
      const before = this.head();
      const retry = await invokeResume(false);
      repeatedSafe = result.code === 1 && retry.code === 1 && this.head() === before && traceRows().length > beforeCount && decisions === 2 && /review_blocked/.test(retry.stdout);
      result = retry;
    }
    const allIds = ids(), results = allIds.map(id => JSON.parse(fs.readFileSync(path.join(runs, id, 'result.json'), 'utf8')));
    const logs = allIds.filter(id => id !== rootId).flatMap(readLogs);
    const pass = logs.filter(e => e.event === 'pass');
    const count = Number(git(this, ['rev-list', '--count', `${start}..HEAD`]));
    const signed = count === 1 && this.git(this.project, ['-c', `gpg.ssh.allowedSignersFile=${this.allowedSignersFile}`, 'verify-commit', 'HEAD']).status === 0;
    const finalApp = mode === 'repair' ? 'cleared repair' : 'reviewer repaired';
    const exact = count === 1 && git(this, ['show', 'HEAD:app.txt']) === finalApp && git(this, ['rev-parse', 'HEAD^{tree}']) === git(this, ['write-tree']);
    const signedLanding = result.code === 0 && signed && exact && fs.existsSync(path.join(this.project, '.kogen/local/hooks'));
    const sameReviewer = resumedReviews.length > 0 && resumedReviews.every(r => r.text.includes('independent_memory') && r.text.includes('original_blocker') && r.text.includes(finding) && JSON.stringify(r.body.input.slice(0, blockedInput.length)) === JSON.stringify(blockedInput));
    const feedback = resumedReviews.map(r => r.text).join('\n');
    const expectedTrace = mode === 'setup-red' ? ['setup'] : ['setup', 'acceptance', 'project'];
    const rows = firstRows.filter(r => r[0] !== this.project && r[1] === 'reviewer repaired').map(r => r[2]);
    const freshObserved = JSON.stringify(rows) === JSON.stringify(expectedTrace) && pass.length > 0;
    const modelGreen = logs.some(e => e.event === 'command_result' && e.name === 'model' && e.status === 0);
    const freshComplete = mode.startsWith('interrupt-') ? traceRows().filter(r => r[0] !== this.project && r[1] === 'reviewer repaired').some(r => r[2] === 'project') && modelGreen && pass.some(e => e.green && (!e.not_run || e.not_run.length === 0)) : freshObserved && modelGreen && pass.some(e => e.green && (!e.not_run || e.not_run.length === 0));
    const honestResults = mode === 'red' ? feedback.includes('synthetic-red-failure') && pass.every(p => !p.green) : mode === 'setup-red' ? feedback.includes('synthetic-setup-red-failure') && /not.run|unrun|skipped/i.test(feedback) && pass.every(p => !p.green) : freshComplete;
    const last = results.find(r => r.build !== rootId && r.outcome === (negative ? 'review_blocked' : 'landed') && r.usage?.input === this.server.responses.length * 100);
    const noCommit = count === 0 && this.head() === start;
    const custody = (negative ? noCommit && fs.readFileSync(path.join(this.gitDir(), 'index')).equals(index) && fs.readFileSync(approvalPath).equals(approvalBytes) : signedLanding) && preserved(baseline) && fs.readFileSync(path.join(this.project, '.kogen/local/effects'), 'utf8').trim() === 'once' && allIds.every(id => fs.readFileSync(path.join(runs, id, 'index-at-start')).equals(index));
    const lineage = results.filter(r => r.build !== rootId).every(r => r.root_build === rootId && allIds.includes(r.resumed_from)) && results.length >= 2;
    this.reopenReceipt = {
      reproduced: true, freshObserved, freshComplete, sameReviewer, honestResults, repeatedSafe,
      newDecision: decisions > 0 && signedLanding, signedLanding, noCommit,
      expectedOutcome: negative ? noCommit && repeatedSafe && honestResults : signedLanding && freshComplete && decisions > 0,
      repairVerified: mode === 'repair' && traceRows().filter(r => r[0] !== this.project && r[1] === 'cleared repair').map(r => r[2]).join(',') === 'setup,acceptance,project' && signedLanding,
      interruptionReached, interruptionSafe, custody,
      history: preserved(initialHistory) && preserved(interruptedHistory) && preserved(repeatedHistory), lineage,
      usage: !!last && last.usage.output === this.server.responses.length * 20 && (mode !== 'interrupt-review' || last.unknown_requests >= 1),
      noBuilderRestart: !this.server.requests.slice(modelAt).some(r => r.kind === 'build'),
      crossVersion: cross && /kogen c3ee2a8e /.test(oldVersion.stdout) && oldVersion.code === 0 && newVersion.code === 0,
      diagnostic: { result: result.stdout + result.stderr, oldVersion: oldVersion.stdout, newVersion: newVersion.stdout, rows, passes: pass, requests: resumedReviews.length }
    };
  });
  Then('the synthetic blocked reviewer observations are saved', function () { fs.writeFileSync(process.env.KOGEN_REOPEN_RECEIPT, JSON.stringify(this.reopenReceipt)); });
} else {
  let installation, work;
  async function candidate() {
    if (!installation) installation = (async () => {
      work = fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-reopen-install-'));
      if (process.env.KOGEN_REOPEN_NEW_BIN) return path.dirname(path.dirname(path.resolve(process.env.KOGEN_REOPEN_NEW_BIN)));
      const packed = await run('/bin/sh', ['packaging/package.sh'], { cwd: REPO, env: { ...process.env, ERL_FLAGS: process.env.ERL_FLAGS || '+S 2:2 +SDcpu 1 +SDio 1' } });
      assert.equal(packed.code, 0, packed.output);
      const archive = packed.output.split('\n').find(s => s.startsWith('/') && s.endsWith('.tar.gz')); assert.ok(archive && fs.existsSync(archive), packed.output);
      const extract = path.join(work, 'extract'); fs.mkdirSync(extract);
      const unpack = await run('tar', ['-xzf', archive, '-C', extract]); assert.equal(unpack.code, 0, unpack.output);
      const entries = fs.readdirSync(extract); assert.equal(entries.length, 1);
      const prefix = path.join(work, 'prefix');
      const install = await run('/bin/sh', [path.join(extract, entries[0], 'install.sh'), '--prefix', prefix], { env: { ...process.env, HOME: work } }); assert.equal(install.code, 0, install.output);
      if (process.platform === 'darwin') {
        const sign = await run('codesign', ['--force', '--sign', '-', path.join(prefix, 'bin/kogen')]); assert.equal(sign.code, 0, sign.output);
        const verify = await run('codesign', ['--verify', path.join(prefix, 'bin/kogen')]); assert.equal(verify.code, 0, verify.output);
      }
      return prefix;
    })(); return installation;
  }
  AfterAll(() => { if (work) fs.rmSync(work, { recursive: true, force: true }); });
  Given('the blocked review qualification uses retained executable {string}', function (old) { this.reopenOld = process.env.KOGEN_REOPEN_OLD_BIN || old; });
  When('I qualify blocked review retry {string} using {string}', { timeout: 300000 }, async function (mode, source) {
    const prefix = await candidate(), temp = fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-reopen-harness-'));
    try {
      assert.ok(process.env.KOGEN_NODE && process.env.KOGEN_CUCUMBER, 'use the installed parent Cucumber');
      if (source === 'retained') {
        assert.ok(fs.existsSync(this.reopenOld), 'retained C3 qualification input missing');
        if (process.platform === 'darwin') { const v = await run('codesign', ['--verify', this.reopenOld]); assert.equal(v.code, 0, v.output); }
      }
      const support = path.join(temp, 'test/acceptance/support'); fs.mkdirSync(support, { recursive: true });
      for (const name of ['world.js', 'fake-servers.js', 'handlers.js']) fs.copyFileSync(path.join(REPO, 'test/acceptance/support', name), path.join(support, name));
      fs.symlinkSync(path.join(REPO, 'test/acceptance/fixtures'), path.join(temp, 'test/acceptance/fixtures'), 'dir');
      fs.symlinkSync(process.env.KOGEN_CUCUMBER, path.join(temp, 'test/acceptance/node_modules'), 'dir');
      const feature = path.join(temp, 'exercise.feature'), receipt = path.join(temp, 'receipt.json');
      fs.writeFileSync(feature, 'Feature: Synthetic blocked reviewer\n  Scenario: Exercise\n    Given the synthetic blocked reviewer exercise runs\n    Then the synthetic blocked reviewer observations are saved\n');
      const child = await run(process.env.KOGEN_NODE, [path.join(process.env.KOGEN_CUCUMBER, '@cucumber/cucumber/bin/cucumber.js'), '--strict', '--require', __filename, '--format', 'progress', feature], { cwd: REPO, env: { ...process.env, NODE_PATH: process.env.KOGEN_CUCUMBER, KOGEN_REOPEN_CHILD: '1', KOGEN_REOPEN_SUPPORT: support, KOGEN_REOPEN_PREFIX: prefix, KOGEN_REOPEN_MODE: mode, KOGEN_REOPEN_SOURCE: source, KOGEN_REOPEN_OLD_BIN: this.reopenOld, KOGEN_REOPEN_RECEIPT: receipt } });
      assert.equal(child.code, 0, child.output); this.reopenReceipt = JSON.parse(fs.readFileSync(receipt, 'utf8'));
      await this.attach(JSON.stringify(this.reopenReceipt), 'application/json');
    } finally { fs.rmSync(temp, { recursive: true, force: true }); }
  });
  Then('the blocked review observations include:', function (table) {
    assert.ok(this.reopenReceipt, 'missing installed observations');
    for (const [key, raw] of table.raw()) assert.deepEqual(this.reopenReceipt[key], JSON.parse(raw), `${key}: ${JSON.stringify(this.reopenReceipt)}`);
  });
}
