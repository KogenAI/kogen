'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const ROOT = path.resolve(__dirname, '../..');

// number of defects left uncovered by each case
const EXPECT = {
  undefined_colon: 0, undefined_equals: 0, undefined_means: 0, undefined_is: 0,
  undefined_mention_only: 1, undefined_marker_before_name: 1, undefined_other_name_defined: 1,
  undefined_question_both: 0, undefined_question_one: 1,
  conflict_empty_result_b: 0, conflict_empty_result_a: 0, conflict_both_results: 1, conflict_one_result: 0, conflict_no_exposing: 1,
  precedence_empty_result_b: 0,
};
const GROUPS = {
  defined: ['undefined_colon', 'undefined_equals', 'undefined_means', 'undefined_is'],
  mention: ['undefined_mention_only', 'undefined_marker_before_name', 'undefined_other_name_defined', 'undefined_question_one'],
  question: ['undefined_question_both'],
  empty: ['conflict_empty_result_b', 'conflict_empty_result_a', 'precedence_empty_result_b'],
  kept: ['conflict_both_results', 'conflict_one_result', 'conflict_no_exposing'],
};

let cached;
function observe() {
  if (cached) return cached;
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-k25b-'));
  fs.chmodSync(dir, 0o700);
  try {
    const output = path.join(dir, 'output.json'), overlay = path.join(dir, 'overlay.json');
    fs.writeFileSync(overlay, JSON.stringify({ Replace: { [path.join(ROOT, 'cli/shape/k25b_coverage_acceptance_test.go')]: path.join(__dirname, 'k25b_coverage_driver.go') } }), { mode: 0o600 });
    const r = spawnSync('go', ['test', '-overlay', overlay, './shape', '-run', '^TestK25bCoverageObservation$', '-count=1'], {
      cwd: path.join(ROOT, 'cli'), encoding: 'utf8', timeout: 240000, maxBuffer: 8 * 1024 * 1024,
      env: { ...process.env, KOGEN_K25B_OUTPUT: output },
    });
    assert.ifError(r.error);
    assert.equal(r.status, 0, `observation failed:\n${r.stdout}\n${r.stderr}`);
    cached = JSON.parse(fs.readFileSync(output, 'utf8'));
    return cached;
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
}

function check(d, group) {
  for (const name of GROUPS[group]) assert.equal(d[name], EXPECT[name], `${name}: uncovered=${d[name]}, want ${EXPECT[name]}`);
}

function controls(kind) {
  const good = () => ({ ...EXPECT });
  for (const g of Object.keys(GROUPS)) check(good(), g);
  if (kind === 'good') { console.log('k25b observer good'); return; }
  assert.equal(kind, 'bad');
  for (const g of Object.keys(GROUPS)) {
    for (const name of GROUPS[g]) {
      const d = good(); d[name] = 1 - d[name];
      assert.throws(() => check(d, g), `accepted a known-bad ${name}`);
      const m = good(); delete m[name];
      assert.throws(() => check(m, g), `accepted a missing ${name}`);
    }
  }
  console.log('k25b observer rejected bad fixtures');
  process.exitCode = 1;
}

if (require.main === module && process.argv[2] === '--control') {
  controls(process.argv[3]);
} else {
  const { When, Then } = require('@cucumber/cucumber');
  When('the k25b coverage rule judges its fixed defects', { timeout: 250000 }, function () { this.k25b = observe(); });
  Then('the k25b {string} cases are judged as specified', function (group) { assert.ok(GROUPS[group], group); check(this.k25b, group); });
}
