'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawn, spawnSync, execFileSync } = require('node:child_process');
const { Given, When, Then, After } = require('@cucumber/cucumber');
const { goDriver } = require('./go_driver_support.js');

const ROOT = path.resolve(__dirname, '../..');
const HEAD = '2ea31bf5438f0bdde537848f678a7331c5fe2a2a';
const EXCLUDED = p => p.startsWith('.kogen/') || p.startsWith('features/');
const GO_ENV = { ...process.env, GOFLAGS: '-buildvcs=false', GOPROXY: 'off', GOTOOLCHAIN: 'local', GOWORK: 'off' };

function walk(dir, base = dir, out = []) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const file = path.join(dir, entry.name);
    if (entry.isDirectory()) walk(file, base, out);
    else out.push(path.relative(base, file).split(path.sep).join('/'));
  }
  return out.sort();
}
const git = (cwd, ...args) => execFileSync('git', args, { cwd, encoding: 'utf8' });
const unescape = s => s.replaceAll('\\n', '\n');

// A process counts as gone when it does not exist or is a zombie awaiting its parent.
function alive(pid) {
  const r = spawnSync('ps', ['-o', 'stat=', '-p', String(pid)], { encoding: 'utf8' });
  const stat = (r.stdout || '').trim();
  return stat !== '' && !stat.startsWith('Z');
}

function scratch(world) {
  if (!world.k5bDirs) world.k5bDirs = [];
  const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-k5b-')));
  world.k5bDirs.push(dir);
  return dir;
}
const own = (world, pid, comm) => (world.k5bPids ||= []).push({ pid, comm });

After(function () {
  // Only process ids this scenario started or recorded from its own commands are stopped.
  // A pid is signalled only while it is still alive and still has the recorded name, so a reused pid is never hit.
  for (const { pid, comm } of this.k5bPids || []) {
    const c = spawnSync('ps', ['-o', 'comm=', '-p', String(pid)], { encoding: 'utf8' }).stdout.trim();
    if (alive(pid) && path.basename(c) === comm) { try { process.kill(pid, 'SIGKILL'); } catch {} }
  }
  for (const dir of this.k5bDirs || []) fs.rmSync(dir, { recursive: true, force: true });
});

// ---------------------------------------------------------------- the pin

Given('KOGEN_LOOP_SOURCE names a clean kogen-loop checkout at 2ea31bf5', function () {
  const dir = process.env.KOGEN_LOOP_SOURCE;
  assert.ok(dir, 'KOGEN_LOOP_SOURCE is not set: point it at a clean kogen-loop checkout at 2ea31bf5438f0bdde537848f678a7331c5fe2a2a');
  assert.ok(fs.existsSync(path.join(dir, '.git')), `KOGEN_LOOP_SOURCE (${dir}) is not a git checkout`);
  assert.equal(git(dir, 'rev-parse', 'HEAD').trim(), HEAD, 'KOGEN_LOOP_SOURCE is not at 2ea31bf5');
  assert.equal(git(dir, 'status', '--porcelain', '--untracked-files=all').trim(), '', 'KOGEN_LOOP_SOURCE is not clean');
  this.k5bSource = dir;
});

Then('the vendored loop has {int} files, none under .kogen or features, byte-equal to that checkout', function (count) {
  const vendoredRoot = path.join(ROOT, 'cli/third_party/kogen-loop');
  const vendored = {};
  for (const f of walk(vendoredRoot)) vendored[f] = fs.readFileSync(path.join(vendoredRoot, f));
  const source = {};
  for (const f of git(this.k5bSource, 'ls-files').split('\n').filter(Boolean)) {
    if (!EXCLUDED(f)) source[f] = fs.readFileSync(path.join(this.k5bSource, f));
  }
  const names = Object.keys(vendored).sort();
  assert.equal(names.length, count, 'vendored file count');
  assert.ok(!names.some(EXCLUDED), 'vendored copy contains .kogen/ or features/ paths');
  assert.deepEqual(names, Object.keys(source).sort(), 'vendored file list differs from the source checkout');
  for (const n of names) assert.ok(vendored[n].equals(source[n]), `bytes differ: ${n}`);
});

Then('cli\\/loop-pin.json is exactly:', function (doc) {
  const actual = JSON.parse(fs.readFileSync(path.join(ROOT, 'cli/loop-pin.json'), 'utf8'));
  assert.deepEqual(actual, JSON.parse(doc));
});

Then('TestLoopPin passes', function () {
  const r = spawnSync('go', ['test', '-count=1', '-run', '^TestLoopPin$', '.'], { cwd: path.join(ROOT, 'cli'), encoding: 'utf8', env: GO_ENV, timeout: 600000 });
  assert.equal(r.status, 0, `TestLoopPin failed:\n${r.stdout}\n${r.stderr}`);
});

