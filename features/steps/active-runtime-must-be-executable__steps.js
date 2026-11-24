'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { Given, When, Then, After } = require('@cucumber/cucumber');

const prefix = 'active-runtime-must-be-executable: ';
const root = path.resolve(__dirname, '../..');

function run(command, args, cwd) {
  const r = spawnSync(command, args, { cwd, encoding: 'utf8', timeout: 90000 });
  assert.equal(r.status, 0, `${command} ${args.join(' ')}: ${r.error || ''}\n${r.stdout || ''}${r.stderr || ''}`);
  return r.stdout;
}

Given(prefix + 'a newer active version {string} with a regular runtime of mode {string}', { timeout: 110000 }, function (version, mode) {
  this.activeExecutableWork = fs.mkdtempSync(path.join(os.tmpdir(), 'active-executable-'));
  this.activeExecutableSource = fs.mkdtempSync(path.join(root, 'cli', 'active-executable-'));
  const source = path.join(this.activeExecutableSource, 'main.go');
  fs.copyFileSync(path.join(__dirname, 'active-runtime-must-be-executable__driver/main.go'), source);
  this.activeExecutableBinary = path.join(this.activeExecutableWork, 'driver');
  run('go', ['build', '-o', this.activeExecutableBinary, source], path.join(root, 'cli'));
  this.activeExecutableHome = path.join(this.activeExecutableWork, 'home');
  // Layout values come from Root, Version, RuntimePath and ActiveFile, not guessed pin values.
  this.activeExecutableLayout = JSON.parse(run(this.activeExecutableBinary, [this.activeExecutableHome, 'layout'], root));
  const layout = this.activeExecutableLayout;
  this.activeExecutableVersion = version;
  this.activeExecutablePath = path.join(layout[0], version, 'claude');
  fs.mkdirSync(path.dirname(this.activeExecutablePath), { recursive: true });
  // No valid program is needed: Active must only inspect the file, not run it.
  fs.writeFileSync(this.activeExecutablePath, 'runtime fixture\n');
  fs.chmodSync(this.activeExecutablePath, parseInt(mode, 8));
  assert.equal(fs.statSync(this.activeExecutablePath).mode & 0o777, parseInt(mode, 8));
  fs.writeFileSync(path.join(layout[0], layout[3]), version + '\n');
});

When(prefix + 'Active is called for that home', function () {
  this.activeExecutableResult = JSON.parse(run(this.activeExecutableBinary, [this.activeExecutableHome, 'active'], root));
});

Then(prefix + 'the returned version and path identify the {string} runtime', function (selected) {
  const layout = this.activeExecutableLayout;
  const expected = selected === 'pinned'
    ? [layout[1], layout[2]]
    : [this.activeExecutableVersion, this.activeExecutablePath];
  assert.deepEqual(this.activeExecutableResult, expected);
});

After(function () {
  if (this.activeExecutableSource) fs.rmSync(this.activeExecutableSource, { recursive: true, force: true });
  if (this.activeExecutableWork) fs.rmSync(this.activeExecutableWork, { recursive: true, force: true });
});
