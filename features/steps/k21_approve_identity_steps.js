'use strict';
// K21: approve and Build without a Git identity, through the installed `kogen` command, a scripted local provider and a
// local Git project with an empty HOME, empty XDG and no repository identity.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { Given, When, Then, After, AfterAll } = require('@cucumber/cucumber');
const H = require('./go_driver_support.js');

let sharedSuite;
const suiteOnce = () => sharedSuite || (sharedSuite = H.setupSuite());

async function noIdentityProject(world) {
  const suite = await suiteOnce();
  const c = await H.project(suite, [], { stagedIntent: false });
  world.c = c;
  const xdg = path.join(c.root, 'xdg');
  fs.mkdirSync(xdg, { recursive: true });
  world.env = { XDG_CONFIG_HOME: xdg };
  await H.gitBang(c, ['config', '--unset', 'user.name']);
  await H.gitBang(c, ['config', '--unset', 'user.email']);
  world.before = { requests: c.server.providerRequests().length, runs: H.runDirs(c).length, head: await H.git(c, ['rev-parse', 'HEAD']) };
}

Given('a Kogen project with an unapproved Intent and no Git identity anywhere', { timeout: 600000 }, async function () {
  await noIdentityProject(this);
  fs.rmSync(H.approvalPath(this.c.repo, 'fixture'), { force: true });
});

Given('an approved Kogen project with no Git identity anywhere', { timeout: 600000 }, async function () {
  await noIdentityProject(this);
  assert.ok(fs.existsSync(H.approvalPath(this.c.repo, 'fixture')), 'fixture should be approved');
});

async function approveWith(world, extra) {
  const hash = await H.baselineHash(world.c, 'fixture');
  world.result = await H.runKogen(world.c, ['intent', 'approve', 'fixture', hash, ...extra], { env: world.env });
}
When('I run kogen intent approve for the Intent with its current hash', { timeout: 300000 }, async function () { await approveWith(this, []); });
When('I run kogen intent approve for the Intent with its current hash and --by {string}', { timeout: 300000 }, async function (by) { await approveWith(this, ['--by', by]); });
When('I run kogen intent build for the Intent', { timeout: 300000 }, async function () {
  this.result = await H.runKogen(this.c, ['intent', 'build', 'fixture'], { env: this.env });
});

Then('the command fails with a nonzero exit', function () { assert.notEqual(this.result.code, 0, this.result.out); });
Then('the command succeeds', function () { assert.equal(this.result.code, 0, this.result.out); });
Then('the output names {string}', function (text) { assert.ok(this.result.out.includes(text), `missing ${text} in: ${this.result.out}`); });
Then('the Intent is not approved', function () { assert.equal(fs.existsSync(H.approvalPath(this.c.repo, 'fixture')), false); });
Then('the Intent is approved by {string}', function (by) {
  const file = H.approvalPath(this.c.repo, 'fixture');
  assert.ok(fs.existsSync(file), 'approval marker missing');
  assert.ok(fs.readFileSync(file, 'utf8').includes(by), 'approval record does not name ' + by);
});
Then('no model request was sent and no Build run or commit was created', async function () {
  const c = this.c;
  assert.equal(c.server.providerRequests().length, this.before.requests, 'a provider request was sent');
  assert.equal(H.runDirs(c).length, this.before.runs, 'a Build run was created');
  assert.equal(await H.git(c, ['rev-parse', 'HEAD']), this.before.head, 'a commit was created');
});

After(async function () { if (this.c) { await H.cleanupCase(this.c); this.c = null; } });
AfterAll(async () => { if (sharedSuite) { const s = await sharedSuite; sharedSuite = null; H.cleanupSuite(s); } });
