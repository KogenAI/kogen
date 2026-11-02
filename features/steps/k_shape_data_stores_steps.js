'use strict';
// K-SHAPE-DATA-STORES acceptance: an independent installed-CLI harness. The packaged `kogen` (go_driver_support.js
// installs the release archive) runs against the scripted local provider; no real provider, account, credential or
// benchmark content is used.
//
// The synthetic fixture: an account's memberships are rows of db/memberships.csv, which its Account model
// (lib/account.js) reaches; each account also has an export file exports/<id>.json, written by lib/exports.js, which
// the model does not reach. Every one of these files references the key account_id.
// Shape: a scripted shaper submits package A (scoped to what the model reaches), then package B (which covers every
// file that references account_id) and acknowledges B's readiness observations; one scripted contract review is clean.
// Build: an approved Intent (A: omits the export store; B: covers every store) is built by a scripted builder that
// writes lib/purge.js; a scripted reviewer approves (and, for A, then reports the omitted files).
//
// Run directly, `node features/steps/k_shape_data_stores_steps.js --control good|bad` qualifies the observers below:
// the feature's expected literals are the formats applied to this fixture, known-good observations are accepted
// (exit 0) and known-bad counterexamples rejected (exit 1).

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const SLUG = 'account-purge';
const DIR = `.kogen/intents/${SLUG}`;
const STEPS = 'features/steps/purge_steps.js';
const FEATURE_FILE = path.join(__dirname, '../../.kogen/intents/k-shape-data-stores/acceptance.feature');

const FIXTURE = {
  'lib/account.js': `// The Account model: an account's memberships are the rows of db/memberships.csv with its account_id.
const fs = require('node:fs');

exports.memberships = id => fs.readFileSync('db/memberships.csv', 'utf8').trim().split('\\n').slice(1)
  .filter(row => row.split(',')[0] === String(id));
`,
  'db/memberships.csv': 'account_id,user\n1,ada\n2,bob\n',
  'lib/exports.js': `// Monthly exports: one file per account at exports/<account_id>.json. The Account model does not reach them.
const fs = require('node:fs');

exports.write = (id, data) => fs.writeFileSync(\`exports/\${id}.json\`, JSON.stringify({ account_id: id, ...data }) + '\\n');
`,
  'exports/1.json': '{"account_id":1,"invoices":3}\n',
  'exports/2.json': '{"account_id":2,"invoices":1}\n',
};
const REQUEST = "Purge a cancelled account's data: `node lib/purge.js <id>` removes what the repository keeps for that account.\n";
// What the scripted builder writes.
const PURGE_JS = `// Purges an account: node lib/purge.js <id>
const fs = require('node:fs');

const id = process.argv[2];
const [header, ...rows] = fs.readFileSync('db/memberships.csv', 'utf8').trim().split('\\n');
fs.writeFileSync('db/memberships.csv', [header, ...rows.filter(row => row.split(',')[0] !== id)].join('\\n') + '\\n');
fs.rmSync(\`exports/\${id}.json\`, { force: true });
`;

const PURGE_STEPS = { path: STEPS, content: `'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { When, Then } = require('@cucumber/cucumber');

const MEMBERSHIPS = 'db/memberships.csv';
const exportFile = id => \`exports/\${id}.json\`;

When('account {int} is purged', function (id) {
  this.copy = fs.mkdtempSync(path.join(os.tmpdir(), 'purge-'));
  for (const dir of ['db', 'exports', 'lib']) fs.cpSync(dir, path.join(this.copy, dir), { recursive: true });
  const r = spawnSync(process.execPath, ['lib/purge.js', String(id)], { cwd: this.copy, encoding: 'utf8' });
  assert.equal(r.status, 0, \`node lib/purge.js \${id} exited \${r.status}:\\n\${r.stdout}\${r.stderr}\`);
});

Then('account {int} has no memberships row', function (id) {
  const rows = fs.readFileSync(path.join(this.copy, MEMBERSHIPS), 'utf8').trim().split('\\n').slice(1);
  assert.deepEqual(rows.filter(row => row.split(',')[0] === String(id)), [], \`\${MEMBERSHIPS} still holds account \${id}\`);
});

Then('account {int} has no export file', function (id) {
  assert.equal(fs.existsSync(path.join(this.copy, exportFile(id))), false, \`\${exportFile(id)} still exists\`);
});
` };

