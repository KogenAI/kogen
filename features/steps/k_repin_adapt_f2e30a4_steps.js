'use strict';
// Acceptance steps of k-repin-adapt-f2e30a4: Kogen's own checks with kogen-loop f2e30a4, whose
// shell tool waits up to 45 seconds for a new command before yielding a running handle.
// `node features/steps/k_repin_adapt_f2e30a4_steps.js good|bad` runs the observer controls of
// the scenario-summary assertion without Cucumber.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawn } = require('node:child_process');

const root = path.resolve(__dirname, '../..');
const LIMIT_MS = 105000;

function tail(text, n = 4000) {
  return text.length > n ? '[...]' + text.slice(-n) : text;
}

function outcome(result) {
  return `exit ${result.status}${result.signal ? `, signal ${result.signal}` : ''}${result.timedOut ? `, timed out after ${LIMIT_MS} ms` : result.error ? `, ${result.error.message}` : ''}`;
}

// run starts a command in its own process group and resolves with its exit and output; a
// command still running after LIMIT_MS is stopped with its group and reported as timed out.
function run(program, args, options) {
  return new Promise(resolve => {
    const result = { status: null, signal: null, stdout: '', stderr: '', error: null, timedOut: false };
    let child;
    try {
      child = spawn(program, args, { ...options, detached: true, stdio: ['ignore', 'pipe', 'pipe'] });
    } catch (error) {
      resolve({ ...result, error });
      return;
    }
    child.stdout.setEncoding('utf8').on('data', chunk => { result.stdout += chunk; });
    child.stderr.setEncoding('utf8').on('data', chunk => { result.stderr += chunk; });
    const timer = setTimeout(() => {
      result.timedOut = true;
      try { process.kill(-child.pid, 'SIGKILL'); } catch { /* already gone */ }
    }, LIMIT_MS);
    child.on('error', error => { result.error = error; });
    child.on('close', (status, signal) => {
      clearTimeout(timer);
      resolve({ ...result, status, signal });
    });
  });
}

// scenarioProblem is why the Cucumber run of `command` did not run exactly one scenario,
// `name`, that passed, or null when it did.
function scenarioProblem(name, command, result) {
  const output = String(result.stdout || '') + String(result.stderr || '');
  let state = null;
  if (result.error || result.timedOut || result.status !== 0) state = 'did not pass';
  else if (!/(^|\n)1 scenario \(1 passed\)\n/.test(output)) state = 'did not run as exactly one passing scenario';
  if (state === null) return null;
  return `building scenario "${name}" ${state}; command: ${command}; ${outcome(result)}\n${tail(output)}`;
}

function controls(mode) {
  const scenario = 'Default shell calls remain unbounded';
  const runCommand = '(cd test/acceptance && npx cucumber-js ...)';
  const good = [
    scenarioProblem(scenario, runCommand, { status: 0, stdout: '.....\n\n1 scenario (1 passed)\n13 steps (13 passed)\n' }),
  ];
  const bad = [
    scenarioProblem(scenario, runCommand, { status: 0, stdout: '0 scenarios\n0 steps\n' }),
    scenarioProblem(scenario, runCommand, { status: 1, stdout: '1 scenario (1 failed)\n13 steps (10 passed, 2 skipped, 1 failed)\n' }),
    scenarioProblem(scenario, runCommand, { status: 0, stdout: '2 scenarios (2 passed)\n' }),
    scenarioProblem(scenario, runCommand, { status: null, timedOut: true, stdout: '1 scenario (1 passed)\n' }),
  ];
  const accepted = mode === 'good' ? good.every(p => p === null) : !bad.every(p => p !== null);
  console.log(accepted ? 'accepted' : 'rejected');
  if (!accepted) process.exitCode = 1;
}

function walk(dir, keep, out = []) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      if (!['node_modules', '.git', 'third_party'].includes(entry.name)) walk(full, keep, out);
    } else if (entry.isFile() && keep(full)) out.push(full);
  }
  return out;
}

// kogenTests are Kogen's own test files: Go tests and test data in cli/ (not the vendored
// loop), the scenario suite's steps and support, the specification's features and the
// Intent steps other than this file.
function kogenTests() {
  const self = path.resolve(__filename);
  return [
    ...walk(path.join(root, 'cli'), f => f.endsWith('_test.go') || f.split(path.sep).includes('testdata')),
    ...['test/acceptance/steps', 'test/acceptance/support', 'spec/features', 'features/steps']
      .flatMap(dir => walk(path.join(root, dir), f => path.resolve(f) !== self)),
  ];
}

