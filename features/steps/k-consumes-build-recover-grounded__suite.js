// Acceptance of k-consumes-build-recover-grounded: kogen's consumes/kogen-build suite runs in a
// scratch copy of cli/, at the pinned kogen-build or at another kogen-build version through an
// alternate module file outside the checkout, so cli/go.mod and cli/go.sum are never edited.
// Observer controls: `node features/steps/k-consumes-build-recover-grounded__suite.js --control good|bad`
// judge the unchanged tree; loaded by Cucumber the file defines the steps.
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');

const P = 'k-consumes-build-recover-grounded: ';
const PKG = './consumes/kogen-build/';
const ARCHIVE = 'TestRecoverArchivesTheBlockedBuildAndClearsTheImplementation';
const REFUSALS = 'TestRecoverRefusalsAreSysErrorsWithTheirExit';
const REQUIRED = [ARCHIVE, REFUSALS, ...['unknown_id', 'absent_checkpoint', 'output_inside_the_checkout', 'output_exists'].map(s => `${REFUSALS}/${s}`)];
const RENDER = 'project.RenderConfig(cfg)';
const DROPPED = 'project.RenderConfig(&project.Config{Acceptance: cfg.Acceptance})';

function goEnv() {
  const env = { ...process.env, GOWORK: 'off' };
  delete env.GOFLAGS;
  return env;
}

// scratch copies cli/ to a new temporary folder and, for a version other than "pinned", writes an
// alternate module file beside it that requires that kogen-build version. It returns the copy, the
// go test arguments that select the version and a cleanup.
function scratch(version) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'k-consumes-build-recover-grounded-'));
  const cli = path.join(dir, 'cli');
  fs.cpSync(path.resolve('cli'), cli, { recursive: true, verbatimSymlinks: true });
  let select = [];
  if (version !== 'pinned') {
    const mod = path.join(dir, 'check.mod');
    fs.copyFileSync(path.join(cli, 'go.mod'), mod);
    fs.copyFileSync(path.join(cli, 'go.sum'), path.join(dir, 'check.sum'));
    const edit = spawnSync('go', ['mod', 'edit', `-modfile=${mod}`, `-require=github.com/KogenAI/kogen-build@${version}`], { cwd: cli, encoding: 'utf8', env: goEnv() });
    assert.equal(edit.status, 0, `go mod edit -require=github.com/KogenAI/kogen-build@${version}: ${edit.error || ''}\n${edit.stdout}${edit.stderr}`);
    select = ['-mod=mod', `-modfile=${mod}`];
  }
  return { cli, select, done: () => fs.rmSync(dir, { recursive: true, force: true }) };
}

function goTest(s, args) {
  const argv = ['test', ...s.select, '-count=1', '-v', ...args, PKG];
  const r = spawnSync('go', argv, { cwd: s.cli, encoding: 'utf8', env: goEnv(), timeout: 240000, maxBuffer: 64 * 1024 * 1024 });
  return { command: `go ${argv.join(' ')}`, status: r.status, error: r.error, output: `${r.stdout || ''}${r.stderr || ''}` };
}

function line(verdict, name) {
  return new RegExp(`^\\s*--- ${verdict}: ${name.replace(/[/]/g, '\\/')} \\(`, 'm');
}

// passes: the whole consumes/kogen-build package passes and each recover test and refusal case ran
// and passed.
function passes(version) {
  const s = scratch(version);
  try {
    const r = goTest(s, []);
    assert.equal(r.status, 0, `${r.command} (kogen-build ${version}) exited ${r.status}${r.error ? ' ' + r.error : ''}, want 0\n${r.output}`);
    for (const name of REQUIRED) {
      assert.match(r.output, line('PASS', name), `${name} did not run and pass in ${r.command} (kogen-build ${version}): ${line('FAIL', name).test(r.output) ? 'it failed' : 'it was absent or skipped'}\n${r.output}`);
    }
  } finally {
    s.done();
  }
}

// faultFails: with the fixture project's checks dropped, the blocker claim is backed by no failing
// verification, and the archive test must fail as a test (not as a build failure).
function faultFails(version) {
  const s = scratch(version);
  try {
    const helper = path.join(s.cli, 'consumes/kogen-build/helper_test.go');
    const text = fs.readFileSync(helper, 'utf8');
    const count = text.split(RENDER).length - 1;
    assert.equal(count, 1, `cli/consumes/kogen-build/helper_test.go must render the fixture configuration with ${RENDER} exactly once; found ${count}`);
    fs.writeFileSync(helper, text.replace(RENDER, DROPPED));
    const r = goTest(s, ['-run', `^${ARCHIVE}$`]);
    assert.ok(!/\[(build|setup) failed\]/.test(r.output), `${r.command} (kogen-build ${version}, fixture checks dropped) did not compile\n${r.output}`);
    assert.notEqual(r.status, 0, `${ARCHIVE} passed in ${r.command} (kogen-build ${version}) although the fixture's checks were dropped and its blocker claim is not grounded\n${r.output}`);
    assert.match(r.output, line('FAIL', ARCHIVE), `${ARCHIVE} did not run and fail in ${r.command} (kogen-build ${version}, fixture checks dropped): exit ${r.status}\n${r.output}`);
  } finally {
    s.done();
  }
}

if (require.main === module) {
  const mode = process.argv[process.argv.indexOf('--control') + 1];
  // good: the unchanged tree passes at the pinned kogen-build and its ungrounded fixture fails the
  // archive test at 2e10d93. bad: the same judges over the cases they must reject.
  const cases = mode === 'good'
    ? [() => passes('pinned'), () => faultFails('v0.0.0-20261104030858-2e10d934cac2')]
    : [() => passes('v0.0.0-20261104030858-2e10d934cac2'), () => faultFails('pinned')];
  let failures = 0;
  for (const c of cases) {
    try { c(); } catch (_) { failures++; }
  }
  console.log(`observer failures: ${failures}`);
  process.exit(failures ? 1 : 0);
} else {
  const { Then, setDefaultTimeout } = require('@cucumber/cucumber');
  setDefaultTimeout(300000);
  Then(P + 'the kogen-build consumes suite passes with kogen-build {string}', function (version) {
    passes(version);
  });
  Then(P + 'with the fixture checks dropped the archive test fails with kogen-build {string}', function (version) {
    faultFails(version);
  });
}
