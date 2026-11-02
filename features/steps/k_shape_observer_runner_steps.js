'use strict';
// K-SHAPE-OBSERVER-RUNNER acceptance: an independent installed-CLI harness. The packaged `kogen` (go_driver_support.js
// installs the release archive) runs against the scripted local provider; no real provider, account, credential, Ruby
// or Rails is used, and no AoR task material is involved.
//
// The shaped fixture project carries a synthetic `bin/rails test`: it prints what minitest's default reporter prints
// under CI_PROGRESS_BAR=0 ("1 runs, 7 assertions, 0 failures, 0 errors, 0 skips") and, like minitest, matches a -n/-i
// value as a literal test name. Its test file has an existing passing test_widget_passes and an existing failing
// test_widget_doubles. Observers 1 to 7 of the shaped step file have the shapes of the seven saved observers of
// research's replay (summary wording "1 tests?" and anchored ^name$ filters); observer 8 accepts "N (runs|tests)" and
// passes the plain name.
//
// Run directly, `node features/steps/k_shape_observer_runner_steps.js --control good|bad` qualifies the observers
// below: known-good observations are accepted (exit 0), known-bad counterexamples rejected (exit 1).

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const SLUG = 'widget-observers';
const DIR = `.kogen/intents/${SLUG}`;
const STEPS = 'features/steps/widget_observer_steps.js';

const INTENT = { path: `${DIR}/intent.md`, content: `# Make Widget#double return twice its input

Slug: ${SLUG}
Model: not applicable — Widget#double is a pure method
Acceptance:
- ${DIR}/acceptance.feature
- ${STEPS}

Widget#double returns twice its input; the existing widget test keeps passing.

## Decisions
- Widget#double returns twice its input (source: request)

## Source comparison
- addressed: Widget#double returns twice its input; source request; contract acceptance.feature.

## Tests
- Widget#double returns twice its input: test_widget_doubles (existing)
- The existing widget test keeps passing: test_widget_passes (existing)

## Feasibility
- none
` };
const step = n => `    Then the widget test "test_widget_passes" passes by observer ${n}\n`;
const A_FEATURE = { path: `${DIR}/acceptance.feature`, content: 'Feature: Widget test observers\n' + [
  'An anchored -i filter and a tests-only summary',
  'A plain -n filter and a tests-only summary',
  'An observer module and a tests-only summary',
  'A plain -i filter, the verbose name and a tests-only summary',
  'A plain -n filter and a line-anchored tests-only summary',
  'An anchored -n filter and a tests-only summary',
  'An anchored -i filter and a runs-or-tests summary',
  'A literal -i filter and a runs-or-tests summary',
].map((name, i) => `  Scenario: ${name}\n${step(i + 1)}`).join('\n') };
const B_FEATURE = { path: `${DIR}/acceptance.feature`, content: `Feature: Widget tests
  Scenario: The existing widget test still passes
    Then the widget test "test_widget_passes" passes by observer 8

  Scenario: The doubling test passes
    Then the widget test "test_widget_doubles" passes by observer 8
` };

