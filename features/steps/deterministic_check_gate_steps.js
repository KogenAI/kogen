const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');
const root = path.resolve(__dirname, '../..');
const feature = path.join(root, '.kogen/intents/deterministic-check-gate/acceptance.feature');
const driver = path.join(__dirname, 'deterministic_check_gate_driver.exs');

// Compare objects semantically, preserving array/string order. Expected values
// come from the feature, not from the implementation or a generated receipt.
function observe(actual, expected, label = 'observations') {
  if (expected && typeof expected === 'object' && !Array.isArray(expected)) {
    assert.ok(actual && typeof actual === 'object', `${label}: missing object`);
    for (const [key, value] of Object.entries(expected)) {
      assert.ok(Object.hasOwn(actual, key), `${label}.${key}: missing`);
      if (key === 'minimumPassed') {
        assert.ok(Number.isInteger(actual[key]) && actual[key] >= value, `${label}.${key}: ${actual[key]} < ${value}`);
      } else observe(actual[key], value, `${label}.${key}`);
    }
  } else assert.deepEqual(actual, expected, label);
}
function expectedControl() {
  const expected = {};
  for (const line of fs.readFileSync(feature, 'utf8').split('\n')) {
    const match = line.match(/^\s*\|\s*([^|]+?)\s*\|\s*(.*?)\s*\|\s*$/);
    if (match) expected[match[1]] = JSON.parse(match[2]);
  }
  assert.ok(Object.keys(expected).length > 0, 'no feature expectations');
  return expected;
}
function leaves(value, prefix = []) {
  if (value && typeof value === 'object' && !Array.isArray(value)) {
    return Object.entries(value).flatMap(([key, v]) => leaves(v, [...prefix, key]));
  }
  return [prefix];
}
if (require.main === module && process.argv[2] === '--control') {
  const expected = expectedControl();
  observe(structuredClone(expected), expected);
  if (process.argv[3] === 'good') {
    process.stdout.write('good control accepted\n');
  } else if (process.argv[3] === 'bad') {
    for (const keys of leaves(expected)) {
      const bad = structuredClone(expected);
      let parent = bad;
      for (const key of keys.slice(0, -1)) parent = parent[key];
      const key = keys.at(-1), old = parent[key];
      parent[key] = typeof old === 'boolean' ? !old : typeof old === 'number' ? (key === 'minimumPassed' ? old - 1 : old + 1) : 'wrong';
      assert.throws(() => observe(bad, expected), `accepted corruption ${keys.join('.')}`);
    }
    // Absent nested data must not silently pass either.
    assert.throws(() => observe({}, expected));
    process.stdout.write('bad controls rejected\n');
    process.exitCode = 1;
  } else throw new Error('unknown control');
} else {
  const { When, Then, AfterAll } = require('@cucumber/cucumber');
  let scratch, archivePromise;
  function run(file, args, extraEnv = {}) {
    return new Promise((resolve, reject) => {
      const child = spawn(file, args, {
        cwd: root, env: { ...process.env, ...extraEnv }, detached: true,
        stdio: ['ignore', 'pipe', 'pipe'],
      });
      let output = '', timedOut = false;
      child.stdout.on('data', data => { output += data; });
      child.stderr.on('data', data => { output += data; });
      const timer = setTimeout(() => {
        timedOut = true;
        try { process.kill(-child.pid, 'SIGTERM'); } catch {}
      }, 900000);
      child.on('error', error => { clearTimeout(timer); reject(error); });
      child.on('close', code => { clearTimeout(timer); resolve({ code, output, timedOut }); });
    });
  }
  async function archive() {
    if (!archivePromise) archivePromise = (async () => {
      scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-check-gate-'));
      const result = await run('/bin/sh', ['packaging/package.sh']);
      assert.equal(result.timedOut, false, result.output);
      assert.equal(result.code, 0, result.output);
      const archivePath = result.output.split('\n').map(s => s.trim()).find(s => s.startsWith('/') && s.endsWith('.tar.gz'));
      assert.ok(archivePath && fs.statSync(archivePath).isFile(), result.output);
      return archivePath;
    })();
    return archivePromise;
  }
  function receipt(output, prefix) {
    const rows = output.split('\n').filter(s => s.startsWith(prefix));
    assert.equal(rows.length, 1, output);
    return JSON.parse(rows[0].slice(prefix.length));
  }
  AfterAll(() => { if (scratch) fs.rmSync(scratch, { recursive: true, force: true }); });
  When('I measure native check fixture lifecycle', { timeout: 960000 }, async function () {
    const archivePath = await archive();
    const result = await run('mix', ['run', '--no-start', driver, 'measure'], { MIX_ENV: 'test', KOGEN_ARCHIVE: archivePath });
    await this.attach(result.output, 'text/plain');
    assert.equal(result.timedOut, false, result.output);
    assert.equal(result.code, 0, result.output);
    this.nativeCheckObservations = receipt(result.output, 'CHECK_GATE_LIFECYCLE=');
  });
  When('I run the reported native check regression modules', { timeout: 960000 }, async function () {
    const archivePath = await archive();
    const result = await run('elixir', ['-r', driver, '-S', 'mix', 'test',
      'test/integration/build_boundaries_test.exs', 'test/integration/shape_context_publication_test.exs',
      '--formatter', 'ExUnit.CLIFormatter', '--formatter', 'KogenCheckGateReporter'], { MIX_ENV: 'test', KOGEN_ARCHIVE: archivePath });
    await this.attach(result.output, 'text/plain');
    assert.equal(result.timedOut, false, result.output);
    const report = receipt(result.output, 'CHECK_GATE_SUITE=');
    this.nativeCheckObservations = { ...report, exit: result.code, minimumPassed: report.passed };
  });
  Then('the native check observations include:', function (table) {
    const expected = Object.fromEntries(table.raw().map(([key, value]) => [key, JSON.parse(value)]));
    observe(this.nativeCheckObservations, expected);
  });
}
