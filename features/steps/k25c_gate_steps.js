'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const ROOT = path.resolve(__dirname, '../..');
const QA = 'Example: is_even(0) returns True.';
const QB = 'Rule B: zero returns False.';
const EXPOSE = 'is_even(0)';
const DEFECT = { kind: 'conflict', quote_a: QA, quote_b: QB, exposing_input: EXPOSE, result_a: 'True', result_b: 'False' };
const HEAD = 'Request audit: 1 defects are not decided or asked; decide each with its exposing input or ask with both quotes:';
const DEFECT_LINE = `quote_a: ${QA} | quote_b: ${QB} | exposing_input: ${EXPOSE}`;
const T_A = '- Decision: for is_even(0) the result is True (because \u2026) (source: request)';
const T_B = '- Decision: for is_even(0) the result is False (because \u2026) (source: request)';
const T_Q = `- Question: "${QA}" versus "${QB}": which applies?`;
const FEED = [HEAD, DEFECT_LINE, T_A, T_B, T_Q].join('\n');
const UFEED = [HEAD, 'quote_a: makes a gadget | quote_b: Widget | exposing_input: any',
  '- Decision: Widget: <definition> (because \u2026) (source: request)',
  '- Question: "makes a gadget" versus "Widget": which applies?'].join('\n');
const SECTION = 'Unresolved request conflicts';
const MODES = ['never', 'paste', 'undefined_template'];
const cache = new Map();

