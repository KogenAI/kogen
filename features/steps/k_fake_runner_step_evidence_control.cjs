'use strict';
// Shaping control only: a fake acceptance runner for mode reports-undefined whose report carries
// complete step evidence. With KFR_CONTROL=incomplete each scenario's last step has no pickle or
// test step, which kogen-verification 11a5244 must refuse.
const fs = require('node:fs');
const path = require('node:path');

const feature = process.env.KOGEN_ACCEPTANCE_FEATURES;
const report = process.env.KOGEN_ACCEPTANCE_REPORT;
const incomplete = process.env.KFR_CONTROL === 'incomplete';
const scenarios = [];
for (const [index, line] of fs.readFileSync(feature, 'utf8').split(/\r?\n/).entries()) {
  const scenario = line.match(/^\s*Scenario:\s*(.+)$/);
  if (scenario) scenarios.push({ name: scenario[1].trim(), line: index + 1, steps: [] });
  const step = line.match(/^\s*(Given |When |Then |And |But |\* )(.*)$/);
  if (step && scenarios.length) scenarios.at(-1).steps.push({ keyword: step[1], text: step[2].trim(), line: index + 1 });
}
const children = scenarios.map((s, i) => ({ scenario: { id: `ast_${i}`, name: s.name, location: { line: s.line }, tags: [],
  steps: s.steps.map((st, j) => ({ id: `ast_${i}_${j}`, keyword: st.keyword, text: st.text, location: { line: st.line } })) } }));
const messages = [{ gherkinDocument: { uri: feature, feature: { children } } }];
for (const [i, s] of scenarios.entries()) {
  const steps = incomplete ? s.steps.slice(0, -1) : s.steps;
  messages.push({ pickle: { id: `pickle_${i}`, uri: feature, name: s.name, astNodeIds: [`ast_${i}`],
    steps: steps.map((st, j) => ({ id: `pickle_${i}_${j}`, text: st.text, astNodeIds: [`ast_${i}_${j}`] })) } });
  messages.push({ testCase: { id: `case_${i}`, pickleId: `pickle_${i}`, testSteps: steps.map((_, j) => ({ id: `test_${i}_${j}`, pickleStepId: `pickle_${i}_${j}` })) } });
  messages.push({ testCaseStarted: { id: `started_${i}`, testCaseId: `case_${i}` } });
  for (const j of steps.keys()) {
    const status = i > 0 ? 'PASSED' : j === 0 ? 'UNDEFINED' : 'SKIPPED';
    messages.push({ testStepFinished: { testCaseStartedId: `started_${i}`, testStepId: `test_${i}_${j}`,
      testStepResult: status === 'UNDEFINED' ? { status, message: 'step definition is missing' } : { status } } });
  }
  messages.push({ testCaseFinished: { testCaseStartedId: `started_${i}`, willBeRetried: false } });
}
fs.mkdirSync(path.dirname(report), { recursive: true });
fs.writeFileSync(report, `${messages.map(value => JSON.stringify(value)).join('\n')}\n`);
