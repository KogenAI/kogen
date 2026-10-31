'use strict';
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const { When, Then } = require('@cucumber/cucumber');
When('I read the targeted-test research record', function () {
  this.targetedResearch = fs.readFileSync(path.resolve(__dirname, '../../docs/round-targeted-tests.md'), 'utf8');
});
Then('the record contains {string}', function (text) {
  assert.ok(this.targetedResearch.includes(text), `docs/round-targeted-tests.md must contain ${JSON.stringify(text)}`);
});
