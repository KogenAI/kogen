'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { When, Then } = require('@cucumber/cucumber');
const root = path.resolve(__dirname, '../..');

function exists(relative) {
  try { fs.lstatSync(path.join(root, relative)); return true; } catch { return false; }
}

Then('k-drop-kogen-wire-goldens: the specification file {string} still has the scenario {string}', function (file, title) {
  const text = fs.readFileSync(path.join(root, file), 'utf8');
  assert.ok(text.split('\n').some(line => line.trim() === `Scenario: ${title}`), `${file} lacks the installed-binary scenario "${title}"`);
});

Then('k-drop-kogen-wire-goldens: these paths are absent from the checkout:', function (table) {
  const present = table.raw().map(row => row[0]).filter(exists);
  assert.deepEqual(present, [], `still present in the checkout: ${present.join(', ')}`);
});

When('k-drop-kogen-wire-goldens: I list the tests of the cli package', { timeout: 300000 }, function () {
  const args = ['test', '-list', '.*', '.'];
  const r = spawnSync('go', args, { cwd: path.join(root, 'cli'), encoding: 'utf8', timeout: 280000, maxBuffer: 16 * 1024 * 1024 });
  const stdout = String(r.stdout || '');
  this.kDropListing = {
    command: `go ${args.join(' ')} in cli`,
    status: r.status,
    error: r.error ? r.error.message : 'none',
    output: stdout + String(r.stderr || ''),
    names: stdout.split('\n').filter(line => /^(Test|Example|Benchmark|Fuzz)\S*$/.test(line)),
  };
});

function describe(listing) {
  return `${listing.command}: exit=${listing.status}, error=${listing.error}\n${listing.output}`;
}

Then('k-drop-kogen-wire-goldens: the cli test listing succeeds', function () {
  const listing = this.kDropListing;
  assert.equal(listing.error, 'none', describe(listing));
  assert.equal(listing.status, 0, `the cli test listing failed; ${describe(listing)}`);
  assert.match(listing.output, /^ok\s+kogen\s/m, `the cli test listing did not report ok for package kogen; ${describe(listing)}`);
  assert.ok(listing.names.length > 0, `the cli test listing named no tests; ${describe(listing)}`);
});

Then('k-drop-kogen-wire-goldens: the cli test listing still names:', function (table) {
  const listing = this.kDropListing;
  for (const [name] of table.raw()) {
    assert.ok(listing.names.includes(name), `${name}: absent from the cli test listing, but it must be kept; ${describe(listing)}`);
  }
});

Then('k-drop-kogen-wire-goldens: the cli test listing names none of:', function (table) {
  const listing = this.kDropListing;
  for (const [name] of table.raw()) {
    assert.ok(!listing.names.includes(name), `${name}: still listed by the cli package, but it must be removed; ${describe(listing)}`);
  }
});
