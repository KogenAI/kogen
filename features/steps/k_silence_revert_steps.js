'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { When, Then } = require('@cucumber/cucumber');
const root = path.resolve(__dirname, '../..');

When('silence revert collects Go sources under cli that mention the no-output shell watch', function () {
  const hits = [];
  const marker = /\bwatchedShell\b|\bshellSilence\b|"no_output"|no output for/;
  function walk(dir) {
    for (const ent of fs.readdirSync(dir, { withFileTypes: true })) {
      const p = path.join(dir, ent.name);
      if (ent.isDirectory()) {
        if (p !== path.join(root, 'cli/third_party')) walk(p);
      } else if (ent.isFile() && p.endsWith('.go') && marker.test(fs.readFileSync(p, 'utf8'))) {
        hits.push(path.relative(root, p));
      }
    }
  }
  walk(path.join(root, 'cli'));
  this.silenceRevertReferences = hits.sort();
});

Then('silence revert source paths are {string}', function (expected) {
  assert.deepEqual(this.silenceRevertReferences, JSON.parse(expected),
    `Go files under cli/ (outside cli/third_party) still mention watchedShell, shellSilence, "no_output" or "no output for": ${JSON.stringify(this.silenceRevertReferences)}`);
});

Then('silence revert finds no file {string}', function (relative) {
  assert.ok(!fs.existsSync(path.join(root, relative)), `${relative} must not exist`);
});

Then('silence revert finds the line starting {string} in {string} is:', function (prefix, relative, expected) {
  const lines = fs.readFileSync(path.join(root, relative), 'utf8').split('\n').filter(l => l.startsWith(prefix));
  assert.equal(lines.length, 1, `${relative} must have exactly one line starting ${prefix}; found ${lines.length}`);
  assert.equal(lines[0], expected.trim(), `${relative}: the line starting ${prefix} differs`);
});

Then('silence revert finds the section {string} of {string} is:', function (heading, relative, expected) {
  const lines = fs.readFileSync(path.join(root, relative), 'utf8').split('\n');
  const at = lines.indexOf(heading);
  assert.ok(at >= 0, `${relative} has no line ${heading}`);
  const body = [];
  for (const l of lines.slice(at + 1)) {
    if (l.startsWith('## ')) break;
    body.push(l);
  }
  assert.equal(body.join('\n').trim(), expected.trim(), `${relative}: section ${heading} differs`);
});
