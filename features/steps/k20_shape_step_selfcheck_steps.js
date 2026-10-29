'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const ROOT = path.resolve(__dirname, '../..');
const STEP_FILE = 'features/steps/is_even_steps.js';
const HEADLINE = 'Step self-check failed';
const CORRECT_KEYS = [
  'definitions|it is even|true', 'definitions|it is not even|true', 'definitions|the number {int}|true',
  `exit_code|${STEP_FILE}|true`, `load|${STEP_FILE}|true`,
  'observer|even-observer bad|true', 'observer|even-observer good|true',
  'steps|it is even|true', 'steps|it is not even|true', 'steps|the number 3|true', 'steps|the number 4|true',
].sort();
const CASES = {
  syntax: { key: `load|${STEP_FILE}|false`, line: `- load ${STEP_FILE}: `, has: ['SyntaxError'] },
  require: { key: `load|${STEP_FILE}|false`, line: `- load ${STEP_FILE}: `, has: ['is_even_missing_helper'] },
  undefined: { key: 'steps|it is not even|false', line: '- steps it is not even: undefined step', has: [] },
  ambiguous: { key: 'steps|it is even|false', line: '- steps it is even: ambiguous step', has: [] },
  gorun: { key: `exit_code|${STEP_FILE}|false`, line: `- exit_code ${STEP_FILE}: `, has: ['go run'] },
  observer: { key: 'observer|even-observer bad|false', line: '- observer even-observer bad: exit 0, recorded exit 1', has: [] },
};
const cache = new Map();

