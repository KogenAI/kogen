'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { When, Then } = require('@cucumber/cucumber');
const root = path.resolve(__dirname, '../..');
When('the removed native fingerprint identifiers are collected', function () {
  const hits = [];
  function walk(dir) {
    for (const ent of fs.readdirSync(dir, { withFileTypes: true })) {
      const p = path.join(dir, ent.name);
      if (ent.isDirectory()) {
        if (p !== path.join(root, 'cli/third_party')) walk(p);
      } else if (ent.isFile() && p.endsWith('.go') && /\bNoProgress\b|native_no_progress|nativeFingerprint/.test(fs.readFileSync(p, 'utf8'))) {
        hits.push(path.relative(root, p));
      }
    }
  }
  walk(path.join(root, 'cli'));
  this.fingerprintReferences = hits.sort();
});
Then('the native fingerprint reference paths are {string}', function (expected) {
  assert.deepEqual(this.fingerprintReferences, JSON.parse(expected));
});
When('the fingerprint removal affected packages run', { timeout: 1210000 }, function () {
  this.fingerprintPackages = spawnSync('go', ['test', './build', './shape', './executor', './project', '-count=1'], {
    cwd: path.join(root, 'cli'), encoding: 'utf8', timeout: 1200000, maxBuffer: 8388608
  });
});
Then('the fingerprint removal package command exits with {int}', function (expected) {
  const r = this.fingerprintPackages;
  assert.ifError(r.error);
  assert.equal(r.status, expected, 'go test ./build ./shape ./executor ./project -count=1\n' + r.stdout + r.stderr);
});
