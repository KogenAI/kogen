'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const ROOT = path.resolve(__dirname, '../..');
const ZERO = '- Zero counts as even.';
const MARKED = `${ZERO} (assumption: the request is silent on zero) (source: request)`;
const CARD_LINE = '  - Zero counts as even. (assumption: the request is silent on zero)';
const COVER = '- Decision: for is_even(0) the result is True (because the example states it) (source: request)';
const MODES = ['unsupported', 'contradicts', 'bounded', 'wrapcol'];
const cache = new Map();

function observe(mode) {
  if (cache.has(mode)) return cache.get(mode);
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-k26c-'));
  fs.chmodSync(dir, 0o700);
  try {
    const output = path.join(dir, 'output.json'), overlay = path.join(dir, 'overlay.json');
    fs.writeFileSync(overlay, JSON.stringify({ Replace: { [path.join(ROOT, 'cli/shape/k26c_fallback_acceptance_test.go')]: path.join(__dirname, 'k26c_fallback_driver.go') } }), { mode: 0o600 });
    const r = spawnSync('go', ['test', '-overlay', overlay, './shape', '-run', '^TestK26cFallbackObservation$', '-count=1'], {
      cwd: path.join(ROOT, 'cli'), encoding: 'utf8', timeout: 240000, maxBuffer: 8 * 1024 * 1024,
      env: { ...process.env, KOGEN_K26C_MODE: mode, KOGEN_K26C_OUTPUT: output },
    });
    assert.ifError(r.error);
    assert.equal(r.status, 0, `observation failed:\n${r.stdout}\n${r.stderr}`);
    const data = JSON.parse(fs.readFileSync(output, 'utf8'));
    assert.equal(data.mode, mode);
    cache.set(mode, data);
    return data;
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
}

function refusedAre(d, attempts, gate) {
  assert.equal(d.refused.length, attempts.length, `one submission_refused event per refused attempt: ${JSON.stringify(d.refused)}`);
  d.refused.forEach((e, i) => {
    assert.equal(e.event, 'submission_refused');
    assert.equal(e.attempt, attempts[i]);
    assert.equal(e.gate, gate);
    assert.ok(Array.isArray(e.problems) && e.problems.length >= 1 && e.problems.length <= 20, 'at most 20 problem lines');
    for (const p of e.problems) assert.ok(typeof p === 'string' && [...p].length <= 300, 'at most 300 characters per line');
  });
}

const CHECKS = {
  unsupported(d) {
    assert.equal(d.error_text, '', d.error_text);
    assert.equal(d.exit, 0);
    assert.equal(d.published, true);
    assert.equal(d.decision_checks, 3, 'the decision check ran on every attempt');
    assert.ok(d.intent.split('\n').includes(MARKED), `the flagged line carries the assumption before its source tag:\n${d.intent}`);
    assert.ok(d.feedback1.includes('Decision check: 1 stated decisions are not supported'), 'earlier attempts get the feedback as before');
    refusedAre(d, [1, 2], 'decision_check');
    assert.ok(d.refused.every(e => e.problems.some(p => p.includes('Zero counts as even.'))), 'the refused problem lines name the statement');
    assert.equal(d.marked.length, 1);
    assert.equal(d.marked[0].event, 'decision_assumptions_marked');
    assert.deepEqual(d.marked[0].statements, [`${ZERO} (source: request)`]);
    assert.equal(d.card_exit, 5, d.card);
    const lines = d.card.split('\n');
    const h = lines.indexOf('Assumptions to confirm');
    assert.ok(h >= 0, `card lacks the section:\n${d.card}`);
    const files = lines.indexOf('Files');
    assert.ok(files > h);
    assert.ok(lines.slice(h + 1, files).includes(CARD_LINE), `card lacks the assumption line:\n${d.card}`);
  },
  contradicts(d) {
    assert.notEqual(d.error_text, '', 'Shape ends refused');
    assert.equal(d.published, false, 'nothing is published');
    assert.ok(!d.intent_disk.includes('(assumption:'), 'a contradicting decision is never marked');
    assert.equal(d.decision_checks, 3);
    refusedAre(d, [1, 2, 3], 'decision_check');
    assert.equal(d.marked.length, 0, 'a contradicting decision is never marked');
    assert.equal(d.card_exit, -1);
  },
  bounded(d) {
    assert.notEqual(d.error_text, '');
    assert.equal(d.published, false);
    refusedAre(d, [1, 2, 3], 'decision_check');
    assert.ok(d.refused.every(e => e.problems.length === 20), 'problem lines are cut to 20');
    assert.ok(d.refused[0].problems.some(p => [...p].length === 300), 'long lines are cut to 300 characters');
    assert.equal(d.marked.length, 0, 'statements that are not Decisions lines are not marked');
  },
  wrapcol(d) {
    assert.ok(!d.error_text.includes('does not exist'), d.error_text);
    assert.equal(d.error_text, '', d.error_text);
    assert.equal(d.exit, 0);
    assert.equal(d.published, true);
    assert.equal(d.feature_exists, true, 'the correction keeps acceptance.feature');
    assert.equal(d.steps_exists, true, 'the correction keeps the step file');
    assert.ok(d.intent.split('\n').includes(COVER), 'the correction is published');
    assert.ok(d.refused.length >= 1);
    assert.equal(d.refused[0].attempt, 1);
    assert.equal(d.refused[0].gate, 'audit');
    assert.ok(d.refused[0].problems[0].startsWith('Request audit: 1 defects'), d.refused[0].problems[0]);
  },
};

function ev(attempt, gate, extra = {}) {
  return { event: 'submission_refused', attempt, gate, problems: ['Mark an assumption with x', `statement: ${ZERO} (source: request) | why: y`], ...extra };
}

function good(mode) {
  const base = { mode, exit: 0, error_text: '', published: true, intent: '', intent_disk: '', feedback1: '', decision_checks: 3, refused: [], marked: [],
    card_exit: -1, card: '', feature_exists: true, steps_exists: true };
  switch (mode) {
    case 'unsupported': return { ...base, intent: `x\n${MARKED}\n`, feedback1: 'Decision check: 1 stated decisions are not supported by the request',
      refused: [ev(1, 'decision_check'), ev(2, 'decision_check')],
      marked: [{ event: 'decision_assumptions_marked', statements: [`${ZERO} (source: request)`] }],
      card_exit: 5, card: `Intent: x\nAssumptions to confirm\n${CARD_LINE}\nFiles\n  - a\n` };
    case 'contradicts': return { ...base, error_text: 'intent/not_ready', published: false, intent_disk: `x\n${ZERO} (source: request)\n`,
      refused: [1, 2, 3].map(n => ev(n, 'decision_check')) };
    case 'bounded': {
      const long = 'z'.repeat(300);
      const problems = Array.from({ length: 20 }, (_, i) => (i === 0 ? long : 'p'));
      return { ...base, error_text: 'intent/not_ready', published: false,
        refused: [1, 2, 3].map(n => ev(n, 'decision_check', { problems })) };
    }
    case 'wrapcol': return { ...base, intent: `x\n${COVER}\n`, decision_checks: 0,
      refused: [{ event: 'submission_refused', attempt: 1, gate: 'audit', problems: ['Request audit: 1 defects are not decided or asked; decide each:'] }] };
  }
  throw new Error(mode);
}

function controls(kind) {
  for (const m of MODES) CHECKS[m](good(m));
  if (kind === 'good') { console.log('k26c observer good'); return; }
  assert.equal(kind, 'bad');
  const bad = (mode, mutate) => { const c = structuredClone(good(mode)); mutate(c); assert.throws(() => CHECKS[mode](c), `accepted a known-bad ${mode} fixture`); };
  bad('unsupported', d => { d.intent = `x\n${ZERO} (source: request)\n`; });
  bad('unsupported', d => { d.intent = `x\n${ZERO} (source: request) (assumption: the request is silent on zero)\n`; });
  bad('unsupported', d => { d.published = false; });
  bad('unsupported', d => { d.marked = []; });
  bad('unsupported', d => { d.marked[0].statements = []; });
  bad('unsupported', d => { d.refused.pop(); });
  bad('unsupported', d => { d.refused[1].gate = 'readiness'; });
  bad('unsupported', d => { d.refused[0].problems = []; });
  bad('unsupported', d => { d.refused[0].problems = Array(21).fill('p'); });
  bad('unsupported', d => { d.refused[0].problems = ['y'.repeat(301)]; });
  bad('unsupported', d => { d.card = d.card.replace('Assumptions to confirm', 'Other'); });
  bad('unsupported', d => { d.card = d.card.replace(CARD_LINE, '  - other'); });
  bad('unsupported', d => { d.card_exit = 0; });
  bad('unsupported', d => { d.decision_checks = 1; });
  bad('contradicts', d => { d.published = true; });
  bad('contradicts', d => { d.error_text = ''; });
  bad('contradicts', d => { d.intent_disk = `x\n${MARKED}\n`; });
  bad('contradicts', d => { d.marked = [{ event: 'decision_assumptions_marked', statements: [ZERO] }]; });
  bad('contradicts', d => { d.refused.pop(); });
  bad('bounded', d => { d.refused[1].problems = d.refused[1].problems.slice(0, 19); });
  bad('bounded', d => { d.refused[0].problems = d.refused[0].problems.map(() => 'p'); });
  bad('bounded', d => { d.published = true; });
  bad('wrapcol', d => { d.error_text = 'intent/lint: .kogen/intents/is-even/acceptance.feature does not exist'; });
  bad('wrapcol', d => { d.feature_exists = false; });
  bad('wrapcol', d => { d.steps_exists = false; });
  bad('wrapcol', d => { d.published = false; });
  bad('wrapcol', d => { d.intent = 'x'; });
  bad('wrapcol', d => { d.refused = []; });
  bad('wrapcol', d => { d.refused[0].gate = 'validation'; });
  console.log('k26c observer rejected bad fixtures');
  process.exitCode = 1;
}

if (require.main === module && process.argv[2] === '--control') {
  controls(process.argv[3]);
} else {
  const { When, Then } = require('@cucumber/cucumber');
  When('the k26c Shape plays {string}', { timeout: 250000 }, function (mode) { assert.ok(MODES.includes(mode), mode); this.k26c = observe(mode); });
  Then('the k26c observation satisfies the contract of its mode', function () { CHECKS[this.k26c.mode](this.k26c); });
}
