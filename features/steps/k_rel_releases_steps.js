const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn, execFileSync } = require('node:child_process');
const { Given, When, Then, AfterAll } = require('@cucumber/cucumber');

const root = path.resolve(__dirname, '../..');
const FOUR = ['darwin-arm64', 'darwin-x86_64', 'linux-x86_64', 'linux-arm64'];
const VERSION = 'v9.9.9-test';
const env = { ...process.env, PATH: `${path.dirname(process.execPath)}${path.delimiter}${process.env.PATH || ''}` };
const cleanup = [];
let repoDir = null;
let packaged = null;
let released = null;

function run(cmd, args, opts = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(cmd, args, { cwd: opts.cwd || root, env: { ...env, ...(opts.env || {}) }, stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '';
    let stderr = '';
    let output = '';
    child.stdout.on('data', b => { stdout += b; output += b; });
    child.stderr.on('data', b => { stderr += b; output += b; });
    child.on('error', reject);
    child.on('close', code => resolve({ code, stdout, stderr, output }));
  });
}
function tmp(label) {
  const d = fs.mkdtempSync(path.join(os.tmpdir(), `k-rel-${label}-`));
  cleanup.push(d);
  return d;
}
function hostTarget() {
  const o = { linux: 'linux', darwin: 'darwin' }[process.platform];
  const a = { x64: 'x86_64', arm64: 'arm64' }[process.arch];
  return `${o}-${a}`;
}
function repo() {
  if (repoDir) return repoDir;
  repoDir = tmp('repo');
  execFileSync('sh', ['-c', 'tar -C "$1" -cf - --exclude=node_modules --exclude=dist --exclude=cli/kogen LICENSE NOTICE cli packaging docs | tar -C "$2" -xf -', 'sh', root, repoDir]);
  const git = (...a) => execFileSync('git', ['-c', 'user.name=k', '-c', 'user.email=k@example.invalid', '-c', 'commit.gpgsign=false', ...a], { cwd: repoDir, stdio: 'pipe' });
  git('init', '-q');
  git('add', '-A');
  git('commit', '-q', '-m', 'k-rel fixture');
  return repoDir;
}
function binaryTarget(buf) {
  if (buf.readUInt32BE(0) === 0x7f454c46) {
    const arch = { 62: 'x86_64', 183: 'arm64' }[buf.readUInt16LE(18)];
    return `linux-${arch}`;
  }
  if (buf.readUInt32LE(0) === 0xfeedfacf) {
    const arch = { 0x01000007: 'x86_64', 0x0100000c: 'arm64' }[buf.readUInt32LE(4)];
    return `darwin-${arch}`;
  }
  return 'unknown';
}
function extract(archive) {
  const dir = tmp('x');
  execFileSync('tar', ['-xzf', archive, '-C', dir]);
  const entries = fs.readdirSync(dir);
  assert.equal(entries.length, 1, `archive top level: ${entries}`);
  return path.join(dir, entries[0]);
}
function sumsCheck(dir) {
  return fs.existsSync('/usr/bin/sha256sum') || fs.existsSync('/usr/local/bin/sha256sum')
    ? run('sha256sum', ['-c', 'SHA256SUMS'], { cwd: dir })
    : run('shasum', ['-a', '256', '-c', 'SHA256SUMS'], { cwd: dir });
}
async function releaseSet() {
  if (released) return released;
  const out = path.join(tmp('rel'), 'out');
  const r = await run('sh', ['packaging/release.sh', '--version', VERSION, '--output', out], { cwd: repo() });
  released = { out, result: r };
  return released;
}

AfterAll(function () {
  for (const d of cleanup) fs.rmSync(d, { recursive: true, force: true });
});

Given('a clean committed copy of the Kogen sources for release testing', function () {
  repo();
});
When('I build every release target with package.sh --target', { timeout: 1200000 }, async function () {
  if (!packaged) {
    packaged = {};
    for (const t of FOUR) {
      const r = await run('sh', ['packaging/package.sh', '--target', t], { cwd: repo() });
      assert.equal(r.code, 0, `${t}: ${r.output}`);
      packaged[t] = r.stdout.trim().split('\n').pop();
    }
  }
  this.packaged = packaged;
});
Then('the release archive for each target names that target and holds a binary for it:', function (table) {
  for (const row of table.hashes()) {
    const archive = this.packaged[row.target];
    assert.ok(archive && fs.existsSync(archive), `no archive for ${row.target}`);
    const dir = extract(archive);
    assert.equal(fs.readFileSync(path.join(dir, 'TARGET'), 'utf8'), `${row.target}\n`);
    assert.equal(binaryTarget(fs.readFileSync(path.join(dir, 'bin/kogen'))), `${row.os}-${row.arch}`);
    assert.ok(fs.existsSync(path.join(dir, 'install.sh')));
  }
});

