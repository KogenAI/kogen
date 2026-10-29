'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { When, Then } = require('@cucumber/cucumber');
const root = path.resolve(__dirname, '../..');
When('the native cap production references are collected', function () {
  const hits = [];
  function walk(dir) {
    for (const ent of fs.readdirSync(dir, { withFileTypes: true })) {
      const p = path.join(dir, ent.name);
      if (ent.isDirectory()) {
        if (p !== path.join(root, 'cli/third_party')) walk(p);
      } else if (ent.isFile() && p.endsWith('.go') && /NativeRoundLimits|native_round_limit/.test(fs.readFileSync(p, 'utf8'))) {
        hits.push(path.relative(root, p));
      }
    }
  }
  walk(path.join(root, 'cli'));
  this.capReferences = hits.sort();
});
Then('the removed native cap reference list is {string}', function (expected) {
  assert.deepEqual(this.capReferences, JSON.parse(expected));
});
When('the native cap affected package tests run', { timeout: 1210000 }, function () {
  this.capTests = spawnSync('go', ['test', './build', './shape', './executor', '-count=1'], {
    cwd: path.join(root, 'cli'), encoding: 'utf8', timeout: 1200000, maxBuffer: 8388608
  });
});
Then('the native cap affected package tests exit with {int}', function (expected) {
  const r = this.capTests;
  assert.ifError(r.error);
  assert.equal(r.status, expected, 'go test ./build ./shape ./executor -count=1\n' + r.stdout + r.stderr);
});