// The shaped step file. Serialized from this function's own source, so the regular expressions keep their bytes.
function widgetObserverSteps() {
  const assert = require('node:assert/strict');
  const { spawnSync } = require('node:child_process');
  const { Then } = require('@cucumber/cucumber');

  const FILE = 'test/models/widget_test.rb';
  function rails(args) {
    const r = spawnSync('bin/rails', ['test', FILE, ...args], { encoding: 'utf8' });
    const output = (r.stdout || '') + (r.stderr || '');
    return { status: r.status, output, detail: `bin/rails test ${FILE} ${args.join(' ')}; exit ${r.status}; error ${r.error || 'none'}\n${output}` };
  }
  function verify(name, result) {
    assert.equal(result.status, 0, `${name}: command failed\n${result.output}`);
    assert.match(result.output, /(?:^|\n)1 tests?, [1-9]\d* assertions?, 0 failures, 0 errors, 0 skips\b/, `${name}: absent, skipped, or ran zero times\n${result.output}`);
  }
  const observers = {
    1: name => {
      const r = rails(['-i', `^${name}$`]);
      assert.equal(r.status, 0, `${name}: ${r.detail}`);
      assert.match(r.output, /\b1 tests?,\s*[1-9]\d* assertions?,\s*0 failures?,\s*0 errors?,\s*0 skips?\b/, `${name}: ${r.detail}`);
    },
    2: name => {
      const r = rails(['-n', name]);
      assert.equal(r.status, 0, `Required test ${name}; ${r.detail}`);
      assert.match(r.output, /\b1 tests?,\s+[1-9]\d* assertions?,\s+0 failures,\s+0 errors,\s+0 skips/, `Required test absent, skipped, ran zero/multiple times, or made no assertions. Required test ${name}; ${r.detail}`);
    },
    3: name => verify(name, rails(['-n', name])),
    4: name => {
      const r = rails(['-i', name, '--verbose']);
      assert.equal(r.status, 0, `Required test ${name}; ${r.detail}`);
      assert.ok(r.output.includes(`#${name}`), `Required test absent or skipped. Required test ${name}; ${r.detail}`);
      assert.match(r.output, /1 tests?,\s*[1-9]\d* assertions?,\s*0 failures?,\s*0 errors?,\s*0 skips?/, `Required test absent, skipped, or ran zero times. Required test ${name}; ${r.detail}`);
    },
    5: name => {
      const r = rails(['-n', name]);
      assert.equal(r.status, 0, `Named test failed or could not run: ${name}: ${r.detail}`);
      assert.match(r.output, /(?:^|\n)1 tests?,\s+\d+ assertions?,\s+0 failures,\s+0 errors,\s+0 skips/m, `Named test absent, skipped, or ran zero/multiple times: ${name}: ${r.detail}`);
    },
    6: name => {
      const r = rails(['-n', `^${name}$`]);
      assert.equal(r.status, 0, `Required test ${name}; ${r.detail}`);
      assert.match(r.output, /\b1 tests?,\s*[1-9]\d* assertions?,\s*0 failures,\s*0 errors,\s*0 skips\b/, `Required test absent, skipped, ran zero times, or did not assert. Required test ${name}; ${r.detail}`);
    },
    7: name => {
      const r = rails(['-i', `^${name}$`, '-v']);
      assert.equal(r.status, 0, `${name}: ${r.detail}`);
      assert.match(r.output, new RegExp(`#${name}\\b`), `Named test absent or not run: ${name}: ${r.detail}`);
      assert.match(r.output, /1 (?:runs|tests), [1-9]\d* assertions, 0 failures, 0 errors, 0 skips/, `Named test absent, skipped, or ran zero times: ${name}: ${r.detail}`);
    },
    8: name => {
      const r = rails(['-i', name]);
      assert.equal(r.status, 0, `Required test ${name}; ${r.detail}`);
      assert.match(r.output, /(?:^|\n)1 (?:runs|tests), [1-9]\d* assertions, 0 failures, 0 errors, 0 skips\b/, `Required test absent, skipped or ran zero times. Required test ${name}; ${r.detail}`);
    },
  };

  Then('the widget test {string} passes by observer {int}', function (name, n) {
    assert.ok(observers[n], `there is no observer ${n}`);
    observers[n](name);
  });
}
const OBSERVER_STEPS = { path: STEPS, content: `'use strict';\n// Eight observers of the widget tests, each in the shape of a shaped acceptance step.\n(${widgetObserverSteps.toString()})();\n` };