const intentText = ({ decisions, stores }) => `# Purge a cancelled account's data

Slug: ${SLUG}
Model: not applicable — one command removes rows and files; no state machine
Acceptance:
- ${DIR}/acceptance.feature
- ${STEPS}

\`node lib/purge.js <id>\` removes what the repository keeps for a cancelled account.

## Decisions
${decisions.join('\n')}

## Data stores
${stores.join('\n')}

## Source comparison
- addressed: purge a cancelled account's data; source request; contract acceptance.feature.

## Tests
- Purging removes the account's data: the purge scenario (scenario)

## Feasibility
- none
`;
const MODEL_DECISION = "- `lib/account.js` is the Account model's code, not a store; the purge removes the memberships rows it reads (source: request)";
// A: scoped to what the Account model reaches.
const A_INTENT = { path: `${DIR}/intent.md`, content: intentText({
  decisions: ['- Purging an account removes its memberships rows (source: request)', MODEL_DECISION],
  stores: ['- key `account_id`', '- `db/memberships.csv`: in scope, observed by `db/memberships.csv`', '- `lib/account.js`: excluded by decision 2'],
}) };
const A_FEATURE = { path: `${DIR}/acceptance.feature`, content: `Feature: Purge a cancelled account's data
  Scenario: Purging account 1 removes its memberships
    When account 1 is purged
    Then account 1 has no memberships row
` };
// B: covers every file that references account_id.
const B_INTENT = { path: `${DIR}/intent.md`, content: intentText({
  decisions: ['- Purging an account removes its memberships rows and its export file (source: request)', MODEL_DECISION,
    '- `lib/exports.js` is the code that writes the export files, not a store; the purge removes the files it wrote (source: request)'],
  stores: ['- key `account_id`', '- `db/memberships.csv`: in scope, observed by `db/memberships.csv`', '- `exports/`: in scope, observed by `exports/`',
    '- `lib/account.js`: excluded by decision 2', '- `lib/exports.js`: excluded by decision 3'],
}) };
const B_FEATURE = { path: `${DIR}/acceptance.feature`, content: `Feature: Purge a cancelled account's data
  Scenario: Purging account 1 removes its memberships and its export file
    When account 1 is purged
    Then account 1 has no memberships row
    And account 1 has no export file
` };
const BLOCKERS = [
  { path: 'exports/1.json', line: 1, severity: 'blocking', message: "holds account 1's export keyed by account_id; the approved Intent neither scopes nor excludes it by a Decision" },
  { path: 'exports/2.json', line: 1, severity: 'blocking', message: "holds account 2's export keyed by account_id; the approved Intent neither scopes nor excludes it by a Decision" },
  { path: 'lib/exports.js', line: 1, severity: 'blocking', message: 'writes the export files keyed by account_id; the approved Intent neither scopes nor excludes it by a Decision' },
];

// ------------------------------------------------------------------ observers (pure; qualified by the controls)

