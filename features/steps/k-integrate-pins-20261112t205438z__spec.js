const { Given, Then } = require('@cucumber/cucumber');
const assert = require('node:assert');
const fs = require('node:fs');

let block = '';

Given('k-integrate-pins-20261112t205438z: the spec scenario {string} is read', function (name) {
  const text = fs.readFileSync('spec/features/02-shaping.feature', 'utf8');
  const i = text.indexOf('Scenario: ' + name);
  assert.ok(i >= 0, 'scenario not found: ' + name);
  const rest = text.slice(i + 1);
  const j = rest.search(/\n\s*(@\S+.*\n\s*)?Scenario/);
  block = j < 0 ? text.slice(i) : text.slice(i, i + 1 + j);
});

Then('k-integrate-pins-20261112t205438z: its tool expectation is {string}', function (tools) {
  const m = block.match(/request 1 offers exactly the tools "([^"]*)"/);
  assert.ok(m, 'no tool expectation in scenario');
  assert.strictEqual(m[1], tools);
});
