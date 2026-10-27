'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const ROOT = path.resolve(__dirname, '../..');
const PROBLEM = /^invalid verdict:\n(\d+) pinned part\(s\) unread; read them before a verdict; incomplete delivery is not a candidate defect; use read_file on \S+/;

function put(file, bytes) {
  fs.writeFileSync(file, bytes, { mode: 0o600 });
  fs.chmodSync(file, 0o600);
}
function observe(steps) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-k11-'));
  fs.chmodSync(dir, 0o700);
  try {
    const input = path.join(dir, 'input.json'), output = path.join(dir, 'output.json'), overlay = path.join(dir, 'overlay.json');
    put(input, JSON.stringify({ steps }));
    put(overlay, JSON.stringify({ Replace: {
      [path.join(ROOT, 'cli/build/k11_review_unread_acceptance_test.go')]: path.join(__dirname, 'k11_review_unread_driver.go'),
    } }));
    const r = spawnSync('go', ['test', '-overlay', overlay, './build', '-run', '^TestK11ReviewUnreadObservation$', '-count=1'], {
      cwd: path.join(ROOT, 'cli'), encoding: 'utf8', timeout: 240000, maxBuffer: 8 * 1024 * 1024,
      env: { ...process.env, KOGEN_K11_INPUT: input, KOGEN_K11_OUTPUT: output },
    });
    assert.ifError(r.error);
    assert.equal(r.status, 0, `observation failed:\n${r.stdout}\n${r.stderr}`);
    // Go success alone is not proof: the requested test must have emitted its observation.
    return JSON.parse(fs.readFileSync(output, 'utf8'));
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
}
const counts = d => d.feedback.map(t => { const m = PROBLEM.exec(t); return m ? Number(m[1]) : null; });

function checkLanded(d, minFeedback) {
  assert.equal(d.outcome, 'landed', d.output);
  assert.equal(d.exit, 0, d.output);
  assert.equal(d.head_changed, true);
  const c = counts(d);
  assert.ok(c.length >= minFeedback, `want at least ${minFeedback} unread feedback(s), got ${JSON.stringify(d.feedback)}`);
  assert.ok(c.every(n => n !== null && n > 0), `feedback is not the unread-parts problem: ${JSON.stringify(d.feedback)}`);
  for (let i = 1; i < c.length; i++) assert.ok(c[i] < c[i - 1], `unread count did not fall: ${c}`);
}
function checkBlocked(d) {
  assert.equal(d.outcome, 'review_blocked', d.output);
  assert.equal(d.exit, 1);
  assert.equal(d.head_changed, false);
  assert.ok(d.output.includes('candidate/review_blocked'), d.output);
  assert.ok(d.output.includes('real defect'), d.output);
  assert.ok(!d.feedback.some(t => /pinned part\(s\) unread/.test(t)), 'unread feedback after all parts were read');
}
function checkStopped(d) {
  assert.equal(d.head_changed, false);
  assert.equal(d.exit, 1);
  assert.ok(['review_invalid', 'review_blocked'].includes(d.outcome), d.output);
  assert.ok(d.requests <= 45, 'the loop did not end');
}
function sourceChecks() {
  const ext = fs.readFileSync(path.join(ROOT, 'cli/build/review_external.go'), 'utf8');
  assert.ok(ext.includes('if err := b.facts.update(b, "reviewing", ""); err != nil {'), 'review_external.go ignores the facts.update error');
  assert.ok(!/^\s*b\.facts\.update\(b, "reviewing", ""\)\s*$/m.test(ext), 'an ignored facts.update call remains');
  const lineup = fs.readFileSync(path.join(ROOT, 'cli/build/review_lineup_test.go'), 'utf8');
  const start = lineup.indexOf('t.Run("native builder checkpoint"');
  assert.ok(start >= 0, 'subtest missing');
  const body = lineup.slice(start, lineup.indexOf('\n\t})\n', start));
  assert.ok(/exit/.test(body) && /(landed|head\(\)|HEAD)/.test(body), 'the resume subtest does not assert exit and landing');
}
function goTests(dir, pattern) {
  const r = spawnSync('go', ['test', '-json', '-run', pattern, '-count=1', dir], {
    cwd: path.join(ROOT, 'cli'), encoding: 'utf8', timeout: 240000, maxBuffer: 16 * 1024 * 1024,
  });
  assert.ifError(r.error);
  const ev = r.stdout.split('\n').filter(l => l.startsWith('{')).map(l => JSON.parse(l));
  return { status: r.status, ev, text: r.stdout + r.stderr };
}
function passed(res, name) { return res.ev.some(e => e.Action === 'pass' && e.Test === name); }

