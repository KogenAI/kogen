'use strict';
// Kogen's fake acceptance runner (test/acceptance/fixtures/runners/run.js), run as Kogen's acceptance
// suite runs it and accounted by the real verify.Account at the pinned kogen-verification and at 11a5244.
const assert = require('node:assert/strict');
const { Given, Then } = require('@cucumber/cucumber');
const { verdicts } = require('./k_fake_runner_step_evidence_check.cjs');

const RUNNER = 'test/acceptance/fixtures/runners/run.js';
let fixtureMode;

Given('Kogen\'s fake acceptance runner runs in mode {string} on the is-even fixture feature', function (mode) {
  fixtureMode = mode;
});

Then('kogen-verification at the current pin and at 11a5244 both account exit {int}, scenarios {string} and problems {string}', { timeout: 600000 }, function (exit, statuses, problems) {
  const lines = verdicts(RUNNER, fixtureMode, { exit, statuses, problems });
  assert.ok(lines.every(l => l.ok), `fixture runner ${RUNNER} mode ${fixtureMode}:\n${lines.map(l => l.line).join('\n')}`);
});
