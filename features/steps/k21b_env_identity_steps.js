'use strict';
// K21b: Build start and `kogen doctor` accept a Git identity that comes only from GIT_AUTHOR_* / GIT_COMMITTER_*.
// Reuses the K21 steps for the no-identity project and the Build command; adds only the environment and doctor steps.
const assert = require('node:assert/strict');
const { Given, When, Then } = require('@cucumber/cucumber');
const H = require('./go_driver_support.js');

Given('the process environment sets the Git author and committer name and email', function () {
  Object.assign(this.env, {
    GIT_AUTHOR_NAME: 'Env Author', GIT_AUTHOR_EMAIL: 'env-author@example.invalid',
    GIT_COMMITTER_NAME: 'Env Committer', GIT_COMMITTER_EMAIL: 'env-committer@example.invalid',
  });
});

Given('the process environment sets only the Git author name and email', function () {
  Object.assign(this.env, { GIT_AUTHOR_NAME: 'Env Author', GIT_AUTHOR_EMAIL: 'env-author@example.invalid' });
});

When('I run kogen doctor with quick checks in the project', { timeout: 300000 }, async function () {
  this.result = await H.runKogen(this.c, ['doctor', '--quick'], { env: this.env });
});

const gitLine = out => out.split('\n').find(l => /^(ok|fail|skip) git - /.test(l));

Then('the doctor git line is ok', function () {
  const l = gitLine(this.result.out);
  assert.ok(l && l.startsWith('ok git - '), `git line: ${l} in ${this.result.out}`);
});
Then('the doctor git line is fail', function () {
  const l = gitLine(this.result.out);
  assert.ok(l && l.startsWith('fail git - '), `git line: ${l} in ${this.result.out}`);
});
Then('the output does not name {string}', function (text) {
  assert.ok(!this.result.out.includes(text), `unexpected ${text} in: ${this.result.out}`);
});
Then('the Build got past its start checks', function () {
  const c = this.c;
  const started = c.server.providerRequests().length > this.before.requests || H.runDirs(c).length > this.before.runs;
  assert.ok(started, 'Build neither sent a model request nor created a run: ' + this.result.out);
});
