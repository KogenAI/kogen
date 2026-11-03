const fs = require('node:fs');
const path = require('node:path');

const feature = process.env.KOGEN_ACCEPTANCE_FEATURES;
const report = process.env.KOGEN_ACCEPTANCE_REPORT;
const mode = process.env.KOGEN_TEST_ACCEPTANCE_MODE || process.argv[2];
if (!feature || !report) process.exit(2);
if (mode === 'hangs') {
  const { spawnSync } = require('node:child_process');
  const group = spawnSync('kogen-pgid', [], { encoding: 'utf8' });
  if (group.status !== 0) process.exit(2);
  fs.writeFileSync(process.env.KOGEN_ACCEPTANCE_RUNNING_PID, `${process.pid} ${process.ppid} ${group.stdout.trim()}\n`);
  setInterval(() => {}, 600000);
} else if (mode === 'record') {
  fs.mkdirSync(path.dirname(report), { recursive: true });
  fs.writeFileSync(path.join(path.dirname(report), 'acceptance-env.json'), JSON.stringify({ features: feature, report }));
  const child = require('node:child_process').spawnSync(process.env.KOGEN_NODE, [
    path.join(process.env.KOGEN_CUCUMBER, '@cucumber/cucumber/bin/cucumber.js'),
    '--strict', '--require', 'features/steps/*.js', '--format', `message:${report}`, feature,
  ], { encoding: 'utf8' });
  process.stdout.write(child.stdout || '');
  process.stderr.write(child.stderr || '');
  process.exit(child.status === null ? 1 : child.status);
}
if (mode !== 'hangs') {
if (mode === 'writes-no-report') process.exit(0);

const text = fs.readFileSync(feature, 'utf8');
const scenarios = [];
for (const [index, line] of text.split(/\r?\n/).entries()) {
  const match = line.match(/^\s*Scenario(?: Outline| Template)?\s*:\s*(.+)$/);
  if (match) { scenarios.push({ name: match[1].trim(), line: index + 1, steps: [] }); continue; }
  const step = line.match(/^\s*((?:Given|When|Then|And|But|\*) )(.*\S)\s*$/);
  if (step && scenarios.length) scenarios[scenarios.length - 1].steps.push({ keyword: step[1], text: step[2], line: index + 1 });
}
if (!scenarios.length) process.exit(2);

let selected = [...scenarios];
if (mode === 'omits-one-scenario') selected = selected.slice(0, -1);
if (mode === 'reports-one-twice') selected = [...selected, scenarios[0]];

const messages = [];
const children = [];
for (const [index, scenario] of scenarios.entries()) {
  const id = `ast_${index}`;
  scenario.astId = id;
  scenario.steps.forEach((step, stepIndex) => { step.astId = `ast_${index}_step_${stepIndex}`; });
  children.push({ scenario: {
    id, name: scenario.name, location: { line: scenario.line }, tags: [],
    steps: scenario.steps.map(step => ({ id: step.astId, keyword: step.keyword, text: step.text, location: { line: step.line } })),
  } });
}
messages.push({ gherkinDocument: { uri: feature, feature: { children } } });

for (const [index, scenario] of selected.entries()) {
  const id = `pickle_${index}`;
  const caseId = `case_${index}`;
  const startedId = `started_${index}`;
  const pickleSteps = scenario.steps.map((step, stepIndex) => ({ id: `pickle_${index}_step_${stepIndex}`, text: step.text, astNodeIds: [step.astId] }));
  const testSteps = pickleSteps.map((step, stepIndex) => ({ id: `test_step_${index}_${stepIndex}`, pickleStepId: step.id }));
  messages.push({ pickle: { id, uri: feature, name: scenario.name, astNodeIds: [scenario.astId], steps: pickleSteps } });
  messages.push({ testCase: { id: caseId, pickleId: id, testSteps } });
  messages.push({ testCaseStarted: { id: startedId, testCaseId: caseId } });
  for (const [stepIndex, testStep] of testSteps.entries()) {
    const first = index === 0;
    const status = mode === 'reports-undefined' && first ? (stepIndex === 0 ? 'UNDEFINED' : 'SKIPPED') : mode === 'reports-skipped' && first ? 'SKIPPED' : 'PASSED';
    messages.push({ testStepFinished: {
      testCaseStartedId: startedId,
      testStepId: testStep.id,
      testStepResult: { status, message: status === 'UNDEFINED' ? 'step definition is missing' : undefined },
    } });
  }
  messages.push({ testCaseFinished: { testCaseStartedId: startedId, willBeRetried: false } });
}

fs.mkdirSync(path.dirname(report), { recursive: true });
fs.writeFileSync(report, `${messages.map(value => JSON.stringify(value)).join('\n')}\n`);
process.exit(mode === 'exits-1-all-passed' ? 1 : 0);
}
