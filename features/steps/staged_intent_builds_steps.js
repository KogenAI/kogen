const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');
const ROOT = path.resolve(__dirname, '../..');

// One observer for native receipts and controls. Compare parsed objects semantically;
// array order and every string byte remain significant. Never accept stdout as a receipt.
function check(receipt, rows) {
  for (const [key, text] of rows) {
    assert.ok(Object.hasOwn(receipt, key), 'missing observation: ' + key);
    assert.deepEqual(receipt[key], JSON.parse(text), key + ': ' + JSON.stringify(receipt));
  }
}

if (require.main === module && process.argv[2] === '--control') {
  // Explicitly synthetic local observer controls, NOT native staged support evidence.
  // Reach each downstream comparison independently, even when a baseline feature red
  // would mask it. These include ordered nested command records and phase identity.
  const good = {
    shape_ok: true, shape_request_exact: true, shape_guidance: true, card_plan: true,
    first_stopped: true, stop_index_approval: true,
    stage_progress: { total: 2, completed: ['foundation'], active: 'surface', phase: 'stage' },
    stage_trace: [{ kind: 'stage-one', state: 'broken', status: 1 }, { kind: 'stage-one', state: 'phase-one', status: 0 }, { kind: 'stage-two', state: 'phase-two', status: 0 }],
    stage_records: [{ stage_id: 'foundation', green: false }, { stage_id: 'foundation', green: true }, { stage_id: 'surface', green: true }],
    no_full_before_stop: true, no_review_before_stop: true, resume_exact: true,
    first_result_unchanged: true, effect_once: true,
    final_trace: ['phase-two', 'final', 'review-broken', 'final-reviewed'],
    model_executed: true, configured_final: true, reviewer_repair_feedback: true,
    independent: true, landed: true, commits: '1', refused: true,
    refusal_unchanged: true, no_model: true, refined: true, revoked: true,
    build_needs_approval: true, changed_card: true, no_commit: true,
    invalid_refused: true, invalid_unchanged: true, no_approval: true
  };
  const rows = Object.entries(good).map(([k, v]) => [k, JSON.stringify(v)]);
  check(JSON.parse(JSON.stringify(good)), rows);
  if (process.argv[3] === 'good') {
    process.stdout.write('observer accepted\n');
  } else if (process.argv[3] === 'bad') {
    for (const key of Object.keys(good)) {
      const bad = structuredClone(good);
      if (typeof bad[key] === 'boolean') bad[key] = false;
      else if (typeof bad[key] === 'string') bad[key] = '0';
      else if (Array.isArray(bad[key])) bad[key].reverse();
      else bad[key].completed.push('surface');
      assert.throws(() => check(bad, rows), undefined, 'accepted corruption: ' + key);
      const missing = structuredClone(good); delete missing[key];
      assert.throws(() => check(missing, rows), undefined, 'accepted absence: ' + key);
    }
    process.stdout.write('observer rejected counterexamples\n');
    process.exitCode = 1;
  } else throw new Error('unknown control');
} else {
  const { Given, When, Then, AfterAll } = require('@cucumber/cucumber');
  let work, archive;
  function run(program, args, env = {}) {
    return new Promise((resolve, reject) => {
      const child = spawn(program, args, { cwd: ROOT, env: { ...process.env, ERL_FLAGS: process.env.ERL_FLAGS || '+S 2:2 +SDcpu 1 +SDio 1', ...env }, detached: true, stdio: ['ignore', 'pipe', 'pipe'] });
      let out = '';
      child.stdout.on('data', b => { out += b; }); child.stderr.on('data', b => { out += b; });
      const timer = setTimeout(() => { try { process.kill(-child.pid, 'SIGKILL'); } catch {} }, 240000);
      child.on('error', e => { clearTimeout(timer); reject(e); });
      child.on('close', code => { clearTimeout(timer); resolve({ code, out }); });
    });
  }
  async function candidate() {
    if (!archive) archive = (async () => {
      work = fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-staged-builds-'));
      // Package THIS candidate, never pick a historical latest archive or the driving CLI.
      const r = await run('/bin/sh', ['packaging/package.sh']);
      assert.equal(r.code, 0, r.out);
      const file = r.out.trim().split('\n').at(-1);
      assert.ok(path.isAbsolute(file) && fs.statSync(file).isFile(), r.out);
      return file;
    })();
    return archive;
  }
  Given('the native staged fixture contract is:', function (text) {
    this.stagedSpec = JSON.parse(text);
  });
  When('I exercise native staged Builds in mode {string}', { timeout: 300000 }, async function (mode) {
    const packed = await candidate();
    const temp = fs.mkdtempSync(path.join(work, 'case-'));
    const input = path.join(temp, 'input.json'), receipt = path.join(temp, 'receipt.json');
    fs.writeFileSync(input, JSON.stringify(this.stagedSpec));
    const r = await run('mix', ['run', 'features/steps/staged_intent_builds_driver.exs'], {
      // Isolate helper temp names from earlier processes with recycled OS pids.
      TMPDIR: temp, TMP: temp, TEMP: temp,
      KOGEN_ARCHIVE: packed, STAGED_MODE: mode, STAGED_INPUT: input, STAGED_RECEIPT: receipt
    });
    assert.equal(r.code, 0, r.out);
    assert.ok(fs.existsSync(receipt), 'no native receipt: ' + r.out);
    this.stagedReceipt = JSON.parse(fs.readFileSync(receipt, 'utf8'));
  });
  Then('the native staged observations are:', function (table) {
    assert.ok(this.stagedReceipt, 'no native behavior observed');
    check(this.stagedReceipt, table.raw());
  });
  AfterAll(function () { if (work) fs.rmSync(work, { recursive: true, force: true }); });
}