const lines = text => String(text).split('\n').map(l => l.replace(/\r$/, ''));
// Every expected line occurs, in order, inside the output (as a whole line or within an indented or prefixed line).
function printedInOrder(out, expected, what) {
  const got = lines(out);
  let at = 0;
  for (const want of lines(expected)) {
    const found = got.findIndex((l, i) => i >= at && l.includes(want));
    assert.ok(found >= 0, `${what} did not print ${JSON.stringify(want)} (in order) in:\n${out}`);
    at = found + 1;
  }
}
function shapeEnded(o, status, kinds) {
  assert.equal(o.code, status, `kogen intent shape ${SLUG} exited ${o.code}, expected ${status}:\n${o.out}`);
  assert.deepEqual(o.kinds, kinds.split(',').map(k => k.trim()), `kogen intent shape ${SLUG} made the requests ${o.kinds.join(', ')}:\n${o.out}`);
}
function feedbackExactly(o, n, expected) {
  assert.equal(o.feedback[n], expected, `the feedback to data-stores submission ${n} is not exactly the expected text:\n${o.feedback[n]}`);
}
function observationFeedback(o, n) {
  const text = o.feedback[n];
  assert.ok(typeof text === 'string' && text.includes('Readiness observations'), `the feedback to submission ${n} is not readiness observations:\n${text}`);
  assert.ok(!text.includes('Data stores:'), `the feedback to submission ${n} is a data-stores refusal:\n${text}`);
}
function publishedB(o) {
  assert.equal(o.files.intent, B_INTENT.content, `${DIR}/intent.md on disk is not the package that covers every store:\n${o.files.intent}`);
  assert.equal(o.files.feature, B_FEATURE.content, `${DIR}/acceptance.feature on disk is not the package that covers every store:\n${o.files.feature}`);
  assert.equal(o.files.steps, PURGE_STEPS.content, `${STEPS} on disk is not the proposed step file:\n${o.files.steps}`);
  assert.ok(lines(o.out).includes('Scenarios: 1 (1 fail now, 0 pass now)'), `the ready output does not report the purge scenario:\n${o.out}`);
  assert.ok(lines(o.out).includes(`Next: kogen intent approve ${SLUG}`), `Shape did not report the package ready:\n${o.out}`);
}
function refusedEvents(o, count, gate) {
  assert.equal(o.events.length, count, `expected ${count} submission_refused events, got ${JSON.stringify(o.events)}`);
  for (const e of o.events) assert.equal(e.gate, gate, `a submission_refused event has gate ${JSON.stringify(e.gate)}: ${JSON.stringify(e)}`);
}
function contains(text, expected, what) {
  assert.ok(String(text).includes(expected), `${what} does not contain:\n${expected}\n--- it was:\n${String(text).slice(0, 4000)}`);
}
function buildEnded(o, status, outcome, reviews) {
  assert.equal(o.code, status, `kogen intent build ${SLUG} exited ${o.code}, expected ${status}:\n${o.out}`);
  assert.equal(o.outcome, outcome, `the Build outcome is ${JSON.stringify(o.outcome)}, expected ${outcome}:\n${o.out}`);
  assert.equal(o.reviews.length, reviews, `the Build made ${o.reviews.length} review requests, expected ${reviews}:\n${o.out}`);
}
function verdictResult(o, n, expected) {
  assert.equal(o.verdicts[n], expected, `submit_review call ${n} received ${JSON.stringify(o.verdicts[n])}, expected ${JSON.stringify(expected)}`);
}
function commitsAdded(o, n) {
  assert.equal(o.commits, n, `the Build added ${o.commits} commit(s), expected ${n}:\n${o.out}`);
}

// ------------------------------------------------------------------ the installed flows

function readOr(file) { return fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : null; }
const toolNames = r => ((r.json && r.json.tools) || []).map(t => t.name);
function kindOf(r) {
  const names = toolNames(r);
  if (names.includes('submit_contract_review')) return 'review';
  if (names.includes('submit_contract_confirmation')) return 'confirmation';
  if (names.includes('submit_review')) return 'reviewer';
  return 'shaper';
}
// Everything a request carries as text: its instructions and every input item's text, in order.
function requestText(r) {
  const parts = [String((r.json && r.json.instructions) || '')];
  for (const it of (r.json && r.json.input) || []) {
    if (typeof it.content === 'string') parts.push(it.content);
    else if (Array.isArray(it.content)) parts.push(it.content.map(b => b.text || '').join('\n'));
    else if (typeof it.output === 'string') parts.push(it.output);
  }
  return parts.join('\n');
}
// The calls of a tool in conversation order and the output each received.
function results(requests, tool) {
  const ids = [], outputs = new Map();
  for (const r of requests) {
    for (const item of (r.json && r.json.input) || []) {
      if (item.type === 'function_call' && item.name === tool && !ids.includes(item.call_id)) ids.push(item.call_id);
      if (item.type === 'function_call_output' && !outputs.has(item.call_id)) outputs.set(item.call_id, item.output);
    }
  }
  const out = {};
  ids.forEach((id, i) => { if (outputs.has(id)) out[i + 1] = outputs.get(id); });
  return out;
}
function writeFixture(c) {
  for (const [p, text] of Object.entries(FIXTURE)) {
    const file = path.join(c.repo, p); fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, text);
  }
}

