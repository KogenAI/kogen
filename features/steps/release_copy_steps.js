const { When, Then } = require('@cucumber/cucumber');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { verdict } = require('./release_copy_observer.cjs');
When('I run the real install and uninstall chapter once with workspace counting', function () {
  const root = process.cwd();
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'release-copy-report-'));
  try {
    const report = path.join(tmp, 'count.json');
    const cucumber = path.join(root, 'test/acceptance/node_modules/@cucumber/cucumber/bin/cucumber.js');
    const run = spawnSync(process.execPath, [cucumber, '--strict', '--tags', 'not @live', '--require', 'steps/*.js', '--require', 'support/*.js', '--require', path.join(root, 'features/steps/release_copy_observer.cjs'), '../../spec/features/10-install-and-uninstall.feature', '--format', `json:${path.join(tmp, 'results.json')}`], {
      cwd: path.join(root, 'test/acceptance'), encoding: 'utf8', maxBuffer: 16 * 1024 * 1024,
      env: { ...process.env, KOGEN_RELEASE_COPY_REPORT: report },
    });
    assert.equal(run.status, 0, `install/uninstall chapter failed: ${run.error || ''}\n${run.stdout}\n${run.stderr}`);
    const scenarios = JSON.parse(fs.readFileSync(path.join(tmp, 'results.json'), 'utf8')).flatMap(f => f.elements || []).filter(e => e.type === 'scenario');
    this.releaseCopy = { ...JSON.parse(fs.readFileSync(report, 'utf8')), scenarios: scenarios.length, passed: scenarios.filter(s => s.steps.length && s.steps.every(t => t.result.status === 'passed')).length };
  } finally { fs.rmSync(tmp, { recursive: true, force: true }); }
});
Then('all {int} chapter scenarios pass with fewer than {int} observed workspace files and no full release copies', function (n, baseline) {
  assert.equal(this.releaseCopy.scenarios, n);
  console.log(`workspace file paths before=${baseline} after=${this.releaseCopy.files}; full release copies=${this.releaseCopy.fullCopies}`);
  assert.ok(verdict(this.releaseCopy, baseline), JSON.stringify(this.releaseCopy));
});
