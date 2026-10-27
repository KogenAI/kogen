'use strict';
// Observes kogen/shape's Go tests through the real `go test` command: the set of test names, that every one of them
// ran and passed (none skipped), the unchanged go-test check command, and the wall time reported for the package.
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { execFile } = require('node:child_process');
const { Given, When, Then, setDefaultTimeout } = require('@cucumber/cucumber');

setDefaultTimeout(15 * 60 * 1000);
const ROOT = path.resolve(__dirname, '../..');

function go(args, env) {
  return new Promise(resolve => {
    execFile('go', args, { cwd: path.join(ROOT, 'cli'), env: { ...process.env, ...env }, maxBuffer: 1 << 28 }, (error, stdout, stderr) => {
      resolve({ code: error ? (typeof error.code === 'number' ? error.code : 1) : 0, stdout, stderr });
    });
  });
}

When('I list the Go tests of the shape package', async function () {
  const r = await go(['test', '-list', '.', './shape']);
  assert.equal(r.code, 0, r.stdout + r.stderr);
  this.names = r.stdout.split('\n').filter(l => l.startsWith('Test')).sort();
});

Then('there are {int} tests whose sorted names hash to {string}', function (count, hash) {
  assert.equal(this.names.length, count);
  assert.equal(crypto.createHash('md5').update(this.names.join('\n') + '\n').digest('hex'), hash);
});

Given('the shape test sources and the project configuration', function () {
  this.sources = fs.readdirSync(path.join(ROOT, 'cli/shape')).filter(n => n.endsWith('_test.go')).map(n => fs.readFileSync(path.join(ROOT, 'cli/shape', n), 'utf8')).join('\n');
  this.config = fs.readFileSync(path.join(ROOT, '.kogen/project.yaml'), 'utf8');
});

Then('the go-test check command is exactly {string}', function (command) {
  const line = this.config.split('\n').find(l => /^\s*(- )?(name: )?go-test\b/.test(l) || l.includes('go-test'));
  assert.ok(this.config.includes(command), 'go-test command changed');
  assert.ok(!/-timeout/.test(this.config), 'a -timeout flag was added to the configuration');
  assert.ok(line, 'go-test check missing');
});

Then('the shape test sources contain exactly {int} t.Skip calls and no build tags', function (n) {
  assert.equal((this.sources.match(/t\.Skip(f|Now)?\(/g) || []).length, n);
  assert.ok(!/\/\/go:build|\/\/ \+build/.test(this.sources), 'a build tag was added');
});

When('I run the shape tests with the race detector and GOMAXPROCS {int} once', async function (procs) {
  const r = await go(['test', '-race', '-count=1', '-json', './shape'], { GOMAXPROCS: String(procs) });
  this.run = r;
  this.events = r.stdout.split('\n').filter(l => l.startsWith('{')).map(l => JSON.parse(l));
});

Then('the package passes with every listed test run and passed and none skipped or failed', async function () {
  const bad = this.events.filter(e => e.Test && (e.Action === 'fail' || e.Action === 'skip')).map(e => `${e.Action} ${e.Test}`);
  assert.deepEqual(bad, []);
  const pkg = this.events.find(e => !e.Test && (e.Action === 'pass' || e.Action === 'fail'));
  assert.ok(pkg && pkg.Action === 'pass', `package did not pass (exit ${this.run.code}): ${this.run.stderr.slice(0, 500)}`);
  const listed = await go(['test', '-list', '.', './shape']);
  const names = listed.stdout.split('\n').filter(l => l.startsWith('Test'));
  const passed = new Set(this.events.filter(e => e.Test && !e.Test.includes('/') && e.Action === 'pass').map(e => e.Test));
  assert.deepEqual(names.filter(n => !passed.has(n)), []);
});

Then('the package elapsed time is at most {int} seconds', function (limit) {
  const pkg = this.events.find(e => !e.Test && e.Action === 'pass');
  assert.ok(pkg.Elapsed <= limit, `package took ${pkg.Elapsed} s, limit ${limit} s`);
});
