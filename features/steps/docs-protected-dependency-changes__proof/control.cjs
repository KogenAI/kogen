const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const root = path.resolve(__dirname, '../../..');
const intentDir = path.join(root, '.kogen/intents/docs-protected-dependency-changes');
const controls = require(path.join(intentDir, 'controls.json'));
const mutant = controls.wrong.find(control => control.name === 'The new required check is enabled before verification');
const mode = process.argv[2];
assert.ok(mode === 'good' || mode === 'bad');
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-docs-dependency-control-'));
try {
  const files = { ...controls.correct.files, ...(mode === 'bad' ? mutant.files : {}) };
  for (const [file, content] of Object.entries(files)) {
    const dest = path.join(dir, file);
    fs.mkdirSync(path.dirname(dest), { recursive: true });
    fs.writeFileSync(dest, content);
  }
  const { KOGEN_NODE, KOGEN_CUCUMBER } = process.env;
  const result = spawnSync(KOGEN_NODE, [path.join(KOGEN_CUCUMBER, '@cucumber/cucumber/bin/cucumber.js'),
    '--strict', '--require', path.join(root, 'features/steps/docs-protected-dependency-changes__copy.js'),
    '--format', 'summary:summary.txt', '--format', 'message:report.ndjson', '--name', `^${mutant.scenario}$`,
    path.join(intentDir, 'acceptance.feature')], {
    cwd: dir, env: { ...process.env, NODE_PATH: KOGEN_CUCUMBER }, encoding: 'utf8', timeout: 15000,
  });
  assert.ifError(result.error);
  const messages = fs.readFileSync(path.join(dir, 'report.ndjson'), 'utf8').trim().split('\n').map(line => JSON.parse(line));
  const scenarios = messages.flatMap(m => m.testCaseFinished ? [m.testCaseFinished] : []);
  const steps = messages.flatMap(m => m.testStepFinished ? [m.testStepFinished.testStepResult] : []);
  assert.equal(scenarios.length, 1, `${mutant.scenario}: expected one completed Cucumber scenario`);
  assert.deepEqual(steps.map(step => step.status), mode === 'good' ? ['PASSED', 'PASSED'] : ['PASSED', 'FAILED'],
    `${mutant.scenario}: unexpected Cucumber results\n${result.stdout}${result.stderr}`);
  assert.equal(result.status, mode === 'good' ? 0 : 1, `${mutant.scenario}: unexpected Cucumber exit code`);
  if (mode === 'bad') {
    assert.match(steps[1].message, /missing or out-of-order guidance for new required check/);
    console.log('Rejected enablement before verification');
    process.exitCode = 1;
  } else {
    console.log('Accepted review and verification before enablement');
  }
} finally {
  fs.rmSync(dir, { recursive: true, force: true });
}
