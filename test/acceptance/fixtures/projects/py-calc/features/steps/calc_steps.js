const { Given, When, Then } = require('@cucumber/cucumber');
const { spawnSync } = require('node:child_process');

Given('the calculator accepts {int} and {int}', function (left, right) {
  this.arguments = [left, right];
});

When('I add the calculator arguments', function () {
  this.result = spawnSync('python3', ['-c', `from calc import add; print(add(${this.arguments[0]}, ${this.arguments[1]}))`], { encoding: 'utf8' });
});

Then('the calculator result is {int}', function (expected) {
  if (this.result.status !== 0 || this.result.stdout.trim() !== String(expected)) throw new Error('calculator result did not match');
});
