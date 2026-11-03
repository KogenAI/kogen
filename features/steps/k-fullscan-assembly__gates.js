'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

// Judge actual Cucumber JSON, including hook results; an exit code alone is not proof.
function completeReport(report, expected) {
  assert.ok(Array.isArray(report), 'Cucumber report must be an array');
  const scenarios = report.flatMap(f => f.elements || []).filter(e => e.type === 'scenario');
  assert.equal(scenarios.length, expected, `expected ${expected} discovered scenarios`);
  assert.ok(expected > 0, 'zero scenarios is not qualification');
  for (const scenario of scenarios) {
    assert.ok(scenario.steps.length > 0, `empty scenario: ${scenario.name}`);
    for (const step of [...(scenario.before || []), ...scenario.steps, ...(scenario.after || [])]) {
      assert.equal(step.result && step.result.status, 'passed', `${scenario.name}: ${step.name || 'hook'} did not pass`);
      for (const hook of [...(step.before || []), ...(step.after || [])]) {
        assert.equal(hook.result && hook.result.status, 'passed', `${scenario.name}: step hook did not pass`);
      }
    }
  }
  return scenarios.length;
}
module.exports = { completeReport };

if (!process.env.KOGEN_FULLSCAN_CONTROL) {
  const { When, Then } = require('@cucumber/cucumber');
  const root = path.resolve(__dirname, '../..');
  When('k-fullscan-assembly: I run the complete deterministic assembly qualification', { timeout: 1800000 }, function () {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-fullscan-'));
    const report = path.join(dir, 'spec.json');
    const command = `set -eu
for d in cli cli/buildprogram; do
  (cd "$d"; test -z "$(gofmt -l .)"; go build ./...; go vet ./...; go test ./...)
done
(cd spec && npm ci && sh check.sh)
(cd test/acceptance && npm ci)
sh test/suite.sh
(cd test/acceptance && "$KOGEN_FULLSCAN_NODE" node_modules/@cucumber/cucumber/bin/cucumber.js --parallel 4 --strict --tags "not @live" --require "steps/*.js" --require "support/*.js" --format "json:$KOGEN_FULLSCAN_REPORT" ../../spec/features)
`;
    const result = spawnSync('/bin/sh', ['-c', command], {
      cwd: root, env: { ...process.env, KOGEN_FULLSCAN_REPORT: report, KOGEN_FULLSCAN_NODE: process.execPath },
      encoding: 'utf8', maxBuffer: 64 * 1024 * 1024, timeout: 1700000,
    });
    this.fullscan = { status: result.status, signal: result.signal, error: result.error && result.error.message,
      output: String(result.stdout || '') + String(result.stderr || ''), report: null };
    try { if (fs.existsSync(report)) this.fullscan.report = JSON.parse(fs.readFileSync(report, 'utf8')); }
    finally { fs.rmSync(dir, { recursive: true, force: true }); }
  });
  Then('k-fullscan-assembly: all gates pass and all {int} specification scenarios and their steps pass', function (count) {
    const r = this.fullscan;
    assert.equal(r.status, 0, `assembly qualification failed (signal=${r.signal}, error=${r.error}):\n${r.output}`);
    const total = completeReport(r.report, count);
    this.attach(`Complete non-live specification: ${total} scenarios, all steps and hooks passed.\n${r.output}`, 'text/plain');
  });
}
