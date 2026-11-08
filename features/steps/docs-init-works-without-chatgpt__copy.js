const { Then } = require('@cucumber/cucumber');
const assert = require('node:assert/strict');
const fs = require('node:fs');

const FILES = ['README.md', 'packaging/README.md', 'docs/getting-started.md'];

function read(file) {
  return fs.readFileSync(file, 'utf8');
}

function norm(text) {
  return text.replace(/\s+/g, ' ').toLowerCase();
}

function guideStep(n) {
  const match = read('docs/getting-started.md').match(
    new RegExp('^## ' + n + '\\. [^\\n]*\\n([\\s\\S]*?)(?=^## |$(?![\\s\\S]))', 'm'),
  );
  assert.ok(match, `docs/getting-started.md must have a step ${n} section`);
  return match[1];
}

function assertPhrases(label, text, table) {
  const haystack = norm(text);
  for (const [phrase] of table.raw()) {
    assert.ok(haystack.includes(norm(phrase)), `${label} is missing: ${phrase}`);
  }
}

Then('docs-init-works-without-chatgpt: step {int} of the getting-started guide contains these phrases', function (n, table) {
  assertPhrases(`docs/getting-started.md step ${n}`, guideStep(n), table);
});

Then('docs-init-works-without-chatgpt: {string} contains these phrases', function (file, table) {
  assertPhrases(file, read(file), table);
});

Then('docs-init-works-without-chatgpt: line 3 of {string} is {string}', function (file, expected) {
  const line = read(file).split('\n')[2];
  assert.equal(line, expected, `line 3 of ${file}`);
});

Then('docs-init-works-without-chatgpt: no file claims that kogen init needs ChatGPT', function () {
  for (const file of FILES) {
    const text = read(file);
    assert.ok(!/needs a ChatGPT login/i.test(text), `${file} still says init needs a ChatGPT login`);
    assert.ok(!/with your ChatGPT plan/i.test(text), `${file} still says 'with your ChatGPT plan'`);
    for (const sentence of text.split(/(?<=[.!?])\s+|\n/)) {
      const claims =
        /chatgpt/i.test(sentence) &&
        /\b(init|discovery)\b/i.test(sentence) &&
        /\b(need|needs|require|requires|required|only|plan|depends?)\b/i.test(sentence) &&
        !/\b(not|without|no|never)\b|n't/i.test(sentence);
      assert.ok(!claims, `${file} claims init needs ChatGPT: ${sentence}`);
    }
  }
});
