const { Then } = require('@cucumber/cucumber');
const assert = require('node:assert/strict');
const fs = require('node:fs');

function norm(text) {
  return text.replace(/\s+/g, ' ').toLowerCase();
}

Then('docs-config-init-without-chatgpt: {string} contains these phrases', function (file, table) {
  const haystack = norm(fs.readFileSync(file, 'utf8'));
  for (const [phrase] of table.raw()) {
    assert.ok(haystack.includes(norm(phrase)), `${file} is missing: ${phrase}`);
  }
});

Then('docs-config-init-without-chatgpt: {string} has none of the stale init claims', function (file) {
  const text = fs.readFileSync(file, 'utf8').replace(/\s+/g, ' ');
  const haystack = text.toLowerCase();
  const stale = [
    'still requires chatgpt',
    'requires chatgpt or claude code',
    'discovery with bare `kogen init` still requires',
  ];
  for (const phrase of stale) {
    assert.ok(!haystack.includes(phrase), `${file} still contains the stale claim: ${phrase}`);
  }
  for (const sentence of text.split(/(?<=[.!?])\s+/)) {
    const claims =
      /chatgpt/i.test(sentence) &&
      /\b(init|discovery)\b/i.test(sentence) &&
      /\b(need|needs|require|requires|required|only|plan|depends?)\b/i.test(sentence) &&
      !/\b(not|without|no|never)\b|n't/i.test(sentence);
    assert.ok(!claims, `${file} claims init needs ChatGPT: ${sentence}`);
  }
});