// The synthetic runner: minitest's default reporter (CI_PROGRESS_BAR=0) and its literal -n/-i name filter.
const RAILS = String.raw`#!/bin/sh
# A synthetic stand-in for ` + '`bin/rails test FILE [-n NAME|-i NAME] [-v|--verbose]`' + String.raw`. It prints what minitest's
# default reporter prints when CI_PROGRESS_BAR=0 ("N runs, ..."), and like minitest it matches a -n/-i value
# as a literal test name. A test whose body calls flunk fails; every other test passes with 7 assertions.
test "$1" = test && test $# -ge 2 || { echo 'usage: bin/rails test FILE [-n NAME|-i NAME] [-v|--verbose]' >&2; exit 2; }
file=$2
shift 2
filter= verbose= opts=
while test $# -gt 0; do
  case $1 in
    -n|--name|-i|--include)
      filter=$2 shown=$2
      case $2 in *' '*|*'$'*|*'|'*|*'&'*|*'<'*|*'>'*|*'('*|*')'*) shown="\"$2\"" ;; esac
      opts="$opts $1 $shown"
      shift 2 ;;
    -v|--verbose) verbose=1 opts="$opts $1"; shift ;;
    *) echo "bin/rails: unknown option $1" >&2; exit 2 ;;
  esac
done
test -f "$file" || { echo "cannot load such file -- $file" >&2; exit 1; }
run=
for name in $(awk '$1 == "def" && $2 ~ /^test_/ { print $2 }' "$file"); do
  if test -z "$filter" || test "$name" = "$filter"; then run="$run $name"; fi
done
test -n "$run" || echo "Nothing ran for filter: $filter"
echo "Run options:$opts --seed 4242"
printf '\n# Running:\n\n'
runs=0 assertions=0 failures=0 marks= failed=
for name in $run; do
  runs=$((runs + 1))
  if awk -v t="$name" 'body { print; exit } $1 == "def" && $2 == t { body = 1 }' "$file" | grep -q flunk; then
    failures=$((failures + 1)) assertions=$((assertions + 1)) mark=F failed="$failed $name"
  else
    assertions=$((assertions + 7)) mark=.
  fi
  if test -n "$verbose"; then echo "WidgetTest#$name = 0.01 s = $mark"; else marks="$marks$mark"; fi
done
test -n "$verbose" || echo "$marks"
for name in $failed; do printf '\nFailure:\nWidgetTest#%s [%s]:\nflunked\n' "$name" "$file"; done
printf '\nFinished in 0.010000s.\n%s runs, %s assertions, %s failures, 0 errors, 0 skips\n' "$runs" "$assertions" "$failures"
test "$runs" -gt 0 && test "$failures" -eq 0
`;
const FIXTURE = {
  'bin/rails': RAILS,
  'test/models/widget_test.rb': `require "test_helper"

class WidgetTest < ActiveSupport::TestCase
  def test_widget_passes
    assert_equal 1, Widget.size
  end

  def test_widget_doubles
    flunk "Widget#double is not implemented"
  end
end
`,
};
const REQUEST = 'Make Widget#double return twice its input.\n';

// ------------------------------------------------------------------ observers (pure; qualified by the controls)

const lines = text => String(text).split('\n').map(l => l.replace(/\r$/, ''));
function shapeEnded(o, status, requests) {
  assert.equal(o.code, status, `kogen intent shape ${SLUG} exited ${o.code}, expected ${status}:\n${o.out}`);
  assert.equal(o.requests, requests, `kogen intent shape ${SLUG} made ${o.requests} shaping requests, expected ${requests}:\n${o.out}`);
}
function refusalFeedback(o, numbers, expected) {
  for (const n of numbers) {
    assert.equal(o.feedback[n], expected, `the feedback to submission ${n} is not the runner-observer refusal:\n${o.feedback[n]}`);
  }
}
function observationFeedback(o, n) {
  const text = o.feedback[n];
  assert.ok(typeof text === 'string' && text.includes('Readiness observations'), `the feedback to submission ${n} is not readiness observations:\n${text}`);
  assert.ok(!text.includes("Acceptance rejects the test runner's real output"), `the feedback to submission ${n} is a refusal:\n${text}`);
}
function refusedEvents(o, count, gate) {
  const refused = o.events.filter(e => e.event === 'submission_refused');
  assert.equal(refused.length, count, `expected ${count} submission_refused events, got ${JSON.stringify(refused)}`);
  for (const e of refused) assert.equal(e.gate, gate, `a submission_refused event has gate ${JSON.stringify(e.gate)}: ${JSON.stringify(e)}`);
}
function publishedCorrected(o) {
  assert.equal(o.files.intent, INTENT.content, `${DIR}/intent.md on disk is not the shaped Intent:\n${o.files.intent}`);
  assert.equal(o.files.feature, B_FEATURE.content, `${DIR}/acceptance.feature on disk is not the corrected package:\n${o.files.feature}`);
  assert.equal(o.files.steps, OBSERVER_STEPS.content, `${STEPS} on disk is not the shaped step file`);
  assert.ok(lines(o.out).includes('Scenarios: 2 (1 fail now, 1 pass now)'), `the ready output does not report the corrected scenarios:\n${o.out}`);
  assert.ok(lines(o.out).includes(`Next: kogen intent approve ${SLUG}`), `Shape did not report the package ready:\n${o.out}`);
}
function instructionsContain(o, text) {
  assert.ok(String(o.instructions).includes(text), `the first shaping request's instructions lack ${JSON.stringify(text)}`);
}

// ------------------------------------------------------------------ the installed flow

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

