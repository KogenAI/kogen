const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');
const REPO = path.resolve(__dirname, '../..');
const { Given, When, Then, Before, After, AfterAll } = require('@cucumber/cucumber');

function run(program, args, options = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(program, args, { ...options, detached: true, stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '', stderr = '';
    child.stdout.on('data', b => { stdout += b; });
    child.stderr.on('data', b => { stderr += b; });
    const timer = setTimeout(() => { try { process.kill(-child.pid, 'SIGKILL'); } catch {} }, 240000);
    child.on('error', e => { clearTimeout(timer); reject(e); });
    child.on('close', code => { clearTimeout(timer); resolve({ code, stdout, stderr }); });
  });
}

if (process.env.KOGEN_READY_CHILD === '1') {
  require(path.join(REPO, 'test/acceptance/support/world'));
  const { dispatch } = require(path.join(REPO, 'test/acceptance/support/handlers'));
  Before(async function () {
    this.prefix = process.env.KOGEN_READY_PREFIX;
    await this.setup();
  });
  After(async function () { await this.cleanup(); });
  const slug = 'ready-fixture';
  const dir = `.kogen/intents/${slug}`;
  const step = 'features/steps/ready_fixture.js';
  function put(w, p, text) {
    fs.mkdirSync(path.dirname(path.join(w.project, p)), { recursive: true });
    fs.writeFileSync(path.join(w.project, p), text);
  }
  function git(w, args) {
    const r = w.git(w.project, args);
    assert.equal(r.status, 0, r.stdout + r.stderr);
    return r.stdout.trim();
  }
  function call(name, args, n) {
    return { type: 'function_call', id: `item_${n}`, call_id: `call_${n}`, name, arguments: JSON.stringify(args) };
  }
  function files() {
    return [
      { path: `${dir}/intent.md`, content: `# Check readiness evidence

Slug: ${slug}
Model: ${dir}/model.qnt invariants=Nonnegative seed=7 samples=10 steps=5
Acceptance:
- ${dir}/acceptance.feature
- ${step}

Exercise an installed readiness card with mixed current scenario results.

## Decisions
- Keep both passing and failing examples. (source: request)

## Source comparison
- addressed: passing and failing examples both stay visible; source request; contract Tests and acceptance.feature.

## Tests
- Current results are visible: readiness fixture scenarios (scenario)

## Feasibility
- none
` },
      { path: `${dir}/acceptance.feature`, content: 'Feature: Readiness fixture\n  Scenario: Passing case\n    Then the readiness fixture passes\n  Scenario Outline: Failing cases\n    Then the readiness fixture fails for <value>\n    Examples:\n      | value |\n      | one   |\n      | two   |\n' },
      { path: `${dir}/model.qnt`, content: 'module fixture {\n var count: int\n action init = all { count\' = 0 }\n action step = all { count\' = count + 1 }\n val Nonnegative = count >= 0\n}\n' },
      { path: step, content: "const { Then } = require('@cucumber/cucumber');\nconst assert = require('node:assert/strict');\nThen('the readiness fixture passes', function () { assert.ok(true); });\nThen(/^the readiness fixture fails for (one|two)$/, function () { assert.fail('intentional current failure'); });\n" },
    ];
  }
  Given('the installed readiness evidence exercise has run', { timeout: 240000 }, async function () {
    await this.createProject('notes');
    await dispatch(this, '^the caller is signed in to ChatGPT$', []);
    const trace = path.join(this.workspace, 'readiness-executions');
    const runner = `const fs = require('node:fs');\nconst { spawnSync } = require('node:child_process');\nconst feature = fs.readFileSync(process.env.KOGEN_ACCEPTANCE_FEATURES, 'utf8');\nif (/Scenario(?: Outline)?:/.test(feature)) fs.appendFileSync(${JSON.stringify(trace)}, 'run\\n');\nconst r = spawnSync(process.env.KOGEN_NODE, [process.env.KOGEN_CUCUMBER + '/@cucumber/cucumber/bin/cucumber.js', '--strict', '--require', 'features/steps/*.js', '--format', 'message:' + process.env.KOGEN_ACCEPTANCE_REPORT, process.env.KOGEN_ACCEPTANCE_FEATURES], { stdio: 'inherit', env: { ...process.env, NODE_PATH: process.env.KOGEN_CUCUMBER } });\nprocess.exit(r.status === null ? 99 : r.status);\n`;
    put(this, 'readiness-runner.cjs', runner);
    put(this, '.gitignore', '.kogen/local/\n');
    put(this, '.kogen/project.yaml', `version: 1
commands:
  setup: []
  fix: []
  checks: []
  acceptance:
    run: '"$KOGEN_NODE" readiness-runner.cjs'
    steps_dir: features/steps
protect: []
models:
  shape: {model: gpt-6.1-sol, effort: high}
  build: {model: gpt-6.1-sol, effort: medium}
  review: {model: gpt-6.1-sol, effort: high}
`);
    git(this, ['add', '-A']);
    git(this, ['commit', '-qm', 'Configure readiness regression']);
    const originalHead = this.head();
    const pkg = files();
    const refinedStep = pkg.find(f => f.path === step).content.replace('assert.ok(true)', "assert.fail('refined current failure')");
    this.server.configure('independent-ready-evidence');
    this.server.scriptResponse = (record, ordinal) => {
      if (record.kind === 'shape') return { items: [call('read_file', { path: 'README.md' }, `shape_${ordinal}_readme`), call('submit', { files: pkg }, `shape_${ordinal}`)] };
      if (record.kind === 'refine') return { items: [call('submit_refinement', { files: [{ path: step, content: refinedStep }] }, `refine_${ordinal}`)] };
      throw new Error('Readiness must not request ' + record.kind);
    };
    const count = () => fs.existsSync(trace) ? fs.readFileSync(trace, 'utf8').trim().split('\n').filter(Boolean).length : 0;
    const receipt = { commands: {} };
    const invoke = async (name, cmd, stdin) => {
      const before = count();
      const r = await this.invoke(cmd, stdin === undefined ? {} : { stdin });
      receipt.commands[name] = { code: r.code, stdout: r.stdout, stderr: r.stderr, executions: count() - before };
      return r;
    };
    const shape = await invoke('shape', `kogen intent shape ${slug} -`, 'Create the readiness fixture.');
    assert.equal(shape.code, 0, shape.stdout + shape.stderr);
    receipt.shapeExecutions = receipt.commands.shape.executions;
    receipt.shapeMetadata = shape.stdout.includes('Scenarios: 3 (2 fail now, 1 pass now)') && shape.stdout.includes(`Model: ${dir}/model.qnt invariants=Nonnegative seed=7 samples=10 steps=5`);
    const first = await invoke('firstCard', `kogen intent approve ${slug}`);
    assert.equal(first.code, 5, first.stdout + first.stderr);
    const hash = first.stdout.match(/^SHA-256: ([a-f0-9]{64})$/m)?.[1];
    assert.ok(hash, 'card must expose full baseline SHA-256');
    const second = await invoke('secondCard', `kogen intent approve ${slug}`);
    receipt.firstCardExecutions = receipt.commands.firstCard.executions;
    receipt.secondCardExecutions = receipt.commands.secondCard.executions;
    receipt.cardsIdentical = first.stdout === second.stdout && second.code === 5;
    receipt.initialAcceptance = first.stdout.split('\n').filter(l => /^  - .*\((passes|fails) now\)$/.test(l)).map(l => l.trim().slice(2));
    receipt.noApprovalFromCards = !fs.existsSync(path.join(this.project, `.kogen/local/approvals/${slug}.json`));
    const mode = process.env.KOGEN_READY_CASE;
    if (mode === 'shape') {
      const mismatch = await invoke('mismatch', `kogen intent approve ${slug} ${hash === '0'.repeat(64) ? '1'.repeat(64) : '0'.repeat(64)}`);
      receipt.mismatchRefused = mismatch.code === 1 && mismatch.stdout.includes('intent/hash_mismatch:') && receipt.commands.mismatch.executions === 0;
      const approval = await invoke('approval', `kogen intent approve ${slug} ${hash}`);
      receipt.approvalCode = approval.code;
      receipt.approvalExecutions = receipt.commands.approval.executions;
      const record = JSON.parse(fs.readFileSync(path.join(this.project, `.kogen/local/approvals/${slug}.json`), 'utf8'));
      receipt.approvalBindsCard = record.sha256 === hash;
    } else if (mode === 'refine') {
      const refined = await invoke('refine', `kogen intent refine ${slug} ${hash} -`, 'Change the passing fixture step to a failing assertion; preserve all other bytes.');
      assert.equal(refined.code, 0, refined.stdout + refined.stderr);
      receipt.refineChecked = receipt.commands.refine.executions > 0;
      const card = await invoke('refinedCard', `kogen intent approve ${slug}`);
      const newHash = card.stdout.match(/^SHA-256: ([a-f0-9]{64})$/m)?.[1];
      receipt.refinedHashChanged = Boolean(newHash && newHash !== hash);
      receipt.refinedAcceptance = card.stdout.split('\n').filter(l => /^  - .*\((passes|fails) now\)$/.test(l)).map(l => l.trim().slice(2));
      receipt.refinedCardExecutions = receipt.commands.refinedCard.executions;
      receipt.refinementUnapproved = !fs.existsSync(path.join(this.project, `.kogen/local/approvals/${slug}.json`));
      const repeat = await invoke('refinedRepeat', `kogen intent approve ${slug}`);
      receipt.refinedCardsIdentical = repeat.code === 5 && card.stdout === repeat.stdout;
      receipt.refinedRepeatExecutions = receipt.commands.refinedRepeat.executions;
      const approval = await invoke('approval', `kogen intent approve ${slug} ${newHash}`);
      receipt.approvalCode = approval.code;
      receipt.approvalExecutions = receipt.commands.approval.executions;
    } else {
      const evidence = path.join(this.project, `.kogen/local/readiness/${slug}.json`);
      if (mode === 'absent') fs.rmSync(evidence, { force: true });
      else if (mode === 'malformed') fs.writeFileSync(evidence, '{not json');
      else if (mode === 'legacy') fs.writeFileSync(evidence, JSON.stringify({ sha256: hash, head: this.head() }));
      else if (mode === 'baseline') {
        // The shaped source provenance is bound to the contract it was shaped with and a changed baseline refuses before
        // readiness; this scenario is about readiness, so the project is the one without recorded provenance.
        fs.rmSync(path.join(this.project, '.kogen/local/provenance', slug), { recursive: true, force: true });
        put(this, step, "const { Then } = require('@cucumber/cucumber');\nThen('a different unrelated step', function () {});\n");
      } else if (mode === 'head') {
        put(this, 'readiness-runner.cjs', runner.split('const r = spawnSync')[0] + "console.log('fresh HEAD readiness runner failure'); process.exit(17);\n");
        git(this, ['add', 'readiness-runner.cjs']);
        git(this, ['commit', '-qm', 'Change HEAD readiness runner']);
      } else throw new Error('Unknown readiness exercise ' + mode);
      const fresh = await invoke('fresh', `kogen intent approve ${slug}`);
      const repeat = await invoke('freshRepeat', `kogen intent approve ${slug}`);
      receipt.freshExecutions = receipt.commands.fresh.executions;
      receipt.freshRepeatExecutions = receipt.commands.freshRepeat.executions;
      receipt.freshCode = fresh.code;
      receipt.freshRepeatCode = repeat.code;
      receipt.freshDiagnostic = mode === 'baseline' ? fresh.stdout.includes('intent/not_ready:') && fresh.stdout.includes('undefined step: Then the readiness fixture passes') && fresh.stdout.includes('undefined step: Then the readiness fixture fails for one') && fresh.stdout.includes('undefined step: Then the readiness fixture fails for two') : mode === 'head' ? fresh.stdout.includes('report_missing: the acceptance command exited 17') && fresh.stdout.includes('fresh HEAD readiness runner failure') : fresh.stdout.includes('Approve with:');
      receipt.noFalseCard = ['baseline', 'head'].includes(mode) ? !fresh.stdout.includes('Approve with:') && !repeat.stdout.includes('Approve with:') : fresh.stdout === repeat.stdout;
      receipt.stillUnapproved = !fs.existsSync(path.join(this.project, `.kogen/local/approvals/${slug}.json`));
    }
    receipt.noBuild = !this.server.requests.some(r => ['build', 'review'].includes(r.kind));
    receipt.headUnchanged = this.head() === originalHead;
    this.readyReceipt = receipt;
  });
  Then('the installed readiness exercise records observations', function () {
    fs.writeFileSync(process.env.KOGEN_READY_RECEIPT, JSON.stringify(this.readyReceipt));
  });
} else {
  let installation;
  let installRoot;
  async function candidate() {
    if (!installation) installation = (async () => {
      installRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-ready-candidate-'));
      // Package the current worktree AFTER Build edits (the one Go program). Never use latestArchive,
      // KOGEN_ARCHIVE, or the driving engine's installation as the candidate.
      const packed = await run('/bin/sh', ['packaging/package.sh'], { cwd: REPO, env: process.env });
      assert.equal(packed.code, 0, packed.stdout + packed.stderr);
      const archive = packed.stdout.trim().split('\n').at(-1);
      assert.ok(path.isAbsolute(archive) && fs.existsSync(archive), packed.stdout);
      const extracted = path.join(installRoot, 'extract');
      fs.mkdirSync(extracted);
      const unpacked = await run('tar', ['-xzf', archive, '-C', extracted]);
      assert.equal(unpacked.code, 0, unpacked.stderr);
      const entries = fs.readdirSync(extracted);
      assert.equal(entries.length, 1);
      const prefix = path.join(installRoot, 'prefix');
      const installed = await run('/bin/sh', [path.join(extracted, entries[0], 'install.sh'), '--prefix', prefix], { env: { ...process.env, HOME: installRoot } });
      assert.equal(installed.code, 0, installed.stdout + installed.stderr);
      return prefix;
    })();
    return installation;
  }
  AfterAll(function () { if (installRoot) fs.rmSync(installRoot, { recursive: true, force: true }); });
  When('I exercise installed readiness evidence in mode {string}', { timeout: 300000 }, async function (mode) {
    const prefix = await candidate();
    const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-ready-exercise-'));
    try {
      const feature = path.join(temp, 'exercise.feature');
      const receipt = path.join(temp, 'receipt.json');
      fs.writeFileSync(feature, 'Feature: Installed readiness evidence\n  Scenario: Exercise\n    Given the installed readiness evidence exercise has run\n    Then the installed readiness exercise records observations\n');
      const result = await run(process.execPath, [path.join(REPO, 'test/acceptance/node_modules/@cucumber/cucumber/bin/cucumber.js'), '--strict', '--require', __filename, '--format', 'progress', feature], { cwd: REPO, env: { ...process.env, NODE_PATH: path.join(REPO, 'test/acceptance/node_modules'), KOGEN_READY_CHILD: '1', KOGEN_READY_PREFIX: prefix, KOGEN_READY_CASE: mode, KOGEN_READY_RECEIPT: receipt } });
      assert.equal(result.code, 0, result.stdout + result.stderr);
      this.readyReceipt = JSON.parse(fs.readFileSync(receipt, 'utf8'));
    } finally { fs.rmSync(temp, { recursive: true, force: true }); }
  });
  Then('the readiness evidence observations are:', function (table) {
    assert.ok(this.readyReceipt, 'missing installed observations');
    for (const [key, raw] of table.raw()) {
      let expected;
      try { expected = JSON.parse(raw); } catch { expected = raw; }
      assert.deepEqual(this.readyReceipt[key], expected, `${key}: ${JSON.stringify(this.readyReceipt)}`);
    }
  });
}
