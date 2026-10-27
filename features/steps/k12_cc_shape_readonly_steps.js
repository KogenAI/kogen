'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const ROOT = path.resolve(__dirname, '../..');
const WRITE_TOOLS = 'Edit,Write,MultiEdit,NotebookEdit';
const NOTE = 'write tools are not available during Shape';
const cache = new Map();

function put(file, bytes) {
  fs.writeFileSync(file, bytes, { mode: 0o600 });
  fs.chmodSync(file, 0o600);
}
// Runs one observation driver, mounted as a test with go -overlay, once per kind and mode.
function observe(kind, mode) {
  const key = `${kind}:${mode}`;
  if (cache.has(key)) return cache.get(key);
  const spec = kind === 'adapter'
    ? { pkg: './executor/claudecode', test: 'TestK12AdapterObservation', mount: 'cli/executor/claudecode/k12_shape_acceptance_test.go', driver: 'k12_adapter_driver.go' }
    : { pkg: './shape', test: 'TestK12ShapeObservation', mount: 'cli/shape/k12_shape_acceptance_test.go', driver: 'k12_shape_driver.go' };
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-k12-'));
  fs.chmodSync(dir, 0o700);
  try {
    const output = path.join(dir, 'output.json'), overlay = path.join(dir, 'overlay.json');
    put(overlay, JSON.stringify({ Replace: { [path.join(ROOT, spec.mount)]: path.join(__dirname, spec.driver) } }));
    const r = spawnSync('go', ['test', '-overlay', overlay, spec.pkg, '-run', `^${spec.test}$`, '-count=1'], {
      cwd: path.join(ROOT, 'cli'), encoding: 'utf8', timeout: 240000, maxBuffer: 8 * 1024 * 1024,
      env: { ...process.env, KOGEN_K12_MODE: mode, KOGEN_K12_OUTPUT: output },
    });
    assert.ifError(r.error);
    assert.equal(r.status, 0, `observation failed:\n${r.stdout}\n${r.stderr}`);
    // Go success alone is not proof: the driver must have written its observation.
    const data = JSON.parse(fs.readFileSync(output, 'utf8'));
    assert.equal(data.mode, mode);
    cache.set(key, data);
    return data;
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
}

const count = (list, v) => list.filter(x => x === v).length;
function checkShapeChild(d) {
  assert.equal(d.round1_error, '', d.round1_error);
  assert.equal(count(d.argv, '--disallowedTools'), 1, 'exactly one --disallowedTools');
  assert.equal(d.argv[d.argv.indexOf('--disallowedTools') + 1], WRITE_TOOLS);
  const allowed = d.argv.indexOf('--allowedTools');
  assert.ok(allowed >= 0 && d.argv[allowed + 1] === 'Bash', 'Bash stays allowed');
  assert.ok(d.argv.includes('--permission-mode') && d.argv.includes('--json-schema'), 'the other shape flags stay');
  assert.deepEqual(d.env.filter(e => e.startsWith('GIT_OPTIONAL_LOCKS=')), ['GIT_OPTIONAL_LOCKS=0']);
}
function checkBuildChild(d) {
  assert.equal(d.round1_error, '', d.round1_error);
  assert.ok(!d.argv.some(a => /^--disallowed/.test(a) || a.includes('NotebookEdit')), 'build argv must not change');
  assert.equal(d.argv[d.argv.indexOf('--allowedTools') + 1], 'Bash');
}
function checkShapeNoHook(d) {
  assert.equal(d.round1_error, '', d.round1_error);
  assert.equal(d.round1_ending, 'finish');
  assert.equal(d.round2_error, '', 'the session must continue');
  assert.equal(d.round2_ending, 'finish');
  assert.equal(d.hook_events.length, 1);
  const h = d.hook_events[0];
  assert.equal(h.decision, 'deny');
  assert.equal(h.hook, 'configuration');
  assert.equal(h.tool_name, 'Write');
  assert.equal(h.message, NOTE);
  assert.ok(d.tool_events.some(e => e.name === 'Write' && e.denied === true), 'the call is reported denied');
}
function checkBuildNoHook(d) {
  assert.match(d.round1_error, /^executor\/protocol: hook did not run for the Write call /);
  assert.equal(d.round2_error, '');
  assert.equal(d.round2_ending, '');
}
const strayPaths = (d, allow) => d.status.filter(l => l.trim()).map(l => l.slice(3))
  .filter(p => !p.startsWith('.kogen/local/') && !p.startsWith('.kogen/intents/is-even/') && p !== 'features/steps/is_even_steps.js' && !allow.includes(p));
function checkRefreshIgnored(d) {
  assert.equal(d.index_changed_by_round, true, 'fixture: git status must have rewritten the index bytes');
  assert.equal(d.error_class, '', d.error_text);
  assert.equal(d.exit, 0, d.error_text);
  assert.equal(d.published, true);
  assert.deepEqual(d.removed_events, []);
}
function checkStagedStops(d) {
  assert.equal(d.index_changed_by_round, true, 'fixture: the round must have staged a path');
  assert.equal(d.error_class, 'candidate');
  assert.equal(d.error_reason, 'baseline_changed');
  assert.ok(d.error_text.includes('changed: (the Git index)'), d.error_text);
  assert.equal(d.published, false);
  assert.ok(d.status.includes('A  notes-staged.txt'), 'the staged path stays as the session left it');
}
function checkNoteRemoved(d, allow) {
  assert.equal(d.error_class, '', d.error_text);
  assert.equal(d.exit, 0, d.error_text);
  assert.equal(d.published, true);
  assert.equal(d.keep_note_exists, false);
  assert.equal(d.removed_events.length, 1);
  assert.deepEqual(d.removed_events[0].paths, ['features/steps/.keep-note']);
  assert.deepEqual(strayPaths(d, allow), [], 'the Build would stop on dirty_tree');
}
function checkPreexisting(d) {
  checkNoteRemoved(d, ['notes-keep.txt']);
  assert.equal(d.preexisting_content, 'mine\n');
  assert.ok(d.status.includes('?? notes-keep.txt'));
}

function controls(kind) {
  const base = { index_changed_by_round: true, error_class: '', error_reason: '', error_text: '', exit: 0, published: true, removed_events: [], keep_note_exists: false, preexisting_content: null, status: ['?? .kogen/intents/is-even/intent.md', '?? features/steps/is_even_steps.js'] };
  const shapeChild = { round1_error: '', argv: ['-p', '--allowedTools', 'Bash', '--disallowedTools', WRITE_TOOLS, '--permission-mode', 'acceptEdits', '--json-schema', '{}'], env: ['PATH=/bin', 'GIT_OPTIONAL_LOCKS=0'] };
  const buildChild = { round1_error: '', argv: ['-p', '--allowedTools', 'Bash', '--permission-mode', 'acceptEdits'], env: [] };
  const hook = { event: 'executor_hook', decision: 'deny', hook: 'configuration', tool_name: 'Write', message: NOTE };
  const noHook = { round1_error: '', round1_ending: 'finish', round2_error: '', round2_ending: 'finish', hook_events: [hook], tool_events: [{ name: 'Write', denied: true }] };
  const buildStop = { round1_error: 'executor/protocol: hook did not run for the Write call "t"; the round was stopped', round2_error: '', round2_ending: '' };
  const staged = { ...base, error_class: 'candidate', error_reason: 'baseline_changed', error_text: 'candidate/baseline_changed: x\n  changed: (the Git index)\n', exit: 1, published: false, status: ['A  notes-staged.txt'] };
  const note = { ...base, index_changed_by_round: false, removed_events: [{ event: 'shape_untracked_removed', paths: ['features/steps/.keep-note'] }] };
  const pre = { ...note, preexisting_content: 'mine\n', status: [...base.status, '?? notes-keep.txt'] };
  checkShapeChild(shapeChild); checkBuildChild(buildChild); checkShapeNoHook(noHook); checkBuildNoHook(buildStop);
  checkRefreshIgnored(base); checkStagedStops(staged); checkNoteRemoved(note, []); checkPreexisting(pre);
  if (kind === 'good') { console.log('k12 observer good'); return; }
  assert.equal(kind, 'bad');
  const bad = (fn, d, mutate) => { const c = structuredClone(d); mutate(c); assert.throws(() => fn(c), 'accepted a known-bad fixture'); };
  bad(checkShapeChild, shapeChild, d => { d.argv = d.argv.filter(a => a !== '--disallowedTools'); });
  bad(checkShapeChild, shapeChild, d => { d.argv[4] = 'Edit,Write'; });
  bad(checkShapeChild, shapeChild, d => { d.env = ['PATH=/bin']; });
  bad(checkShapeChild, shapeChild, d => { d.env = ['GIT_OPTIONAL_LOCKS=1']; });
  bad(checkBuildChild, buildChild, d => { d.argv.push('--disallowedTools', WRITE_TOOLS); });
  bad(checkShapeNoHook, noHook, d => { d.round1_error = 'executor/protocol: hook did not run'; });
  bad(checkShapeNoHook, noHook, d => { d.round2_ending = ''; });
  bad(checkShapeNoHook, noHook, d => { d.hook_events[0].message = 'x'; });
  bad(checkShapeNoHook, noHook, d => { d.hook_events = []; });
  bad(checkBuildNoHook, buildStop, d => { d.round1_error = ''; });
  bad(checkRefreshIgnored, base, d => { d.error_class = 'candidate'; d.exit = 1; });
  bad(checkRefreshIgnored, base, d => { d.index_changed_by_round = false; });
  bad(checkStagedStops, staged, d => { d.error_class = ''; });
  bad(checkStagedStops, staged, d => { d.published = true; });
  bad(d => checkNoteRemoved(d, []), note, d => { d.keep_note_exists = true; });
  bad(d => checkNoteRemoved(d, []), note, d => { d.removed_events = []; });
  bad(d => checkNoteRemoved(d, []), note, d => { d.status.push('?? features/steps/.keep-note'); });
  bad(checkPreexisting, pre, d => { d.preexisting_content = null; });
  bad(checkPreexisting, pre, d => { d.status = d.status.filter(l => l !== '?? notes-keep.txt'); });
  console.log('k12 observer rejected bad fixtures');
  process.exitCode = 1;
}

if (require.main === module && process.argv[2] === '--control') {
  controls(process.argv[3]);
} else {
  const { When, Then } = require('@cucumber/cucumber');
  const STEP = { timeout: 250000 };
  When('the k12 Claude Code adapter runs a {string} session', STEP, function (mode) { this.k12 = observe('adapter', mode); });
  When('the k12 Shape round plays {string}', STEP, function (mode) { this.k12 = observe('shape', mode); });
  Then('the k12 Shape child has the write tools disallowed and GIT_OPTIONAL_LOCKS=0', function () { checkShapeChild(this.k12); });
  Then('the k12 Build child has its unchanged arguments', function () { checkBuildChild(this.k12); });
  Then('the k12 Shape session got feedback that write tools are not available during Shape and both rounds completed', function () { checkShapeNoHook(this.k12); });
  Then('the k12 Build round still stops with an executor protocol failure because the hook did not run', function () { checkBuildNoHook(this.k12); });
  Then('the k12 Shape published an Intent although the index stat data was refreshed', function () { checkRefreshIgnored(this.k12); });
  Then('the k12 Shape stopped with a candidate baseline_changed naming the Git index and published nothing', function () { checkStagedStops(this.k12); });
  Then('the k12 Shape published an Intent without the keep note and no untracked path outside the Intent remains', function () { checkNoteRemoved(this.k12, []); });
  Then('the k12 Shape published without the keep note and left the pre-existing untracked file alone', function () { checkPreexisting(this.k12); });
}
