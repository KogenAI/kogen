'use strict';
const assert = require('node:assert/strict');
const path = require('node:path');
const { execFile } = require('node:child_process');
const { When, Then } = require('@cucumber/cucumber');
When('fixed-wait acceptance runs the regression entry point', { timeout: 110000 }, async function () {
  this.fixedWaitResult = await new Promise(resolve => {
    execFile(process.execPath, ['test/acceptance/fixed-wait-regression.cjs'], {
      cwd: path.resolve(__dirname, '../..'), timeout: 100000, maxBuffer: 4 * 1024 * 1024
    }, (error, stdout, stderr) => resolve({ code: error ? error.code : 0, output: stdout + stderr }));
  });
});
Then('fixed-wait acceptance succeeds with {string}', function (expected) {
  const result = this.fixedWaitResult;
  assert.equal(result.code, 0, `node test/acceptance/fixed-wait-regression.cjs: ${result.code}\n${result.output}`);
  assert.ok(result.output.split(/\r?\n/).includes(expected), `regression completion missing: ${expected}\n${result.output}`);
});
