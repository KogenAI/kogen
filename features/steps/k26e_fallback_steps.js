'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const ROOT = path.resolve(__dirname, '../..');
const MODES = ['mixed', 'missing', 'contradicts'];
const L_D1 = '- Zero counts as even. (assumption: the request is silent on zero) (source: request)';
const L_D2 = '- Negative numbers are even by parity. (assumption: the request is silent on negatives) (source: request)';
const L_P1 = '- Input --5 stays invalid. (assumption: the request is silent on input syntax) (source: request)';
const L_P2 = '- (a zero result is plain 0) (assumption: the request is silent on zero results) (source: request)';
const PROSE = 'calc.is_even(n) returns True for even integers. Input --5 stays invalid. Zero is handled (a zero result\nis plain 0).';
const CARD = [
  '  - Zero counts as even. (assumption: the request is silent on zero)',
  '  - Negative numbers are even by parity. (assumption: the request is silent on negatives)',
  '  - Input --5 stays invalid. (assumption: the request is silent on input syntax)',
  '  - (a zero result is plain 0) (assumption: the request is silent on zero results)',
];
const STATEMENTS = [
  '- Zero counts as even. (source: request)',
  '- Negative numbers are even by parity. (source: request)',
  'Input --5 stays invalid.',
  '(a zero result  is plain 0)',
];
const cache = new Map();

