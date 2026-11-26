'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

function printResult(result) {
  return `exit ${result.status}; stdout: ${result.stdout}; stderr: ${result.stderr}`;
}

function expectEmpty(result, option) {
  assert.deepEqual([result.status, JSON.parse(result.stdout)], [2, {
    schema_version: 1, kind: 'usage', checkout: null, data: null,
    error: { class: 'intent', reason: 'invalid_argument', paths: [],
      detail: `kogen intent usage: ${option} must not be empty` },
  }], `expected an empty-value usage error for ${option}; ${printResult(result)}`);
}

function expectPhases(result, phases) {
  const report = JSON.parse(result.stdout);
  assert.deepEqual([result.status, report.kind, report.error, report.data?.requests?.map(row => row.phase)],
    [0, 'usage', null, phases], `expected usage request phases ${JSON.stringify(phases)}; ${printResult(result)}`);
}

if (require.main === module) {
  // Observer-only controls: feed result samples to the exact assertions used by the steps.
  const bad = process.argv[2] === 'bad';
  const sample = (status, report) => ({ status, stdout: JSON.stringify(report) + '\n', stderr: '' });
  const reply = detail => sample(2, { checkout: null, data: null, error: {
    class: 'intent', detail, paths: [], reason: 'invalid_argument',
  }, kind: 'usage', schema_version: 1 });
  const usage = phases => sample(0, { kind: 'usage', error: null,
    data: { requests: phases.map(phase => ({ phase })) } });
  let rejected = 0;
  for (const [name, observe] of [
    ['phase error', () => expectEmpty(bad ? usage([]) : reply('kogen intent usage: --phase must not be empty'), '--phase')],
    ['model error', () => expectEmpty(reply(bad ? 'kogen intent usage: --phase must not be empty' : 'kogen intent usage: --model must not be empty'), '--model')],
    ['phase selection', () => expectPhases(usage(bad ? ['review', 'Review'] : ['review']), ['review'])],
  ]) {
    try {
      observe();
      console.log(`${name}: accepted`);
    } catch (err) {
      if (!(err instanceof assert.AssertionError)) throw err;
      console.log(`${name}: rejected`);
      rejected++;
    }
  }
  process.exitCode = rejected === 0 ? 0 : 1;
} else {
  const { Given, When, Then, AfterAll } = require('@cucumber/cucumber');
  const P = 'usage-empty-filter-values-refuse: ';
  let scratch;
  let binary;

  function run(file, args, options) {
    const result = spawnSync(file, args, { encoding: 'utf8', ...options });
    if (result.error) throw result.error;
    assert.notEqual(result.status, null, `${file} terminated by ${result.signal}`);
    return result;
  }

  Given(P + 'a project with retained requests in phases {string}', { timeout: 110000 }, function (phases) {
    if (!binary) {
      scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'usage-empty-filter-'));
      const target = path.join(scratch, 'kogen');
      const build = run('go', ['build', '-o', target, '.'], {
        cwd: path.resolve(__dirname, '../../cli'), timeout: 95000,
      });
      assert.equal(build.status, 0, `go build in cli failed: ${printResult(build)}`);
      binary = target;
    }
    this.project = fs.mkdtempSync(path.join(scratch, 'project-'));
    const git = run('git', ['init', '-q', this.project], { timeout: 5000 });
    assert.equal(git.status, 0, `git init failed: ${printResult(git)}`);
    const dir = path.join(this.project, '.kogen/local/runs/11111111');
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(this.project, '.kogen/project.yaml'), 'version: 1\n');
    fs.writeFileSync(path.join(dir, 'result.json'), '{"slug":"fixture"}\n');
    const rows = phases.split(',').map(phase => JSON.stringify({
      event: 'request', phase, role: 'review', model: 'configured', at: '2026-10-21T00:00:00Z',
      usage: { input: 100, cached: 20, output: 10, reasoning: 2 },
    }));
    fs.writeFileSync(path.join(dir, 'log.jsonl'), rows.join('\n') + '\n');
  });

  When(P + 'kogen intent usage runs with these extra arguments', { timeout: 15000 }, function (argvJSON) {
    this.result = run(binary, ['intent', 'usage', '--project', this.project, '--json', ...JSON.parse(argvJSON)], { timeout: 10000 });
  });

  Then(P + 'the usage error names {string} as empty', function (option) {
    expectEmpty(this.result, option);
  });

  Then(P + 'the report lists exactly these request phases in order {string}', function (phases) {
    expectPhases(this.result, phases.split(','));
  });

  AfterAll(function () {
    if (scratch) fs.rmSync(scratch, { recursive: true, force: true });
  });
}
