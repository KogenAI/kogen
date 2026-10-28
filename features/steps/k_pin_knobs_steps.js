const assert = require('node:assert/strict');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const { When, Then } = require('@cucumber/cucumber');
const root = path.resolve(__dirname, '../..');

When('I run the loop knob contract test {string} in {string}', { timeout: 300000 }, function (name, directory) {
  this.loopKnobOutput = execFileSync('go', ['test', '-race', '-count=1', '-v', '-run', `^${name}$`, '.'], {
    cwd: path.join(root, directory), encoding: 'utf8', timeout: 290000, stdio: ['ignore', 'pipe', 'pipe'],
  });
});
Then('the loop knob contract test {string} passes', function (name) {
  assert.ok(this.loopKnobOutput.includes(`--- PASS: ${name} (`), `Required test did not execute and pass: ${name}\n${this.loopKnobOutput}`);
});
When('I run the pinned loop race suite', { timeout: 300000 }, function () {
  this.loopKnobRace = execFileSync('go', ['test', '-race', '-count=1', './...'], {
    cwd: path.join(root, 'cli/third_party/kogen-loop'), encoding: 'utf8', timeout: 290000, stdio: ['ignore', 'pipe', 'pipe'],
  });
});
Then('the pinned loop race suite succeeds', function () {
  assert.equal(typeof this.loopKnobRace, 'string');
});
