const { Then } = require('@cucumber/cucumber');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

function install(file) {
  const text = fs.readFileSync(file, 'utf8');
  const start = /^## (?:1\. )?Install\s*$/m.exec(text);
  assert.ok(start, `${file}: Install heading missing`);
  const rest = text.slice(start.index + start[0].length);
  return rest.split(/^## /m)[0];
}

Then('docs-prerelease-install-command-first: the first shell command in {string} is {string}', function (file, expected) {
  const block = /```(?:sh|bash|shell)\s*\n([^\n]+)/.exec(install(file));
  assert.equal(block && block[1].trim(), expected, `${file}: first install command`);
  // Check Markdown link targets in each edited document without network requests.
  for (const match of fs.readFileSync(file, 'utf8').matchAll(/\[[^\]]*\]\(([^\s)]+)\)/g)) {
    const target = match[1];
    if (/^https?:/.test(target)) {
      assert.ok(new URL(target).hostname, `${file}: invalid URL ${target}`);
    } else if (!target.startsWith('#')) {
      assert.ok(fs.existsSync(path.resolve(path.dirname(file), target.split('#')[0])), `${file}: broken relative link ${target}`);
    }
  }
});

Then('docs-prerelease-install-command-first: install section in {string} contains {string}', function (file, expected) {
  assert.ok(install(file).includes(expected), `${file}: Install missing ${expected}`);
});

Then('docs-prerelease-install-command-first: in {string} the text {string} precedes {string}', function (file, first, second) {
  const text = fs.readFileSync(file, 'utf8');
  const a = text.indexOf(first);
  const b = text.indexOf(second);
  assert.ok(a >= 0 && b > a, `${file}: expected ${first} before ${second}`);
});