function paragraph(file, id) {
  const lines = fs.readFileSync(path.join(root, file), 'utf8').split('\n');
  const start = lines.findIndex(line => line.startsWith(`**${id} `));
  assert.ok(start >= 0, `${file} has no paragraph starting "**${id} "`);
  const end = lines.findIndex((line, i) => i > start && line.trim() === '');
  return lines.slice(start, end < 0 ? lines.length : end).join('\n');
}

function scenarioBlock(name) {
  const file = 'spec/features/04-building.feature';
  const lines = fs.readFileSync(path.join(root, file), 'utf8').split('\n').map(line => line.trim());
  const start = lines.indexOf(`Scenario: ${name}`);
  assert.ok(start >= 0, `${file} has no scenario "${name}"`);
  let end = start + 1;
  while (end < lines.length && !/^(Scenario|Scenario Outline|Rule|Examples):/.test(lines[end]) && !lines[end].startsWith('@')) end++;
  return { file, tags: lines[start - 1], steps: lines.slice(start + 1, end).filter(line => line !== '' && !line.startsWith('#')) };
}

if (require.main === module) {
  controls(process.argv[2]);
} else {
  const { When, Then } = require('@cucumber/cucumber');

  When('f2e30a4 adaptation runs the building scenario {string}', { timeout: 115000 }, async function (name) {
    const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const args = ['cucumber-js', '--strict', '--tags', 'not @live', '--require', 'steps/*.js', '--require', 'support/*.js',
      '--name', `^${escaped}$`, '../../spec/features/04-building.feature'];
    const command = `(cd test/acceptance && npx ${args.map(a => (/^[\w./@-]+$/.test(a) ? a : `'${a}'`)).join(' ')})`;
    const env = { ...process.env };
    delete env.NODE_PATH;
    const result = await run('npx', args, { cwd: path.join(root, 'test/acceptance'), env });
    this.f2e30a4Scenario = { name, command, result };
  });

  Then('f2e30a4 adaptation observed that building scenario run once and pass', function () {
    assert.ok(this.f2e30a4Scenario, 'no building scenario was run');
    const { name, command, result } = this.f2e30a4Scenario;
    const problem = scenarioProblem(name, command, result);
    assert.ok(problem === null, problem);
  });

  Then('f2e30a4 adaptation finds that building scenario tagged {string} with these steps:', function (tags, table) {
    assert.ok(this.f2e30a4Scenario, 'no building scenario was run');
    const { file, tags: actualTags, steps } = scenarioBlock(this.f2e30a4Scenario.name);
    assert.equal(actualTags, tags, `${file}: scenario "${this.f2e30a4Scenario.name}" tags`);
    const wanted = table.hashes().map(row => row.step);
    assert.deepEqual(steps, wanted, `${file}: scenario "${this.f2e30a4Scenario.name}" does not prove what it must`);
  });

  Then('f2e30a4 adaptation finds {string} contains these texts:', function (file, table) {
    const text = fs.readFileSync(path.join(root, file), 'utf8');
    const missing = table.hashes().map(row => row.text).filter(wanted => !text.includes(wanted));
    assert.ok(missing.length === 0, `${file} lacks:\n${missing.join('\n')}`);
  });

  Then('f2e30a4 adaptation finds the {string} paragraph of {string} contains {string}', function (id, file, text) {
    assert.ok(paragraph(file, id).includes(text), `the ${id} paragraph of ${file} does not contain "${text}"`);
  });

  Then('f2e30a4 adaptation finds the {string} paragraph of {string} does not contain {string}', function (id, file, text) {
    assert.ok(!paragraph(file, id).includes(text), `the ${id} paragraph of ${file} still contains "${text}"`);
  });

  Then("f2e30a4 adaptation finds none of these texts in Kogen's tests outside the vendored loop:", function (table) {
    const texts = table.hashes().map(row => row.text);
    const found = [];
    for (const file of kogenTests()) {
      fs.readFileSync(file, 'utf8').split('\n').forEach((line, i) => {
        for (const text of texts) if (line.includes(text)) found.push(`${path.relative(root, file)}:${i + 1} contains "${text}"`);
      });
    }
    assert.ok(found.length === 0, `Kogen's tests still describe the old one-second shell wait:\n${found.join('\n')}`);
  });
}
