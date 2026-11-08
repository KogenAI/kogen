const { Then } = require('@cucumber/cucumber');
const assert = require('node:assert/strict');
const fs = require('node:fs');

Then('k-spec-wording-contradictions: file {string} contains {string}', function (path, text) {
  assert.ok(fs.readFileSync(path, 'utf8').includes(text), `${path} must contain: ${text}`);
});

Then('k-spec-wording-contradictions: file {string} excludes {string}', function (path, text) {
  assert.ok(!fs.readFileSync(path, 'utf8').toLowerCase().includes(text.toLowerCase()), `${path} must exclude: ${text}`);
});
