'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const ROOT = path.resolve(__dirname, '../..');
const HEAD = 'Decision check: 1 stated decisions are not supported by the request; follow the request, or ask, or mark the decision as an assumption the user must confirm:';
const INSTR = 'Mark an assumption with (assumption: <what the user must confirm>) before the required trailing tag, e.g. - <decision> (assumption: <what the user must confirm>) (source: request); every Decision line keeps its trailing (source: request) or (source: answer N).';
const ASSUMED = '- Zero counts as even. (assumption: the request is silent on zero) (source: request)';
const ASSUMED_CARD = '  - Zero counts as even. (assumption: the request is silent on zero)';
const SECTION = 'Unresolved request conflicts';
const CONFLICT = '  - quote_a: Example: is_even(0) returns True. | quote_b: Rule B: zero returns False. | exposing_input: is_even(0)';
const PASTED = '- Decision: for is_even(0) the result is True (because …) (source: request)';
const MODES = ['assume', 'paste', 'stale', 'stale_covered'];
const cache = new Map();

function observe(mode) {
  if (cache.has(mode)) return cache.get(mode);
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-k26b-'));
  fs.chmodSync(dir, 0o700);
  try {
    const output = path.join(dir, 'output.json'), overlay = path.join(dir, 'overlay.json');
    fs.writeFileSync(overlay, JSON.stringify({ Replace: { [path.join(ROOT, 'cli/shape/k26b_source_tag_acceptance_test.go')]: path.join(__dirname, 'k26b_source_tag_driver.go') } }), { mode: 0o600 });
    const r = spawnSync('go', ['test', '-overlay', overlay, './shape', '-run', '^TestK26bSourceTagObservation$', '-count=1'], {
      cwd: path.join(ROOT, 'cli'), encoding: 'utf8', timeout: 240000, maxBuffer: 8 * 1024 * 1024,
      env: { ...process.env, KOGEN_K26B_MODE: mode, KOGEN_K26B_OUTPUT: output },
    });
    assert.ifError(r.error);
    assert.equal(r.status, 0, `observation failed:\n${r.stdout}\n${r.stderr}`);
    const data = JSON.parse(fs.readFileSync(output, 'utf8'));
    assert.equal(data.mode, mode);
    cache.set(mode, data);
    return data;
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
}

function published(d) {
  assert.equal(d.error_text, '', d.error_text);
  assert.equal(d.exit, 0);
  assert.equal(d.published, true);
  assert.equal(d.card_exit, 5, d.card);
}
function cardLines(card) { return card.split('\n'); }

const CHECKS = {
  assume(d) {
    published(d);
    const lines = d.feedback.split('\n');
    assert.equal(lines[0], HEAD, d.feedback);
    assert.equal(lines[1], INSTR, `the feedback says exactly how to mark an assumption:\n${d.feedback}`);
    assert.ok(lines.slice(2).some(l => l.startsWith('statement: - Zero counts as even. (source: request) |')), d.feedback);
    assert.ok(d.intent.split('\n').includes(ASSUMED), `the assumption keeps its trailing source tag:\n${d.intent}`);
    const cl = cardLines(d.card);
    const at = cl.indexOf('Assumptions to confirm');
    assert.ok(at >= 0, d.card);
    assert.equal(cl[at + 1], ASSUMED_CARD, `the card lists the assumption without its source tag:\n${d.card}`);
    assert.ok(cl.filter(l => l.includes('(assumption:')).every(l => l === ASSUMED_CARD), d.card);
  },
  paste(d) {
    published(d);
    assert.equal(d.pasted, PASTED);
    assert.ok(d.pasted.endsWith(' (source: request)'));
    assert.ok(d.intent.split('\n').includes(d.pasted), d.intent);
    assert.ok(!d.card.includes(SECTION), d.card);
  },
  stale(d) {
    published(d);
    const cl = cardLines(d.card);
    const at = cl.indexOf(SECTION);
    assert.ok(at >= 0 && cl[at + 1] === CONFLICT, `the run that left a defect uncovered shows the section:\n${d.card}`);
    reshaped(d);
  },
  stale_covered(d) {
    published(d);
    assert.ok(cardLines(d.card).includes(SECTION), d.card);
    reshaped(d);
  },
};
function reshaped(d) {
  assert.equal(d.second_error, '', d.second_error);
  assert.equal(d.second_exit, 0);
  assert.equal(d.card2_exit, 5, d.card2);
  assert.ok(d.card2.includes('Intent: is-even'), d.card2);
  assert.ok(!d.card2.includes(SECTION) && !d.card2.includes('quote_a:'), `no stale conflicts section after the reshape:\n${d.card2}`);
}

function good(mode) {
  const base = { mode, exit: 0, error_text: '', published: true, intent: '', feedback: '', pasted: '', card_exit: 5,
    card: 'Intent: is-even\nFiles\n', card2_exit: -1, card2: '', second_exit: -1, second_error: '' };
  switch (mode) {
    case 'assume': return { ...base, feedback: `${HEAD}\n${INSTR}\nstatement: - Zero counts as even. (source: request) | request_quotes:  | why: silent`,
      intent: `- Non-integers raise TypeError. (source: request)\n${ASSUMED}\n`, card: `Intent: is-even\nAssumptions to confirm\n${ASSUMED_CARD}\nFiles\n` };
    case 'paste': return { ...base, pasted: PASTED, intent: `${PASTED}\n` };
    case 'stale': case 'stale_covered': return { ...base, card: `Intent: is-even\n${SECTION}\n${CONFLICT}\nFiles\n`,
      second_exit: 0, card2_exit: 5, card2: 'Intent: is-even\nFiles\n' };
  }
  throw new Error(mode);
}

function controls(kind) {
  for (const m of MODES) CHECKS[m](good(m));
  if (kind === 'good') { console.log('k26b observer good'); return; }
  assert.equal(kind, 'bad');
  const bad = (mode, mutate) => { const c = structuredClone(good(mode)); mutate(c); assert.throws(() => CHECKS[mode](c), `accepted a known-bad ${mode} fixture`); };
  bad('assume', d => { d.exit = 4; });
  bad('assume', d => { d.feedback = d.feedback.replace(INSTR, 'x'); });
  bad('assume', d => { d.feedback = d.feedback.replace(HEAD, 'x'); });
  bad('assume', d => { d.intent = '- Zero counts as even. (assumption: the request is silent on zero)\n'; });
  bad('assume', d => { d.card = d.card.replace(ASSUMED_CARD, `${ASSUMED_CARD} (source: request)`); });
  bad('assume', d => { d.card = d.card.replace('Assumptions to confirm', 'Notes'); });
  bad('assume', d => { d.card_exit = 0; });
  bad('paste', d => { d.pasted = d.pasted.replace(' (source: request)', ''); });
  bad('paste', d => { d.intent = ''; });
  bad('paste', d => { d.card += `${SECTION}\n`; });
  bad('paste', d => { d.error_text = 'boom'; });
  for (const m of ['stale', 'stale_covered']) {
    bad(m, d => { d.card2 += `${SECTION}\n${CONFLICT}\n`; });
    bad(m, d => { d.card2_exit = 1; });
    bad(m, d => { d.second_error = 'boom'; });
    bad(m, d => { d.card2 = ''; });
    bad(m, d => { d.card = 'Intent: is-even\nFiles\n'; });
  }
  console.log('k26b observer rejected bad fixtures');
  process.exitCode = 1;
}

if (require.main === module && process.argv[2] === '--control') {
  controls(process.argv[3]);
} else {
  const { When, Then } = require('@cucumber/cucumber');
  When('the k26b Shape plays {string}', { timeout: 250000 }, function (mode) { assert.ok(MODES.includes(mode), mode); this.k26b = observe(mode); });
  Then('the k26b observation satisfies the contract of its mode', function () { CHECKS[this.k26b.mode](this.k26b); });
}
