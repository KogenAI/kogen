'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { When, Then, After } = require('@cucumber/cucumber');
const { check } = require('./cli_green_report');
const root = path.resolve(__dirname, '../..');
function run(args, cwd) {
  return new Promise((resolve, reject) => {
    const p = spawn(process.execPath, args, { cwd, env: process.env, stdio: ['ignore', 'pipe', 'pipe'] });
    let output = '';
    p.stdout.on('data', b => { output += b; });
    p.stderr.on('data', b => { output += b; });
    p.on('error', reject);
    p.on('close', code => resolve({ code, output }));
  });
}
function rows(file) {
  const result = [];
  for (const feature of JSON.parse(fs.readFileSync(file, 'utf8'))) {
    for (const scenario of feature.elements || []) {
      if (scenario.type !== 'scenario') continue;
      const statuses = scenario.steps.map(s => s.result?.status);
      const status = statuses.includes('failed') ? 'failed' : statuses.length && statuses.every(s => s === 'passed') ? 'passed' : 'incomplete';
      const uri = feature.uri.replace(/^.*spec\/features\//, '');
      result.push({ key: `${uri}:${scenario.line}`, status });
    }
  }
  return result;
}
When('I run the CLI repair selections three times and the non-live suite once:', { timeout: 1200000 }, async function (table) {
  this.cliGreenDir = fs.mkdtempSync(path.join(os.tmpdir(), 'k-cli-green-'));
  const selected = table.hashes().map(row => {
    const file = path.join(root, 'spec/features', row.file);
    const lines = fs.readFileSync(file, 'utf8').split('\n');
    const matches = lines.flatMap((line, i) => row.command ? (line.includes(`| ${row.command}`) ? [i + 1] : []) : (line.trim() === `Scenario: ${row.name}` ? [i + 1] : []));
    assert.equal(matches.length, 1, `selection ${row.file}:${row.original_line} (${row.name || row.command}) must resolve once`);
    return { arg: `../../spec/features/${row.file}:${matches[0]}`, key: `${row.file}:${matches[0]}` };
  });
  const cwd = path.join(root, 'test/acceptance');
  const cucumber = path.join(cwd, 'node_modules/@cucumber/cucumber/bin/cucumber.js');
  const common = [cucumber, '--parallel', '8', '--strict', '--tags', 'not @live', '--require', 'steps/*.js', '--require', 'support/*.js'];
  this.cliGreenFocused = [];
  for (let i = 1; i <= 3; i++) {
    const report = path.join(this.cliGreenDir, `focused-${i}.json`);
    const result = await run([...common, '--format', `json:${report}`, ...selected.map(s => s.arg)], cwd);
    this.attach(`focused run ${i}\n${result.output}`, 'text/plain');
    assert.equal(result.code, 0, `focused run ${i}: ${result.output}`);
    const actual = rows(report);
    check(actual, selected.length);
    assert.deepEqual(actual.map(r => r.key).sort(), selected.map(r => r.key).sort(), `focused run ${i} selected inventory`);
    this.cliGreenFocused.push(actual);
  }
  const report = path.join(this.cliGreenDir, 'full.json');
  const result = await run([...common, '--format', `json:${report}`, '../../spec/features'], cwd);
  this.attach(`complete non-live run\n${result.output}`, 'text/plain');
  this.cliGreenFull = rows(report);
  this.cliGreenFullCode = result.code;
});
Then('all {int} selected scenarios passed on each run and the {int} scenario suite has no regression outside:', function (selectedCount, total, table) {
  assert.equal(this.cliGreenFocused.length, 3);
  for (const report of this.cliGreenFocused) check(report, selectedCount);
  const allowed = table.raw().map(([key]) => key);
  check(this.cliGreenFull, total, allowed);
  const failed = this.cliGreenFull.filter(r => r.status === 'failed');
  assert.equal(this.cliGreenFullCode, failed.length ? 1 : 0, 'full suite process outcome disagrees with scenario report');
  this.attach(JSON.stringify({ total: this.cliGreenFull.length, passed: this.cliGreenFull.length - failed.length, failed: failed.length, failures: failed }, null, 2), 'application/json');
});
After(function () {
  if (this.cliGreenDir) fs.rmSync(this.cliGreenDir, { recursive: true, force: true });
});
