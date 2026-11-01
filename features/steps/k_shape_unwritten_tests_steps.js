'use strict';
// K-SHAPE-UNWRITTEN-TESTS acceptance: an independent installed-CLI harness. The packaged `kogen` (go_driver_support.js
// installs the release archive) runs against the scripted local provider; no real provider, account or credential is
// used, and no Go test name the Build has to write is required.
//
// Shape: a disposable Go fixture module (package widget, an existing TestWidgetExists, a cmd/double program whose
// Double still returns its input) is shaped by a scripted shaper. Package A's acceptance runs the not-yet-written Go
// test TestWidgetDoubles; package B observes the program's output and runs the existing TestWidgetExists.
// Build: a scripted native builder of the candidate-app fixture Intent edits app.txt once against red acceptance,
// then answers without a tool call ("stuck") or answers the missing-items notice with report_blocker ("blocker").
//
// Run directly, `node features/steps/k_shape_unwritten_tests_steps.js --control good|bad` qualifies the observers
// below: known-good observations are accepted (exit 0), known-bad counterexamples rejected (exit 1).

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const SLUG = 'widget-double';
const DIR = `.kogen/intents/${SLUG}`;
const STEPS = 'features/steps/widget_steps.js';

const intent = (tests) => `# Make Double return twice its input

Slug: ${SLUG}
Model: not applicable — Double is a pure function
Acceptance:
- ${DIR}/acceptance.feature
- ${STEPS}

widget.Double returns twice its input.

## Decisions
- Double returns twice its input (source: request)

## Source comparison
- addressed: Double returns twice its input; source request; contract acceptance.feature.

## Tests
${tests}

## Feasibility
- none
`;
const A_INTENT = { path: `${DIR}/intent.md`, content: intent('- Double returns twice its input: TestWidgetDoubles (unit)') };
const A_FEATURE = { path: `${DIR}/acceptance.feature`, content: `Feature: Widget doubling
  Scenario: The doubling test passes
    Then the Go test "TestWidgetDoubles" passes in package "."
` };
const B_INTENT = { path: `${DIR}/intent.md`, content: intent('- Double returns twice its input: the widget program scenario (scenario)\n- The existing widget test keeps passing: TestWidgetExists (existing)') };
const B_FEATURE = { path: `${DIR}/acceptance.feature`, content: `Feature: Widget doubling
  Scenario: Double prints twice its input
    When the widget program doubles 21
    Then the widget program prints "42"

  Scenario: The existing widget test still passes
    Then the Go test "TestWidgetExists" passes in package "."
` };
const WIDGET_STEPS = { path: STEPS, content: `'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { When, Then } = require('@cucumber/cucumber');

Then('the Go test {string} passes in package {string}', function (id, pkg) {
  const command = \`go test -count=1 -json -run ^\${id}$ \${pkg}\`;
  const r = spawnSync('go', ['test', '-count=1', '-json', '-run', \`^\${id}$\`, pkg], { encoding: 'utf8' });
  const rows = r.stdout.split('\\n').filter(l => l.startsWith('{')).map(l => JSON.parse(l));
  const runs = rows.filter(x => x.Action === 'run' && x.Test === id).length;
  const passed = rows.filter(x => x.Action === 'pass' && x.Test === id).length;
  assert.ok(r.status === 0 && runs === 1 && passed === 1,
    \`required test \${id} must run once and pass: \${command} exited \${r.status}, ran \${runs} time(s)\\n\${r.stdout}\${r.stderr}\`);
});

When('the widget program doubles {int}', function (n) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'widget-'));
  try {
    const bin = path.join(dir, 'double');
    const b = spawnSync('go', ['build', '-o', bin, './cmd/double'], { encoding: 'utf8' });
    assert.equal(b.status, 0, \`go build -o \${bin} ./cmd/double failed:\\n\${b.stdout}\${b.stderr}\`);
    this.widgetOutput = spawnSync(bin, [String(n)], { encoding: 'utf8' }).stdout.trim();
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});

Then('the widget program prints {string}', function (want) {
  assert.equal(this.widgetOutput, want, \`the widget program printed \${JSON.stringify(this.widgetOutput)}\`);
});
` };
const FIXTURE = {
  'go.mod': 'module example.com/widget\n\ngo 1.21\n',
  'widget.go': 'package widget\n\n// Double returns its input; the requested change makes it return twice its input.\nfunc Double(n int) int { return n }\n',
  'widget_test.go': 'package widget\n\nimport "testing"\n\nfunc TestWidgetExists(t *testing.T) {\n\tif Double(0) != 0 {\n\t\tt.Fatal("Double(0) is not 0")\n\t}\n}\n',
  'cmd/double/main.go': 'package main\n\nimport (\n\t"fmt"\n\t"os"\n\t"strconv"\n\n\t"example.com/widget"\n)\n\nfunc main() {\n\tn, err := strconv.Atoi(os.Args[1])\n\tif err != nil {\n\t\tfmt.Fprintln(os.Stderr, err)\n\t\tos.Exit(2)\n\t}\n\tfmt.Println(widget.Double(n))\n}\n',
};
const REQUEST = 'Make widget.Double return twice its input.\n';
// The Build fixture: an approved Intent whose one scenario needs app.txt to read "candidate".
const APP_SLUG = 'candidate-app';
const APP_DIR = `.kogen/intents/${APP_SLUG}`;
const APP_STEPS = 'features/steps/candidate_app_steps.js';

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
function shapeEnded(o, status, requests) {
  assert.equal(o.code, status, `kogen intent shape ${SLUG} exited ${o.code}, expected ${status}:\n${o.out}`);
  assert.equal(o.requests, requests, `kogen intent shape ${SLUG} made ${o.requests} shaping requests, expected ${requests}:\n${o.out}`);
}
function refusalFeedback(o, numbers, expected) {
  for (const n of numbers) {
    assert.equal(o.feedback[n], expected, `the feedback to submission ${n} is not the unwritten-tests refusal:\n${o.feedback[n]}`);
  }
}
function observationFeedback(o, n) {
  const text = o.feedback[n];
  assert.ok(typeof text === 'string' && text.includes('Readiness observations'), `the feedback to submission ${n} is not readiness observations:\n${text}`);
  assert.ok(!text.includes('Acceptance depends on tests'), `the feedback to submission ${n} is a refusal:\n${text}`);
}
function refusedEvents(o, count, gate) {
  const refused = o.events.filter(e => e.event === 'submission_refused');
  assert.equal(refused.length, count, `expected ${count} submission_refused events, got ${JSON.stringify(refused)}`);
  for (const e of refused) assert.equal(e.gate, gate, `a submission_refused event has gate ${JSON.stringify(e.gate)}: ${JSON.stringify(e)}`);
}
function publishedB(o) {
  assert.equal(o.files.intent, B_INTENT.content, `${DIR}/intent.md on disk is not the behavioural package:\n${o.files.intent}`);
  assert.equal(o.files.feature, B_FEATURE.content, `${DIR}/acceptance.feature on disk is not the behavioural package:\n${o.files.feature}`);
  assert.ok(lines(o.out).includes('Scenarios: 2 (1 fail now, 1 pass now)'), `the ready output does not report the behavioural scenarios:\n${o.out}`);
  assert.ok(lines(o.out).includes(`Next: kogen intent approve ${SLUG}`), `Shape did not report the package ready:\n${o.out}`);
}
function instructionsContain(o, text) {
  assert.ok(String(o.instructions).includes(text), `the first shaping request's instructions lack ${JSON.stringify(text)}`);
}
function buildEnded(o, status, requests, outcome, passes) {
  assert.equal(o.code, status, `kogen intent build ${APP_SLUG} exited ${o.code}, expected ${status}:\n${o.out}`);
  assert.equal(o.requests, requests, `the Build made ${o.requests} builder requests, expected ${requests}:\n${o.out}`);
  assert.equal(o.outcome, outcome, `the Build outcome is ${JSON.stringify(o.outcome)}, expected ${outcome}`);
  if (passes !== undefined) assert.equal(o.passes, passes, `the Build ran ${o.passes} verification passes, expected ${passes}`);
}
function noticeAt(o, request, notice) {
  const text = o.inputs[request - 1];
  const want = `${notice}\n\nVerification pass 2 is not green.`;
  assert.ok(typeof text === 'string' && text.startsWith(want), `builder request ${request} does not begin with the notice and pass 2's feedback:\n${String(text).slice(0, 1500)}`);
  for (let i = 0; i < o.inputs.length; i++) {
    if (i !== request - 1) assert.ok(!String(o.inputs[i]).includes('Required acceptance items'), `builder request ${i + 1} also carries a notice`);
  }
  assert.equal(o.notices, 1, `expected one missing_items_notice event, got ${o.notices}`);
}
function candidateKept(o, app) {
  assert.equal(o.app, app, `app.txt is ${JSON.stringify(o.app)}`);
  assert.equal(o.headSame, true, 'the Build moved HEAD');
}

