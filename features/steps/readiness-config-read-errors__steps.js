'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { Given, When, Then, After, AfterAll } = require('@cucumber/cucumber');
const observe = require('./readiness-config-read-errors__driver/observe.cjs');
const root = path.resolve(__dirname, '../..');
const prefix = 'readiness-config-read-errors: ';
let buildDir;
let binary;

function run(command, args, cwd) {
  const r = spawnSync(command, args, { cwd, encoding: 'utf8', timeout: 100000, maxBuffer: 4 * 1024 * 1024 });
  assert.ifError(r.error);
  assert.equal(r.status, 0, `${command} ${args.join(' ')} failed: ${r.stdout}\n${r.stderr}`);
  return r.stdout;
}

Given(prefix + 'a project whose config path is {string}', function (kind) {
  this.configCase = fs.mkdtempSync(path.join(os.tmpdir(), 'readiness-config-'));
  this.project = path.join(this.configCase, 'project');
  this.home = path.join(this.configCase, 'home');
  fs.mkdirSync(path.join(this.project, '.kogen'), { recursive: true });
  fs.mkdirSync(this.home);
  this.configPath = '.kogen/project.yaml';
  const file = path.join(this.project, this.configPath);
  if (kind === 'directory') fs.mkdirSync(file);
  else if (kind !== 'missing') throw new Error(`unknown config fixture: ${kind}`);
});

Given(prefix + 'the config file contains:', function (text) {
  fs.writeFileSync(path.join(this.project, this.configPath), text + '\n');
});

When(prefix + 'the readiness report is produced', { timeout: 115000 }, function () {
  if (!binary) {
    buildDir = fs.mkdtempSync(path.join(os.tmpdir(), 'readiness-config-build-'));
    binary = path.join(buildDir, 'report');
    run('go', ['build', '-o', binary, path.join(__dirname, 'readiness-config-read-errors__driver/main.go')], path.join(root, 'cli'));
  }
  this.report = JSON.parse(run(binary, [this.project, this.home], root));
});

Then(prefix + 'the config report is:', function (expected) {
  observe.exact(this.report, JSON.parse(expected));
});

Then(prefix + 'the existing directory at {string} is reported as unreadable with a file repair instead of init', function (configPath) {
  observe.directory(this.report, configPath);
});

After(function () {
  if (this.configCase) fs.rmSync(this.configCase, { recursive: true, force: true });
});
AfterAll(function () {
  if (buildDir) fs.rmSync(buildDir, { recursive: true, force: true });
});