When('I build the release set with release.sh', { timeout: 1200000 }, async function () {
  this.release = await releaseSet();
  assert.equal(this.release.result.code, 0, this.release.result.output);
});
Then('the release folder holds exactly the four archives, SHA256SUMS and install-kogen.sh', function () {
  const expected = [...FOUR.map(t => `kogen-${VERSION}-${t}.tar.gz`), 'SHA256SUMS', 'install-kogen.sh'].sort();
  assert.deepEqual(fs.readdirSync(this.release.out).sort(), expected);
});
Then('sha256sum accepts SHA256SUMS naming exactly the four archives', async function () {
  const sums = fs.readFileSync(path.join(this.release.out, 'SHA256SUMS'), 'utf8');
  const names = sums.trim().split('\n').map(l => l.split(/\s+/)[1].replace(/^\*/, '')).sort();
  assert.deepEqual(names, FOUR.map(t => `kogen-${VERSION}-${t}.tar.gz`).sort());
  const r = await sumsCheck(this.release.out);
  assert.equal(r.code, 0, r.output);
});

When('I run release.sh in a checkout with an uncommitted file', async function () {
  const stray = path.join(repo(), 'packaging/k-rel-stray.txt');
  const out = path.join(tmp('dirty'), 'out');
  fs.writeFileSync(stray, 'stray\n');
  try {
    this.dirty = await run('sh', ['packaging/release.sh', '--version', VERSION, '--output', out], { cwd: repo() });
    this.dirtyOut = out;
  } finally {
    fs.rmSync(stray, { force: true });
  }
});
Then('release.sh refuses with a message about a clean checkout and writes no SHA256SUMS', function () {
  assert.notEqual(this.dirty.code, 0, this.dirty.output);
  assert.match(this.dirty.output, /clean/);
  assert.equal(fs.existsSync(path.join(this.dirtyOut, 'SHA256SUMS')), false);
});

async function install(from, prefix, tmpdir) {
  const home = tmp('home');
  return run('sh', [path.join(from, 'install-kogen.sh'), '--from', from, '--version', VERSION, '--prefix', prefix], { env: { TMPDIR: tmpdir, HOME: home } });
}
When('I install the host archive with install-kogen.sh from the release folder', { timeout: 1500000 }, async function () {
  this.release = await releaseSet();
  assert.equal(this.release.result.code, 0, this.release.result.output);
  this.prefix = path.join(tmp('prefix'), 'p');
  this.tmpdir = tmp('tmpdir');
  this.install = await install(this.release.out, this.prefix, this.tmpdir);
});
Then('the installer succeeds and leaves its temp directory empty', function () {
  assert.equal(this.install.code, 0, this.install.output);
  assert.deepEqual(fs.readdirSync(this.tmpdir), []);
});
Then('kogen --version in the prefix exits 0 and prints exactly what kogen version prints', async function () {
  const bin = path.join(this.prefix, 'bin/kogen');
  const a = await run(bin, ['--version'], { cwd: '/' });
  const b = await run(bin, ['version'], { cwd: '/' });
  assert.equal(a.code, 0, a.output);
  assert.equal(b.code, 0, b.output);
  assert.equal(a.stdout, b.stdout);
  assert.match(a.stdout, new RegExp(`^kogen ${VERSION} \\(`));
  assert.ok(this.install.stdout.includes(a.stdout.trim()), this.install.output);
});

