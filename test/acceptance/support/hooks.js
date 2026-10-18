const assert = require('node:assert/strict');
const { BeforeAll, Before, After, AfterAll, setParallelCanAssign, parallelCanAssignHelpers, HookTarget } = require('@cucumber/cucumber');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const { REPO, NODE24, PYTHON_BIN, ERL_FLAGS, findProgram } = require('./world');

// Cucumber workers are threads in this process; coordinator hooks prepare and clean this handoff.
const sharedManifest = path.join(os.tmpdir(), `kogen-acceptance-shared-${process.pid}.json`);
const shared = { root: null, prefix: null, archive: null, source: null };
// The real OAuth callback has one fixed port; other scenarios use isolated homes and ports.
setParallelCanAssign(parallelCanAssignHelpers.atMostOnePicklePerTag(['@GPT-2']));

const PLATFORM = process.platform === 'darwin' ? 'darwin-arm64' : 'linux-x86_64';

function latestArchive() {
  if (process.env.KOGEN_ARCHIVE) return path.resolve(process.env.KOGEN_ARCHIVE);
  const dist = path.join(REPO, 'dist');
  const files = fs.readdirSync(dist)
    .filter(name => name.startsWith('kogen-') && name.endsWith(`-${PLATFORM}.tar.gz`))
    .map(name => path.join(dist, name))
    .filter(file => fs.statSync(file).isFile());
  files.sort((a, b) => fs.statSync(b).mtimeMs - fs.statSync(a).mtimeMs);
  return files[0] || null;
}

function installPath() {
  return [NODE24, path.dirname(PYTHON_BIN), path.dirname(findProgram('git') || '/usr/bin/git'), '/usr/bin', '/bin', '/usr/sbin', '/sbin'].join(path.delimiter);
}

BeforeAll({ on: HookTarget.COORDINATOR }, async function () {
  assert.ok(fs.existsSync(path.join(NODE24, 'node')), `Node 24 is missing at ${path.join(NODE24, 'node')}`);
  assert.ok(fs.existsSync(PYTHON_BIN), `Python is missing at ${PYTHON_BIN}`);
  const git = findProgram('git');
  assert.ok(git, 'git is required by the acceptance suite');

  shared.archive = latestArchive();
  shared.root = fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-acceptance-release-'));
  const buildTemp = fs.realpathSync(shared.root);
  if (!shared.archive) {
    const source = path.join(shared.root, 'source');
    fs.mkdirSync(source, { recursive: true });
    for (const name of ['mix.exs', 'mix.lock', 'LICENSE', 'NOTICE', 'config', 'lib', 'rel', 'cli', 'packaging', 'docs']) {
      fs.cpSync(path.join(REPO, name), path.join(source, name), { recursive: true, dereference: false });
    }
    shared.source = source;
    const result = execFileSync('/bin/sh', [path.join(source, 'packaging/package.sh')], {
      cwd: source,
      encoding: 'utf8',
      env: { ...process.env, HOME: shared.root, TMPDIR: buildTemp, PATH: installPath() },
      stdio: ['ignore', 'pipe', 'inherit'],
    });
    shared.archive = result.trim().split('\n').at(-1);
  }
  assert.ok(shared.archive && fs.existsSync(shared.archive), 'a Kogen release archive is required');

  const listing = execFileSync('tar', ['-tzf', shared.archive], { encoding: 'utf8' }).split('\n').filter(Boolean);
  const top = listing[0].split('/')[0];
  shared.source = path.join(shared.root, 'archive', top);
  fs.mkdirSync(path.dirname(shared.source), { recursive: true });
  execFileSync('tar', ['-xzf', shared.archive, '-C', path.dirname(shared.source)]);
  shared.prefix = path.join(shared.root, 'shared-prefix');
  const installHome = path.join(shared.root, 'install-home');
  fs.mkdirSync(installHome, { recursive: true });
  execFileSync('/bin/sh', [path.join(shared.source, 'install.sh'), '--prefix', shared.prefix], {
    cwd: shared.source,
    encoding: 'utf8',
    env: { HOME: installHome, TMPDIR: buildTemp, PATH: installPath(), ERL_FLAGS, KOGEN_NO_BROWSER: '1', GIT_CONFIG_NOSYSTEM: '1' },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  const core = path.join(shared.prefix, 'lib/kogen/lib/release/bin/kogen');
  const coreStat = fs.lstatSync(core);
  let realCore = fs.realpathSync(core);
  if (!coreStat.isSymbolicLink()) {
    realCore = `${core}.acceptance-real`;
    fs.renameSync(core, realCore);
  } else {
    fs.unlinkSync(core);
  }
  const quote = value => `'${String(value).replaceAll("'", "'\\''")}'`;
  fs.writeFileSync(core, `#!/bin/sh\nprintf '%s\\n' "$$" >> "$KOGEN_CORE_PID_FILE"\nRELEASE_PROG=kogen; export RELEASE_PROG\nexec ${quote(realCore)} "$@"\n`);
  fs.chmodSync(core, 0o755);
  fs.writeFileSync(sharedManifest, JSON.stringify(shared), { mode: 0o600 });
});

BeforeAll(async function () {
  Object.assign(shared, JSON.parse(fs.readFileSync(sharedManifest, 'utf8')));
});

Before(async function ({ pickle }) {
  this.prefix = shared.prefix;
  this.archive = shared.archive;
  this.sharedSource = shared.source;
  await this.setup();
  // Only these assertions need snapshots of real process arguments/environments.
  // PID/group instrumentation remains active for every scenario.
  this.observeProcessArguments = pickle.steps.some(step => step.text.startsWith('no Kogen process had '));
});

After(async function () {
  try {
    await this.verifyWatchedCommandGroups();
  } finally {
    await this.cleanup();
  }
});

AfterAll({ on: HookTarget.COORDINATOR }, async function () {
  if (shared.root) fs.rmSync(shared.root, { recursive: true, force: true });
  fs.rmSync(sharedManifest, { force: true });
});

module.exports = { shared };