let observed;
async function shapeFlow() {
  if (observed) return observed;
  const H = require('./go_driver_support.js');
  const suite = await H.setupSuite(); let c;
  try {
    c = await H.project(suite, [], { stagedIntent: false });
    for (const [p, text] of Object.entries(FIXTURE)) {
      const file = path.join(c.repo, p); fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, text);
    }
    fs.chmodSync(path.join(c.repo, 'bin/rails'), 0o755);
    await H.git(c, ['add', ...Object.keys(FIXTURE)]);
    await H.git(c, ['commit', '-qm', 'Add the widget fixture']);
    const before = c.server.providerRequests().length;
    c.server.setScript([
      H.inspectThenSubmit('submit', { files: [INTENT, A_FEATURE, OBSERVER_STEPS] }, 'o1'),
      H.fn('submit', { files: [INTENT] }),
      H.fn('submit', { files: [INTENT, B_FEATURE] }),
      H.fn('submit', { files: [B_FEATURE] }),
    ]);
    const request = path.join(c.root, 'request.md'); fs.writeFileSync(request, REQUEST);
    const r = await H.runKogen(c, ['intent', 'shape', SLUG, request], { timeout: 8 * H.MIN });
    const shaping = c.server.providerRequests().slice(before);
    const eventsText = readOr(path.join(c.repo, `.kogen/local/shaping/${SLUG}/events.ndjson`)) || '';
    observed = {
      code: r.code, out: r.out, requests: shaping.length,
      feedback: submissions(shaping),
      events: eventsText.split('\n').filter(Boolean).map(l => JSON.parse(l)).filter(e => e.event === 'submission_refused'),
      files: { intent: readOr(path.join(c.repo, INTENT.path)), feature: readOr(path.join(c.repo, B_FEATURE.path)), steps: readOr(path.join(c.repo, STEPS)) },
      instructions: shaping.length ? shaping[0].json.instructions : '',
    };
    return observed;
  } finally { await H.cleanupCase(c); H.cleanupSuite(suite); }
}

// ------------------------------------------------------------------ controls

// The expected literals, as acceptance.feature states them.
const passing = '1 runs, 7 assertions, 0 failures, 0 errors, 0 skips';
const nothing = '0 runs, 0 assertions, 0 failures, 0 errors, 0 skips';
const literal = option => `the name filter ${option} ^test_widget_passes$ is a regular expression that the runner matched as a literal test name, so nothing ran: ${nothing}`;
const rejected = `the step failed although the test runner reported a passing run: ${passing}`;
const C = {
  headline: "Acceptance rejects the test runner's real output: 7 scenario(s) fail although the test runner reported a passing run, or pass an anchored regular expression as a name filter the runner matches literally; nothing was published. A step that observes a test runner must accept the summary the runner really prints on the unchanged tree (minitest's default reporter prints \"N runs\", other reporters \"N tests\") and give a literal name filter (minitest's -n and -i) only the plain test name. Rewrite these steps; resubmitting them unchanged is refused again.",
  items: [
    `- An anchored -i filter and a tests-only summary (line 2): ${literal('-i')}`,
    `- A plain -n filter and a tests-only summary (line 5): ${rejected}`,
    `- An observer module and a tests-only summary (line 8): ${rejected}`,
    `- A plain -i filter, the verbose name and a tests-only summary (line 11): ${rejected}`,
    `- A plain -n filter and a line-anchored tests-only summary (line 14): ${rejected}`,
    `- An anchored -n filter and a tests-only summary (line 17): ${literal('-n')}`,
    `- An anchored -i filter and a runs-or-tests summary (line 20): ${literal('-i')}`,
  ],
  guidance: 'Test-runner observers: a step that runs a test runner and judges its output must accept that runner\'s real output on the unchanged tree, in the environment acceptance runs in. Derive the summary wording and the name-filter semantics from a real run of an existing passing test there, not from memory; an observer control\'s known-good input is that real output, not hand-written runner text. For example, minitest\'s default reporter (bin/rails test with CI_PROGRESS_BAR=0) prints "1 runs, 7 assertions, 0 failures, 0 errors, 0 skips" where other reporters print "1 tests, ...", so match "N (runs|tests)"; minitest\'s -n and -i match a plain name literally, so pass the test name itself, never ^name$. Shape refuses a candidate whose step fails although the test runner it ran reported a passing run, or whose anchored name filter made the runner run nothing.',
};
function controlObservation() {
  const refusal = [C.headline, ...C.items].join('\n');
  const ok = {
    code: 0, requests: 4,
    out: `Intent: /x/${DIR}/intent.md\nScenarios: 2 (1 fail now, 1 pass now)\nNext: kogen intent approve ${SLUG}\n`,
    feedback: { 1: refusal, 2: refusal, 3: 'Inspect whether ...\n\nReadiness observations\nChecked baseline: x' },
    events: [{ event: 'submission_refused', gate: 'runner_observer' }, { event: 'submission_refused', gate: 'runner_observer' }],
    files: { intent: INTENT.content, feature: B_FEATURE.content, steps: OBSERVER_STEPS.content }, instructions: `prefix\n${C.guidance}\nsuffix`,
  };
  return { refusal, ok };
}
function checkOk(o, refusal) {
  shapeEnded(o, 0, 4); publishedCorrected(o); refusalFeedback(o, [1, 2], refusal); observationFeedback(o, 3);
  refusedEvents(o, 2, 'runner_observer'); instructionsContain(o, C.guidance);
}

