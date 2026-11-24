'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { Given, When, Then, AfterAll } = require('@cucumber/cucumber');
const observe = require('./readiness-claude-auth-probe-errors__driver/observe.cjs');
const root = path.resolve(__dirname, '../..');
const prefix = 'readiness-claude-auth-probe-errors: ';
let buildDir, binary;

function run(command, args, options) {
  const result = spawnSync(command, args, { encoding: 'utf8', timeout: 100000, maxBuffer: 4 * 1024 * 1024, ...options });
  assert.ifError(result.error);
  assert.equal(result.status, 0, `${command} ${args.join(' ')} exited ${result.status}: ${result.stdout}\n${result.stderr}`);
  return result.stdout;
}

Given(prefix + 'a managed Claude Code without a stored token returns exit {int} and auth status:', function (code, body) {
  this.authCode = code;
  this.authBody = body;
});

When(prefix + 'the public readiness report is produced', { timeout: 115000 }, function () {
  if (!binary) {
    buildDir = fs.mkdtempSync(path.join(os.tmpdir(), 'readiness-auth-build-'));
    binary = path.join(buildDir, 'report');
    run('go', ['build', '-o', binary, path.join(__dirname, 'readiness-claude-auth-probe-errors__driver/main.go')], { cwd: path.join(root, 'cli') });
  }
  this.authReport = JSON.parse(run(binary, [String(this.authCode)], { cwd: root, input: this.authBody }));
});

Then(prefix + 'the models report satisfies:', function (expected) {
  observe(this.authReport, JSON.parse(expected));
});

AfterAll(function () {
  if (buildDir) fs.rmSync(buildDir, { recursive: true, force: true });
});
