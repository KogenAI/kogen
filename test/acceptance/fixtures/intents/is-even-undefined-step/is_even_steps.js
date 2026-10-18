const { Given, When, Then } = require('@cucumber/cucumber');
const { spawnSync } = require('node:child_process');

Given('the input is {word}', function (value) { this.inputValue = value; });
When('I check is_even', function () {
  this.python = spawnSync('python3', ['-c', `from calc import is_even; print(is_even(${this.inputValue}))`], { encoding: 'utf8' });
});
Then('result is {word}', function (expected) {
  if (this.python.status !== 0) throw new Error(this.python.stderr || 'python failed');
  if (this.python.stdout.trim() !== expected) throw new Error(`expected ${expected}, got ${this.python.stdout.trim()}`);
});
Then('a TypeError is raised', function () {
  if (this.python.status === 0 || !this.python.stderr.includes('TypeError')) throw new Error('expected TypeError');
});