// ------------------------------------------------------------------ the installed flows

function goEnv() {
  const r = spawnSync('go', ['env', 'GOCACHE'], { encoding: 'utf8' });
  assert.equal(r.status, 0, `go env GOCACHE failed: ${r.stdout}${r.stderr}`);
  return { GOCACHE: r.stdout.trim(), GOTOOLCHAIN: 'local', GOPROXY: 'off', GOWORK: 'off', GOFLAGS: '-buildvcs=false' };
}
function readOr(file) { return fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : null; }
// The submit calls in conversation order and the tool output each received.
function submissions(requests) {
  const ids = [], outputs = new Map();
  for (const r of requests) {
    for (const item of (r.json && r.json.input) || []) {
      if (item.type === 'function_call' && item.name === 'submit' && !ids.includes(item.call_id)) ids.push(item.call_id);
      if (item.type === 'function_call_output' && !outputs.has(item.call_id)) outputs.set(item.call_id, item.output);
    }
  }
  const feedback = {};
  ids.forEach((id, i) => { if (outputs.has(id)) feedback[i + 1] = outputs.get(id); });
  return feedback;
}
function lastInput(request) {
  const items = (request.json && request.json.input) || [];
  const it = items[items.length - 1] || {};
  if (typeof it.output === 'string') return it.output;
  if (typeof it.content === 'string') return it.content;
  if (Array.isArray(it.content)) return it.content.map(b => b.text || '').join('\n');
  return '';
}

