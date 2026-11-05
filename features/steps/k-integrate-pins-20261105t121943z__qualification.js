// Acceptance of k-integrate-pins-20261105t121943z: kogen's qualification on the adopted component
// tuple, within the 120-second acceptance limit. Run directly,
// `node features/steps/k-integrate-pins-20261105t121943z__qualification.js --control good|bad`
// qualifies the named-test observer on an existing passing test and on a test that does not exist.
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

// passes runs the named top-level Go tests ([name, package] pairs) of cli/ in one go test and
// requires that each ran exactly once in its package and passed.
function passes(tests) {
  const names = [...new Set(tests.map(([name]) => name))];
  const pkgs = [...new Set(tests.map(([, pkg]) => pkg))];
  const args = ['test', '-json', '-count=1', '-run', `^(${names.join('|')})$`, ...pkgs];
  const r = spawnSync('go', args, { cwd: path.join(root, 'cli'), encoding: 'utf8', env: env(), timeout: STEP - 5000, maxBuffer: 512 * 1024 * 1024 });
  const rows = (r.stdout || '').split('\n').filter(l => l.startsWith('{')).map(l => { try { return JSON.parse(l); } catch { return {}; } });
  const command = `GOFLAGS=-trimpath go ${args.join(' ')} in cli; exit=${r.status}, error=${r.error || 'none'}`;
  assert(!r.error, `${names.join(', ')}: ${command}\n${tail(r.stderr || '')}`);
  for (const [name, pkg] of tests) {
    const full = pkg === '.' ? 'kogen' : 'kogen/' + pkg.replace(/^\.\//, '');
    const mine = rows.filter(x => x.Test === name && x.Package === full);
    const outcome = mine.filter(x => ['pass', 'fail', 'skip'].includes(x.Action)).map(x => x.Action).join(',') || 'absent (ran zero times)';
    const output = mine.filter(x => x.Action === 'output').map(x => x.Output).join('');
    const diagnostic = `${name} in ${full}: ${command}, outcome=${outcome}\n${tail(output || ((r.stdout || '') + (r.stderr || '')))}`;
    assert.equal(mine.filter(x => x.Action === 'run').length, 1, `${name} did not run exactly once; ${diagnostic}`);
    assert.equal(outcome, 'pass', `${name} did not pass; ${diagnostic}`);
  }
  assert.equal(r.status, 0, `${names.join(', ')}: go test exited nonzero; ${command}\n${tail((r.stdout || '') + (r.stderr || ''))}`);
}

if (require.main === module && process.argv[2] === '--control') {
  try {
    if (process.argv[3] === 'good') passes([['TestConfigPathAndModelRoles', './consumes/kogen-coordinator']]);
    else passes([['TestKIntegratePinsNoSuchTest', './consumes/kogen-coordinator']]);
    console.log('observer accepted');
  } catch {
    console.log('observer rejected');
    process.exitCode = 1;
  }
} else {
  const { Then } = require('@cucumber/cucumber');

  Then('k-integrate-pins-20261105t121943z: these Go tests pass in one run:', { timeout: STEP }, function (table) {
    passes(table.rows());
  });

  Then('k-integrate-pins-20261105t121943z: the cli module resolves the components:', { timeout: STEP }, function (table) {
    for (const [module, version] of table.rows()) {
      const r = run('cli', `go list -m -f '{{.Path}} {{.Version}}{{with .Replace}} => {{.Path}}{{end}}' ${module}`);
      assert.equal(r.status, 0, `go list -m ${module} in cli: exit=${r.status}, error=${r.error || 'none'}\n${r.out}`);
      assert.equal(r.out.trim(), `${module} ${version}`, `go list -m ${module} in cli`);
    }
  });

  Then('k-integrate-pins-20261105t121943z: the loop pin names module {string} at source head {string}', function (module, head) {
    const pin = JSON.parse(fs.readFileSync(path.join(root, 'cli/loop-pin.json'), 'utf8'));
    assert.equal(pin.module, module, 'cli/loop-pin.json module');
    assert.equal(pin.source_head, head, 'cli/loop-pin.json source_head');
  });

  Then('k-integrate-pins-20261105t121943z: gofmt lists no file in cli', { timeout: STEP }, function () {
    const r = run('cli', 'gofmt -l .');
    assert.equal(r.status, 0, `gofmt -l . in cli: exit=${r.status}, error=${r.error || 'none'}\n${r.out}`);
    assert.equal(r.out, '', 'gofmt -l . in cli lists unformatted files');
  });

  Then('k-integrate-pins-20261105t121943z: {string} in {string} succeeds', { timeout: STEP }, function (command, dir) {
    const r = run(dir, command);
    assert(!r.error && r.status === 0, `${command} in ${dir}: exit=${r.status}, error=${r.error || 'none'}\n${tail(r.out)}`);
  });
}