function control(kind) {
  const { refusal, ok } = controlObservation();
  checkOk(ok, refusal);
  if (kind === 'good') return 'accepted';
  const bad = change => { const o = structuredClone(ok); change(o); assert.throws(() => checkOk(o, refusal), `accepted a known-bad observation: ${change}`); };
  const without = i => [C.headline, ...C.items.filter((_, k) => k !== i)].join('\n');
  // The old behaviour: the seven-pattern package acknowledged and published after two requests.
  bad(o => { o.requests = 2; o.feedback = { 1: ok.feedback[3], 2: 'accepted: unchanged checked observations acknowledged' }; o.files.feature = A_FEATURE.content; o.events = []; });
  bad(o => { o.code = 1; });
  bad(o => { o.requests = 5; });
  bad(o => { o.files.feature = A_FEATURE.content; });
  bad(o => { o.files.intent = INTENT.content.replace('Widget#double returns twice its input;', 'Widget#double doubles;'); });
  bad(o => { o.files.steps = null; });
  bad(o => { o.out = o.out.replace('Next: kogen intent approve', 'Next: kogen intent shape'); });
  bad(o => { o.out = o.out.replace('1 fail now, 1 pass now', '2 fail now, 0 pass now'); });
  bad(o => { o.feedback[2] = 'accepted: unchanged checked observations acknowledged'; });
  for (let i = 0; i < C.items.length; i++) bad(o => { o.feedback[1] = without(i); });
  bad(o => { o.feedback[1] = `${refusal}\n- A literal -i filter and a runs-or-tests summary (line 23): ${rejected}`; });
  bad(o => { o.feedback[1] = refusal.replace('7 scenario(s)', '8 scenario(s)'); });
  bad(o => { o.feedback[1] = refusal.replace(literal('-n'), literal('-i')); });
  bad(o => { o.feedback[1] = refusal.replace(`(line 5): ${rejected}`, `(line 5): ${rejected.replace('1 runs', '1 tests')}`); });
  bad(o => { o.feedback[2] = `${refusal}\n`; });
  bad(o => { o.feedback[3] = refusal; });
  bad(o => { delete o.feedback[3]; });
  bad(o => { o.events.pop(); });
  bad(o => { o.events[1].gate = 'unwritten_tests'; });
  bad(o => { o.instructions = 'Unwritten tests: ...'; });
  bad(o => { o.instructions = C.guidance.replace('never ^name$', 'or ^name$'); });
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
  const shapeOf = w => { assert.ok(w.observerShape, 'the runner-observer shape flow did not run'); return w.observerShape; };

  When('the runner-observer shaper submits the seven-pattern package, resubmits it unchanged, then submits the corrected package and acknowledges it', STEP, async function () {
    this.observerShape = await shapeFlow();
  });
  Then('the runner-observer shape exited with status {int} after {int} shaping requests', function (status, requests) { shapeEnded(shapeOf(this), status, requests); });
  Then('the published runner-observer package is the corrected package', function () { publishedCorrected(shapeOf(this)); });
  Then('the feedback to runner-observer submissions 1 and 2 was exactly:', function (text) { refusalFeedback(shapeOf(this), [1, 2], text); });
  Then('the feedback to runner-observer submission {int} is readiness observations, not a refusal', function (n) { observationFeedback(shapeOf(this), n); });
  Then('the runner-observer shaping events record {int} submission_refused events with gate {string}', function (count, gate) { refusedEvents(shapeOf(this), count, gate); });
  Then('the first runner-observer shaping request instructions contain:', function (text) { instructionsContain(shapeOf(this), text); });
}