const cache = new Map();
async function shapeFlow(mode) {
  if (cache.has(`shape:${mode}`)) return cache.get(`shape:${mode}`);
  const H = require('./go_driver_support.js');
  const script = {
    'refused-then-behavioural': [
      H.inspectThenSubmit('submit', { files: [A_INTENT, A_FEATURE, WIDGET_STEPS] }, 'a1'),
      H.fn('submit', { files: [A_INTENT] }),
      H.fn('submit', { files: [B_INTENT, B_FEATURE] }),
      H.fn('submit', { files: [B_INTENT] }),
    ],
    persistent: [
      H.inspectThenSubmit('submit', { files: [A_INTENT, A_FEATURE, WIDGET_STEPS] }, 'a1'),
      H.fn('submit', { files: [A_INTENT] }),
      H.fn('submit', { files: [A_INTENT] }),
    ],
  }[mode];
  assert.ok(script, `unknown shape case ${mode}`);
  const suite = await H.setupSuite(); let c;
  try {
    c = await H.project(suite, [], { stagedIntent: false });
    for (const [p, text] of Object.entries(FIXTURE)) {
      const file = path.join(c.repo, p); fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, text);
    }
    await H.git(c, ['add', ...Object.keys(FIXTURE)]);
    await H.git(c, ['commit', '-qm', 'Add the widget fixture module']);
    const before = c.server.providerRequests().length;
    c.server.setScript(script);
    const request = path.join(c.root, 'request.md'); fs.writeFileSync(request, REQUEST);
    const r = await H.runKogen(c, ['intent', 'shape', SLUG, request], { env: goEnv(), timeout: 8 * H.MIN });
    const shaping = c.server.providerRequests().slice(before);
    const eventsText = readOr(path.join(c.repo, `.kogen/local/shaping/${SLUG}/events.ndjson`)) || '';
    const o = {
      mode, code: r.code, out: r.out, requests: shaping.length,
      feedback: submissions(shaping),
      events: eventsText.split('\n').filter(Boolean).map(l => JSON.parse(l)).filter(e => e.event === 'submission_refused'),
      files: { intent: readOr(path.join(c.repo, `${DIR}/intent.md`)), feature: readOr(path.join(c.repo, `${DIR}/acceptance.feature`)) },
      instructions: shaping.length ? shaping[0].json.instructions : '',
    };
    cache.set(`shape:${mode}`, o);
    return o;
  } finally { await H.cleanupCase(c); H.cleanupSuite(suite); }
}

