const { Given, Then } = require('@cucumber/cucumber');
const assert = require('assert');
const fs = require('fs');
const path = require('path');

const root = process.cwd();

Given('release-drop-duplicate-homebrew-workflow: the repository checkout', function () {
  assert.ok(fs.existsSync(path.join(root, 'README.md')), 'README.md missing in ' + root);
});

Then('release-drop-duplicate-homebrew-workflow: these paths do not exist', function (table) {
  const present = table.raw().map((r) => r[0]).filter((p) => fs.existsSync(path.join(root, p)));
  assert.deepStrictEqual(present, [], 'paths still present: ' + present.join(', '));
});

Then('release-drop-duplicate-homebrew-workflow: no workflow mentions homebrew-tap or HOMEBREW_TAP_TOKEN', function () {
  const dir = path.join(root, '.github', 'workflows');
  const hits = fs
    .readdirSync(dir)
    .filter((f) => /\.ya?ml$/.test(f))
    .filter((f) => /homebrew-tap|HOMEBREW_TAP_TOKEN/i.test(fs.readFileSync(path.join(dir, f), 'utf8')));
  assert.deepStrictEqual(hits, [], 'workflows still referencing the tap: ' + hits.join(', '));
});

Then('release-drop-duplicate-homebrew-workflow: README.md contains {string} ignoring case', function (text) {
  const readme = fs.readFileSync(path.join(root, 'README.md'), 'utf8').toLowerCase();
  assert.ok(readme.includes(text.toLowerCase()), 'README.md lacks: ' + text);
});
