const assert = require('node:assert');
const fs = require('node:fs');
const { Given, Then } = require('@cucumber/cucumber');

function scenarioLines(file, title) {
  const lines = fs.readFileSync(file, 'utf8').split('\n');
  const start = lines.findIndex(line => line.trim() === `Scenario: ${title}`);
  assert.notStrictEqual(start, -1, `scenario "${title}" not found in ${file}`);
  const body = [];
  for (let i = start + 1; i < lines.length; i++) {
    const t = lines[i].trim();
    if (t.startsWith('Scenario:') || t.startsWith('@')) break;
    body.push(t);
  }
  return body;
}

Given('k-acceptance-init-provider: the scenario {string} is read from {string}', function (title, file) {
  this.kipLines = scenarioLines(file, title);
  this.kipTitle = title;
});

Then('k-acceptance-init-provider: it has the step {string}', function (step) {
  assert.ok(this.kipLines.includes(step), `scenario "${this.kipTitle}" lacks the step: ${step}\nsteps: ${this.kipLines.join(' | ')}`);
});

Then('k-acceptance-init-provider: it does not pin setup wording', function () {
  const text = this.kipLines.join('\n');
  assert.ok(!text.includes('stdout is:'), `scenario "${this.kipTitle}" still pins exact stdout`);
  assert.ok(!text.includes('browser sign-in'), `scenario "${this.kipTitle}" still quotes setup's login wording`);
  assert.ok(!text.includes('kogen provider --help lists'), `scenario "${this.kipTitle}" still quotes setup's login wording`);
});