const cache = new Map();
async function shapeFlow() {
  if (cache.has('shape')) return cache.get('shape');
  const H = require('./go_driver_support.js');
  const suite = await H.setupSuite(); let c;
  try {
    c = await H.project(suite, [], { stagedIntent: false });
    writeFixture(c);
    await H.git(c, ['add', '-A']);
    await H.git(c, ['commit', '-qm', 'Add the account fixture']);
    const before = c.server.providerRequests().length;
    c.server.setScript([
      H.inspectThenSubmit('submit', { files: [A_INTENT, A_FEATURE, PURGE_STEPS] }, 'a1'),
      H.fn('submit', { files: [B_INTENT, B_FEATURE] }),
      H.fn('submit_contract_review', { findings: [] }),
      H.fn('submit', { files: [B_INTENT] }),
    ]);
    const request = path.join(c.root, 'request.md'); fs.writeFileSync(request, REQUEST);
    const r = await H.runKogen(c, ['intent', 'shape', SLUG, request], { timeout: 8 * H.MIN });
    const shaping = c.server.providerRequests().slice(before);
    const eventsText = readOr(path.join(c.repo, `.kogen/local/shaping/${SLUG}/events.ndjson`)) || '';
    const shaper = shaping.filter(q => kindOf(q) === 'shaper');
    const o = {
      code: r.code, out: r.out, kinds: shaping.map(kindOf),
      feedback: results(shaper, 'submit'),
      events: eventsText.split('\n').filter(Boolean).map(l => JSON.parse(l)).filter(e => e.event === 'submission_refused'),
      files: { intent: readOr(path.join(c.repo, `${DIR}/intent.md`)), feature: readOr(path.join(c.repo, `${DIR}/acceptance.feature`)), steps: readOr(path.join(c.repo, STEPS)) },
      first: shaper.length ? requestText(shaper[0]) : '',
    };
    cache.set('shape', o);
    return o;
  } finally { await H.cleanupCase(c); H.cleanupSuite(suite); }
}

async function buildFlow(mode) {
  if (cache.has(`build:${mode}`)) return cache.get(`build:${mode}`);
  const H = require('./go_driver_support.js');
  const f = H.fn;
  const pkg = { omitted: [A_INTENT, A_FEATURE], covered: [B_INTENT, B_FEATURE] }[mode];
  assert.ok(pkg, `unknown build case ${mode}`);
  const reviewer = mode === 'omitted'
    ? [f('submit_review', { verdict: 'approve', findings: [] }), f('submit_review', { verdict: 'changes', findings: BLOCKERS })]
    : [f('submit_review', { verdict: 'approve', findings: [] })];
  const suite = await H.setupSuite(); let c;
  try {
    c = await H.project(suite, [], { stagedIntent: false });
    writeFixture(c);
    await H.git(c, ['add', '-A']); await H.git(c, ['commit', '-qm', 'Add the account fixture']);
    // The account-purge Intent is the only uncommitted change when the Build starts.
    for (const file of [...pkg, PURGE_STEPS]) {
      const p = path.join(c.repo, file.path); fs.mkdirSync(path.dirname(p), { recursive: true }); fs.writeFileSync(p, file.content);
    }
    await H.approve(c, SLUG);
    const start = await H.git(c, ['rev-parse', 'HEAD']);
    const before = c.server.providerRequests().length;
    c.server.setScript([f('write_file', { path: 'lib/purge.js', content: PURGE_JS }), f('finish', { summary: 'lib/purge.js purges an account' }), ...reviewer]);
    const r = await H.runKogen(c, ['intent', 'build', SLUG], { timeout: 8 * H.MIN });
    const requests = c.server.providerRequests().slice(before);
    const reviews = requests.filter(q => kindOf(q) === 'reviewer');
    const dirs = H.runDirs(c);
    assert.equal(dirs.length, 1, `the ${SLUG} Build made ${dirs.length} runs:\n${r.out}`);
    const result = JSON.parse(readOr(path.join(dirs[0], 'result.json')) || '{}');
    const o = {
      code: r.code, out: r.out, outcome: result.outcome, reviews: reviews.map(requestText),
      verdicts: results(reviews, 'submit_review'),
      commits: Number(await H.git(c, ['rev-list', '--count', `${start}..HEAD`])),
    };
    cache.set(`build:${mode}`, o);
    return o;
  } finally { await H.cleanupCase(c); H.cleanupSuite(suite); }
}

