'use strict';
// K-UNATTENDED-SHAPE-ANSWERS. An unattended `kogen intent shape` that stops on questions (exit 5) leaves the pending
// questions and their recommended options in .kogen/local/shaping/<slug>/questions.json: the version 1 checkout facts
// envelope (docs/checkout-facts.md) with kind "questions". The existing `all: recommended` input answers them, and the
// source receipt records the answers like any other answer. The installed release runs through its CLI without a
// terminal (stdin is /dev/null or a pipe, stdout and stderr are pipes) against the scripted local provider of
// go_driver_support.js; no real provider or account is used.
//
// Run directly, `node features/steps/k_unattended_shape_answers_steps.js --control good|bad` qualifies the questions
// file observer: known-good documents are accepted (exit 0), known-bad counterexamples rejected (exit 1).

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { isDeepStrictEqual } = require('node:util');

const SLUG = 'answers-demo';
const ENVELOPE_KEYS = ['checkout', 'data', 'error', 'kind', 'schema_version'];

// The questions file observer: the problems of an observed file, none when it is exactly the expected document.
// observed: {path, exists, mode, text}; expected: {checkout, data}. JSON objects compare semantically, arrays in order.
function questionsFileProblems(observed, expected) {
  const where = observed.path;
  if (!observed.exists) return [`${where} does not exist`];
  const problems = [];
  if (observed.mode !== 0o600) problems.push(`${where} has mode ${Number(observed.mode).toString(8)}, expected 600`);
  let doc;
  try { doc = JSON.parse(observed.text); } catch (e) { return [...problems, `${where} is not JSON: ${e.message}`]; }
  if (doc === null || typeof doc !== 'object' || Array.isArray(doc)) return [...problems, `${where} is not a JSON object`];
  const keys = Object.keys(doc).sort();
  if (!isDeepStrictEqual(keys, ENVELOPE_KEYS)) problems.push(`${where} has keys ${JSON.stringify(keys)}, expected ${JSON.stringify(ENVELOPE_KEYS)}`);
  if (doc.schema_version !== 1) problems.push(`${where} schema_version is ${JSON.stringify(doc.schema_version)}, expected 1`);
  if (doc.kind !== 'questions') problems.push(`${where} kind is ${JSON.stringify(doc.kind)}, expected "questions"`);
  if (doc.error !== null) problems.push(`${where} error is ${JSON.stringify(doc.error)}, expected null`);
  if (!isDeepStrictEqual(doc.checkout, expected.checkout)) problems.push(`${where} checkout is ${JSON.stringify(doc.checkout)}, expected ${JSON.stringify(expected.checkout)} (as kogen context reports it)`);
  if (!isDeepStrictEqual(doc.data, expected.data)) problems.push(`${where} data is ${JSON.stringify(doc.data)}, expected ${JSON.stringify(expected.data)}`);
  return problems;
}

function control(which) {
  const checkout = { id: 'c'.repeat(64), root: '/control/repo', git_dir: '/control/repo/.git' };
  const q1 = { number: 1, question: 'Which wording should the banner use?', kind: 'product', options: [{ letter: 'a', label: 'Keep the current wording', recommended: false }, { letter: 'b', label: 'Use the shorter wording', recommended: true }], recommended: 'b' };
  const q2 = { number: 2, question: 'Should the banner show the unread count?', kind: 'product', options: [{ letter: 'a', label: 'Show the count', recommended: true }, { letter: 'b', label: 'Hide the count', recommended: false }], recommended: 'a' };
  const full = { slug: SLUG, questions: [q1, q2] };
  const partial = { slug: SLUG, questions: [q1] };
  const envelope = data => ({ schema_version: 1, kind: 'questions', checkout, data, error: null });
  const file = (doc, extra = {}) => ({ path: 'control/questions.json', exists: true, mode: 0o600, text: `${JSON.stringify(doc)}\n`, ...extra });
  const changed = (data, change) => { const d = structuredClone(envelope(data)); change(d); return d; };
  for (const data of [full, partial]) {
    const p = questionsFileProblems(file(envelope(data)), { checkout, data });
    if (p.length) throw new Error(`known-good document rejected: ${p.join('; ')}`);
  }
  if (which === 'good') return 'accepted';
  const bad = [
    [{ path: 'control/questions.json', exists: false }, full],
    [file(envelope(full), { mode: 0o644 }), full],
    [file(envelope(full), { text: '{"schema_version":1' }), full],
    [file(envelope(full).data), full],
    [file(changed(full, d => { d.kind = 'shape_questions'; })), full],
    [file(changed(full, d => { d.schema_version = 2; })), full],
    [file(changed(full, d => { d.error = { class: 'intent', reason: 'questions_pending' }; })), full],
    [file(changed(full, d => { delete d.error; })), full],
    [file(changed(full, d => { d.checkout.id = 'd'.repeat(64); })), full],
    [file(changed(full, d => { d.questions = d.data.questions; })), full],
    [file(changed(full, d => { d.data.slug = 'other-slug'; })), full],
    [file(changed(full, d => { d.data.questions[0].recommended = 'a'; })), full],
    [file(changed(full, d => { d.data.questions[0].recommended = true; })), full],
    [file(changed(full, d => { d.data.questions[1].recommended = null; })), full],
    [file(changed(full, d => { d.data.questions[0].options.reverse(); })), full],
    [file(changed(full, d => { delete d.data.questions[0].options[0].recommended; })), full],
    [file(changed(full, d => { d.data.questions[0].options[1].letter = 'B'; })), full],
    [file(changed(full, d => { d.data.questions.reverse(); })), full],
    [file(changed(full, d => { d.data.questions[1].number = 1; })), full],
    [file(changed(full, d => { delete d.data.questions[0].kind; })), full],
    [file(changed(full, d => { d.data.questions[1].kind = 'handoff'; })), full],
    [file(envelope(full)), partial],
    [file(envelope(partial)), full],
  ];
  for (const [observed, data] of bad) {
    if (!questionsFileProblems(observed, { checkout, data }).length) throw new Error(`counterexample accepted: ${observed.text}`);
  }
  return 'rejected';
}

