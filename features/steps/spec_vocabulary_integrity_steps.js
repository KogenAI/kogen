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

// What this scenario protects is that the specification checker was not weakened: the wrapper is the pinned original
// and the checker `spec/tools/check.mjs` is byte-identical to it. The Go migration removed the Elixir core, so the one wrapper
// line that names its crash signal changed from CoreCrash to InternalError (two `refute run_control.qnt` lines); that
// rename is the only accepted difference, proved by reversing it and comparing the digest with the pinned one. Any
// other edit to the wrapper changes the reversed digest and fails. The checker's digest is main 76109e1's.
const CHECKER_SHA256 = 'a8394209603281ee4a72fee01034d50eb1fd873e96b927407f98eacae74495d1';
Then('the specification wrapper SHA-256 is {string}', function (expected) {
  const spec = path.resolve(__dirname, '../../spec');
  const sha = bytes => createHash('sha256').update(bytes).digest('hex');
  assert.equal(sha(fs.readFileSync(path.join(spec, 'tools/check.mjs'))), CHECKER_SHA256, 'spec/tools/check.mjs must stay unchanged (no weakened unused-step lint)');
  if (this.specWrapperDigest === expected) return;
  const wrapper = fs.readFileSync(path.join(spec, 'check.sh'), 'utf8');
  const original = wrapper.replaceAll('signal == InternalError', 'signal == CoreCrash');
  assert.equal(sha(original), expected, `wrapper digest ${this.specWrapperDigest} differs from the pinned original by more than the CoreCrash to InternalError rename`);
});

// The pinned coverage counts of the original wrapper are floors: the public specification only grew since (main
// 76109e1 reports 105 requirements and 166 scenarios), so fewer requirements or scenarios than pinned, or than main, fails.
// Every other expected line must appear exactly.
const FLOORS = { requirements: 105, scenarios: 166 };
Then('the specification wrapper output includes:', function (expected) {
  for (const line of expected.split('\n')) {
    const counts = /^requirements (\d+), scenarios (\d+),$/.exec(line);
    if (counts) {
      const actual = /^requirements (\d+), scenarios (\d+),/m.exec(this.specWrapperOutput);
      const requirements = Math.max(Number(counts[1]), FLOORS.requirements), scenarios = Math.max(Number(counts[2]), FLOORS.scenarios);
      assert.ok(actual && Number(actual[1]) >= requirements && Number(actual[2]) >= scenarios,
        `Wrapper counts ${actual && actual[0]} fall below ${requirements} requirements and ${scenarios} scenarios (pinned ${counts[1]} and ${counts[2]})\n${this.specWrapperOutput}`);
      continue;
    }
    assert.ok(this.specWrapperOutput.includes(line),
      `Missing wrapper output: ${line}\n${this.specWrapperOutput}`);
  }
});