// ------------------------------------------------------------------ controls

// The formats the Intent states, applied to this fixture independently of the product.
const KEY = 'account_id';
function references(text) {
  const re = new RegExp(`(?<![A-Za-z0-9_])${KEY}(?![A-Za-z0-9_])`);
  return lines(text).flatMap((l, i) => re.test(l) ? [i + 1] : []);
}
const scanned = Object.keys(FIXTURE).sort().map(p => ({ path: p, at: references(FIXTURE[p]) })).filter(x => x.at.length);
const atText = at => `${at.length === 1 ? 'line' : 'lines'} ${at.join(', ')}`;
function expected() {
  const uncovered = ['exports/1.json', 'exports/2.json', 'lib/exports.js'];
  const refusalItems = scanned.filter(x => uncovered.includes(x.path)).map(x => `- ${x.path} references ${KEY} (${atText(x.at)}); no ## Data stores item covers it`);
  const refusal = `Data stores: ${refusalItems.length} problem(s) with where the data of the declared keys lives; nothing was published. Every file tracked at HEAD that references a key declared under ## Data stores needs an item that covers it: in scope, observed by text that acceptance.feature or a listed step file contains, or excluded by a numbered Decision that names it. Resubmitting this candidate unchanged is refused again.\n${refusalItems.join('\n')}`;
  const cover = {
    omitted: { 'db/memberships.csv': '`db/memberships.csv`: in scope, observed by `db/memberships.csv`', 'lib/account.js': '`lib/account.js`: excluded by decision 2' },
    covered: {
      'db/memberships.csv': '`db/memberships.csv`: in scope, observed by `db/memberships.csv`', 'exports/1.json': '`exports/`: in scope, observed by `exports/`',
      'exports/2.json': '`exports/`: in scope, observed by `exports/`', 'lib/account.js': '`lib/account.js`: excluded by decision 2', 'lib/exports.js': '`lib/exports.js`: excluded by decision 3',
    },
  };
  // Every cover item is one of the package's own Data stores lines.
  for (const p of Object.values(cover.omitted)) assert.ok(A_INTENT.content.includes(`\n- ${p}\n`), `package A has no item ${p}`);
  for (const p of Object.values(cover.covered)) assert.ok(B_INTENT.content.includes(`\n- ${p}\n`), `package B has no item ${p}`);
  const evidence = m => `# Data stores\n\nKeys declared under the approved Intent's ## Data stores: ${KEY}\n` +
    "Files tracked at the Build's start commit that reference a declared key, and the item that covers each:\n" +
    scanned.map(x => `- ${x.path} references ${KEY} (${atText(x.at)}): ${cover[m][x.path] ? `covered by ${cover[m][x.path]}` : 'not covered'}`).join('\n') +
    '\nA file that is not covered holds or reaches data the approved Intent neither scopes nor excludes by a Decision: report a blocking finding at its path. You cannot change the approved Intent; Kogen refuses a verdict without that finding.';
  const rejection = `invalid verdict:\neach data store the approved Intent omits needs a blocking finding at its path; the Intent neither scopes it nor excludes it by a Decision: ${uncovered.join(', ')}`;
  const blocked = ['candidate/review_blocked: the reviewer could not resolve a substantive blocker within the approved Intent; edits are left in place',
    ...BLOCKERS.map(b => `review: ${b.path}:${b.line}: ${b.message}`)].join('\n');
  assert.deepEqual(BLOCKERS.map(b => b.path), uncovered, 'the scripted blockers are not exactly the uncovered files');
  return { refusal, evidenceOmitted: evidence('omitted'), evidenceCovered: evidence('covered'), rejection, blocked };
}
// The docstrings of the feature in order, with the indentation of their opening delimiter removed.
function docStrings(text) {
  const out = []; let open = null, body = [];
  for (const l of lines(text)) {
    if (l.trim() === '"""') {
      if (open === null) { open = l.indexOf('"""'); body = []; } else { out.push(body.join('\n')); open = null; }
    } else if (open !== null) body.push(l.slice(Math.min(open, l.length - l.trimStart().length)));
  }
  return out;
}
const GUIDANCE_PREFIX = "Data stores: for a request about an entity's data";
const REVIEW_GUIDANCE_PREFIX = 'Data stores: when the authority has a # Data stores section';
function controlObservations(e, docs) {
  const [, guidance, reviewGuidance] = docs;
  const okShape = {
    code: 0, kinds: ['shaper', 'shaper', 'review', 'shaper'],
    out: `Intent: /x/${DIR}/intent.md\nScenarios: 1 (1 fail now, 0 pass now)\nNext: kogen intent approve ${SLUG}\n`,
    feedback: { 1: e.refusal, 2: 'Inspect whether ...\n\nReadiness observations\nChecked baseline: x', 3: 'accepted: unchanged checked observations acknowledged' },
    events: [{ event: 'submission_refused', gate: 'data_stores' }],
    files: { intent: B_INTENT.content, feature: B_FEATURE.content, steps: PURGE_STEPS.content },
    first: `You are Kogen's shaper.\n${guidance}\n# Request`,
  };
  const omitted = {
    code: 1, outcome: 'review_blocked',
    out: `kogen: ${e.blocked.split('\n')[0]}\n${e.blocked.split('\n').slice(1).map(l => `  ${l}`).join('\n')}\n`,
    reviews: [`You review code.\n${reviewGuidance}\n# Intent\n...\n${e.evidenceOmitted}\n\n# Check results`, `${reviewGuidance}\n${e.evidenceOmitted}\n${e.rejection}`],
    verdicts: { 1: e.rejection }, commits: 0,
  };
  const covered = {
    code: 0, outcome: 'landed', out: `landed ${SLUG} 1234567 (Build x)\n  review: approved\n`,
    reviews: [`You review code.\n${reviewGuidance}\n${e.evidenceCovered}\n`], verdicts: {}, commits: 1,
  };
  return { okShape, omitted, covered };
}
function checkShape(o, d) {
  shapeEnded(o, 0, 'shaper, shaper, review, shaper'); feedbackExactly(o, 1, d.refusal); observationFeedback(o, 2); publishedB(o);
  refusedEvents(o, 1, 'data_stores'); contains(o.first, d.guidance, 'the first shaping request');
}
function checkOmitted(o, d) {
  buildEnded(o, 1, 'review_blocked', 2); contains(o.reviews[0], d.reviewGuidance, 'the first review request'); contains(o.reviews[0], d.evidenceOmitted, 'the first review request');
  verdictResult(o, 1, d.rejection); printedInOrder(o.out, d.blocked, 'kogen intent build'); commitsAdded(o, 0);
}
function checkCovered(o, d) {
  buildEnded(o, 0, 'landed', 1); contains(o.reviews[0], d.evidenceCovered, 'the first review request'); printedInOrder(o.out, d.approvedLine, 'kogen intent build'); commitsAdded(o, 1);
}

