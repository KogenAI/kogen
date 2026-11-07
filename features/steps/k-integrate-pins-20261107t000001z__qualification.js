// Acceptance of k-integrate-pins-20261107t000001z: kogen's qualification on the new component
// tuple (kogen-loop 84ee1ed6652f, kogen-build 45d5823fa40c, kogen-setup 43be668ea101).
// Run directly, `node features/steps/k-integrate-pins-20261107t000001z__qualification.js --control good|bad`
// qualifies the go test observer on a real run of the existing passing test
// TestRecoverArchivesTheBlockedBuildAndClearsTheImplementation in ./consumes/kogen-build (good),
// and on corruptions of that real run and a requirement of a test that does not exist (bad).
const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');

const root = path.resolve(__dirname, '../..');
const STEP = 110000;

// env is the environment of a child command: the acceptance runner's own variables removed, and
// GOFLAGS=-trimpath as the configured go-test check uses.
function env() {
  const e = { ...process.env, GOFLAGS: '-trimpath' };
  for (const k of ['NODE_PATH', 'KOGEN_ACCEPTANCE_FEATURES', 'KOGEN_ACCEPTANCE_REPORT']) delete e[k];
  return e;
}

function tail(text) {
  return text.length > 20000 ? '...' + text.slice(-20000) : text;
}

function run(dir, command) {
  const r = spawnSync('sh', ['-c', command], { cwd: path.join(root, dir), encoding: 'utf8', env: env(), timeout: STEP - 5000, maxBuffer: 512 * 1024 * 1024 });
  return { status: r.status, error: r.error, out: (r.stdout || '') + (r.stderr || '') };
}

// goTest runs `go test -json -count=1 [-run <filter>] <pkg>` in cli and keeps its events.
function goTest(pkg, filter) {
  const args = ['test', '-json', '-count=1', ...(filter ? ['-run', filter] : []), pkg];
  const r = spawnSync('go', args, { cwd: path.join(root, 'cli'), encoding: 'utf8', env: env(), timeout: STEP - 5000, maxBuffer: 512 * 1024 * 1024 });
  const rows = (r.stdout || '').split('\n').filter(l => l.startsWith('{')).map(l => { try { return JSON.parse(l); } catch { return {}; } });
  return {
    pkg, rows, status: r.status, error: r.error, stdout: r.stdout || '', stderr: r.stderr || '',
    what: `GOFLAGS=-trimpath go ${args.join(' ')} in cli; exit=${r.status}, error=${r.error || 'none'}`,
  };
}

