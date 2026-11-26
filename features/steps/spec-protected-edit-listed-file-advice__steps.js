const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { Then } = require('@cucumber/cucumber');

Then('spec-protected-edit-listed-file-advice: scenario {string} has exactly the stdout Next step for {string}', function (name, message) {
  const file = 'spec/features/02-shaping.feature';
  const scenarios = readFileSync(file, 'utf8').split(/^  (?:Scenario(?: Outline)?|Rule|Background): /m);
  const scenario = scenarios.find(section => section.split(/\r?\n/, 1)[0] === name);
  assert.ok(scenario, `${file}: missing scenario ${name}`);
  const steps = scenario.split(/\r?\n/).filter(line => /^    (?:Given|When|Then|And|But|\*) stdout \S+ "Next:/.test(line));
  assert.deepEqual(steps, [`    And stdout contains "${message}"`], `${file}: wrong Next step in ${name}`);
});

Then('spec-protected-edit-listed-file-advice: SHP-4 contains the literal {string}', function (message) {
  const file = 'spec/prose/02-shaping.md';
  const clause = readFileSync(file, 'utf8').split(/\r?\n/).find(line => line.startsWith('**SHP-4 — Submission.**'));
  assert.ok(clause?.includes('`' + message + '`'), `${file}: SHP-4 is missing the exact Next literal`);
});
