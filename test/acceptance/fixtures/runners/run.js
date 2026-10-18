const fs = require('node:fs');
const path = require('node:path');

const feature = process.env.KOGEN_ACCEPTANCE_FEATURES;
const report = process.env.KOGEN_ACCEPTANCE_REPORT;
const mode = process.argv[2];
if (!feature || !report) process.exit(2);
if (mode === 'hangs') {
  const { spawnSync } = require('node:child_process');
  const group = spawnSync('kogen-pgid', [], { encoding: 'utf8' });
  if (group.status !== 0) process.exit(2);
  fs.writeFileSync(process.env.KOGEN_ACCEPTANCE_RUNNING_PID, `${process.pid} ${process.ppid} ${group.stdout.trim()}\n`);
  setInterval(() => {}, 600000);
} else if (mode === 'record') {
  fs.mkdirSync('.kogen/local', { recursive: true });
  fs.writeFileSync('.kogen/local/acceptance-env.json', JSON.stringify({ features: feature, report }));
  const child = require('node:child_process').spawnSync('node_modules/.bin/cucumber-js', [
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
  if (match) scenarios.push({ name: match[1].trim(), line: index + 1 });
}
if (!scenarios.length) process.exit(2);

let selected = scenarios.map((scenario, index) => ({ ...scenario, index }));
if (mode === 'omits-one-scenario') selected = selected.slice(0, -1);
if (mode === 'reports-one-twice') selected = [...selected, scenarios[0]];

const messages = [];
const children = [];
for (const [index, scenario] of scenarios.entries()) {
  const id = `ast_${index}`;
  scenario.astId = id;
  children.push({ scenario: { id, name: scenario.name, location: { line: scenario.line }, tags: [], steps: [] } });
}
messages.push({ gherkinDocument: { uri: feature, feature: { children } } });

for (const [index, scenario] of selected.entries()) {
  const id = `pickle_${index}`;
  const caseId = `case_${index}`;
  const startedId = `started_${index}`;
  const stepId = `test_step_${index}`;
  const status = mode === 'reports-undefined' && index === 0 ? 'UNDEFINED' : mode === 'reports-skipped' && index === 0 ? 'SKIPPED' : 'PASSED';
  messages.push({ pickle: { id, uri: feature, name: scenario.name, astNodeIds: [`ast_${scenario.index ?? 0}`], steps: [] } });
  messages.push({ testCase: { id: caseId, pickleId: id, testSteps: [{ id: stepId }] } });
  messages.push({ testCaseStarted: { id: startedId, testCaseId: caseId } });
  messages.push({ testStepFinished: {
    testCaseStartedId: startedId,
    testStepId: stepId,
    testStepResult: { status, message: status === 'UNDEFINED' ? 'step definition is missing' : undefined },
  } });
  messages.push({ testCaseFinished: { testCaseStartedId: startedId, willBeRetried: false } });
}

fs.mkdirSync(path.dirname(report), { recursive: true });
fs.writeFileSync(report, `${messages.map(value => JSON.stringify(value)).join('\n')}\n`);
process.exit(mode === 'exits-1-all-passed' ? 1 : 0);
}
