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
const USAGE = { three: 'input=303 cached=120 output=90 reasoning=30', two: 'input=201 cached=80 output=60 reasoning=20', one: 'input=100 cached=40 output=30 reasoning=10' };
const MODES = ['clean', 'decision', 'ambiguous', 'question', 'partial', 'off', 'badkey'];
const cache = new Map();

function observe(mode) {
  if (cache.has(mode)) return cache.get(mode);
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-k25-'));
  fs.chmodSync(dir, 0o700);
  try {
    const output = path.join(dir, 'output.json'), overlay = path.join(dir, 'overlay.json');
    fs.writeFileSync(overlay, JSON.stringify({ Replace: { [path.join(ROOT, 'cli/shape/k25_request_audit_acceptance_test.go')]: path.join(__dirname, 'k25_request_audit_driver.go') } }), { mode: 0o600 });
    const r = spawnSync('go', ['test', '-overlay', overlay, './shape', '-run', '^TestK25RequestAuditObservation$', '-count=1'], {
      cwd: path.join(ROOT, 'cli'), encoding: 'utf8', timeout: 240000, maxBuffer: 8 * 1024 * 1024,
      env: { ...process.env, KOGEN_K25_MODE: mode, KOGEN_K25_OUTPUT: output },
    });
    assert.ifError(r.error);
    assert.equal(r.status, 0, `observation failed:\n${r.stdout}\n${r.stderr}`);
    const data = JSON.parse(fs.readFileSync(output, 'utf8'));
    assert.equal(data.mode, mode);
    cache.set(mode, data);
    return data;
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
}

function auditCall(d) {
  assert.equal(d.audit_requests, 1, 'exactly one audit call');
  assert.equal(d.audit_first, true, 'the audit is the first provider request');
  assert.equal(d.audit_has_request, true, 'the audit is given the request text');
  assert.equal(d.audit_leak, false, 'the audit sees only the request text');
  assert.equal(d.shaper_tools_have_audit, false, 'the shaper has no audit tool');
}
function auditEvent(d, defects) {
  assert.equal(d.audits.length, 1, 'exactly one request_audit event');
  const a = d.audits[0];
  assert.equal(a.event, 'request_audit');
  assert.equal(a.examples, 1);
  assert.equal(a.rules, 2);
  assert.equal(a.cells, 2);
  assert.deepEqual(a.defects, defects);
}
function fedBack(d) {
  const lines = d.feedback.split('\n');
  assert.equal(lines[0], HEAD, d.feedback);
  assert.ok(lines.slice(1).some(l => l.includes(QA) && l.includes(QB) && l.includes(EXPOSE)), `no defect line:\n${d.feedback}`);
  assert.ok(!/Step self-check failed|Readiness observations/.test(d.feedback), 'coverage feedback precedes the step self-check');
}
function published(d) {
  assert.equal(d.error_text, '', d.error_text);
  assert.equal(d.exit, 0);
  assert.equal(d.published, true);
}
function asked(d) {
  assert.equal(d.error_text, '', d.error_text);
  assert.equal(d.exit, 5);
  assert.equal(d.published, false);
  assert.equal(d.selfchecks, 0);
}

const CHECKS = {
  clean(d) {
    published(d); auditCall(d); auditEvent(d, []);
    assert.equal(d.requests, 2);
    assert.equal(d.selfchecks, 1);
    assert.equal(d.feedback, '');
    assert.ok(d.stdout.includes(USAGE.two), `usage: ${d.stdout}`);
  },
  decision(d) {
    published(d); auditCall(d); auditEvent(d, [DEFECT]);
    assert.equal(d.requests, 3);
    assert.equal(d.shaper_first_has_defect, true, 'the shaper is given the audit result');
    assert.equal(d.selfchecks, 1, 'the step self-check runs once, after the coverage gate');
    assert.equal(d.audit_before_selfcheck, true);
    fedBack(d);
    assert.ok(d.intent.includes('- is_even(0) returns True. (source: request)'), 'the corrected Decision is published');
    assert.ok(d.stdout.includes(USAGE.three), `usage includes the audit call: ${d.stdout}`);
  },
  question(d) {
    asked(d); auditCall(d); auditEvent(d, [DEFECT]);
    assert.equal(d.requests, 2);
    assert.equal(d.feedback, '');
  },
  partial(d) {
    asked(d); auditCall(d); auditEvent(d, [DEFECT]);
    assert.equal(d.requests, 3);
    fedBack(d);
  },
  off(d) {
    published(d);
    assert.equal(d.requests, 1);
    assert.equal(d.audit_requests, 0);
    assert.equal(d.audits.length, 0);
    assert.equal(d.shaper_mentions_audit, false);
    assert.equal(d.shaper_tools_have_audit, false);
    assert.equal(d.selfchecks, 1);
    assert.equal(d.feedback, '');
    assert.ok(d.stdout.includes(USAGE.one), `usage: ${d.stdout}`);
  },
  badkey(d) {
    assert.notEqual(d.exit, 0);
    assert.ok(d.error_text.includes('unknown key extra'), d.error_text);
    assert.equal(d.requests, 0);
    assert.equal(d.published, false);
  },
};
CHECKS.ambiguous = CHECKS.decision;

function good(mode) {
  const base = { mode, exit: 0, error_text: '', published: true, requests: 3, audit_requests: 1, audit_first: true, audit_has_request: true,
    audit_leak: false, shaper_tools_have_audit: false, shaper_mentions_audit: true, shaper_first_has_defect: true, feedback: '',
    audits: [{ event: 'request_audit', examples: 1, rules: 2, cells: 2, defects: [DEFECT] }], selfchecks: 1, audit_before_selfcheck: true,
    stdout: `shape m/high ${USAGE.three} wall_ms=1\n`, intent: '- is_even(0) returns True. (source: request)\n' };
  const fed = `${HEAD}\n- ${QA} / ${QB}: decide ${EXPOSE}`;
  switch (mode) {
    case 'clean': return { ...base, requests: 2, audits: [{ ...base.audits[0], defects: [] }], stdout: `shape m/high ${USAGE.two} wall_ms=1\n` };
    case 'decision': case 'ambiguous': return { ...base, feedback: fed };
    case 'question': return { ...base, exit: 5, published: false, requests: 2, selfchecks: 0, intent: '' };
    case 'partial': return { ...base, exit: 5, published: false, selfchecks: 0, feedback: fed, intent: '' };
    case 'off': return { ...base, requests: 1, audit_requests: 0, audit_first: false, audit_has_request: false, audits: [], shaper_mentions_audit: false, stdout: `shape m/high ${USAGE.one} wall_ms=1\n` };
    case 'badkey': return { ...base, exit: 3, error_text: 'line 3: unknown key extra', published: false, requests: 0, audits: [], selfchecks: 0, stdout: '', intent: '' };
  }
  throw new Error(mode);
}

function controls(kind) {
  for (const m of MODES) CHECKS[m](good(m));
  if (kind === 'good') { console.log('k25 observer good'); return; }
  assert.equal(kind, 'bad');
  const bad = (mode, mutate) => { const c = structuredClone(good(mode)); mutate(c); assert.throws(() => CHECKS[mode](c), `accepted a known-bad ${mode} fixture`); };
  for (const m of ['clean', 'decision', 'question', 'partial']) {
    bad(m, d => { d.audit_requests = 0; });
    bad(m, d => { d.audit_first = false; });
    bad(m, d => { d.audit_has_request = false; });
    bad(m, d => { d.audit_leak = true; });
    bad(m, d => { d.audits = []; });
    bad(m, d => { d.audits[0].defects = m === 'clean' ? [DEFECT] : []; });
    bad(m, d => { d.audits[0].cells = 3; });
    bad(m, d => { d.audits.push(d.audits[0]); });
    bad(m, d => { d.published = !d.published; });
    bad(m, d => { d.requests += 1; });
  }
  for (const m of ['decision', 'ambiguous', 'partial']) {
    bad(m, d => { d.feedback = ''; });
    bad(m, d => { d.feedback = d.feedback.replace('Request audit', 'Audit'); });
    bad(m, d => { d.feedback = d.feedback.replace(QB, 'x'); });
    bad(m, d => { d.feedback = d.feedback.replace(EXPOSE, 'x'); });
    bad(m, d => { d.feedback += '\nStep self-check failed'; });
  }
  bad('decision', d => { d.selfchecks = 2; });
  bad('decision', d => { d.selfchecks = 0; });
  bad('decision', d => { d.audit_before_selfcheck = false; });
  bad('decision', d => { d.shaper_first_has_defect = false; });
  bad('decision', d => { d.intent = ''; });
  bad('decision', d => { d.stdout = d.stdout.replace(USAGE.three, USAGE.two); });
  bad('clean', d => { d.stdout = d.stdout.replace(USAGE.two, USAGE.one); });
  bad('question', d => { d.exit = 0; });
  bad('question', d => { d.feedback = 'x'; });
  bad('partial', d => { d.exit = 0; });
  bad('off', d => { d.audit_requests = 1; });
  bad('off', d => { d.requests = 2; });
  bad('off', d => { d.audits = [good('decision').audits[0]]; });
  bad('off', d => { d.shaper_mentions_audit = true; });
  bad('off', d => { d.shaper_tools_have_audit = true; });
  bad('off', d => { d.stdout = d.stdout.replace(USAGE.one, USAGE.two); });
  bad('badkey', d => { d.exit = 0; });
  bad('badkey', d => { d.error_text = 'boom'; });
  bad('badkey', d => { d.requests = 1; });
  bad('badkey', d => { d.published = true; });
  console.log('k25 observer rejected bad fixtures');
  process.exitCode = 1;
}

if (require.main === module && process.argv[2] === '--control') {
  controls(process.argv[3]);
} else {
  const { When, Then } = require('@cucumber/cucumber');
  When('the k25 Shape plays {string}', { timeout: 250000 }, function (mode) { assert.ok(MODES.includes(mode), mode); this.k25 = observe(mode); });
  Then('the k25 observation satisfies the contract of its mode', function () { CHECKS[this.k25.mode](this.k25); });
}
