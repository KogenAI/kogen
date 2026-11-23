'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const ROOT = path.resolve(__dirname, '../..');

// Each mutant is one wrong resume policy in completeCandidates (cli/facts.go).
const MUTANTS = {
  'offers unsupported runs': ['r["resume_status"] == "unsupported" ||', 'false ||'],
  'offers landed runs': ['r["state"] == "landed"', 'false'],
  'offers already present runs': ['r["state"] == "already_present"', 'false'],
  'drops potentially available runs': ['if op == "resume" && (', 'if op == "resume" && (r["resume_status"] == "potentially_available" || '],
  'keeps input order': ['sort.Slice(candidates, func(i, j int) bool {', 'sort.Slice(candidates, func(i, j int) bool {\n\t\tif true {\n\t\t\treturn false\n\t\t}'],
};

function judge(baseline, mutant, name) {
  assert.ok(baseline.code === 0 && /^ok\s+kogen\s/m.test(baseline.out),
    `facts tests do not pass on the unmodified policy (exit ${baseline.code}):\n${baseline.out}`);
  assert.ok(!/\[(build|setup) failed\]/.test(mutant.out),
    `policy "${name}" did not compile or set up, so it proves nothing:\n${mutant.out}`);
  assert.ok(mutant.code !== 0 && /^--- FAIL: /m.test(mutant.out),
    `cli/facts_test.go tests still pass with the wrong resume policy "${name}" (exit ${mutant.code}):\n${mutant.out}`);
}

function goTest(dir, names) {
  const r = spawnSync('go', ['test', '-count=1', '-run', `^(${names.join('|')})$`, '.'],
    { cwd: dir, encoding: 'utf8', timeout: 50000 });
  return { code: r.status === null ? 124 : r.status, out: (r.stdout || '') + (r.stderr || '') };
}

function exercise(name) {
  const m = MUTANTS[name];
  assert.ok(m, `unknown policy ${name}`);
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'resume-policy-'));
  try {
    for (const d of ['cli', 'docs']) fs.cpSync(path.join(ROOT, d), path.join(tmp, d), { recursive: true });
    const dir = path.join(tmp, 'cli');
    const names = [...fs.readFileSync(path.join(dir, 'facts_test.go'), 'utf8').matchAll(/^func (Test\w+)\(t \*testing\.T\)/gm)].map((x) => x[1]);
    assert.ok(names.length > 0, 'no tests declared in cli/facts_test.go');
    const baseline = goTest(dir, names);
    const src = fs.readFileSync(path.join(dir, 'facts.go'), 'utf8');
    const start = src.indexOf('func completeCandidates(');
    assert.ok(start >= 0, 'completeCandidates not found in cli/facts.go');
    const at = src.indexOf(m[0], start);
    assert.ok(at >= 0, `policy "${name}" does not apply: ${m[0]} not found in completeCandidates`);
    fs.writeFileSync(path.join(dir, 'facts.go'), src.slice(0, at) + m[1] + src.slice(at + m[0].length));
    return { name, baseline, mutant: goTest(dir, names) };
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
}

if (require.main === module) {
  const arg = process.argv[2] === '--control' ? process.argv[3] : null;
  if (arg === 'good' || arg === 'bad') {
    const ok = { code: 0, out: 'ok  \tkogen\t0.329s\n' };
    const failed = { code: 1, out: '--- FAIL: TestResumeCompletionOffersOnlyResumableRuns (0.00s)\nFAIL\nFAIL\tkogen\t0.010s\nFAIL\n' };
    try {
      judge(ok, arg === 'good' ? failed : ok, 'control');
      console.log('observer accepted ' + arg);
    } catch (e) {
      console.log('observer rejected ' + arg);
      process.exit(1);
    }
  } else if (process.argv[2] === '--run') {
    const r = exercise(process.argv[3]);
    judge(r.baseline, r.mutant, r.name);
    console.log('caught ' + r.name);
  }
} else {
  const { When, Then } = require('@cucumber/cucumber');
  When('completion-resume-candidate-filter: the cli facts tests run against the resume policy {string}', { timeout: 110000 }, function (name) {
    this.resumePolicy = exercise(name);
  });
  Then('completion-resume-candidate-filter: the cli facts tests pass unmodified and fail under that policy', function () {
    judge(this.resumePolicy.baseline, this.resumePolicy.mutant, this.resumePolicy.name);
  });
}