When('I install from a release folder whose host archive was tampered with', { timeout: 1500000 }, async function () {
  this.release = await releaseSet();
  assert.equal(this.release.result.code, 0, this.release.result.output);
  const copy = path.join(tmp('tamper'), 'out');
  fs.cpSync(this.release.out, copy, { recursive: true });
  fs.appendFileSync(path.join(copy, `kogen-${VERSION}-${hostTarget()}.tar.gz`), 'x');
  this.prefix = path.join(tmp('prefix'), 'p');
  this.tmpdir = tmp('tmpdir');
  this.install = await install(copy, this.prefix, this.tmpdir);
});
Then('the installer refuses with a checksum mismatch message before extracting anything', function () {
  assert.notEqual(this.install.code, 0, this.install.output);
  assert.match(this.install.output, /checksum mismatch/);
  assert.match(this.install.output, /refusing/);
  assert.equal(fs.existsSync(this.prefix), false);
  assert.deepEqual(fs.readdirSync(this.tmpdir), []);
});

When('I run install.sh from an archive built for another target', { timeout: 1500000 }, async function () {
  this.release = await releaseSet();
  assert.equal(this.release.result.code, 0, this.release.result.output);
  this.other = FOUR.find(t => t !== hostTarget());
  const dir = extract(path.join(this.release.out, `kogen-${VERSION}-${this.other}.tar.gz`));
  this.prefix = path.join(tmp('prefix'), 'p');
  this.install = await run('sh', [path.join(dir, 'install.sh'), '--prefix', this.prefix], { env: { HOME: tmp('home') } });
});
Then('install.sh refuses naming both targets and installs nothing', function () {
  assert.equal(this.install.code, 1, this.install.output);
  assert.ok(this.install.output.includes(`this archive is for ${this.other}, not ${hostTarget()}`), this.install.output);
  assert.equal(fs.existsSync(path.join(this.prefix, 'lib/kogen')), false);
});

When('I parse the release workflow file', function () {
  let YAML;
  try { YAML = require('yaml'); } catch { YAML = require(path.join(root, 'test/acceptance/node_modules/yaml')); }
  this.workflowText = fs.readFileSync(path.join(root, '.github/workflows/release.yml'), 'utf8');
  this.workflow = YAML.parse(this.workflowText);
});
const steps = job => JSON.stringify(job.steps);
Then('the workflow triggers on pushed v* tags and on pull requests', function () {
  const on = this.workflow.on ?? this.workflow[true];
  assert.deepEqual(on.push.tags, ['v*']);
  assert.ok('pull_request' in on);
});
Then('the workflow has the jobs build, install-check, pr-check and draft-release', function () {
  assert.deepEqual(Object.keys(this.workflow.jobs).sort(), ['build', 'draft-release', 'install-check', 'pr-check']);
  assert.match(this.workflow.jobs.build['runs-on'], /^ubuntu/);
  assert.ok(steps(this.workflow.jobs.build).includes('packaging/release.sh'));
});
Then('install-check runs the four native runners, installs from local files and checks version and help', function () {
  const job = this.workflow.jobs['install-check'];
  const pairs = job.strategy.matrix.include.map(e => `${e.target}=${e.runner}`).sort();
  assert.deepEqual(pairs, ['darwin-arm64=macos-14', 'darwin-x86_64=macos-13', 'linux-arm64=ubuntu-24.04-arm', 'linux-x86_64=ubuntu-24.04']);
  const s = steps(job);
  for (const needle of ['install-kogen.sh', '--from', 'kogen --version', 'kogen help']) assert.ok(s.includes(needle), needle);
  assert.ok([].concat(job.needs).includes('build'));
});
Then('pr-check builds and installs on ubuntu-24.04 only', function () {
  const job = this.workflow.jobs['pr-check'];
  assert.equal(job['runs-on'], 'ubuntu-24.04');
  const s = steps(job);
  for (const needle of ['packaging/release.sh', 'install-kogen.sh', '--from']) assert.ok(s.includes(needle), needle);
  assert.ok(!s.includes('gh release'));
});
Then('draft-release creates only a draft with the default token and never publishes', function () {
  const job = this.workflow.jobs['draft-release'];
  assert.ok([].concat(job.needs).includes('install-check'));
  const s = steps(job);
  assert.ok(s.includes('gh release create') && s.includes('--draft'));
  for (const needle of ['SHA256SUMS', 'install-kogen.sh']) assert.ok(s.includes(needle), needle);
  assert.ok(!/gh release edit|draft: false|--draft=false/.test(this.workflowText));
  const secrets = [...this.workflowText.matchAll(/secrets\.(\w+)/g)].map(m => m[1]);
  assert.ok(secrets.length > 0 && secrets.every(n => n === 'GITHUB_TOKEN'), secrets.join(','));
});
