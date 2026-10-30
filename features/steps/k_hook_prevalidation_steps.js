'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const ROOT = path.resolve(__dirname, '../..');
const cache = new Map();

function put(file, bytes) {
  fs.writeFileSync(file, bytes, { mode: 0o600 });
  fs.chmodSync(file, 0o600);
}
// Runs the observation driver, mounted as a test with go -overlay, once per mode.
function observe(mode) {
  if (cache.has(mode)) return cache.get(mode);
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-khp-'));
  fs.chmodSync(dir, 0o700);
  try {
    const output = path.join(dir, 'output.json'), overlay = path.join(dir, 'overlay.json');
    put(overlay, JSON.stringify({ Replace: { [path.join(ROOT, 'cli/build/k_hook_prevalidation_acceptance_test.go')]: path.join(__dirname, 'k_hook_prevalidation_driver.go') } }));
    const r = spawnSync('go', ['test', '-overlay', overlay, './build', '-run', '^TestKHookPrevalidationObservation$', '-count=1'], {
      cwd: path.join(ROOT, 'cli'), encoding: 'utf8', timeout: 280000, maxBuffer: 8 * 1024 * 1024,
      env: { ...process.env, KOGEN_KHP_MODE: mode, KOGEN_KHP_OUTPUT: output, GOWORK: 'off', GOPROXY: 'off', GOTOOLCHAIN: 'local' },
    });
    assert.ifError(r.error);
    assert.equal(r.status, 0, `observation failed:\n${r.stdout}\n${r.stderr}`);
    // Go success alone is not proof: the driver must have written its observation.
    const data = JSON.parse(fs.readFileSync(output, 'utf8'));
    assert.equal(data.mode, mode);
    cache.set(mode, data);
    return data;
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
}

// rows are the expected executor_tool events; an empty rejected_before_hook cell means the field is absent.
function toolRows(rows) {
  return rows.map(r => ({ name: r.name, tool_use_id: r.tool_use_id, denied: r.denied === 'true', rejected_before_hook: r.rejected_before_hook === '' ? null : r.rejected_before_hook === 'true' }));
}
function checkLanded(d, content) {
  assert.equal(d.mode, 'rejected-before-hook');
  assert.deepEqual(d.round_failed, [], 'no executor round failed');
  assert.equal(d.exit, 0, d.stdout);
  assert.equal(d.outcome, 'landed');
  assert.equal(d.calls, '1', 'the round continued: one Claude Code invocation');
  assert.equal(d.commits, '1', 'exactly one commit');
  assert.equal(d.committed_app, content);
  assert.equal(d.notebook_exists, false, 'the rejected NotebookEdit created nothing');
}
function checkTools(d, rows) {
  assert.deepEqual(d.tool_events, toolRows(rows));
}
function checkHooks(d, id) {
  assert.deepEqual(d.hook_events, [{ tool_use_id: id, decision: 'allow', hook: 'pretool' }]);
}
function checkStopped(d, detail) {
  assert.equal(d.mode, 'written-without-hook');
  assert.equal(d.app, 'candidate\n', 'fixture: the call really wrote app.txt without the hook');
  assert.equal(d.exit, 1, d.stdout);
  assert.equal(d.outcome, 'protocol');
  assert.ok(d.stdout.includes(`executor/protocol: ${detail}\n`), d.stdout);
  assert.deepEqual(d.round_failed, [{ reason: 'protocol', detail }]);
  assert.equal(d.commits, '0', 'no commit');
  assert.equal(d.calls, '1');
  assert.ok(!d.tool_events.some(e => e.rejected_before_hook === true), 'the written call is not reported as rejected before the hook');
  assert.deepEqual(d.hook_events, []);
}

function controls(kind) {
  const INCIDENT = 'toolu_014z3hLJe9neZ1V8rmXgJRRi';
  const DETAIL = `hook did not run for the Write call "${INCIDENT}"; the round was stopped`;
  const rows = [
    { name: 'Bash', tool_use_id: 'toolu_khp_bash', denied: 'false', rejected_before_hook: '' },
    { name: 'Write', tool_use_id: INCIDENT, denied: 'false', rejected_before_hook: 'true' },
    { name: 'NotebookEdit', tool_use_id: 'toolu_khp_notebook', denied: 'false', rejected_before_hook: 'true' },
    { name: 'Read', tool_use_id: 'toolu_khp_read', denied: 'false', rejected_before_hook: '' },
    { name: 'Write', tool_use_id: 'toolu_khp_retry', denied: 'false', rejected_before_hook: '' },
  ];
  const landed = {
    mode: 'rejected-before-hook', exit: 0, stdout: 'building fixture\n', outcome: 'landed', calls: '1', commits: '1',
    committed_app: 'candidate\n', app: 'candidate\n', notebook_exists: false, round_failed: [],
    tool_events: toolRows(rows), hook_events: [{ tool_use_id: 'toolu_khp_retry', decision: 'allow', hook: 'pretool' }],
  };
  const stopped = {
    mode: 'written-without-hook', exit: 1, stdout: `building fixture\nfailed fixture: protocol (Build 4a0d42ef)\nexecutor/protocol: ${DETAIL}\n  edited: app.txt\n`,
    outcome: 'protocol', calls: '1', commits: '0', committed_app: '', app: 'candidate\n', notebook_exists: false,
    round_failed: [{ reason: 'protocol', detail: DETAIL }],
    tool_events: [{ name: 'Bash', tool_use_id: 'toolu_khp_bash', denied: false, rejected_before_hook: null }], hook_events: [],
  };
  checkLanded(landed, 'candidate\n'); checkTools(landed, rows); checkHooks(landed, 'toolu_khp_retry'); checkStopped(stopped, DETAIL);
  if (kind === 'good') { console.log('k-hook-prevalidation observer good'); return; }
  assert.equal(kind, 'bad');
  const bad = (fn, d, mutate, ...args) => { const c = structuredClone(d); mutate(c); assert.throws(() => fn(c, ...args), 'accepted a known-bad fixture'); };
  // The incident as it is today: the round stops at the rejected Write.
  bad(checkLanded, landed, d => { d.exit = 1; d.outcome = 'protocol'; d.commits = '0'; d.committed_app = ''; d.round_failed = [{ reason: 'protocol', detail: DETAIL }]; }, 'candidate\n');
  bad(checkLanded, landed, d => { d.round_failed = [{ reason: 'protocol', detail: DETAIL }]; }, 'candidate\n');
  bad(checkLanded, landed, d => { d.calls = '2'; }, 'candidate\n');
  bad(checkLanded, landed, d => { d.commits = '0'; }, 'candidate\n');
  bad(checkLanded, landed, d => { d.committed_app = 'changed by bash\n'; }, 'candidate\n');
  bad(checkLanded, landed, d => { d.notebook_exists = true; }, 'candidate\n');
  bad(checkTools, landed, d => { d.tool_events.splice(1, 1); }, rows);
  bad(checkTools, landed, d => { d.tool_events[2].rejected_before_hook = null; }, rows);
  bad(checkTools, landed, d => { d.tool_events[1].denied = true; }, rows);
  bad(checkTools, landed, d => { d.tool_events[4].rejected_before_hook = true; }, rows);
  bad(checkTools, landed, d => { d.tool_events.reverse(); }, rows);
  bad(checkHooks, landed, d => { d.hook_events = []; }, 'toolu_khp_retry');
  bad(checkHooks, landed, d => { d.hook_events.push({ tool_use_id: INCIDENT, decision: 'allow', hook: 'pretool' }); }, 'toolu_khp_retry');
  // Accepting every is_error result: the written call lands instead of stopping.
  bad(checkStopped, stopped, d => { d.exit = 0; d.outcome = 'landed'; d.commits = '1'; d.round_failed = []; d.stdout = 'building fixture\n'; }, DETAIL);
  bad(checkStopped, stopped, d => { d.tool_events.push({ name: 'Write', tool_use_id: INCIDENT, denied: false, rejected_before_hook: true }); }, DETAIL);
  bad(checkStopped, stopped, d => { d.round_failed[0].detail = 'hook did not run'; }, DETAIL);
  bad(checkStopped, stopped, d => { d.app = 'changed by bash\n'; }, DETAIL);
  bad(checkStopped, stopped, d => { d.stdout = 'building fixture\n'; }, DETAIL);
  bad(checkStopped, stopped, d => { d.commits = '1'; }, DETAIL);
  console.log('k-hook-prevalidation observer rejected bad fixtures');
  process.exitCode = 1;
}

if (require.main === module && process.argv[2] === '--control') {
  controls(process.argv[3]);
} else {
  const { When, Then } = require('@cucumber/cucumber');
  const STEP = { timeout: 300000 };
  When('the k-hook-prevalidation fake Claude Code build round plays {string}', STEP, function (mode) { this.khp = observe(mode); });
  Then('the k-hook-prevalidation Build continued the round, landed exactly one commit with app.txt {string} and created no notebook', function (content) { checkLanded(this.khp, content + '\n'); });
  Then('the k-hook-prevalidation run log has exactly these executor_tool events in order:', function (table) { checkTools(this.khp, table.hashes()); });
  Then('the k-hook-prevalidation hook ran only for the call {string}, which it allowed', function (id) { checkHooks(this.khp, id); });
  Then('the k-hook-prevalidation Build stopped as executor\\/protocol with the detail {string} and made no commit', function (detail) { checkStopped(this.khp, detail); });
}
