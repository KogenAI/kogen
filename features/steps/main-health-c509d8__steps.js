'use strict';
// Runs a freshly built kogen binary for a usage error and compares the printed provider help page
// with chapter 09 and with the page the acceptance harness expects. No network, no model.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { Given, When, Then } = require('@cucumber/cucumber');

const ROOT = path.resolve(__dirname, '../..');
const LOGIN_LINE = '  login                    On an interactive terminal, ask which account to use and guide the sign-in\n';

let built;
function kogenBinary() {
  if (!built) {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'mh-bin-'));
    const out = path.join(dir, 'kogen');
    const r = spawnSync('go', ['build', '-o', out, '.'], { cwd: path.join(ROOT, 'cli'), encoding: 'utf8', timeout: 100000 });
    assert.equal(r.status, 0, 'go build of cli failed: ' + r.stdout + r.stderr);
    built = out;
  }
  return built;
}

function chapterNineProviderPage() {
  const text = fs.readFileSync(path.join(ROOT, 'spec/prose/09-cli-and-process.md'), 'utf8');
  const match = text.match(/`kogen provider`:\n```\n([\s\S]*?)\n```/);
  assert.ok(match, 'spec/prose/09-cli-and-process.md has no fenced page after "`kogen provider`:"');
  return match[1] + '\n';
}

function harnessProviderPage() {
  const file = 'test/acceptance/support/handlers.js';
  const text = fs.readFileSync(path.join(ROOT, file), 'utf8');
  const match = text.match(/^const providerHelp = `([^`]*)`;$/m);
  assert.ok(match, file + ' has no providerHelp template literal');
  return new Function('return `' + match[1] + '`')();
}

function restAfterBlankLine(world) {
  const separator = world.mhOut.match(/\r?\n\r?\n/);
  assert.ok(separator, 'stdout did not contain a blank line: ' + JSON.stringify(world.mhOut));
  return world.mhOut.slice(separator.index + separator[0].length);
}

Given('main-health-c509d8: the kogen binary is built from the cli folder', function () {
  kogenBinary();
});

When('main-health-c509d8: the caller runs {string}', function (command) {
  const words = command.split(' ');
  assert.equal(words[0], 'kogen', 'command must start with kogen: ' + command);
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'mh-home-'));
  const r = spawnSync(kogenBinary(), words.slice(1), { cwd: home, env: { PATH: process.env.PATH, HOME: home }, input: '', encoding: 'utf8', timeout: 60000 });
  this.mhStatus = r.status;
  this.mhOut = r.stdout;
});

Then('main-health-c509d8: the exit code is {int}', function (code) {
  assert.equal(this.mhStatus, code);
});

Then('main-health-c509d8: the first line of stdout is {string}', function (message) {
  assert.equal(this.mhOut.split('\n')[0], message);
});

Then('main-health-c509d8: the rest of stdout after a blank line is the provider page given in chapter 09', function () {
  assert.equal(restAfterBlankLine(this), chapterNineProviderPage());
});

Then('main-health-c509d8: the rest of stdout after a blank line is the provider page the acceptance harness expects', function () {
  assert.equal(restAfterBlankLine(this), harnessProviderPage());
});

Then('main-health-c509d8: the printed provider page carries the login line', function () {
  assert.ok(restAfterBlankLine(this).includes(LOGIN_LINE), 'printed provider page lacks the login line: ' + JSON.stringify(restAfterBlankLine(this)));
});
