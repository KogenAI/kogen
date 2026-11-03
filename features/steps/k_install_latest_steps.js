const path = require('node:path');
const { Given, When, Then } = require('@cucumber/cucumber');
const { runInstaller, checks } = require('./k_install_latest_fake.cjs');

const installer = path.resolve(__dirname, '../../packaging/install-kogen.sh');

Given('a fake github.com whose releases\\/latest redirects to the tag {string}', function (version) {
  this.fakeGithub = { mode: 'redirect', version };
});
Given('a fake github.com whose releases\\/latest answers HTTP {int}', function (status) {
  this.fakeGithub = { mode: 'status', status };
});
Given('a fake GitHub API whose Latest release is {string}', function (version) {
  this.fakeApi = { mode: 'tag', version };
});
Given('a fake GitHub API that answers HTTP {int} rate limit exceeded', function (status) {
  this.fakeApi = { mode: 'status', status };
});
When('I pipe install-kogen.sh to sh with no options through the fakes', { timeout: 120000 }, async function () {
  this.installRun = await runInstaller(installer, this.fakeGithub, this.fakeApi);
});
Then('the installer exits 0 and the installed kogen reports {string}', function (version) {
  checks.installed(this.installRun, version);
});
Then('the installer exits 1 and installs nothing', function () {
  checks.failed(this.installRun);
});
Then('the fake github.com was asked for releases\\/latest exactly once', function () {
  checks.latestAsked(this.installRun, 1);
});
Then('the fake GitHub API was asked {int} time(s)', function (n) {
  checks.apiAsked(this.installRun, n);
});
Then('the only downloads were the {string} archive for this platform and its SHA256SUMS, once each', function (version) {
  checks.downloads(this.installRun, version);
});
Then('nothing was downloaded', function () {
  checks.downloads(this.installRun, null);
});
Then('the installer output has these lines in this order:', function (text) {
  checks.linesInOrder(this.installRun, text.split('\n'));
});
