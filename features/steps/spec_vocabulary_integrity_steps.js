const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { createHash } = require('node:crypto');
const { spawnSync } = require('node:child_process');
const { When, Then } = require('@cucumber/cucumber');

When('I run the full specification wrapper', { timeout: 300000 }, function () {
  const spec = path.resolve(__dirname, '../../spec');
  this.specWrapperDigest = createHash('sha256')
    .update(fs.readFileSync(path.join(spec, 'check.sh'))).digest('hex');
  this.specWrapperResult = spawnSync('sh', ['check.sh'], {
    cwd: spec, encoding: 'utf8', maxBuffer: 8 * 1024 * 1024,
  });
  this.specWrapperOutput = (this.specWrapperResult.stdout || '') +
    (this.specWrapperResult.stderr || '');
});

Then('the specification wrapper exits with {int}', function (expected) {
  const result = this.specWrapperResult;
  assert.ok(!result.error, `${result.error}\n${this.specWrapperOutput}`);
  assert.equal(result.status, expected,
    `Full spec wrapper status ${result.status}, signal ${result.signal}\n${this.specWrapperOutput}`);
});

Then('the specification wrapper SHA-256 is {string}', function (expected) {
  assert.equal(this.specWrapperDigest, expected);
});

Then('the specification wrapper output includes:', function (expected) {
  for (const line of expected.split('\n')) {
    assert.ok(this.specWrapperOutput.includes(line),
      `Missing wrapper output: ${line}\n${this.specWrapperOutput}`);
  }
});