// ---------------------------------------------------------------- probes

Given('a sibling process built from a tiny Go program is running under a unique name', function () {
  const dir = scratch(this);
  const name = 'ks' + crypto.randomBytes(5).toString('hex');
  fs.writeFileSync(path.join(dir, 'go.mod'), 'module sibling\n\ngo 1.27.2\n');
  fs.writeFileSync(path.join(dir, 'main.go'), 'package main\n\nimport "time"\n\nfunc main() { time.Sleep(10 * time.Minute) }\n');
  const bin = path.join(dir, name);
  const b = spawnSync('go', ['build', '-o', bin, '.'], { cwd: dir, encoding: 'utf8', env: GO_ENV, timeout: 300000 });
  assert.equal(b.status, 0, `building the sibling failed:\n${b.stdout}${b.stderr}`);
  const child = spawn(bin, [], { detached: true, stdio: 'ignore' });
  child.unref();
  assert.ok(child.pid, 'sibling did not start');
  own(this, child.pid, name);
  this.k5bSibling = { name, pid: child.pid };
  assert.ok(alive(child.pid), 'sibling is not alive after start');
});

async function probe(world, command, ms) {
  const dir = scratch(world);
  const root = path.join(dir, 'root');
  fs.mkdirSync(root);
  const pidfile = path.join(dir, 'pidfile');
  world.k5bPidfile = pidfile;
  const sib = world.k5bSibling || { name: 'NO-SIBLING', pid: 0 };
  const cmd = command.replaceAll('SIBLING_NAME', sib.name).replaceAll('SIBLING_PID', String(sib.pid)).replaceAll('PIDFILE', pidfile);
  const driver = await goDriver('k5b-probe', fs.readFileSync(path.join(__dirname, 'k5b_probe_driver.go'), 'utf8'));
  const r = await driver([root, String(ms), cmd]);
  // The driver may have left a recorded background pid behind (before the fix); remember it so the scenario stops it.
  if (fs.existsSync(pidfile)) { const pid = Number(fs.readFileSync(pidfile, 'utf8').trim()); if (pid) own(world, pid, 'sleep'); }
  assert.equal(r.code, 0, `probe driver failed:\n${r.out}`);
  const line = r.out.trim().split('\n').pop();
  world.k5bProbe = JSON.parse(line);
}

When('a probe runs {string}', async function (command) { await probe(this, command, 0); });
When('a probe runs {string} under a {int} ms deadline', async function (command, ms) { await probe(this, command, ms); });

Then('the probe result has status {int} and output exactly {string}', function (status, output) {
  assert.equal(this.k5bProbe.first.status, status);
  assert.equal(this.k5bProbe.first.timed_out, false);
  assert.equal(this.k5bProbe.first.output, unescape(output));
});

Then('the sibling is still alive', function () {
  assert.ok(alive(this.k5bSibling.pid), 'the sibling process was killed');
});

Then('the round continues: the next probe in the same session has status 0 and output {string}', function (output) {
  assert.equal(this.k5bProbe.second.status, 0);
  assert.equal(this.k5bProbe.second.output, unescape(output));
});

Then('the recorded background process is gone', function () {
  const pid = Number(fs.readFileSync(this.k5bPidfile, 'utf8').trim());
  assert.ok(pid > 0, 'no background pid was recorded');
  assert.ok(!alive(pid), `background process ${pid} outlived the command`);
});

Then('the probe result reports a timeout', function () {
  assert.equal(this.k5bProbe.first.timed_out, true);
});

// ---------------------------------------------------------------- configured checks through cli/build

When('Kogen runs the configured check {string} through cli\\/build', function (command) {
  const dir = scratch(this);
  const pidfile = path.join(dir, 'pidfile');
  this.k5bPidfile = pidfile;
  const out = path.join(dir, 'out.json');
  const overlay = path.join(dir, 'overlay.json');
  fs.writeFileSync(overlay, JSON.stringify({ Replace: { [path.join(ROOT, 'cli/build/k5b_check_acceptance_test.go')]: path.join(__dirname, 'k5b_build_check_driver.go') } }));
  const r = spawnSync('go', ['test', '-overlay', overlay, './build', '-run', '^TestK5bConfiguredCheckObservation$', '-count=1'], {
    cwd: path.join(ROOT, 'cli'), encoding: 'utf8', timeout: 300000, maxBuffer: 8 * 1024 * 1024,
    env: { ...GO_ENV, KOGEN_K5B_CHECK: command.replaceAll('PIDFILE', pidfile), KOGEN_K5B_OUT: out },
  });
  if (fs.existsSync(pidfile)) { const pid = Number(fs.readFileSync(pidfile, 'utf8').trim()); if (pid) own(this, pid, 'sleep'); }
  assert.equal(r.status, 0, `build observation failed:\n${r.stdout}\n${r.stderr}`);
  this.k5bCheck = JSON.parse(fs.readFileSync(out, 'utf8'));
});

