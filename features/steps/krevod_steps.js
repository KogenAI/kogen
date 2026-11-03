'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { Then } = require('@cucumber/cucumber');
const ROOT = path.resolve(__dirname, '../..');

Then('the krevod configuration documentation presents review_material as experimental and off by default', function () {
  const text = fs.readFileSync(path.join(ROOT, 'docs/configuration.md'), 'utf8');
  const line = text.split('\n').find(l => l.includes('review_material'));
  assert.ok(line, 'docs/configuration.md does not mention review_material');
  assert.ok(/experimental/i.test(line) && /off by default/i.test(line) && line.includes('on_demand') && line.includes('parts'), line);
  assert.ok(text.indexOf('review_material') > text.indexOf('shape_decision_check'), 'not next to the other levers');
});
