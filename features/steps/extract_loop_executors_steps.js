const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const ROOT = path.resolve(__dirname, '../..');

function goEvidence(result, names) {
  assert.equal(result.timed, false, 'Go watchdog expired');
  assert.equal(result.code, 0, result.out);
  const events = result.out.split('\n').flatMap(line => {
    try { return [JSON.parse(line)]; } catch { return []; }
  });
  assert.ok(events.some(e => !e.Test && e.Action === 'pass'), 'no package passed');
  assert.ok(!events.some(e => ['fail', 'skip'].includes(e.Action)), 'failed or skipped Go result');
  for (const name of names) {
    assert.equal(events.filter(e => e.Test === name && e.Action === 'run').length, 1, `${name} must run once`);
    assert.equal(events.filter(e => e.Test === name && e.Action === 'pass').length, 1, `${name} must pass once`);
  }
}

function scenarioEvidence(result, report, names) {
  assert.equal(result.timed, false, 'scenario watchdog expired');
  assert.equal(result.code, 0, result.out);
  const features = JSON.parse(report);
  assert.ok(Array.isArray(features), 'not a Cucumber JSON report');
  const scenarios = features.flatMap(f => f.elements || []).filter(e => e.type === 'scenario');
  assert.deepEqual(scenarios.map(s => s.name).sort(), [...names].sort(), 'each expected scenario must execute exactly once');
  for (const scenario of scenarios) {
    assert.ok(scenario.steps && scenario.steps.length, `${scenario.name}: no steps`);
    for (const step of [...(scenario.before || []), ...scenario.steps, ...(scenario.after || [])]) {
      assert.equal(step.result && step.result.status, 'passed', `${scenario.name}: unpassed step or hook`);
    }
  }
}

function controls(mode) {
  const result = { code: 0, timed: false, out: '' };
  const events = [
    { Action: 'run', Package: 'fixture', Test: 'TestBoundary' },
    { Action: 'pass', Package: 'fixture', Test: 'TestBoundary' },
    { Action: 'pass', Package: 'fixture' },
  ];
  const encode = xs => xs.map(x => JSON.stringify(x)).join('\n') + '\n';
  const scenario = { type: 'scenario', name: 'Boundary', steps: [{ result: { status: 'passed' } }], after: [{ result: { status: 'passed' } }] };
  const report = elements => JSON.stringify([{ elements }]);
  goEvidence({ ...result, out: encode(events) }, ['TestBoundary']);
  scenarioEvidence(result, report([scenario]), ['Boundary']);
  if (mode === 'good') {
    process.stdout.write('loop observers accept good evidence\n');
    return;
  }
  assert.equal(mode, 'bad');
  for (const bad of [events.slice(1), events.slice(0, 1).concat(events.slice(2)), [...events, events[1]], events.map(e => e.Test && e.Action === 'pass' ? { ...e, Action: 'skip' } : e)]) {
    assert.throws(() => goEvidence({ ...result, out: encode(bad) }, ['TestBoundary']));
  }
  for (const elements of [[], [scenario, scenario], [{ ...scenario, steps: [] }], [{ ...scenario, steps: [{ result: { status: 'skipped' } }] }], [{ ...scenario, after: [{ result: { status: 'failed' } }] }]]) {
    assert.throws(() => scenarioEvidence(result, report(elements), ['Boundary']));
  }
  assert.throws(() => scenarioEvidence({ ...result, code: 1 }, report([scenario]), ['Boundary']));
  process.stdout.write('loop observers reject bad evidence\n');
  process.exitCode = 19;
}

if (require.main === module) {
  controls(process.argv[2]);
} else {
  const { When, Then } = require('@cucumber/cucumber');
  const H = require('./go_driver_support');

  When('I execute the focused loop boundary tests:', { timeout: 600000 }, async function (table) {
    this.loopGo = [];
    const groups = new Map();
    for (const row of table.hashes()) {
      const key = `${row.module}\0${row.package}`;
      if (!groups.has(key)) groups.set(key, { module: row.module, package: row.package, names: [] });
      groups.get(key).names.push(row.test);
    }
    for (const group of groups.values()) {
      assert.ok(group.names.every(n => /^Test[A-Za-z0-9_]+$/.test(n)), 'invalid test name');
      const result = await H.run('go', ['test', '-count=1', '-json', '-run', `^(${group.names.join('|')})$`, group.package], {
        cwd: path.join(ROOT, group.module), timeout: 120000,
        env: { ...process.env, GOWORK: 'off', GOPROXY: 'off', GOTOOLCHAIN: 'local' },
      });
      this.loopGo.push({ result, names: group.names });
    }
  });
  Then('each focused loop boundary test executes and passes once', function () {
    assert.ok(this.loopGo && this.loopGo.length, 'no requested tests');
    for (const group of this.loopGo) goEvidence(group.result, group.names);
  });

  When('I execute the installed loop specifications tagged {string} in:', { timeout: 600000 }, async function (tags, table) {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-loop-report-'));
    try {
      const report = path.join(dir, 'report.json');
      const files = table.raw().map(row => path.resolve(ROOT, row[0]));
      const result = await H.run(process.execPath, ['node_modules/@cucumber/cucumber/bin/cucumber.js', '--strict', '--tags', `not @live and (${tags})`, '--require', 'steps/*.js', '--require', 'support/*.js', '--format', `json:${report}`, ...files], {
        cwd: path.join(ROOT, 'test/acceptance'), timeout: 540000,
      });
      this.loopScenarios = { result, report: fs.existsSync(report) ? fs.readFileSync(report, 'utf8') : '[]' };
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });
  Then('exactly these installed loop scenarios execute with every step passing:', function (table) {
    assert.ok(this.loopScenarios, 'no installed run');
    scenarioEvidence(this.loopScenarios.result, this.loopScenarios.report, table.raw().map(row => row[0]));
  });

  When('I inspect the prepared generic loop pin', function () {
    const root = path.join(ROOT, 'cli/third_party/kogen-loop');
    const files = [];
    function walk(dir) {
      for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
        const file = path.join(dir, entry.name);
        if (entry.isDirectory()) walk(file);
        else { assert.ok(entry.isFile(), `not a regular file: ${file}`); files.push(path.relative(root, file).split(path.sep).join('/')); }
      }
    }
    walk(root);
    files.sort();
    const sha = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
    const digest = sha(files.map(file => file + '\0' + sha(fs.readFileSync(path.join(root, file))) + '\n').join(''));
    this.loopPin = { ...JSON.parse(fs.readFileSync(path.join(ROOT, 'cli/loop-pin.json'), 'utf8')), actual_digest: digest, actual_files: files.length };
  });
  Then('the prepared loop pin has exactly this identity:', function (doc) {
    assert.deepEqual(this.loopPin, JSON.parse(doc));
  });
}
