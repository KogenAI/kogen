'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { Then } = require('@cucumber/cucumber');
const ROOT = path.resolve(__dirname, '../..');

Then('the k-line-period file {string} contains:', function (rel, text) {
  const body = fs.readFileSync(path.join(ROOT, rel), 'utf8');
  assert.ok(body.includes(text), `${rel} does not contain:\n${text}`);
});
