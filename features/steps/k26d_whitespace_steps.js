'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const ROOT = path.resolve(__dirname, '../..');
const LONG = 'Add an is-even check for integers and also reject every string';
const SHORT = 'Add an is-even check for integers and also reject';
const TITLE_PROBLEM = 'title: the title must be at most 50 characters';
const MODES = ['unit', 'wrap', 'title_last', 'title_first'];
const UNIT = {
  wrapped: 'follows', crlf: 'follows', tabs: 'follows', spaces: 'follows', statement_ws: 'follows',
  one_word: 'unsupported', case: 'unsupported',
  audit_input: true, audit_wrong: false, question: true, question_wrong: false,
  title_plain: SHORT, title_punct: SHORT, title_mid: 'Add an is-even check for integers and also',
};
const cache = new Map();

function observe(mode) {
  if (cache.has(mode)) return cache.get(mode);
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-k26d-'));
  fs.chmodSync(dir, 0o700);
  try {
    const output = path.join(dir, 'output.json'), overlay = path.join(dir, 'overlay.json');
    fs.writeFileSync(overlay, JSON.stringify({ Replace: { [path.join(ROOT, 'cli/shape/k26d_whitespace_acceptance_test.go')]: path.join(__dirname, 'k26d_whitespace_driver.go') } }), { mode: 0o600 });
    const r = spawnSync('go', ['test', '-overlay', overlay, './shape', '-run', '^TestK26dWhitespaceObservation$', '-count=1'], {
      cwd: path.join(ROOT, 'cli'), encoding: 'utf8', timeout: 240000, maxBuffer: 8 * 1024 * 1024,
      env: { ...process.env, KOGEN_K26D_MODE: mode, KOGEN_K26D_OUTPUT: output },
    });
    assert.ifError(r.error);
    assert.equal(r.status, 0, `observation failed:\n${r.stdout}\n${r.stderr}`);
    const data = JSON.parse(fs.readFileSync(output, 'utf8'));
    assert.equal(data.mode, mode);
    cache.set(mode, data);
    return data;
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
}

const titleOf = intent => intent.split('\n')[0];

const CHECKS = {
  unit(d) { assert.deepEqual(d.unit, UNIT); },
  wrap(d) {
    assert.equal(d.error_text, '', d.error_text);
    assert.equal(d.exit, 0);
    assert.equal(d.published, true);
    assert.equal(d.refused.length, 0, 'no refusal');
    assert.equal(d.decision_checks, 1, 'the first attempt carrying the quotes passes');
    assert.equal(d.decision_events.length, 1);
    assert.equal(d.decision_events[0].follows, 2);
    assert.equal(d.decision_events[0].unsupported, 0);
    assert.ok(d.intent.includes('- Use only the Go standard library. (source: request)'));
  },
  title_last(d) {
    assert.equal(d.error_text, '', d.error_text);
    assert.equal(d.published, true);
    assert.equal(titleOf(d.intent), `# ${SHORT}`);
    assert.ok([...SHORT].length <= 50);
    assert.equal(d.title_events.length, 1);
    assert.equal(d.title_events[0].event, 'title_shortened');
    assert.equal(d.title_events[0].original, LONG);
    assert.equal(d.title_events[0].title, SHORT);
    assert.equal(d.refused.length, 2);
    assert.deepEqual(d.refused.map(e => e.attempt), [1, 2]);
    assert.equal(d.card_exit, 5, d.card);
    assert.ok(d.card.includes(SHORT), d.card);
    assert.ok(!d.card.includes(LONG), d.card);
  },
  title_first(d) {
    assert.equal(d.error_text, '', d.error_text);
    assert.equal(d.published, true);
    assert.ok(d.feedback1.includes(TITLE_PROBLEM), `feedback as today:\n${d.feedback1}`);
    assert.equal(d.title_events.length, 0, 'no title_shortened before the last attempt');
    assert.equal(titleOf(d.intent), '# Add an is-even check');
    assert.equal(d.refused.length, 1);
    assert.equal(d.refused[0].attempt, 1);
  },
};

function good(mode) {
  const base = { mode, exit: 0, error_text: '', published: true, intent: '', feedback1: '', decision_checks: 0, refused: [], decision_events: [], title_events: [], card_exit: -1, card: '', unit: {} };
  switch (mode) {
    case 'unit': return { ...base, unit: { ...UNIT } };
    case 'wrap': return { ...base, decision_checks: 1, intent: 'x\n- Use only the Go standard library. (source: request)\n', decision_events: [{ event: 'decision_check', follows: 2, unsupported: 0 }] };
    case 'title_last': return { ...base, intent: `# ${SHORT}\n`, card_exit: 5, card: `Intent: ${SHORT}\n`,
      title_events: [{ event: 'title_shortened', original: LONG, title: SHORT }],
      refused: [{ event: 'submission_refused', attempt: 1, gate: 'intent', problems: [TITLE_PROBLEM] }, { event: 'submission_refused', attempt: 2, gate: 'intent', problems: [TITLE_PROBLEM] }] };
    case 'title_first': return { ...base, intent: '# Add an is-even check\n', feedback1: `invalid submission:\n${TITLE_PROBLEM}`,
      refused: [{ event: 'submission_refused', attempt: 1, gate: 'intent', problems: [TITLE_PROBLEM] }] };
  }
  throw new Error(mode);
}

function controls(kind) {
  for (const m of MODES) CHECKS[m](good(m));
  if (kind === 'good') { console.log('k26d observer good'); return; }
  assert.equal(kind, 'bad');
  const bad = (mode, mutate) => { const c = structuredClone(good(mode)); mutate(c); assert.throws(() => CHECKS[mode](c), `accepted a known-bad ${mode} fixture`); };
  bad('unit', d => { d.unit.wrapped = 'unsupported'; });
  bad('unit', d => { d.unit.crlf = 'unsupported'; });
  bad('unit', d => { d.unit.one_word = 'follows'; });
  bad('unit', d => { d.unit.case = 'follows'; });
  bad('unit', d => { d.unit.audit_input = false; });
  bad('unit', d => { d.unit.audit_wrong = true; });
  bad('unit', d => { d.unit.question = false; });
  bad('unit', d => { d.unit.title_plain = LONG; });
  bad('unit', d => { d.unit.title_punct = `${SHORT},`; });
  bad('wrap', d => { d.published = false; });
  bad('wrap', d => { d.refused = [{ attempt: 1 }]; });
  bad('wrap', d => { d.decision_checks = 2; });
  bad('wrap', d => { d.decision_events[0].unsupported = 1; });
  bad('title_last', d => { d.intent = `# ${LONG}\n`; });
  bad('title_last', d => { d.title_events = []; });
  bad('title_last', d => { d.title_events[0].original = SHORT; });
  bad('title_last', d => { d.refused.pop(); });
  bad('title_last', d => { d.card = d.card.replace(SHORT, LONG); });
  bad('title_first', d => { d.feedback1 = ''; });
  bad('title_first', d => { d.intent = `# ${SHORT}\n`; });
  bad('title_first', d => { d.title_events = [{ event: 'title_shortened' }]; });
  console.log('k26d observer rejected bad fixtures');
  process.exitCode = 1;
}

if (require.main === module && process.argv[2] === '--control') {
  controls(process.argv[3]);
} else {
  const { When, Then } = require('@cucumber/cucumber');
  When('the k26d Shape plays {string}', { timeout: 250000 }, function (mode) { assert.ok(MODES.includes(mode), mode); this.k26d = observe(mode); });
  Then('the k26d observation satisfies the contract of its mode', function () { CHECKS[this.k26d.mode](this.k26d); });
}