async function buildFlow(mode) {
  if (cache.has(`build:${mode}`)) return cache.get(`build:${mode}`);
  const H = require('./go_driver_support.js');
  const f = H.fn;
  const tail = {
    stuck: [{ text: 'The round is complete.' }, { text: 'I made no correction.' }, { text: 'Still nothing to add.' }, { text: 'Nothing more.' }, { text: 'Done.' }],
    blocker: [{ text: 'The round is complete.' }, f('report_blocker', { paths: [`${APP_DIR}/acceptance.feature`], reason: 'the scenario expects a value no correct implementation produces', evidence: 'acceptance pass 2: the fixture app is "candidate" failed' })],
  }[mode];
  assert.ok(tail, `unknown build case ${mode}`);
  const suite = await H.setupSuite(); let c;
  try {
    c = await H.project(suite, [], { stagedIntent: false });
    // The candidate-app Intent is the only uncommitted change when the Build starts.
    await H.git(c, ['add', '-A']); await H.git(c, ['commit', '-qm', 'Commit the fixture project']);
    const put = (p, text) => { const file = path.join(c.repo, p); fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, text); };
    put(`${APP_DIR}/intent.md`, `# Change the fixture app\n\nSlug: ${APP_SLUG}\nModel: not applicable — the fixture has no state\nAcceptance:\n- ${APP_DIR}/acceptance.feature\n- ${APP_STEPS}\n\nChange app.txt to candidate.\n\n## Decisions\n- Use candidate. (source: request)\n\n## Source comparison\n- addressed: app.txt is candidate; source request; contract Tests and acceptance.feature.\n\n## Tests\n- app.txt is candidate: the acceptance scenario (scenario)\n\n## Feasibility\n- none\n`);
    put(`${APP_DIR}/acceptance.feature`, 'Feature: Fixture app\n  Scenario: The candidate app\n    Then the fixture app is "candidate"\n');
    put(APP_STEPS, "const { Then } = require('@cucumber/cucumber'); const fs = require('node:fs'); const assert = require('node:assert/strict');\nThen('the fixture app is {string}', expected => { assert.equal(fs.readFileSync('app.txt', 'utf8').trim(), expected); });\n");
    await H.approve(c, APP_SLUG);
    const start = await H.git(c, ['rev-parse', 'HEAD']);
    const before = c.server.providerRequests().length;
    c.server.setScript([f('write_file', { path: 'app.txt', content: 'started\n' }), f('finish', { summary: 'first round' }), ...tail]);
    const r = await H.runKogen(c, ['intent', 'build', APP_SLUG], { timeout: 8 * H.MIN });
    const builder = c.server.providerRequests().slice(before);
    const dirs = H.runDirs(c);
    assert.equal(dirs.length, 1, `the ${APP_SLUG} Build made ${dirs.length} runs:\n${r.out}`);
    const result = JSON.parse(readOr(path.join(dirs[0], 'result.json')) || '{}');
    const log = (readOr(path.join(dirs[0], 'log.jsonl')) || '').split('\n').filter(Boolean).map(l => JSON.parse(l));
    const o = {
      mode, code: r.code, out: r.out, requests: builder.length, inputs: builder.map(lastInput),
      outcome: result.outcome, passes: result.passes,
      notices: log.filter(e => e.event === 'missing_items_notice').length,
      app: readOr(path.join(c.repo, 'app.txt')), headSame: (await H.git(c, ['rev-parse', 'HEAD'])) === start,
    };
    cache.set(`build:${mode}`, o);
    return o;
  } finally { await H.cleanupCase(c); H.cleanupSuite(suite); }
}

// ------------------------------------------------------------------ controls

