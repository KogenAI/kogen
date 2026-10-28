'use strict';
// K22: effort validation when .kogen/project.yaml is read. Builds the real `kogen` binary from cli/ once, then runs
// `kogen intent build abc` in scratch Git projects (config is loaded before the Intent is looked up). No network,
// no provider and no real credentials: HOME is an empty scratch directory.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { Given, When, Then, After, AfterAll } = require('@cucumber/cucumber');

const ROOT = path.resolve(__dirname, '../..');
let suiteDir;
let binary;
const scratch = [];

function kogenBinary() {
  if (binary) return binary;
  suiteDir = fs.mkdtempSync(path.join(os.tmpdir(), 'k22-bin-'));
  binary = path.join(suiteDir, 'kogen');
  const r = spawnSync('go', ['build', '-o', binary, '.'], { cwd: path.join(ROOT, 'cli'), encoding: 'utf8', timeout: 280000 });
  assert.equal(r.status, 0, 'go build failed: ' + r.stdout + r.stderr);
  return binary;
}

function git(dir, args) {
  const r = spawnSync('git', ['-c', 'user.name=k22', '-c', 'user.email=k22@example.invalid', ...args], { cwd: dir, encoding: 'utf8' });
  assert.equal(r.status, 0, 'git ' + args.join(' ') + ': ' + r.stdout + r.stderr);
}

function newProject(world, yaml) {
  const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'k22-proj-')));
  scratch.push(dir);
  git(dir, ['init', '-q']);
  fs.mkdirSync(path.join(dir, '.kogen'));
  fs.writeFileSync(path.join(dir, '.kogen', 'project.yaml'), yaml);
  git(dir, ['add', '-A']);
  git(dir, ['commit', '-q', '-m', 'configuration']);
  world.dir = dir;
  return dir;
}

function runBuild(dir) {
  const r = spawnSync(kogenBinary(), ['intent', 'build', 'abc', '--project', dir], {
    cwd: dir, encoding: 'utf8', timeout: 60000,
    env: { PATH: process.env.PATH, HOME: dir, XDG_CONFIG_HOME: path.join(dir, 'xdg') },
  });
  return { code: r.status, out: (r.stdout || '') + (r.stderr || '') };
}

Given('a scratch Kogen project whose project.yaml is:', function (yaml) { newProject(this, yaml + '\n'); });

Given("a scratch Kogen project with the repository's own project configuration", function () {
  newProject(this, fs.readFileSync(path.join(ROOT, '.kogen', 'project.yaml'), 'utf8'));
});

When('I run kogen intent build for an Intent named abc', { timeout: 300000 }, function () { this.result = runBuild(this.dir); });

When('I load every models or shape_workers example of the configuration guide', { timeout: 300000 }, function () {
  const text = fs.readFileSync(path.join(ROOT, 'docs', 'configuration.md'), 'utf8');
  const blocks = [...text.matchAll(/```ya?ml\n([\s\S]*?)```/g)].map(m => m[1]).filter(b => /^(models|shape_workers):/m.test(b));
  assert.ok(blocks.length >= 3, 'expected several configuration examples, found ' + blocks.length);
  const outs = [];
  for (const b of blocks) {
    const yaml = /^version:/m.test(b) ? b : 'version: 1\n' + b;
    outs.push(runBuild(newProject(this, yaml)).out);
  }
  this.result = { code: null, out: outs.join('\n----\n') };
});

Then('the command exits with status {int}', function (code) { assert.equal(this.result.code, code, this.result.out); });
Then('the output contains {string}', function (s) { assert.ok(this.result.out.includes(s), `missing ${JSON.stringify(s)} in: ${this.result.out}`); });
Then('the output does not contain {string}', function (s) { assert.ok(!this.result.out.includes(s), `unexpected ${JSON.stringify(s)} in: ${this.result.out}`); });
Then('the output reports no problem about an effort', function () {
  const bad = this.result.out.split('\n').filter(l => /line \d+:.*effort/.test(l));
  assert.deepEqual(bad, [], bad.join('\n'));
});
Then('the project has no file named {string}', function (name) { assert.equal(fs.existsSync(path.join(this.dir, name)), false, name + ' exists'); });

After(function () { while (scratch.length) fs.rmSync(scratch.pop(), { recursive: true, force: true }); });
AfterAll(function () { if (suiteDir) fs.rmSync(suiteDir, { recursive: true, force: true }); });