function observe(mode) {
  if (cache.has(mode)) return cache.get(mode);
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-k26e-'));
  fs.chmodSync(dir, 0o700);
  try {
    const output = path.join(dir, 'output.json'), overlay = path.join(dir, 'overlay.json');
    fs.writeFileSync(overlay, JSON.stringify({ Replace: { [path.join(ROOT, 'cli/shape/k26e_fallback_acceptance_test.go')]: path.join(__dirname, 'k26e_fallback_driver.go') } }), { mode: 0o600 });
    const r = spawnSync('go', ['test', '-overlay', overlay, './shape', '-run', '^TestK26eFallbackObservation$', '-count=1'], {
      cwd: path.join(ROOT, 'cli'), encoding: 'utf8', timeout: 240000, maxBuffer: 8 * 1024 * 1024,
      env: { ...process.env, KOGEN_K26E_MODE: mode, KOGEN_K26E_OUTPUT: output },
    });
    assert.ifError(r.error);
    assert.equal(r.status, 0, `observation failed:\n${r.stdout}\n${r.stderr}`);
    const data = JSON.parse(fs.readFileSync(output, 'utf8'));
    assert.equal(data.mode, mode);
    cache.set(mode, data);
    return data;
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
}

function refusedAre(d, n) {
  assert.equal(d.refused.length, n, `one submission_refused event per refused attempt: ${JSON.stringify(d.refused)}`);
  d.refused.forEach((e, i) => { assert.equal(e.attempt, i + 1); assert.equal(e.gate, 'decision_check'); });
}

function refusedUnchanged(d) {
  assert.notEqual(d.error_text, '', 'Shape ends refused');
  assert.equal(d.published, false);
  assert.equal(d.decision_checks, 3);
  assert.ok(!d.intent_disk.includes('(assumption:'), 'nothing is marked');
  assert.ok(!d.intent_disk.includes('- Input --5'), 'nothing is added');
  assert.ok(!d.intent_disk.includes('- (a zero result'), 'nothing is added');
  assert.equal(d.marked.length, 0, 'no marked event');
  refusedAre(d, 3);
  assert.equal(d.card_exit, -1);
}

const CHECKS = {
  mixed(d) {
    assert.equal(d.error_text, '', d.error_text);
    assert.equal(d.exit, 0);
    assert.equal(d.published, true);
    assert.equal(d.decision_checks, 3, 'the decision check ran on every attempt only');
    refusedAre(d, 2);
    const lines = d.intent.split('\n');
    for (const l of [L_D1, L_D2, L_P1, L_P2]) assert.equal(lines.filter(x => x === l).length, 1, `exactly one line ${l}:\n${d.intent}`);
    assert.ok(!lines.includes('- Zero counts as even. (source: request)'), 'unmarked tagged line is gone');
    assert.ok(d.intent.includes(PROSE), 'the prose is unchanged');
    const sec = lines.slice(lines.indexOf('## Decisions'), lines.indexOf('## Source comparison'));
    assert.deepEqual(sec.filter(l => l.startsWith('- ')), ['- Non-integers raise TypeError. (source: request)', L_D1, L_D2, L_P1, L_P2], 'marked in place, fragments appended in order');
    assert.equal(d.marked.length, 1);
    const m = d.marked[0];
    assert.equal(m.event, 'decision_assumptions_marked');
    assert.deepEqual(m.statements, STATEMENTS);
    assert.deepEqual(m.placement, ['in_place', 'in_place', 'added', 'added']);
    assert.equal(d.card_exit, 5, d.card);
    const card = d.card.split('\n');
    const h = card.indexOf('Assumptions to confirm');
    assert.ok(h >= 0, `card lacks the section:\n${d.card}`);
    const files = card.indexOf('Files');
    assert.ok(files > h);
    assert.deepEqual(card.slice(h + 1, files).filter(l => l.startsWith('  - ')), CARD);
  },
  missing(d) { refusedUnchanged(d); },
  contradicts(d) { refusedUnchanged(d); },
};

function good(mode) {
  const ev = n => ({ event: 'submission_refused', attempt: n, gate: 'decision_check', problems: ['x'] });
  const base = { mode, exit: 0, error_text: '', published: true, decision_checks: 3, refused: [ev(1), ev(2)], marked: [], card_exit: 5, card: '', intent: '', intent_disk: '' };
  if (mode === 'mixed') {
    const intent = `# T\n\n${PROSE}\n\n## Decisions\n- Non-integers raise TypeError. (source: request)\n${L_D1}\n${L_D2}\n${L_P1}\n${L_P2}\n\n## Source comparison\n- x\n`;
    return { ...base, intent, intent_disk: intent,
      marked: [{ event: 'decision_assumptions_marked', statements: [...STATEMENTS], placement: ['in_place', 'in_place', 'added', 'added'] }],
      card: `Intent\nAssumptions to confirm\n${CARD.join('\n')}\nFiles\n  - a\n` };
  }
  return { ...base, published: false, error_text: 'intent/not_ready', refused: [ev(1), ev(2), ev(3)], card_exit: -1,
    intent_disk: `# T\n\n${PROSE}\n\n## Decisions\n- Zero counts as even. (source: request)\n` };
}

function controls(kind) {
  for (const m of MODES) CHECKS[m](good(m));
  if (kind === 'good') { console.log('k26e observer good'); return; }
  assert.equal(kind, 'bad');
  const bad = (mode, mutate) => { const c = structuredClone(good(mode)); mutate(c); assert.throws(() => CHECKS[mode](c), `accepted a known-bad ${mode} fixture`); };
  bad('mixed', d => { d.published = false; });
  bad('mixed', d => { d.intent = d.intent.replace(L_P1, ''); });
  bad('mixed', d => { d.intent = d.intent.replace(L_P2, '- (a zero result is plain 0) (source: request)'); });
  bad('mixed', d => { d.intent = d.intent.replace(L_D1, '- Zero counts as even. (source: request)'); });
  bad('mixed', d => { d.intent = d.intent.replace(PROSE, 'changed prose'); });
  bad('mixed', d => { d.intent = d.intent.replace(`${L_P1}\n${L_P2}`, `${L_P2}\n${L_P1}`); });
  bad('mixed', d => { d.marked = []; });
  bad('mixed', d => { d.marked[0].placement = ['in_place', 'in_place', 'in_place', 'added']; });
  bad('mixed', d => { d.marked[0].statements.pop(); });
  bad('mixed', d => { d.card = d.card.replace(CARD[3], '  - other'); });
  bad('mixed', d => { d.card = d.card.replace('Assumptions to confirm', 'Other'); });
  bad('mixed', d => { d.card_exit = 0; });
  bad('mixed', d => { d.decision_checks = 1; });
  bad('mixed', d => { d.refused.pop(); });
  for (const m of ['missing', 'contradicts']) {
    bad(m, d => { d.published = true; });
    bad(m, d => { d.error_text = ''; });
    bad(m, d => { d.intent_disk += `${L_P1}\n`; });
    bad(m, d => { d.intent_disk = d.intent_disk.replace('- Zero counts as even. (source: request)', L_D1); });
    bad(m, d => { d.marked = [{ event: 'decision_assumptions_marked', statements: [] }]; });
    bad(m, d => { d.refused.pop(); });
    bad(m, d => { d.card_exit = 5; });
  }
  console.log('k26e observer rejected bad fixtures');
  process.exitCode = 1;
}

if (require.main === module && process.argv[2] === '--control') {
  controls(process.argv[3]);
} else {
  const { When, Then } = require('@cucumber/cucumber');
  When('the k26e Shape plays {string}', { timeout: 250000 }, function (mode) { assert.ok(MODES.includes(mode), mode); this.k26e = observe(mode); });
  Then('the k26e observation satisfies the contract of its mode', function () { CHECKS[this.k26e.mode](this.k26e); });
}