function observe(mode) {
  if (cache.has(mode)) return cache.get(mode);
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-k25c-'));
  fs.chmodSync(dir, 0o700);
  try {
    const output = path.join(dir, 'output.json'), overlay = path.join(dir, 'overlay.json');
    fs.writeFileSync(overlay, JSON.stringify({ Replace: { [path.join(ROOT, 'cli/shape/k25c_gate_acceptance_test.go')]: path.join(__dirname, 'k25c_gate_driver.go') } }), { mode: 0o600 });
    const r = spawnSync('go', ['test', '-overlay', overlay, './shape', '-run', '^TestK25cGateObservation$', '-count=1'], {
      cwd: path.join(ROOT, 'cli'), encoding: 'utf8', timeout: 240000, maxBuffer: 8 * 1024 * 1024,
      env: { ...process.env, KOGEN_K25C_MODE: mode, KOGEN_K25C_OUTPUT: output },
    });
    assert.ifError(r.error);
    assert.equal(r.status, 0, `observation failed:\n${r.stdout}\n${r.stderr}`);
    const data = JSON.parse(fs.readFileSync(output, 'utf8'));
    assert.equal(data.mode, mode);
    cache.set(mode, data);
    return data;
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
}

function lastAudit(d) {
  assert.ok(d.audits.length >= 1, 'a request_audit event is recorded');
  const a = d.audits[d.audits.length - 1];
  assert.equal(a.event, 'request_audit');
  assert.deepEqual(a.defects, [DEFECT]);
  return a;
}
function published(d) {
  assert.equal(d.error_text, '', d.error_text);
  assert.ok(!d.error_text.includes('invalid_output'));
  assert.equal(d.exit, 0);
  assert.equal(d.published, true);
  assert.equal(d.audit_requests, 1);
}

const CHECKS = {
  never(d) {
    published(d);
    assert.equal(d.requests, 4, 'one audit and three shaper attempts');
    assert.equal(d.feedback1, FEED, 'first attempt: strict feedback with the template');
    assert.equal(d.feedback2, FEED, 'second attempt: strict feedback with the template');
    assert.equal(d.selfchecks, 1, 'only the last attempt reaches the step self-check');
    assert.deepEqual(lastAudit(d).uncovered, [DEFECT], 'the uncovered defect is recorded in the request_audit event');
    assert.equal(d.card_exit, 5, d.card);
    const lines = d.card.split('\n');
    const h = lines.indexOf(SECTION);
    assert.ok(h >= 0, `card lacks the section:\n${d.card}`);
    const files = lines.indexOf('Files');
    assert.ok(files > h, 'the section precedes the Files list');
    assert.ok(lines.slice(h + 1, files).some(l => l.includes(QA) && l.includes(QB) && l.includes(EXPOSE)), `no conflict line:\n${d.card}`);
  },
  paste(d) {
    published(d);
    assert.equal(d.requests, 3, 'one audit and two shaper attempts');
    assert.equal(d.feedback1, FEED);
    assert.equal(d.feedback2, '');
    assert.equal(d.selfchecks, 1);
    const a = lastAudit(d);
    assert.ok(a.uncovered === undefined || a.uncovered === null || a.uncovered.length === 0, 'nothing is uncovered once the template is pasted');
    assert.ok(d.intent.includes(T_A), 'the pasted template is published');
    assert.equal(d.card_exit, 5, d.card);
    assert.ok(!d.card.includes(SECTION), 'a covered defect is not listed on the card');
  },
  undefined_template(d) {
    assert.equal(d.error_text, '');
    assert.equal(d.feedback1, UFEED);
  },
};

function good(mode) {
  const ev = { event: 'request_audit', examples: 1, rules: 2, cells: 2, defects: [DEFECT] };
  const base = { mode, exit: 0, error_text: '', published: true, requests: 4, audit_requests: 1, feedback1: FEED, feedback2: FEED, selfchecks: 1,
    audits: [ev, { ...ev, uncovered: [DEFECT] }], card_exit: 5, intent: '',
    card: `Intent: x\n${SECTION}\n  - ${DEFECT_LINE}\nFiles\n  - a\n` };
  switch (mode) {
    case 'never': return base;
    case 'paste': return { ...base, requests: 3, feedback2: '', audits: [ev], intent: `x\n${T_A}\n`, card: 'Intent: x\nFiles\n' };
    case 'undefined_template': return { ...base, feedback1: UFEED, feedback2: '' };
  }
  throw new Error(mode);
}

function controls(kind) {
  for (const m of MODES) CHECKS[m](good(m));
  if (kind === 'good') { console.log('k25c observer good'); return; }
  assert.equal(kind, 'bad');
  const bad = (mode, mutate) => { const c = structuredClone(good(mode)); mutate(c); assert.throws(() => CHECKS[mode](c), `accepted a known-bad ${mode} fixture`); };
  bad('never', d => { d.exit = 1; d.published = false; });
  bad('never', d => { d.error_text = 'shape/invalid_output'; });
  bad('never', d => { d.published = false; });
  bad('never', d => { d.requests = 3; });
  bad('never', d => { d.feedback1 = HEAD + '\n' + DEFECT_LINE; });
  bad('never', d => { d.feedback2 = ''; });
  bad('never', d => { d.feedback2 = d.feedback2.replace(T_Q, ''); });
  bad('never', d => { d.selfchecks = 3; });
  bad('never', d => { d.audits = [d.audits[0]]; });
  bad('never', d => { d.audits[1].uncovered = []; });
  bad('never', d => { d.card_exit = 0; });
  bad('never', d => { d.card = d.card.replace(SECTION, 'Other'); });
  bad('never', d => { d.card = d.card.replace(QB, 'x'); });
  bad('never', d => { d.card = `Intent: x\nFiles\n  - a\n${SECTION}\n  - ${DEFECT_LINE}\n`; });
  bad('paste', d => { d.feedback1 = HEAD + '\n' + DEFECT_LINE; });
  bad('paste', d => { d.intent = 'x'; });
  bad('paste', d => { d.audits = [d.audits[0], { ...d.audits[0], uncovered: [DEFECT] }]; });
  bad('paste', d => { d.card += `${SECTION}\n`; });
  bad('paste', d => { d.published = false; });
  bad('paste', d => { d.requests = 4; });
  bad('undefined_template', d => { d.feedback1 = HEAD; });
  bad('undefined_template', d => { d.feedback1 = UFEED.replace('<definition>', 'x'); });
  console.log('k25c observer rejected bad fixtures');
  process.exitCode = 1;
}

if (require.main === module && process.argv[2] === '--control') {
  controls(process.argv[3]);
} else {
  const { When, Then } = require('@cucumber/cucumber');
  When('the k25c Shape plays {string}', { timeout: 250000 }, function (mode) { assert.ok(MODES.includes(mode), mode); this.k25c = observe(mode); });
  Then('the k25c observation satisfies the contract of its mode', function () { CHECKS[this.k25c.mode](this.k25c); });
}
