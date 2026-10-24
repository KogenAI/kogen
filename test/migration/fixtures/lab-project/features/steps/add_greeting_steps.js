const { Then } = require('@cucumber/cucumber');
const fs = require('node:fs');
const assert = require('node:assert/strict');

Then('the greeting file holds a greeting', () => {
  assert.match(fs.readFileSync('hello.txt', 'utf8'), /^(hi|hello)\n$/);
});
