'use strict';
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const ROOT = path.resolve(__dirname, '../..');
const sha = x => crypto.createHash('sha256').update(x).digest('hex');
const prompt = () => fs.readFileSync(path.join(ROOT, 'cli/agent/prompts/reviewer.md'), 'utf8');
const schema = () => fs.readFileSync(path.join(ROOT, 'cli/agent/defs.go'));

function put(file, bytes) {
  fs.writeFileSync(file, bytes, { mode: 0o600 });
  fs.chmodSync(file, 0o600);
}
function observe(mode, cases, twice = false) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-review-efficiency-'));
  fs.chmodSync(dir, 0o700);
  try {
    const input = path.join(dir, 'input.json'), output = path.join(dir, 'output.json');
    const overlay = path.join(dir, 'overlay.json');
    put(input, JSON.stringify({ mode, cases, twice }));
    put(overlay, JSON.stringify({ Replace: {
      [path.join(ROOT, 'cli/build/review_efficiency_acceptance_test.go')]: path.join(__dirname, 'review_efficiency_driver.go'),
    } }));
    const r = spawnSync('go', ['test', '-overlay', overlay, './build', '-run', '^TestReviewEfficiencyObservation$', '-count=1'], {
      cwd: path.join(ROOT, 'cli'), encoding: 'utf8', timeout: 240000, maxBuffer: 8 * 1024 * 1024,
      env: { ...process.env, KOGEN_REVIEW_EFFICIENCY_INPUT: input, KOGEN_REVIEW_EFFICIENCY_OUTPUT: output },
    });
    assert.ifError(r.error);
    assert.equal(r.status, 0, `review observation failed:\n${r.stdout}\n${r.stderr}`);
    // Go success alone is not proof: the requested test must have emitted observations.
    const data = JSON.parse(fs.readFileSync(output, 'utf8'));
    assert.equal(data.length, cases.length);
    return data;
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
}

function checkDirect(data, expected, marker) {
  assert.equal(data.length, expected.length);
  expected.forEach((e, i) => {
    assert.equal(data[i].error, '', `validate error at row ${i + 1}`);
    assert.equal(data[i].accepted, e.accepted, `acceptance changed at row ${i + 1}`);
    assert.equal(data[i].problems, e.feedback, `diagnostic at row ${i + 1}`);
    assert.ok(!data[i].problems.includes(marker), 'private submitted value echoed');
  });
}
function checkConversation(data, expected, marker) {
  assert.equal(data.length, expected.length);
  expected.forEach((e, i) => {
    const d = data[i];
    for (const key of ['exit', 'requests', 'head_changed', 'outcome']) assert.equal(d[key], e[key], `${key} at row ${i + 1}: ${d.output}`);
    assert.deepEqual(d.feedback, e.feedback, `actual submit_review tool output at row ${i + 1}`);
    assert.ok(d.feedback.every(text => !text.includes(marker)), 'private submitted value echoed');
    if (e.stop) assert.ok(d.output.includes(e.stop), 'missing terminal stop diagnostic');
  });
}
function checkPrompt(data, spec, bytes = prompt(), schemaBytes = schema()) {
  assert.equal(data.length, 1);
  assert.equal(sha(bytes), spec.targetHash, 'prompt must have exactly the requested bytes');
  assert.equal(bytes.split(spec.paragraph).length - 1, 1, 'replacement must occur once');
  assert.ok(!bytes.includes(spec.oldSentence), 'old sentence remains');
  assert.equal(sha(bytes.replace(spec.paragraph, spec.oldSentence)), spec.originalHash, 'unrelated prompt bytes changed');
  assert.equal(data[0].instructions, bytes, 'actual emitted reviewer instructions differ');
  assert.ok(data[0].instructions.includes(spec.paragraph));
  assert.ok(!data[0].instructions.includes(spec.oldSentence));
  assert.equal(sha(schemaBytes), spec.schemaHash, 'tool schema file changed');
}
function expectedRows(table, prefixes) {
  return table.map(r => {
    const accepted = r.accepted === 'true';
    const detail = r.detail === '-' ? '' : r.detail;
    return { args: JSON.parse(r.args), accepted, feedback: r.shape === 'true' ? `${prefixes.shape}; ${detail}` : detail };
  });
}
function conversationExpected(rows, toolPrefix) {
  return rows.map(r => {
    const blocked = r.accepted && r.args.verdict === 'changes';
    return {
      exit: blocked ? 1 : 0, requests: r.accepted ? 1 : 2, head_changed: !blocked,
      outcome: blocked ? 'review_blocked' : 'landed',
      feedback: r.accepted ? [] : [`${toolPrefix}\n${r.feedback}`],
    };
  });
}

