'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const ROOT = path.resolve(__dirname, '../..');
const REQ = 'Add calc.is_even(n). Example: is_even(0) returns True. Non-integers raise TypeError.';
const EXAMPLE = 'Example: is_even(0) returns True.';
const RULE = 'Non-integers raise TypeError.';
const FAKE = 'Example: is_even(0) always returns True.';
const BASE = '- Non-integers raise TypeError. (source: request)';
const WRONG = '- is_even(0) returns False. (source: request)';
const RIGHT = '- is_even(0) returns True. (source: request)';
const ASSUME = '- Zero counts as even. (assumption: the request is silent on zero) (source: request)';
const ASSUME_CARD = 'Zero counts as even. (assumption: the request is silent on zero)';
const HEAD = 'Decision check: 1 stated decisions are not supported by the request; follow the request, or ask, or mark the decision as an assumption the user must confirm:';
const WHY_WRONG = 'the request example says True';
const WHY_FAKE = 'the request says so';
const USAGE = {
  four: 'input=406 cached=160 output=120 reasoning=40',
  two: 'input=201 cached=80 output=60 reasoning=20',
  one: 'input=100 cached=40 output=30 reasoning=10',
};
const MODES = ['contradict', 'unsupported', 'assumption', 'off', 'badkey'];
const cache = new Map();

const item = (statement, quotes, verdict, why) => ({ statement, request_quotes: quotes, verdict, why });
const I_BASE = item(BASE, [RULE], 'follows', 'the request states it');
const EVENTS = {
  contradict: [
    { event: 'decision_check', follows: 1, contradicts: 1, unsupported: 0, items: [I_BASE, item(WRONG, [EXAMPLE], 'contradicts', WHY_WRONG)] },
    { event: 'decision_check', follows: 2, contradicts: 0, unsupported: 0, items: [I_BASE, item(RIGHT, [EXAMPLE], 'follows', WHY_WRONG)] },
  ],
  unsupported: [
    { event: 'decision_check', follows: 1, contradicts: 0, unsupported: 1, items: [I_BASE, item(RIGHT, [FAKE], 'unsupported', WHY_FAKE)] },
    { event: 'decision_check', follows: 2, contradicts: 0, unsupported: 0, items: [I_BASE, item(RIGHT, [EXAMPLE], 'follows', WHY_WRONG)] },
  ],
  assumption: [
    { event: 'decision_check', follows: 1, contradicts: 0, unsupported: 1, items: [I_BASE, item(ASSUME, [], 'unsupported', 'the request is silent on zero')] },
  ],
};