if (require.main === module) {
  try {
    if (process.argv[2] !== '--control' || !['good', 'bad'].includes(process.argv[3])) throw new Error('usage: --control good|bad');
    const verdict = control(process.argv[3]);
    process.stdout.write(`${verdict}\n`);
    process.exitCode = verdict === 'accepted' ? 0 : 1;
  } catch (e) { process.stderr.write(`${e.message}\n`); process.exitCode = 2; }
} else {
  const { Given, Then } = require('@cucumber/cucumber');
  const H = require('./go_driver_support.js');

  // The shaper's one round: the first question omits kind (a product question), the second names it; the recommended
  // option of the first is b, so a reader that always picks a is told apart.
  const QUESTIONS = [
    { question: 'Which wording should the banner use?', options: [{ label: 'Keep the current wording' }, { label: 'Use the shorter wording', recommended: true }] },
    { question: 'Should the banner show the unread count?', kind: 'product', options: [{ label: 'Show the count', recommended: true }, { label: 'Hide the count', recommended: false }] },
  ];
  const REQUEST = 'Shorten the inbox banner copy and decide whether it shows the unread count.\n';
  const FEATURE = `.kogen/intents/${SLUG}/acceptance.feature`;
  const INTENT = [
    { path: `.kogen/intents/${SLUG}/intent.md`, content: `# Shorten the inbox banner

Slug: ${SLUG}
Model: not applicable — the fixture banner has no state
Acceptance:
- ${FEATURE}
- features/steps/integration_steps.js

The banner uses the shorter wording and shows the unread count.

## Decisions
- The banner uses the shorter wording (source: answer 1)
- The banner shows the unread count (source: answer 2)

## Source comparison
- addressed: banner wording and unread count; source answers 1 and 2; contract prose.

## Tests
- the fixture stays available: the acceptance scenario (existing)

## Feasibility
- none
` },
    { path: FEATURE, content: `Feature: Banner fixture
  Scenario: The banner fixture remains available
    Given the fixture is available
    Then the acceptance check passes
` },
  ];

  function observeQuestions(c) {
    const p = path.join(c.repo, `.kogen/local/shaping/${SLUG}/questions.json`);
    let st = null;
    try { st = fs.lstatSync(p); } catch {}
    if (!st) return { path: p, exists: false };
    return { path: p, exists: st.isFile(), mode: st.mode & 0o777, text: st.isFile() ? fs.readFileSync(p, 'utf8') : '' };
  }
  const stateExists = c => fs.existsSync(path.join(c.repo, `.kogen/local/shaping/${SLUG}/state.json`));
  const shape = async (c, file, input) => {
    const r = await H.runKogen(c, ['intent', 'shape', SLUG, file], input === undefined ? {} : { input });
    return { code: r.code, out: r.out, questions: observeQuestions(c), state: stateExists(c) };
  };

  // One installed project: the shaper asks two questions, the caller answers question 2, then all: recommended.
  async function flow() {
    const suite = await H.setupSuite();
    try {
      const c = await H.project(suite, [H.fn('submit', { questions: QUESTIONS }), H.inspectThenSubmit('submit', { files: INTENT }, 'answers')]);
      try {
        const request = path.join(c.root, 'request.md');
        fs.writeFileSync(request, REQUEST);
        const first = await shape(c, request);
        const context = await H.runKogen(c, ['context']);
        const line = context.out.split('\n').find(l => l.startsWith('{'));
        assert.equal(context.code, 0, `kogen context failed (${context.code}): ${context.out}`);
        const checkout = JSON.parse(line).checkout;
        assert.equal(checkout && checkout.root, fs.realpathSync(c.repo), `kogen context names another checkout: ${context.out}`);
        const partial = await shape(c, '-', '2: a\n');
        const answered = await shape(c, '-', 'all: recommended\n');
        const receipt = path.join(c.repo, `.kogen/local/provenance/${SLUG}/current.json`);
        return { checkout, runs: { first, partial, answered }, receipt: fs.existsSync(receipt) ? fs.readFileSync(receipt, 'utf8') : null };
      } finally { await H.cleanupCase(c); }
    } finally { H.cleanupSuite(suite); }
  }
  let once;
  const exercised = () => { if (!once) once = flow(); return once; };

  const runOf = (world, name) => {
    assert.ok(world.unattendedShape, 'the unattended banner shape flow did not run');
    const r = world.unattendedShape.runs[name];
    assert.ok(r, `no unattended "${name}" shape in the flow`);
    return r;
  };
  const lines = text => String(text).split('\n').map(l => l.replace(/\r$/, ''));

  Given('the unattended banner shape flow has run', { timeout: 1200000 }, async function () {
    this.unattendedShape = await exercised();
  });

  Then('the unattended {string} shape exited with status {int}', function (name, status) {
    const r = runOf(this, name);
    assert.equal(r.code, status, `the unattended "${name}" shape exited ${r.code}, expected ${status}:\n${r.out}`);
  });

  Then('the unattended {string} shape printed these lines in order:', function (name, text) {
    const r = runOf(this, name);
    const out = lines(r.out);
    let at = 0;
    for (const want of lines(text)) {
      const found = out.indexOf(want, at);
      assert.ok(found >= 0, `the unattended "${name}" shape did not print the line ${JSON.stringify(want)} (in order) in:\n${r.out}`);
      at = found + 1;
    }
  });

  Then('the unattended {string} shape did not print the line {string}', function (name, line) {
    const r = runOf(this, name);
    assert.equal(lines(r.out).includes(line), false, `the unattended "${name}" shape printed ${JSON.stringify(line)}:\n${r.out}`);
  });

  Then('after the unattended {string} shape the questions file holds this checkout and data:', function (name, text) {
    const r = runOf(this, name);
    const problems = questionsFileProblems(r.questions, { checkout: this.unattendedShape.checkout, data: JSON.parse(text) });
    assert.deepEqual(problems, [], `after the unattended "${name}" shape (exit ${r.code}):\n${problems.join('\n')}`);
  });

  Then('the {word} source receipt records one answered round with:', function (slug, text) {
    assert.equal(slug, SLUG);
    const receipt = this.unattendedShape && this.unattendedShape.receipt;
    assert.ok(receipt, `no source receipt .kogen/local/provenance/${slug}/current.json after the answered shape`);
    const rounds = JSON.parse(receipt).rounds;
    assert.ok(Array.isArray(rounds) && rounds.length === 1, `the receipt has ${JSON.stringify(rounds && rounds.length)} rounds, expected 1: ${receipt}`);
    for (const [key, value] of Object.entries(JSON.parse(text))) {
      assert.deepEqual(rounds[0][key], value, `receipt round 1 ${key}`);
    }
  });

  Then('the shaping state file is gone after the unattended {string} shape', function (name) {
    assert.equal(runOf(this, name).state, false, `.kogen/local/shaping/${SLUG}/state.json remains after the unattended "${name}" shape`);
  });

  Then('the questions file left by the unattended {string} shape is gone after the unattended {string} shape', function (before, after) {
    const left = runOf(this, before).questions, now = runOf(this, after).questions;
    assert.equal(left.exists, true, `the unattended "${before}" shape left no questions file at ${left.path}`);
    assert.equal(now.exists, false, `${now.path} remains after the unattended "${after}" shape`);
  });

  Then('these maintained documents name the unattended questions file:', function (table) {
    for (const row of table.hashes()) {
      const text = fs.readFileSync(path.join(H.ROOT, row.path), 'utf8');
      assert.ok(text.includes(row.text), `${row.path} does not contain ${JSON.stringify(row.text)}`);
    }
  });
}