function control(kind) {
  const e = expected();
  const docs = docStrings(fs.readFileSync(FEATURE_FILE, 'utf8'));
  assert.equal(docs.length, 8, `the feature has ${docs.length} docstrings, expected 8`);
  const [refusal, guidance, reviewGuidance, evidenceOmitted, rejection, blocked, evidenceCovered, approvedLine] = docs;
  assert.equal(refusal, e.refusal, 'the feature\'s refusal is not the refusal format applied to the fixture');
  assert.ok(guidance.startsWith(GUIDANCE_PREFIX) && !guidance.includes('\n'), 'the feature\'s shaping guidance is not one Data stores paragraph');
  assert.ok(reviewGuidance.startsWith(REVIEW_GUIDANCE_PREFIX) && !reviewGuidance.includes('\n'), 'the feature\'s review guidance is not one Data stores paragraph');
  assert.equal(evidenceOmitted, e.evidenceOmitted, 'the feature\'s evidence of the omitting Intent is not the evidence format applied to the fixture');
  assert.equal(rejection, e.rejection, 'the feature\'s rejected verdict is not the rejection format applied to the fixture');
  assert.equal(approvedLine, 'review: approved', 'the feature\'s landing line is not the approved review line');
  assert.equal(blocked, e.blocked, 'the feature\'s blocked lines are not the scripted blockers');
  assert.equal(evidenceCovered, e.evidenceCovered, 'the feature\'s evidence of the covering Intent is not the evidence format applied to the fixture');
  const d = { refusal, guidance, reviewGuidance, evidenceOmitted, evidenceCovered, rejection, blocked, approvedLine };
  const { okShape, omitted, covered } = controlObservations(e, docs);
  checkShape(okShape, d); checkOmitted(omitted, d); checkCovered(covered, d);
  if (kind === 'good') return 'accepted';
  const bad = (check, base, change) => { const o = structuredClone(base); change(o); assert.throws(() => check(o, d), `accepted a known-bad observation: ${change}`); };
  // Shape: the old behaviour publishes A after readiness and a clean contract review.
  bad(checkShape, okShape, o => { o.kinds = ['shaper', 'review', 'shaper']; o.feedback = { 1: okShape.feedback[2] }; o.files.intent = A_INTENT.content; o.files.feature = A_FEATURE.content; o.events = []; });
  bad(checkShape, okShape, o => { o.code = 1; });
  bad(checkShape, okShape, o => { o.kinds = ['shaper', 'review', 'shaper', 'review', 'shaper']; });
  bad(checkShape, okShape, o => { o.feedback[1] = o.feedback[1].replace('- exports/2.json references account_id (line 1); no ## Data stores item covers it\n', ''); });
  bad(checkShape, okShape, o => { o.feedback[1] = o.feedback[1].replace('(lines 1, 4)', '(line 1)'); });
  bad(checkShape, okShape, o => { o.feedback[1] = `${o.feedback[1]}\n- lib/account.js references account_id (line 1); no ## Data stores item covers it`; });
  bad(checkShape, okShape, o => { o.feedback[1] = `${o.feedback[1]}\n`; });
  bad(checkShape, okShape, o => { o.feedback[2] = e.refusal; });
  bad(checkShape, okShape, o => { o.feedback[2] = 'accepted: the Intent is ready'; });
  bad(checkShape, okShape, o => { o.files.intent = A_INTENT.content; });
  bad(checkShape, okShape, o => { o.files.feature = A_FEATURE.content; });
  bad(checkShape, okShape, o => { o.files.steps = null; });
  bad(checkShape, okShape, o => { o.out = o.out.replace('Next: kogen intent approve', 'Next: kogen intent shape'); });
  bad(checkShape, okShape, o => { o.events = []; });
  bad(checkShape, okShape, o => { o.events[0].gate = 'readiness'; });
  bad(checkShape, okShape, o => { o.events.push({ event: 'submission_refused', gate: 'data_stores' }); });
  bad(checkShape, okShape, o => { o.first = 'You are Kogen\'s shaper.\nUnwritten tests: ...'; });
  // Review of the omitting Intent: the old behaviour lands on the first approval.
  bad(checkOmitted, omitted, o => { o.code = 0; o.outcome = 'landed'; o.reviews = [omitted.reviews[0]]; o.verdicts = { 1: 'accepted' }; o.commits = 1; o.out = covered.out; });
  bad(checkOmitted, omitted, o => { o.reviews = o.reviews.map(t => t.replace(e.evidenceOmitted, '')); });
  bad(checkOmitted, omitted, o => { o.reviews[0] = o.reviews[0].replace('- exports/1.json references account_id (line 1): not covered', '- exports/1.json references account_id (line 1): covered by `exports/`: in scope, observed by `exports/`'); });
  bad(checkOmitted, omitted, o => { o.reviews[0] = o.reviews[0].replace(reviewGuidance, ''); });
  bad(checkOmitted, omitted, o => { o.verdicts[1] = 'accepted'; });
  bad(checkOmitted, omitted, o => { o.verdicts[1] = o.verdicts[1].replace(', lib/exports.js', ''); });
  bad(checkOmitted, omitted, o => { delete o.verdicts[1]; });
  bad(checkOmitted, omitted, o => { o.outcome = 'review_invalid'; o.out = 'kogen: candidate/review_invalid: the review ended without a valid verdict\n'; });
  bad(checkOmitted, omitted, o => { o.reviews.push('third'); });
  bad(checkOmitted, omitted, o => { o.out = o.out.replace('  review: lib/exports.js:1:', '  review: lib/account.js:1:'); });
  bad(checkOmitted, omitted, o => { o.commits = 1; });
  // Review of the covering Intent.
  bad(checkCovered, covered, o => { o.reviews[0] = 'You review code.\n# Intent\n'; });
  bad(checkCovered, covered, o => { o.reviews[0] = o.reviews[0].replace('covered by `lib/exports.js`: excluded by decision 3', 'not covered'); });
  bad(checkCovered, covered, o => { o.code = 1; o.outcome = 'review_invalid'; o.commits = 0; o.out = 'kogen: candidate/review_invalid: the review ended without a valid verdict\n'; });
  bad(checkCovered, covered, o => { o.out = o.out.replace('review: approved', 'review: changes'); });
  bad(checkCovered, covered, o => { o.reviews.push('second'); });
  bad(checkCovered, covered, o => { o.commits = 0; });
  bad(checkCovered, covered, o => { o.outcome = 'review_blocked'; });
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
  const { When, Then } = require('@cucumber/cucumber');
  const STEP = { timeout: 1200000 };
  const shapeOf = w => { assert.ok(w.dataStoresShape, 'the data-stores shape flow did not run'); return w.dataStoresShape; };
  const buildOf = w => { assert.ok(w.dataStoresBuild, 'the data-stores build flow did not run'); return w.dataStoresBuild; };

  When('the data-stores shaper submits the package scoped to the model\'s associations, then the package that covers every store, and acknowledges its readiness', STEP, async function () {
    this.dataStoresShape = await shapeFlow();
  });
  Then('the data-stores shape exited with status {int} after the requests {string}', function (status, kinds) { shapeEnded(shapeOf(this), status, kinds); });
  Then('the feedback to data-stores submission {int} was exactly:', function (n, text) { feedbackExactly(shapeOf(this), n, text); });
  Then('the feedback to data-stores submission {int} was readiness observations, not a refusal', function (n) { observationFeedback(shapeOf(this), n); });
  Then('the published data-stores package is the package that covers every store', function () { publishedB(shapeOf(this)); });
  Then('the data-stores shaping events record {int} submission_refused event(s) with gate {string}', function (count, gate) { refusedEvents(shapeOf(this), count, gate); });
  Then('the first data-stores shaping request contains:', function (text) { contains(shapeOf(this).first, text, 'the first shaping request'); });

  When('the data-stores Build runs the approved Intent that omits the export store, and its reviewer approves and then reports the omitted files', STEP, async function () {
    this.dataStoresBuild = await buildFlow('omitted');
  });
  When('the data-stores Build runs the approved Intent that covers every store, and its reviewer approves', STEP, async function () {
    this.dataStoresBuild = await buildFlow('covered');
  });
  Then('the data-stores Build exited with status {int} with outcome {string} after {int} review request(s)', function (status, outcome, reviews) { buildEnded(buildOf(this), status, outcome, reviews); });
  Then('the first data-stores review request contains:', function (text) { const o = buildOf(this); assert.ok(o.reviews.length > 0, `the Build made no review request:\n${o.out}`); contains(o.reviews[0], text, 'the first review request'); });
  Then('the data-stores reviewer\'s verdict {int} received exactly:', function (n, text) { verdictResult(buildOf(this), n, text); });
  Then('the data-stores Build printed these lines in order:', function (text) { printedInOrder(buildOf(this).out, text, 'kogen intent build'); });
  Then('the data-stores Build added {int} commit(s)', function (n) { commitsAdded(buildOf(this), n); });
}