function observe(mode) {
  if (cache.has(mode)) return cache.get(mode);
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-k20-'));
  fs.chmodSync(dir, 0o700);
  try {
    const output = path.join(dir, 'output.json'), overlay = path.join(dir, 'overlay.json');
    fs.writeFileSync(overlay, JSON.stringify({ Replace: { [path.join(ROOT, 'cli/shape/k20_step_selfcheck_acceptance_test.go')]: path.join(__dirname, 'k20_shape_step_selfcheck_driver.go') } }), { mode: 0o600 });
    const r = spawnSync('go', ['test', '-overlay', overlay, './shape', '-run', '^TestK20StepSelfcheckObservation$', '-count=1'], {
      cwd: path.join(ROOT, 'cli'), encoding: 'utf8', timeout: 240000, maxBuffer: 8 * 1024 * 1024,
      env: { ...process.env, KOGEN_K20_MODE: mode, KOGEN_K20_OUTPUT: output },
    });
    assert.ifError(r.error);
    assert.equal(r.status, 0, `observation failed:\n${r.stdout}\n${r.stderr}`);
    const data = JSON.parse(fs.readFileSync(output, 'utf8'));
    assert.equal(data.mode, mode);
    cache.set(mode, data);
    return data;
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
}

const keys = ev => ev.items.map(i => `${i.check}|${i.target}|${i.ok}`).sort();
function checkPublished(d) {
  assert.equal(d.error_text, '', d.error_text);
  assert.equal(d.exit, 0);
  assert.equal(d.published, true);
}
function checkCorrect(d) {
  checkPublished(d);
  assert.equal(d.rounds, 1, 'no extra round');
  assert.equal(d.selfchecks.length, 1, 'exactly one step_selfcheck event');
  assert.equal(d.selfchecks[0].event, 'step_selfcheck');
  assert.equal(d.selfchecks[0].ok, true);
  assert.deepEqual(keys(d.selfchecks[0]), CORRECT_KEYS);
  assert.equal(d.feedback, '');
}
function checkFedBack(d, name) {
  const c = CASES[name];
  assert.ok(c, `unknown case ${name}`);
  checkPublished(d);
  assert.equal(d.rounds, 2);
  assert.equal(d.selfchecks.length, 2);
  assert.equal(d.selfchecks[0].ok, false);
  assert.ok(keys(d.selfchecks[0]).includes(c.key), `first event lacks ${c.key}: ${keys(d.selfchecks[0])}`);
  assert.equal(d.selfchecks[1].ok, true);
  assert.deepEqual(keys(d.selfchecks[1]), CORRECT_KEYS);
  assert.ok(d.feedback.startsWith(HEADLINE), d.feedback);
  assert.ok(!d.feedback.includes('Readiness observations'), 'the failing package must not reach readiness');
  const line = d.feedback.split('\n').find(l => l.startsWith(c.line) && c.has.every(h => l.includes(h)));
  assert.ok(line, `no feedback line ${c.line} with ${c.has}:\n${d.feedback}`);
}

const parse = k => { const [check, target, ok] = k.split('|'); return { check, target, ok: ok === 'true', detail: '' }; };
function controls(kind) {
  const okEvent = { event: 'step_selfcheck', ok: true, items: CORRECT_KEYS.map(parse) };
  const base = { mode: 'x', exit: 0, error_text: '', published: true, rounds: 1, feedback: '', selfchecks: [okEvent] };
  const fed = name => {
    const c = CASES[name];
    return { ...base, rounds: 2, feedback: `${HEADLINE}; nothing was published.\n${c.line}${c.has.join(' ')}\n`,
      selfchecks: [{ event: 'step_selfcheck', ok: false, items: [parse(c.key)] }, okEvent] };
  };
  checkCorrect(base);
  for (const name of Object.keys(CASES)) checkFedBack(fed(name), name);
  if (kind === 'good') { console.log('k20 observer good'); return; }
  assert.equal(kind, 'bad');
  const bad = (fn, d, mutate) => { const c = structuredClone(d); mutate(c); assert.throws(() => fn(c), 'accepted a known-bad fixture'); };
  bad(checkCorrect, base, d => { d.rounds = 2; });
  bad(checkCorrect, base, d => { d.selfchecks.push(d.selfchecks[0]); });
  bad(checkCorrect, base, d => { d.selfchecks = []; });
  bad(checkCorrect, base, d => { d.selfchecks[0].ok = false; });
  bad(checkCorrect, base, d => { d.selfchecks[0].items.pop(); });
  bad(checkCorrect, base, d => { d.selfchecks[0].event = 'other'; });
  bad(checkCorrect, base, d => { d.published = false; });
  bad(checkCorrect, base, d => { d.exit = 1; });
  bad(checkCorrect, base, d => { d.feedback = 'x'; });
  for (const name of Object.keys(CASES)) {
    const fn = d => checkFedBack(d, name);
    bad(fn, fed(name), d => { d.published = false; });
    bad(fn, fed(name), d => { d.rounds = 1; });
    bad(fn, fed(name), d => { d.feedback = d.feedback.replace(HEADLINE, 'Other'); });
    bad(fn, fed(name), d => { d.feedback = HEADLINE + '\n'; });
    bad(fn, fed(name), d => { d.feedback += 'Readiness observations\n'; });
    bad(fn, fed(name), d => { d.selfchecks[0].ok = true; });
    bad(fn, fed(name), d => { d.selfchecks[0].items = []; });
    bad(fn, fed(name), d => { d.selfchecks[1].ok = false; });
    bad(fn, fed(name), d => { d.selfchecks.pop(); });
  }
  bad(d => checkFedBack(d, 'syntax'), fed('syntax'), d => { d.feedback = d.feedback.replace('SyntaxError', 'Error'); });
  bad(d => checkFedBack(d, 'gorun'), fed('gorun'), d => { d.feedback = d.feedback.replace('go run', 'run'); });
  console.log('k20 observer rejected bad fixtures');
  process.exitCode = 1;
}

if (require.main === module && process.argv[2] === '--control') {
  controls(process.argv[3]);
} else {
  const { When, Then } = require('@cucumber/cucumber');
  const OPT = { timeout: 250000 };
  When('the k20 Shape plays {string}', OPT, function (mode) { this.k20 = observe(mode); });
  Then('the k20 package published after one round with one step_selfcheck event listing every item checked', function () { checkCorrect(this.k20); });
  Then('the k20 first submission was fed back for the {string} failure and the corrected second submission published', function (name) { checkFedBack(this.k20, name); });
}
