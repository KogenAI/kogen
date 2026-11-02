'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const ROOT = path.resolve(__dirname, '../..');
const TEST = 'TestKLinePeriodObservation';
const MOUNT = 'cli/shape/k_intent_line_period_acceptance_test.go';
const cache = new Map();

// observe runs the observation driver mounted as a test of ./shape with go -overlay.
function observe(input) {
  const key = JSON.stringify(input);
  if (cache.has(key)) return cache.get(key);
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-k-line-period-'));
  fs.chmodSync(dir, 0o700);
  try {
    const output = path.join(dir, 'output.json'), overlay = path.join(dir, 'overlay.json');
    fs.writeFileSync(overlay, JSON.stringify({ Replace: { [path.join(ROOT, MOUNT)]: path.join(__dirname, 'k_intent_line_period_driver.go') } }), { mode: 0o600 });
    const args = ['test', '-overlay', overlay, './shape', '-run', `^${TEST}$`, '-count=1', '-v'];
    const r = spawnSync('go', args, {
      cwd: path.join(ROOT, 'cli'), encoding: 'utf8', timeout: 280000, maxBuffer: 8 * 1024 * 1024,
      env: { ...process.env, KOGEN_KLP_INPUT: key, KOGEN_KLP_OUTPUT: output },
    });
    const ran = `go ${args.join(' ')} in cli (mounting ${MOUNT})`;
    assert.ifError(r.error);
    assert.equal(r.status, 0, `${TEST} failed: ${ran} exited ${r.status}:\n${r.stdout}\n${r.stderr}`);
    assert.ok(fs.existsSync(output), `${TEST} did not run (absent, skipped or ran zero times): ${ran} exited 0 and wrote no observation:\n${r.stdout}\n${r.stderr}`);
    const data = JSON.parse(fs.readFileSync(output, 'utf8'));
    assert.equal(data.mode, input.mode, `${TEST} observed mode`);
    cache.set(key, data);
    return data;
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
}

// A row with an empty problem is a valid line: the Intent check reports nothing.
function checkLint(obs, rows) {
  assert.equal(obs.mode, 'lint');
  assert.equal(obs.cases.length, rows.length, 'one observed case per line');
  rows.forEach((row, i) => {
    const c = obs.cases[i];
    assert.equal(c.section, row.section, `case ${i + 1} section`);
    assert.equal(c.line, row.line, `case ${i + 1} line`);
    const want = row.problem === '' ? [] : [row.problem];
    assert.deepEqual(c.problems, want, `${row.section} line ${JSON.stringify(row.line)}`);
  });
}

function checkShape(obs, exit, requests) {
  assert.equal(obs.mode, 'shape');
  assert.equal(obs.error_text, '', obs.error_text);
  assert.equal(obs.exit, exit, 'Shape exit');
  assert.deepEqual(obs.refused, [], `refused submissions: ${JSON.stringify(obs.refused)}`);
  assert.equal(obs.shaper_requests, requests, 'shaper requests');
  assert.equal(obs.published, true, 'intent.md was published');
}

function checkStored(obs, rows) {
  assert.equal(obs.intent, obs.submitted, 'the published intent.md is the submitted bytes');
  const lines = obs.intent.split('\n');
  for (const r of rows) assert.ok(lines.includes(r.line), `published intent.md lacks the line as written: ${r.line}`);
}

function checkCard(obs, code) { assert.equal(obs.card_exit, code, obs.card); }

const TESTS_PROBLEM = l => `tests: ${l} must be \`- <rule>: <test to add or update> (<layer>)\` or \`- none: <reason>\``;
const SAMPLE = [
  { section: 'Tests', line: '- r: add t (unit).', problem: '' },
  { section: 'Tests', line: '- r: add t (unit)..', problem: TESTS_PROBLEM('- r: add t (unit)..') },
  { section: 'Decisions', line: '- d (source: request).', problem: '' },
  { section: 'Decisions', line: '- d (source: caller).', problem: 'decisions: a decision has no source' },
];
const SHAPE_ROWS = [{ section: 'Decisions', line: '- d (source: request).' }, { section: 'Tests', line: '- r: add t (unit).' }];
const SUBMITTED = '# T\n\n## Decisions\n- d (source: request).\n\n## Tests\n- r: add t (unit).\n';

function goodLint() {
  return { mode: 'lint', cases: SAMPLE.map(r => ({ section: r.section, line: r.line, problems: r.problem === '' ? [] : [r.problem] })) };
}
function goodShape() {
  return { mode: 'shape', exit: 0, error_text: '', refused: [], shaper_requests: 1, published: true, submitted: SUBMITTED, intent: SUBMITTED, card_exit: 5, card: 'Approve with:\n' };
}
function checkAllShape(d) { checkShape(d, 0, 1); checkStored(d, SHAPE_ROWS); checkCard(d, 5); }

function controls(kind) {
  checkLint(goodLint(), SAMPLE);
  checkAllShape(goodShape());
  if (kind === 'good') { console.log('k-line-period observer good'); return; }
  assert.equal(kind, 'bad');
  const badLint = mutate => { const c = structuredClone(goodLint()); mutate(c); assert.throws(() => checkLint(c, SAMPLE), 'accepted a known-bad lint observation'); };
  const badShape = mutate => { const c = structuredClone(goodShape()); mutate(c); assert.throws(() => checkAllShape(c), 'accepted a known-bad shape observation'); };
  badLint(d => { d.cases[0].problems = [TESTS_PROBLEM(SAMPLE[0].line)]; });
  badLint(d => { d.cases[1].problems = []; });
  badLint(d => { d.cases[1].problems = ['tests: something else']; });
  badLint(d => { d.cases[2].problems = ['decisions: a decision has no source']; });
  badLint(d => { d.cases[3].problems = []; });
  badLint(d => { d.cases[3].problems.push('decisions: a decision has no source'); });
  badLint(d => { d.cases[0].line = '- r: add t (unit)'; });
  badLint(d => { d.cases.pop(); });
  badLint(d => { d.mode = 'shape'; });
  badShape(d => { d.exit = 1; });
  badShape(d => { d.error_text = 'shape/invalid_output'; });
  badShape(d => { d.refused = [{ event: 'submission_refused', attempt: 1 }]; });
  badShape(d => { d.shaper_requests = 2; });
  badShape(d => { d.published = false; });
  badShape(d => { d.intent = SUBMITTED.replace('(unit).', '(unit)'); });
  badShape(d => { d.intent = SUBMITTED.replace('(source: request).', '(source: request)'); d.submitted = d.intent; });
  badShape(d => { d.card_exit = 1; });
  console.log('k-line-period observer rejected bad fixtures');
  process.exitCode = 1;
}

if (require.main === module && process.argv[2] === '--control') {
  controls(process.argv[3]);
} else {
  const { When, Then } = require('@cucumber/cucumber');
  When('the k-line-period Intent check reads each line alone in an otherwise valid Intent:', { timeout: 300000 }, function (table) {
    this.klpRows = table.hashes().map(r => ({ section: r.section, line: r.line, problem: r.problem }));
    this.klp = observe({ mode: 'lint', lines: this.klpRows.map(r => ({ section: r.section, line: r.line })) });
  });
  Then('the k-line-period Intent check reports exactly the expected problem of each line', function () { checkLint(this.klp, this.klpRows); });
  When('the k-line-period scripted Shape submits the is-even Intent with these lines:', { timeout: 300000 }, function (table) {
    this.klpRows = table.hashes().map(r => ({ section: r.section, line: r.line }));
    this.klp = observe({ mode: 'shape', lines: this.klpRows });
  });
  Then('the k-line-period Shape exits {int} after {int} shaper request(s) with no refused submission', function (exit, requests) { checkShape(this.klp, exit, requests); });
  Then('the k-line-period published intent.md is the submitted bytes with every line as written', function () { checkStored(this.klp, this.klpRows); });
  Then('the k-line-period approval card exits {int}', function (code) { checkCard(this.klp, code); });
  Then('the k-line-period file {string} contains:', function (rel, text) {
    const body = fs.readFileSync(path.join(ROOT, rel), 'utf8');
    assert.ok(body.includes(text), `${rel} does not contain:\n${text}`);
  });
}
