'use strict';
const path = require('node:path');
const { spawnSync } = require('node:child_process');

function observe(name, status, output) {
  const events = output.split('\n').filter(Boolean).map(line => { try { return JSON.parse(line); } catch { return {}; } });
  const terminal = events.filter(e => e.Package === 'kogen/build' && e.Test === name && ['pass', 'fail', 'skip'].includes(e.Action));
  if (status !== 0 || terminal.length !== 1 || terminal[0].Action !== 'pass') {
    throw new Error(`${name}: go test -json ./build: absent, skipped, failed or zero runs`);
  }
}

if (require.main === module && process.argv[2] === '--control') {
  const name = 'TestContextExternalFirstPrompt';
  const action = process.argv[3] === 'good' ? 'pass' : 'skip';
  try { observe(name, 0, JSON.stringify({ Package: 'kogen/build', Test: name, Action: action })); }
  catch (error) { process.stderr.write(error.message + '\n'); process.exitCode = 1; }
} else {
  const { When, Then } = require('@cucumber/cucumber');
  When('I run the context external regression {string}', { timeout: 300000 }, function (name) {
    this.contextExternalRun = spawnSync('go', ['test', '-json', './build', '-run', `^${name}$`, '-count=1'], {
      cwd: path.resolve(__dirname, '../../cli'), encoding: 'utf8', timeout: 280000,
    });
  });
  Then('the context external regression {string} ran and passed', function (name) {
    const result = this.contextExternalRun;
    if (!result) throw new Error(`${name}: go test -json ./build: command was not run`);
    try { observe(name, result.status, result.stdout || ''); }
    catch (error) { throw new Error(error.message + '\n' + (result.stdout || '') + (result.stderr || '') + (result.error ? String(result.error) : '')); }
  });
}