function observe(mode) {
  if (cache.has(mode)) return cache.get(mode);
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-k26-'));
  fs.chmodSync(dir, 0o700);
  try {
    const output = path.join(dir, 'output.json'), overlay = path.join(dir, 'overlay.json');
    fs.writeFileSync(overlay, JSON.stringify({ Replace: { [path.join(ROOT, 'cli/shape/k26_decision_check_acceptance_test.go')]: path.join(__dirname, 'k26_decision_check_driver.go') } }), { mode: 0o600 });
    const r = spawnSync('go', ['test', '-overlay', overlay, './shape', '-run', '^TestK26DecisionCheckObservation$', '-count=1'], {
      cwd: path.join(ROOT, 'cli'), encoding: 'utf8', timeout: 240000, maxBuffer: 8 * 1024 * 1024,
      env: { ...process.env, KOGEN_K26_MODE: mode, KOGEN_K26_OUTPUT: output },
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
function checkCalls(d, n) {
  assert.equal(d.check_requests, n, 'one decision-check call per complete candidate');
  assert.equal(d.check_after_shaper, true, 'the check follows the first candidate submission');
  assert.equal(d.check_input_ok, true, 'the check is given the request and the candidate intent.md');
  assert.equal(d.check_leak, false, 'the check sees only the request and the intent.md');
  assert.equal(d.shaper_tools_have_check, false, 'the shaper has no decision-check tool');
  assert.equal(d.selfchecks, 1, 'the step self-check runs once, after the decision check is clean');
  assert.equal(d.check_before_selfcheck, true);
}
function fedBack(d, statement, quote, why) {
  const lines = d.feedback.split('\n');
  assert.equal(lines[0], HEAD, d.feedback);
  assert.ok(lines.slice(1).some(l => l.includes(statement) && l.includes(quote) && l.includes(why)), `no item line:\n${d.feedback}`);
  assert.ok(!/Step self-check failed|Readiness observations/.test(d.feedback), 'decision feedback precedes the step self-check');
}
function noAssumptionCard(d) {
  assert.ok(!d.card.includes('Assumptions to confirm'), d.card);
}

const CHECKS = {
  contradict(d) {
    published(d); checkCalls(d, 2);
    assert.equal(d.requests, 4);
    assert.deepEqual(d.checks, EVENTS.contradict);
    fedBack(d, WRONG, EXAMPLE, WHY_WRONG);
    assert.ok(d.intent.includes(RIGHT) && !d.intent.includes(WRONG), 'the corrected Decision is published');
    assert.ok(d.stdout.includes(USAGE.four), `usage counts both checks: ${d.stdout}`);
    noAssumptionCard(d);
  },
  unsupported(d) {
    published(d); checkCalls(d, 2);
    assert.equal(d.requests, 4);
    assert.deepEqual(d.checks, EVENTS.unsupported);
    fedBack(d, RIGHT, FAKE, WHY_FAKE);
    assert.ok(d.intent.includes(RIGHT));
    assert.ok(d.stdout.includes(USAGE.four), `usage: ${d.stdout}`);
    noAssumptionCard(d);
  },
  assumption(d) {
    published(d); checkCalls(d, 1);
    assert.equal(d.requests, 2);
    assert.deepEqual(d.checks, EVENTS.assumption);
    assert.equal(d.feedback, '', 'an assumption is not fed back');
    assert.ok(d.intent.includes(ASSUME));
    assert.ok(d.stdout.includes(USAGE.two), `usage: ${d.stdout}`);
    const at = d.card.indexOf('Assumptions to confirm');
    assert.ok(at >= 0, d.card);
    assert.ok(d.card.indexOf(ASSUME_CARD) > at, `the card lists the assumption:\n${d.card}`);
  },
  off(d) {
    published(d);
    assert.equal(d.requests, 1);
    assert.equal(d.check_requests, 0);
    assert.deepEqual(d.checks, []);
    assert.equal(d.shaper_mentions_check, false);
    assert.equal(d.shaper_tools_have_check, false);
    assert.equal(d.selfchecks, 1);
    assert.equal(d.feedback, '');
    assert.ok(d.stdout.includes(USAGE.one), `usage: ${d.stdout}`);
    assert.ok(d.intent.includes(ASSUME));
    noAssumptionCard(d);
  },
  badkey(d) {
    assert.notEqual(d.exit, 0);
    assert.ok(d.error_text.includes('unknown key extra'), d.error_text);
    assert.equal(d.requests, 0);
    assert.equal(d.published, false);
  },
};

function good(mode) {
  const base = { mode, exit: 0, error_text: '', published: true, requests: 4, check_requests: 2, check_after_shaper: true, check_input_ok: true,
    check_leak: false, shaper_tools_have_check: false, shaper_mentions_check: true, feedback: '', checks: EVENTS[mode] || [], selfchecks: 1,
    check_before_selfcheck: true, stdout: `shape m/high ${USAGE.four} wall_ms=1\n`, intent: `${BASE}\n${RIGHT}\n`,
    card: 'Intent: is-even\nFiles\n', card_exit: 5 };
  const line = (s, q, w) => `${HEAD}\nstatement: ${s} | request_quotes: "${q}" | why: ${w}`;
  switch (mode) {
    case 'contradict': return { ...base, feedback: line(WRONG, EXAMPLE, WHY_WRONG) };
    case 'unsupported': return { ...base, feedback: line(RIGHT, FAKE, WHY_FAKE) };
    case 'assumption': return { ...base, requests: 2, check_requests: 1, shaper_mentions_check: false, stdout: `shape m/high ${USAGE.two} wall_ms=1\n`,
      intent: `${BASE}\n${ASSUME}\n`, card: `Intent: is-even\nAssumptions to confirm\n  - ${ASSUME_CARD}\nFiles\n` };
    case 'off': return { ...base, requests: 1, check_requests: 0, check_after_shaper: false, check_input_ok: false, shaper_mentions_check: false, checks: [],
      stdout: `shape m/high ${USAGE.one} wall_ms=1\n`, intent: `${BASE}\n${ASSUME}\n` };
    case 'badkey': return { ...base, exit: 3, error_text: 'line 3: unknown key extra', published: false, requests: 0, check_requests: 0, check_after_shaper: false,
      check_input_ok: false, shaper_mentions_check: false, checks: [], selfchecks: 0, stdout: '', intent: '', card: '', card_exit: -1 };
  }
  throw new Error(mode);
}

function controls(kind) {
  for (const m of MODES) CHECKS[m](good(m));
  if (kind === 'good') { console.log('k26 observer good'); return; }
  assert.equal(kind, 'bad');
  const bad = (mode, mutate) => { const c = structuredClone(good(mode)); mutate(c); assert.throws(() => CHECKS[mode](c), `accepted a known-bad ${mode} fixture`); };
  for (const m of ['contradict', 'unsupported', 'assumption']) {
    bad(m, d => { d.check_requests = 0; });
    bad(m, d => { d.check_requests += 1; });
    bad(m, d => { d.check_after_shaper = false; });
    bad(m, d => { d.check_input_ok = false; });
    bad(m, d => { d.check_leak = true; });
    bad(m, d => { d.shaper_tools_have_check = true; });
    bad(m, d => { d.checks = []; });
    bad(m, d => { d.checks[0].unsupported += 1; });
    bad(m, d => { d.checks[0].items[1].verdict = 'follows'; });
    bad(m, d => { d.checks.push(d.checks[0]); });
    bad(m, d => { d.published = false; });
    bad(m, d => { d.requests += 1; });
    bad(m, d => { d.selfchecks = 2; });
    bad(m, d => { d.selfchecks = 0; });
    bad(m, d => { d.check_before_selfcheck = false; });
    bad(m, d => { d.card_exit = 0; });
  }
  for (const [m, s, q, w] of [['contradict', WRONG, EXAMPLE, WHY_WRONG], ['unsupported', RIGHT, FAKE, WHY_FAKE]]) {
    bad(m, d => { d.feedback = ''; });
    bad(m, d => { d.feedback = d.feedback.replace('Decision check', 'Check'); });
    bad(m, d => { d.feedback = d.feedback.replace(s, 'x'); });
    bad(m, d => { d.feedback = d.feedback.replace(q, 'x'); });
    bad(m, d => { d.feedback = d.feedback.replace(w, 'x'); });
    bad(m, d => { d.feedback += '\nStep self-check failed'; });
    bad(m, d => { d.stdout = d.stdout.replace(USAGE.four, USAGE.two); });
    bad(m, d => { d.card += 'Assumptions to confirm\n'; });
    bad(m, d => { d.intent = ''; });
  }
  bad('contradict', d => { d.intent += WRONG; });
  bad('assumption', d => { d.feedback = 'x'; });
  bad('assumption', d => { d.card = d.card.replace('Assumptions to confirm', 'Notes'); });
  bad('assumption', d => { d.card = d.card.replace(ASSUME_CARD, 'x'); });
  bad('assumption', d => { d.card = d.card.replace('Assumptions to confirm', '') + 'Assumptions to confirm\n'; });
  bad('assumption', d => { d.stdout = d.stdout.replace(USAGE.two, USAGE.one); });
  bad('assumption', d => { d.intent = ''; });
  bad('off', d => { d.check_requests = 1; });
  bad('off', d => { d.requests = 2; });
  bad('off', d => { d.checks = EVENTS.assumption; });
  bad('off', d => { d.shaper_mentions_check = true; });
  bad('off', d => { d.shaper_tools_have_check = true; });
  bad('off', d => { d.stdout = d.stdout.replace(USAGE.one, USAGE.two); });
  bad('off', d => { d.card += 'Assumptions to confirm\n'; });
  bad('off', d => { d.published = false; });
  bad('badkey', d => { d.exit = 0; });
  bad('badkey', d => { d.error_text = 'boom'; });
  bad('badkey', d => { d.requests = 1; });
  bad('badkey', d => { d.published = true; });
  console.log('k26 observer rejected bad fixtures');
  process.exitCode = 1;
}

if (require.main === module && process.argv[2] === '--control') {
  controls(process.argv[3]);
} else {
  const { When, Then } = require('@cucumber/cucumber');
  When('the k26 Shape plays {string}', { timeout: 250000 }, function (mode) { assert.ok(MODES.includes(mode), mode); this.k26 = observe(mode); });
  Then('the k26 observation satisfies the contract of its mode', function () { CHECKS[this.k26.mode](this.k26); });
}
