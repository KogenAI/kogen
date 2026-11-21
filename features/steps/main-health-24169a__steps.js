const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { Given, Then } = require('@cucumber/cucumber');
const root = path.resolve(__dirname, '../..');

Given('main-health-24169a: the release script and the archive mode observer are read', function () {
  const script = fs.readFileSync(path.join(root, 'packaging/package.sh'), 'utf8');
  const line = script.split('\n').find(l => /\bcp docs\/\S+.* "\$work\/docs\/"/.test(l));
  assert.ok(line, 'packaging/package.sh has no line copying docs into "$work/docs/"');
  this.mh = {
    copied: [...line.matchAll(/docs\/([^\s"]+\.md)/g)].map(m => m[1]).sort(),
  };
  const observer = fs.readFileSync(path.join(root, 'features/steps/release_archive_public_modes.py'), 'utf8');
  const m = observer.match(/^SHIPPED_DOCS = \(([^)]*)\)/m);
  assert.ok(m, 'release_archive_public_modes.py has no SHIPPED_DOCS tuple');
  this.mh.expected = [...m[1].matchAll(/'([^']+)'/g)].map(x => x[1]).sort();
});

Then('main-health-24169a: the release script still copies the Providers guide into the archive docs', function () {
  assert.ok(this.mh.copied.includes('providers.md'),
    'packaging/package.sh must keep copying docs/providers.md; copied: ' + this.mh.copied.join(', '));
});

Then('main-health-24169a: the observer expects exactly the docs the release script copies', function () {
  assert.deepEqual(this.mh.expected, this.mh.copied,
    'SHIPPED_DOCS in release_archive_public_modes.py differs from the docs copied by packaging/package.sh');
});

Then('main-health-24169a: every doc the observer expects exists in the docs folder', function () {
  for (const name of this.mh.expected) {
    assert.ok(fs.existsSync(path.join(root, 'docs', name)), 'docs/' + name + ' does not exist');
  }
});