// judge requires that each named test (top-level or Parent/sub) of the package ran exactly once and
// passed, that the package itself passed and that go test exited 0.
function judge(result, tests) {
  const full = result.pkg === '.' ? 'kogen' : 'kogen/' + result.pkg.replace(/^\.\//, '');
  assert(!result.error, `${tests.join(', ')}: ${result.what}\n${tail(result.stderr)}`);
  for (const name of tests) {
    const mine = result.rows.filter(x => x.Test === name && x.Package === full);
    const outcome = mine.filter(x => ['pass', 'fail', 'skip'].includes(x.Action)).map(x => x.Action).join(',') || 'absent (ran zero times)';
    const output = mine.filter(x => x.Action === 'output').map(x => x.Output).join('');
    const diagnostic = `${name} in ${full}: ${result.what}, outcome=${outcome}\n${tail(output || (result.stdout + result.stderr))}`;
    assert.equal(mine.filter(x => x.Action === 'run').length, 1, `${name} did not run exactly once; ${diagnostic}`);
    assert.equal(outcome, 'pass', `${name} did not pass; ${diagnostic}`);
  }
  const pkgOutcome = result.rows.filter(x => !x.Test && x.Package === full && ['pass', 'fail', 'skip'].includes(x.Action)).map(x => x.Action).join(',') || 'absent';
  assert.equal(pkgOutcome, 'pass', `package ${full} did not pass (outcome=${pkgOutcome}); ${result.what}\n${tail(result.stdout + result.stderr)}`);
  assert.equal(result.status, 0, `go test exited nonzero; ${result.what}\n${tail(result.stdout + result.stderr)}`);
}

const CONTROL_PKG = './consumes/kogen-build';
const CONTROL = 'TestRecoverArchivesTheBlockedBuildAndClearsTheImplementation';

if (require.main === module && process.argv[2] === '--control') {
  const real = goTest(CONTROL_PKG, `^${CONTROL}$`);
  const accepts = f => { try { f(); return true; } catch { return false; } };
  const good = () => judge(real, [CONTROL]);
  if (process.argv[3] === 'good') {
    const ok = accepts(good);
    console.log(ok ? 'observer accepted' : 'observer rejected');
    if (!ok) process.exitCode = 1;
  } else if (!accepts(good)) {
    console.log('control run broken');
    process.exitCode = 2;
  } else {
    const corrupt = change => { const c = structuredClone({ ...real, error: undefined }); change(c); return c; };
    const bad = [
      () => judge(real, [CONTROL, 'TestNoSuchConsumerTest']),
      () => judge(corrupt(c => { c.status = 1; }), [CONTROL]),
      () => judge(corrupt(c => { c.rows.find(x => x.Test === CONTROL && x.Action === 'pass').Action = 'fail'; }), [CONTROL]),
      () => judge(corrupt(c => { c.rows = c.rows.filter(x => !(x.Test === CONTROL && x.Action === 'pass')); }), [CONTROL]),
      () => judge(corrupt(c => { c.rows.push({ ...c.rows.find(x => x.Test === CONTROL && x.Action === 'run') }); }), [CONTROL]),
      () => judge(corrupt(c => { c.rows = c.rows.filter(x => x.Test || x.Action !== 'pass'); }), [CONTROL]),
      () => judge(corrupt(c => { c.rows = []; }), [CONTROL]),
    ];
    const accepted = bad.filter(f => accepts(f)).length;
    console.log(accepted === 0 ? 'observer rejected' : 'observer accepted');
    if (accepted === 0) process.exitCode = 1;
  }
} else {
  const { When, Then } = require('@cucumber/cucumber');

  Then('k-integrate-pins-20261107t000001z: the cli module resolves the components:', { timeout: STEP }, function (table) {
    for (const [module, version] of table.rows()) {
      const r = run('cli', `go list -m -f '{{.Path}} {{.Version}}{{with .Replace}} => {{.Path}}{{end}}' ${module}`);
      assert.equal(r.status, 0, `go list -m ${module} in cli: exit=${r.status}, error=${r.error || 'none'}\n${r.out}`);
      assert.equal(r.out.trim(), `${module} ${version}`, `go list -m ${module} in cli`);
    }
  });

  Then('k-integrate-pins-20261107t000001z: the loop pin names module {string} at source head {string}', function (module, head) {
    const pin = JSON.parse(fs.readFileSync(path.join(root, 'cli/loop-pin.json'), 'utf8'));
    assert.equal(pin.module, module, 'cli/loop-pin.json module');
    assert.equal(pin.source_head, head, 'cli/loop-pin.json source_head');
  });

  Then('k-integrate-pins-20261107t000001z: gofmt lists no file in cli', { timeout: STEP }, function () {
    const r = run('cli', 'gofmt -l .');
    assert.equal(r.status, 0, `gofmt -l . in cli: exit=${r.status}, error=${r.error || 'none'}\n${r.out}`);
    assert.equal(r.out, '', 'gofmt -l . in cli lists unformatted files');
  });

  Then('k-integrate-pins-20261107t000001z: {string} in {string} succeeds', { timeout: STEP }, function (command, dir) {
    const r = run(dir, command);
    assert(!r.error && r.status === 0, `${command} in ${dir}: exit=${r.status}, error=${r.error || 'none'}\n${tail(r.out)}`);
  });

  When('k-integrate-pins-20261107t000001z: go test runs the whole package {string} in cli', { timeout: STEP }, function (pkg) {
    this.kIntegratePins20261107 = goTest(pkg, '');
  });

  Then('k-integrate-pins-20261107t000001z: the package passed with each of these tests run once and passed:', function (table) {
    judge(this.kIntegratePins20261107, table.rows().map(([name]) => name));
  });

  Then('k-integrate-pins-20261107t000001z: the file {string} contains each of these texts:', function (file, table) {
    const text = fs.readFileSync(path.join(root, file), 'utf8');
    const missing = table.rows().map(([t]) => t).filter(t => !text.includes(t));
    assert.deepEqual(missing, [], `${file} lacks these texts`);
  });

  Then('k-integrate-pins-20261107t000001z: the file {string} contains none of these texts:', function (file, table) {
    const text = fs.readFileSync(path.join(root, file), 'utf8');
    const present = table.rows().map(([t]) => t).filter(t => text.includes(t));
    assert.deepEqual(present, [], `${file} still contains these texts`);
  });
}