// Final-byte observer controls: the checks must accept good observations and reject bad ones.
function controls(kind) {
  const fb = n => `invalid verdict:\n${n} pinned part(s) unread; read them before a verdict; incomplete delivery is not a candidate defect; use read_file on a.json, b.json`;
  const landed = { outcome: 'landed', exit: 0, head_changed: true, feedback: [fb(9), fb(4)], output: '', requests: 5 };
  const blocked = { outcome: 'review_blocked', exit: 1, head_changed: false, feedback: [], output: 'candidate/review_blocked\n  review: app.txt:1: real defect', requests: 3 };
  const stopped = { outcome: 'review_invalid', exit: 1, head_changed: false, feedback: [fb(3)], output: '', requests: 3 };
  checkLanded(landed, 2); checkBlocked(blocked); checkStopped(stopped);
  if (kind === 'good') { console.log('k11 observer good'); return; }
  assert.equal(kind, 'bad');
  const bad = (fn, d, mutate) => { const c = structuredClone(d); mutate(c); assert.throws(() => fn(c), 'accepted a known-bad fixture'); };
  bad(d => checkLanded(d, 2), landed, d => { d.feedback = [fb(4), fb(9)]; });
  bad(d => checkLanded(d, 2), landed, d => { d.feedback = [fb(4), 'other']; });
  bad(d => checkLanded(d, 2), landed, d => { d.outcome = 'review_invalid'; });
  bad(d => checkLanded(d, 2), landed, d => { d.feedback = [fb(4)]; });
  bad(checkBlocked, blocked, d => { d.outcome = 'landed'; });
  bad(checkBlocked, blocked, d => { d.feedback = [fb(2)]; });
  bad(checkStopped, stopped, d => { d.head_changed = true; });
  bad(checkStopped, stopped, d => { d.requests = 60; });
  console.log('k11 observer rejected bad fixtures');
  process.exitCode = 1;
}

if (require.main === module && process.argv[2] === '--control') {
  controls(process.argv[3]);
} else {
  const { When, Then } = require('@cucumber/cucumber');
  When('the k11 reviewer plays {string}', { timeout: 250000 }, function (script) { this.k11 = observe(script.split(',')); });
  Then('the k11 build landed after at least {int} unread-parts feedback(s) with a falling count', function (n) { checkLanded(this.k11, n); });
  Then('the k11 build stopped as review_blocked on the real finding', function () { checkBlocked(this.k11); });
  Then('the k11 build ended without a commit and without looping', function () { checkStopped(this.k11); });
  Then('the k11 review_external.go and resume subtest follow-ups are in place', function () { sourceChecks(); });
  Then('the go test {string} named {string} passes', { timeout: 250000 }, function (pkg, name) {
    const res = goTests(pkg, '^' + name.split('/')[0] + '$');
    assert.equal(res.status, 0, res.text);
    assert.ok(passed(res, name.replace(/ /g, '_')), `test ${name} did not run and pass:\n${res.text}`);
  });
  Then('the go package {string} has a passing test whose name starts with {string}', { timeout: 250000 }, function (pkg, prefix) {
    const res = goTests(pkg, '^' + prefix);
    assert.equal(res.status, 0, res.text);
    assert.ok(res.ev.some(e => e.Action === 'pass' && e.Test && e.Test.startsWith(prefix)), `no passing ${prefix}* test:\n${res.text}`);
  });
}