Then('the check is reported failing with status {int}', function (status) {
  assert.equal(this.k5bCheck.error, '', `unexpected result: ${this.k5bCheck.error}`);
  assert.equal(this.k5bCheck.status, status, `unexpected baseline status: ${JSON.stringify(this.k5bCheck)}`);
});

// ---------------------------------------------------------------- sources, specification and evidence

function kogenGoSources() {
  const files = [];
  (function scan(dir) {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const file = path.join(dir, entry.name);
      if (entry.isDirectory()) { if (entry.name !== 'third_party' && entry.name !== 'node_modules') scan(file); }
      else if (entry.name.endsWith('.go') && !entry.name.endsWith('_test.go')) files.push({ f: path.relative(ROOT, file), text: fs.readFileSync(file, 'utf8') });
    }
  })(path.join(ROOT, 'cli'));
  return files;
}

Then('every command Kogen runs with sys.Options sweeps its process group and only probes refuse foreign kills', function () {
  let literals = 0;
  for (const { f, text } of kogenGoSources()) {
    for (const m of text.matchAll(/sys\.Options\{[^}]*\}/g)) {
      literals++;
      assert.match(m[0], /KillGroupOnExit:\s*true/, `${f}: ${m[0]} lacks KillGroupOnExit: true`);
      if (f === 'cli/verify/probe.go') {
        assert.match(m[0], /RefuseForeignKill:\s*true/, 'probe lacks RefuseForeignKill: true');
        assert.match(m[0], /Timeout:\s*deadline/, 'probe lost its deadline');
      } else {
        assert.ok(!/RefuseForeignKill/.test(m[0]), `${f} refuses foreign kills for a configured command`);
        assert.ok(!/Timeout/.test(m[0]), `${f} adds a Timeout`);
      }
    }
    assert.ok(!/ShellTimeout/.test(text), `${f} names ShellTimeout`);
    if (f !== 'cli/verify/probe.go') assert.ok(!/RefuseForeignKill/.test(text), `${f} names RefuseForeignKill`);
  }
  assert.ok(literals >= 10, `expected at least 10 sys.Options literals, found ${literals}`);
  const probe = kogenGoSources().find(g => g.f === 'cli/verify/probe.go').text;
  assert.match(probe, /Context:\s*ctx/, 'probe lost its context');
  assert.match(probe, /const ProbeTimeout = 5 \* time\.Minute/, 'probe lost its 5-minute deadline');
});

Then('the specification and the executor contract state what Kogen enforces and cannot enforce', function () {
  const spec = fs.readFileSync(path.join(ROOT, 'spec/prose/02-shaping.md'), 'utf8');
  const shp10 = spec.split('\n').find(l => l.startsWith('**SHP-10'));
  assert.ok(shp10, 'SHP-10 missing');
  for (const needle of ['refus', 'process group']) assert.ok(shp10.includes(needle), `SHP-10 does not mention ${needle}`);
  const contract = fs.readFileSync(path.join(ROOT, 'docs/executor-contract.md'), 'utf8');
  for (const needle of ['refus', 'KillGroupOnExit', 'K-SAFE-2', 'setsid', 'PreToolUse', 'sys.ForeignKill']) {
    assert.ok(contract.includes(needle), `docs/executor-contract.md does not mention ${needle}`);
  }
});

Then('a re-pin evidence note names 2ea31bf5, 111 files and the new digest while the older notes keep their history', function () {
  const dir = path.join(ROOT, 'docs/evidence');
  const digest = '0f2daaefc9f0c6c22851dc29df1f774a7d8c863261200eac16e1489435cecec1';
  const notes = walk(dir).map(f => ({ f, text: fs.readFileSync(path.join(dir, f), 'utf8') }));
  assert.ok(notes.some(n => n.text.includes(HEAD) && n.text.includes(digest) && n.text.includes('111')), 'no note under docs/evidence names 2ea31bf5, 111 and the new digest');
  const old = notes.find(n => n.f === 'k5-loop-repin/README.md');
  assert.ok(old && old.text.includes('33e7f4ec8ba899fc4aa621127379e5cb26b77648') && old.text.includes('3f99ae913cfe08c356bc0543746ae0ebf581880531081633e8d23559d0a74c2c'), 'the k5-loop-repin note history was rewritten');
  assert.ok(notes.find(n => n.f === 'extract-loop-executors/README.md'), 'older note removed');
});