// The expected literals, as acceptance.feature states them.
const C = {
  headline: 'Acceptance depends on tests the Build would have to invent: 1 scenario(s) run named tests that do not exist before the Build; nothing was published. Acceptance must observe behaviour that any correct implementation produces (run the program, call the code or inspect its output), not test names or files the Build has to write. Rewrite these steps; resubmitting them unchanged is refused again.',
  item: '- The doubling test passes (line 2): TestWidgetDoubles: did not run (no tests to run)',
  guidance: 'Unwritten tests: acceptance must not depend on test names or files the Build has to invent. A step may run a named test only when that test already exists before the Build; Shape refuses a candidate whose acceptance runs a named test that did not run on the unchanged tree. Observe behaviour that any correct implementation produces instead.',
  notice: 'Required acceptance items are still missing: verification pass 2 is the same red as the pass before it, and your last round ended without a tool call. The Build is not complete until each of these acceptance scenarios passes:\n' +
    '- failed: The candidate app (line 2)\n' +
    'Act on them now with your tools (change the code and the tests it needs), then call finish. If a correct implementation cannot make them pass because a protected acceptance file is wrong, call report_blocker with its paths, the contradiction and your observed evidence instead. Another round without a tool call into the same red stops the Build as no_progress.',
  stop: 'candidate/no_progress: the builder was told which required acceptance items are missing and answered again without a tool call; verification pass 3 is the same red as the pass before it; edits are left in place\nmissing: failed: The candidate app (line 2)',
};
function controlObservations() {
  const refusal = `${C.headline}\n${C.item}`;
  const okShape = {
    mode: 'refused-then-behavioural', code: 0, requests: 4,
    out: `Intent: /x/${DIR}/intent.md\nScenarios: 2 (1 fail now, 1 pass now)\nNext: kogen intent approve ${SLUG}\n`,
    feedback: { 1: refusal, 2: refusal, 3: 'Inspect whether ...\n\nReadiness observations\nChecked baseline: x' },
    events: [{ event: 'submission_refused', gate: 'unwritten_tests' }, { event: 'submission_refused', gate: 'unwritten_tests' }],
    files: { intent: B_INTENT.content, feature: B_FEATURE.content }, instructions: `prefix\n${C.guidance}\nsuffix`,
  };
  const notReady = {
    mode: 'persistent', code: 1, requests: 3,
    out: `kogen: intent/not_ready: the Intent is not ready to build\n  ${C.item}\n`,
    feedback: { 1: refusal, 2: refusal }, events: [1, 2, 3].map(() => ({ event: 'submission_refused', gate: 'unwritten_tests' })),
    files: { intent: A_INTENT.content, feature: A_FEATURE.content }, instructions: C.guidance,
  };
  const pass2 = `${C.notice}\n\nVerification pass 2 is not green.\nacceptance failed`;
  const stuck = {
    mode: 'stuck', code: 1, requests: 4, outcome: 'no_progress', passes: 3, notices: 1, app: 'started\n', headSame: true,
    out: `failed fixture: no_progress (Build x)\nkogen: ${C.stop.split('\n')[0]}\n  failing: acceptance\n  missing: failed: The candidate app (line 2)\n`,
    inputs: ['brief', 'write ok', 'Verification pass 1 is not green.', pass2],
  };
  const blocker = { ...stuck, mode: 'blocker', outcome: 'build_blocked', passes: 2, out: 'kogen: candidate/build_blocked: BUILDER-REPORTED protected-baseline contradiction; edits are left in place; this report is not independently proven\n' };
  return { refusal, okShape, notReady, stuck, blocker };
}
function checkShapeOk(o, refusal) {
  shapeEnded(o, 0, 4); publishedB(o); refusalFeedback(o, [1, 2], refusal); observationFeedback(o, 3);
  refusedEvents(o, 2, 'unwritten_tests'); instructionsContain(o, C.guidance);
}
function checkNotReady(o, refusal) {
  shapeEnded(o, 1, 3); printedInOrder(o.out, `intent/not_ready: the Intent is not ready to build\n${C.item}`, 'Shape');
  refusalFeedback(o, [1, 2], refusal); refusedEvents(o, 3, 'unwritten_tests');
}
function checkStuck(o) { buildEnded(o, 1, 4, 'no_progress', 3); printedInOrder(o.out, C.stop, 'the Build'); noticeAt(o, 4, C.notice); candidateKept(o, 'started\n'); }
function checkBlocker(o) { buildEnded(o, 1, 4, 'build_blocked'); printedInOrder(o.out, 'candidate/build_blocked: BUILDER-REPORTED protected-baseline contradiction; edits are left in place; this report is not independently proven', 'the Build'); noticeAt(o, 4, C.notice); candidateKept(o, 'started\n'); }

