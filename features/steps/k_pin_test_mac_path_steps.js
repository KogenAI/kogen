const { Given, Then, After } = require('@cucumber/cucumber');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const scratch = [];

function resolvedScratch() {
  const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'k-pin-test-mac-path-')));
  scratch.push(dir);
  return dir;
}

Given('a temporary directory reached through a symlink', function () {
  const real = resolvedScratch();
  const link = path.join(resolvedScratch(), 'tmp-link');
  fs.symlinkSync(real, link);
  assert.ok(fs.lstatSync(link).isSymbolicLink(), `${link} is not a symlink`);
  assert.equal(fs.realpathSync(link), real);
  assert.notEqual(link, real);
  this.kPinTmp = link;
});

Given('a temporary directory with no symlink in its path', function () {
  const dir = resolvedScratch();
  assert.equal(fs.realpathSync(dir), dir, `${dir} has a symlink in its path`);
  this.kPinTmp = dir;
});

Then('the pin Go test {string} passes from that temporary directory', { timeout: 300000 }, function (name) {
  assert.match(name, /^(?:TestPinExecutableConfiguration(?:\/an_included_file_and_a_conditional_include)?|TestPinConditionalIncludeThroughSymlinkedCheckout)$/, `unsupported test ${name}`);
  assert.ok(this.kPinTmp, `no temporary directory prepared for ${name}`);
  const pattern = name.split('/').map(part => `^${part}$`).join('/');
  const args = ['test', '-count=1', '-json', './git', '-run', pattern];
  // GOTMPDIR would move t.TempDir away from TMPDIR, hiding the directory under test.
  const env = { ...process.env, TMPDIR: this.kPinTmp };
  delete env.GOTMPDIR;
  const result = spawnSync('go', args, { cwd: 'cli', env, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  const output = (result.stdout || '') + (result.stderr || '');
  const diagnostic = `required test ${name}; command: cd cli && env -u GOTMPDIR TMPDIR=${this.kPinTmp} go ${args.join(' ')}; status=${result.status}; error=${result.error || ''}\n${output}`;
  assert.equal(result.status, 0, `test ${name} failed: ${diagnostic}`);
  const events = (result.stdout || '').split('\n').filter(line => line.startsWith('{')).map(line => JSON.parse(line));
  assert.ok(events.some(e => e.Test === name && e.Action === 'run'), `test ${name} was absent or ran zero times: ${diagnostic}`);
  assert.ok(events.some(e => e.Test === name && e.Action === 'pass'), `test ${name} was skipped or did not pass: ${diagnostic}`);
});

After(function () { while (scratch.length) fs.rmSync(scratch.pop(), { recursive: true, force: true }); });