// Final-byte observer controls use the real fixture, not a simulated implementation.
// Existing inner-finding validation is deliberately used so new shape diagnostics cannot
// mask retry, stop, privacy or emitted-instruction assertions.
function controls(kind) {
  const marker = 'PRIVATE_REVIEW_MARKER';
  const badArgs = { verdict: 'approve', findings: [{ path: 'app.txt', line: 1, severity: 'blocking', message: marker }] };
  const detail = 'an approve verdict cannot have blocking findings';
  const direct = observe('direct', [{ verdict: 'approve', findings: [] }, badArgs]);
  const directExpected = [{ accepted: true, feedback: '' }, { accepted: false, feedback: detail }];
  const retry = observe('conversation', [badArgs]);
  const retryExpected = [{ exit: 0, requests: 2, head_changed: true, outcome: 'landed', feedback: [`invalid verdict:\n${detail}`] }];
  const stop = observe('conversation', [badArgs], true);
  const stopExpected = [{ exit: 1, requests: 2, head_changed: false, outcome: 'review_invalid', feedback: [`invalid verdict:\n${detail}`], stop: 'candidate/review_invalid' }];
  const bytes = prompt();
  const paragraph = bytes.split('\n')[2].slice(bytes.split('\n')[2].indexOf('Read other files only'));
  const oldSentence = 'CONTROL_REPLACED_SENTENCE';
  const spec = { targetHash: sha(bytes), originalHash: sha(bytes.replace(paragraph, oldSentence)), schemaHash: sha(schema()), paragraph, oldSentence };
  const verify = () => {
    checkDirect(direct, directExpected, marker);
    checkConversation(retry, retryExpected, marker);
    checkConversation(stop, stopExpected, marker);
    checkPrompt(retry, spec);
  };
  verify();
  if (kind === 'good') { console.log('review efficiency observer good'); return; }
  assert.equal(kind, 'bad');
  const reject = (source, mutate, check) => {
    const copy = structuredClone(source); mutate(copy);
    assert.throws(() => check(copy), 'observer accepted a known-bad fixture');
  };
  reject(direct, d => { d[0].accepted = false; }, d => checkDirect(d, directExpected, marker));
  reject(direct, d => { d[1].problems = ''; }, d => checkDirect(d, directExpected, marker));
  reject(direct, d => { d[1].error = 'failed'; }, d => checkDirect(d, directExpected, marker));
  reject(retry, d => { d[0].feedback = []; }, d => checkConversation(d, retryExpected, marker));
  reject(retry, d => { d[0].requests = 3; }, d => checkConversation(d, retryExpected, marker));
  reject(stop, d => { d[0].head_changed = true; }, d => checkConversation(d, stopExpected, marker));
  reject(stop, d => { d[0].outcome = 'landed'; }, d => checkConversation(d, stopExpected, marker));
  reject(stop, d => { d[0].exit = 0; }, d => checkConversation(d, stopExpected, marker));
  reject(stop, d => { d[0].output = ''; }, d => checkConversation(d, stopExpected, marker));
  reject(retry, d => { d[0].instructions += 'unrequested'; }, d => checkPrompt(d, spec));
  // Independently reach privacy rejection rather than masking it with a text mismatch.
  reject(retry, d => { d[0].feedback = [marker]; }, d => checkConversation(d, [{ ...retryExpected[0], feedback: [marker] }], marker));
  assert.throws(() => checkPrompt(retry, { ...spec, schemaHash: 'changed' }));
  console.log('review efficiency observer rejected bad fixtures');
  process.exitCode = 1;
}

if (require.main === module && process.argv[2] === '--control') {
  controls(process.argv[3]);
} else {
  const { Given, When, Then } = require('@cucumber/cucumber');
  Given('these review-efficiency feedback prefixes:', function (table) { this.rePrefixes = table.rowsHash(); });
  When('I capture review-efficiency instructions from an approving review request', { timeout: 250000 }, function () {
    this.reData = observe('conversation', [{ verdict: 'approve', findings: [] }]);
    checkConversation(this.reData, [{ exit: 0, requests: 1, head_changed: true, outcome: 'landed', feedback: [] }], 'PRIVATE_REVIEW_MARKER');
  });
  Then('the review-efficiency prompt bytes and emitted instructions match:', function (doc) { checkPrompt(this.reData, JSON.parse(doc)); });
  When('I observe review-efficiency submissions through {string}:', { timeout: 250000 }, function (boundary, table) {
    assert.ok(['direct', 'conversation'].includes(boundary));
    this.reBoundary = boundary;
    this.reExpected = expectedRows(table.hashes(), this.rePrefixes);
    this.reData = observe(boundary, this.reExpected.map(r => r.args));
  });
  Then('every review-efficiency result matches its table without disclosing {string}', function (marker) {
    if (this.reBoundary === 'direct') checkDirect(this.reData, this.reExpected, marker);
    else checkConversation(this.reData, conversationExpected(this.reExpected, this.rePrefixes.tool), marker);
  });
  When('I repeat this review-efficiency invalid submission twice:', { timeout: 250000 }, function (doc) {
    this.reData = observe('conversation', [JSON.parse(doc)], true);
  });
  Then('the review-efficiency stop has these observations:', function (table) {
    const e = table.rowsHash();
    checkConversation(this.reData, [{ exit: Number(e.exit), requests: Number(e.requests), head_changed: e.head_changed === 'true', outcome: e.outcome,
      feedback: [`${this.rePrefixes.tool}\n${this.rePrefixes.shape}; ${e.detail}`], stop: e.stop }], e.private);
  });
}