function control(kind) {
  const { refusal, okShape, notReady, stuck, blocker } = controlObservations();
  checkShapeOk(okShape, refusal); checkNotReady(notReady, refusal); checkStuck(stuck); checkBlocker(blocker);
  if (kind === 'good') return 'accepted';
  const bad = (check, base, change, ...rest) => { const o = structuredClone(base); change(o); assert.throws(() => check(o, ...rest), `accepted a known-bad ${base.mode} observation: ${change}`); };
  // The old behaviour: A acknowledged and published after two requests.
  bad(checkShapeOk, okShape, o => { o.requests = 2; o.feedback = { 1: okShape.feedback[3] }; o.files = { intent: A_INTENT.content, feature: A_FEATURE.content }; o.events = []; }, refusal);
  bad(checkShapeOk, okShape, o => { o.code = 1; }, refusal);
  bad(checkShapeOk, okShape, o => { o.requests = 5; }, refusal);
  bad(checkShapeOk, okShape, o => { o.files.intent = A_INTENT.content; }, refusal);
  bad(checkShapeOk, okShape, o => { o.files.feature = A_FEATURE.content; }, refusal);
  bad(checkShapeOk, okShape, o => { o.out = o.out.replace('Next: kogen intent approve', 'Next: kogen intent shape'); }, refusal);
  bad(checkShapeOk, okShape, o => { o.out = o.out.replace('1 fail now, 1 pass now', '2 fail now, 0 pass now'); }, refusal);
  bad(checkShapeOk, okShape, o => { o.feedback[2] = 'accepted: unchanged checked observations acknowledged'; }, refusal);
  bad(checkShapeOk, okShape, o => { o.feedback[1] = `${C.headline}\n- The doubling test passes (line 2): TestWidgetDoubles: skipped`; }, refusal);
  bad(checkShapeOk, okShape, o => { o.feedback[1] = `${refusal}\nextra`; }, refusal);
  bad(checkShapeOk, okShape, o => { o.feedback[3] = refusal; }, refusal);
  bad(checkShapeOk, okShape, o => { delete o.feedback[3]; }, refusal);
  bad(checkShapeOk, okShape, o => { o.events.pop(); }, refusal);
  bad(checkShapeOk, okShape, o => { o.events[1].gate = 'readiness'; }, refusal);
  bad(checkShapeOk, okShape, o => { o.instructions = 'Named-test helpers: ...'; }, refusal);
  bad(checkNotReady, notReady, o => { o.code = 0; }, refusal);
  bad(checkNotReady, notReady, o => { o.requests = 2; }, refusal);
  bad(checkNotReady, notReady, o => { o.out = 'kogen: intent/not_ready: the Intent is not ready to build\n'; }, refusal);
  bad(checkNotReady, notReady, o => { o.out = `  ${C.item}\nkogen: intent/not_ready: the Intent is not ready to build\n`; }, refusal);
  bad(checkNotReady, notReady, o => { o.out = 'kogen: shape/invalid_output: the shaper\'s output was not a valid Intent after 3 attempts\n'; }, refusal);
  bad(checkNotReady, notReady, o => { o.events = o.events.slice(0, 2); }, refusal);
  bad(checkNotReady, notReady, o => { o.feedback[2] = okShape.feedback[3]; }, refusal);
  bad(checkStuck, stuck, o => { o.inputs[3] = o.inputs[3].replace('Act on them now with your tools (change the code and the tests it needs), then call finish. If a correct implementation cannot make them pass because a protected acceptance file is wrong, call report_blocker with its paths, the contradiction and your observed evidence instead.', 'Work on them now with your tools (write the missing tests and the implementation they need), then call finish.'); });
  bad(checkStuck, stuck, o => { o.inputs[2] = `${C.notice}\n\n${o.inputs[2]}`; });
  bad(checkStuck, stuck, o => { o.inputs[3] = 'Verification pass 2 is not green.'; });
  bad(checkStuck, stuck, o => { o.notices = 2; });
  bad(checkStuck, stuck, o => { o.requests = 8; o.inputs.push('a', 'b', 'c', 'd'); });
  bad(checkStuck, stuck, o => { o.passes = 9; });
  bad(checkStuck, stuck, o => { o.outcome = 'executor_round_limit'; });
  bad(checkStuck, stuck, o => { o.code = 0; });
  bad(checkStuck, stuck, o => { o.out = o.out.replace('missing: failed', 'failing: failed'); });
  bad(checkStuck, stuck, o => { o.out = 'kogen: candidate/no_progress: the builder answered the failure feedback without a tool call\n'; });
  bad(checkStuck, stuck, o => { o.app = 'baseline\n'; });
  bad(checkStuck, stuck, o => { o.headSame = false; });
  bad(checkBlocker, blocker, o => { o.outcome = 'no_progress'; });
  bad(checkBlocker, blocker, o => { o.out = stuck.out; });
  bad(checkBlocker, blocker, o => { o.requests = 5; });
  bad(checkBlocker, blocker, o => { o.inputs[3] = 'Verification pass 2 is not green.'; });
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
  const shapeOf = w => { assert.ok(w.unwrittenShape, 'the unwritten-tests shape flow did not run'); return w.unwrittenShape; };
  const buildOf = w => { assert.ok(w.unwrittenBuild, 'the unwritten-tests build flow did not run'); return w.unwrittenBuild; };

  When('the unwritten-tests shaper submits the named-test package, resubmits it unchanged, then submits the behavioural package and acknowledges it', STEP, async function () {
    this.unwrittenShape = await shapeFlow('refused-then-behavioural');
  });
  When('the unwritten-tests shaper submits the named-test package three times', STEP, async function () {
    this.unwrittenShape = await shapeFlow('persistent');
  });
  Then('the unwritten-tests shape exited with status {int} after {int} shaping requests', function (status, requests) { shapeEnded(shapeOf(this), status, requests); });
  Then('the published unwritten-tests package is the behavioural package', function () { publishedB(shapeOf(this)); });
  Then('the feedback to unwritten-tests submissions 1 and 2 was exactly:', function (text) { refusalFeedback(shapeOf(this), [1, 2], text); });
  Then('the feedback to unwritten-tests submission {int} is readiness observations, not a refusal', function (n) { observationFeedback(shapeOf(this), n); });
  Then('the unwritten-tests shaping events record {int} submission_refused events with gate {string}', function (count, gate) { refusedEvents(shapeOf(this), count, gate); });
  Then('the first unwritten-tests shaping request instructions contain:', function (text) { instructionsContain(shapeOf(this), text); });
  Then('the unwritten-tests shape printed these lines in order:', function (text) { printedInOrder(shapeOf(this).out, text, 'kogen intent shape'); });

  When('the unwritten-tests fake builder edits once and then answers without a tool call in the case {string}', STEP, async function (mode) {
    this.unwrittenBuild = await buildFlow(mode);
  });
  Then('the unwritten-tests Build exited with status {int} after {int} builder requests with outcome {string}', function (status, requests, outcome) { buildEnded(buildOf(this), status, requests, outcome); });
  Then('the unwritten-tests Build ran {int} verification passes', function (passes) { assert.equal(buildOf(this).passes, passes, `the Build ran ${buildOf(this).passes} verification passes`); });
  Then('the unwritten-tests Build printed these lines in order:', function (text) { printedInOrder(buildOf(this).out, text, 'kogen intent build'); });
  Then('the unwritten-tests builder request {int} begins with this notice and then pass 2\'s feedback:', function (request, text) { noticeAt(buildOf(this), request, text); });
  Then('the unwritten-tests Build left app.txt as {string} and HEAD unchanged', function (app) { candidateKept(buildOf(this), `${app}\n`); });
}
