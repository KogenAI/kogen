const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { Given, When, Then } = require('@cucumber/cucumber');

const P = 'suite-go-layer-timeout-fits-loaded-host: ';
const repo = process.cwd();

function write(file, text, mode) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, text, { mode: mode || 0o644 });
}

// A scratch project that holds a copy of the maintained test/suite.sh and fake spec, live-helper
// and acceptance layers. The archive exists and the node dependency stamps match their manifests,
// so the suite reaches its layers without packaging or installing anything.
function scratch(world) {
  const base = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'suite-go-layer-')));
  const project = path.join(base, 'project');
  const bin = path.join(base, 'bin');
  write(path.join(project, 'test/suite.sh'), fs.readFileSync(path.join(repo, 'test/suite.sh'), 'utf8'), 0o755);
  write(path.join(project, 'archive.tar.gz'), 'archive\n');
  for (const [dir, tool] of [['spec', 'quint'], ['test/acceptance', 'cucumber-js']]) {
    const d = path.join(project, dir);
    write(path.join(d, 'package.json'), '{}\n');
    write(path.join(d, 'package-lock.json'), '{}\n');
    write(path.join(d, 'node_modules/.bin', tool), '#!/bin/sh\nexit 0\n', 0o755);
    const sum = spawnSync('shasum', ['-a', '256', 'package.json', 'package-lock.json'], { cwd: d, encoding: 'utf8' });
    assert.equal(sum.status, 0, `${P}shasum failed: ${sum.stderr}`);
    write(path.join(d, 'node_modules/.kogen-suite-manifests'), sum.stdout.replace(/\n$/, '') + '\n');
  }
  write(path.join(project, 'spec/check.sh'), 'exit 0\n');
  write(path.join(project, 'test/live/check-verify.sh'), 'exit 0\n');
  write(path.join(project, 'test/live/check-journey.sh'), 'exit 0\n');
  write(path.join(project, 'cli/.keep'), '');
  write(path.join(bin, 'npm'), '#!/bin/sh\nexit 0\n', 0o755);
  world.base = base;
  world.project = project;
  world.bin = bin;
  world.record = path.join(base, 'go-calls.txt');
}

Given(P + 'a scratch project with the maintained suite and fake spec, live-helper and acceptance layers', function () {
  scratch(this);
});

Given(P + 'a fake go executable that records its arguments and working directory and exits {int}', function (status) {
  // One block per invocation: a "call" line, the working directory, then one "arg:" line per argument.
  write(path.join(this.bin, 'go'),
    `#!/bin/sh\n{ echo call; echo "cwd:$(pwd -P)"; for a in "$@"; do printf 'arg:%s\\n' "$a"; done; } >> "${this.record}"\nexit ${status}\n`,
    0o755);
});

When(P + 'the suite is run', function () {
  const env = { ...process.env };
  env.KOGEN_ARCHIVE = path.join(this.project, 'archive.tar.gz');
  env.PATH = [this.bin, path.dirname(process.execPath), '/usr/bin', '/bin', '/usr/sbin', '/sbin'].join(path.delimiter);
  const r = spawnSync('/bin/sh', [path.join(this.project, 'test/suite.sh')], {
    cwd: this.base, env, encoding: 'utf8', timeout: 90000,
  });
  this.output = (r.stdout || '') + (r.stderr || '');
  this.status = r.status;
  this.calls = fs.existsSync(this.record)
    ? fs.readFileSync(this.record, 'utf8').split('call\n').filter(Boolean).map(block => {
      const lines = block.split('\n').filter(Boolean);
      return {
        cwd: lines.find(l => l.startsWith('cwd:')).slice(4),
        args: lines.filter(l => l.startsWith('arg:')).map(l => l.slice(4)),
      };
    })
    : [];
});

Then(P + 'go was invoked exactly once with the arguments {string}', function (expected) {
  assert.equal(this.calls.length, 1, `${P}expected exactly one go invocation, got ${this.calls.length}\n${this.output}`);
  assert.deepEqual(this.calls[0].args, expected.split(' '), `${P}go arguments\n${this.output}`);
});

Then(P + 'go ran in the cli directory of the scratch project', function () {
  assert.equal(this.calls.length, 1, `${P}expected exactly one go invocation, got ${this.calls.length}\n${this.output}`);
  assert.equal(this.calls[0].cwd, path.join(this.project, 'cli'), `${P}go working directory\n${this.output}`);
});

Then(P + 'the suite exits with status {int}', function (status) {
  assert.equal(this.status, status, `${P}suite exit status\n${this.output}`);
});

Then(P + 'the suite prints a line that starts with {string}', function (prefix) {
  const lines = this.output.split('\n');
  assert.ok(lines.some(l => l.startsWith(prefix)), `${P}no line starts with ${JSON.stringify(prefix)}\n${this.output}`);
});

Then(P + 'the suite prints no line that starts with {string}', function (prefix) {
  const lines = this.output.split('\n');
  assert.ok(!lines.some(l => l.startsWith(prefix)), `${P}a line starts with ${JSON.stringify(prefix)}\n${this.output}`);
});
