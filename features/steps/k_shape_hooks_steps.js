'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const ROOT = path.resolve(__dirname, '../..');
const TEST = 'TestShapeHooksObservation';
function check(d, name) {
  assert.equal(d.round_reached, true, 'fixture must reach the Shape round');
  assert.equal(d.hook_ran, false, 'no Git hook/configured monitor may run');
  if (name) {
    assert.notEqual(d.exit, 0, 'mutating Shape must refuse');
    assert.equal(d.published, false, 'mutating Shape must not publish');
    assert.ok(d.error.toLowerCase().includes(name.toLowerCase()), `refusal must name ${name}: ${d.error}`);
  } else {
    assert.equal(d.exit, 0, d.error);
    assert.equal(d.error, '');
    assert.equal(d.published, true, 'honest Shape must publish');
  }
}
function observe(mode) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-hooks-'));
  try {
    const output = path.join(dir, 'result.json');
    const overlay = path.join(dir, 'overlay.json');
    fs.writeFileSync(overlay, JSON.stringify({ Replace: { [path.join(ROOT, 'cli/shape/hooks_acceptance_test.go')]: path.join(__dirname, 'k_shape_hooks_driver.go') } }));
    const args = ['test', '-json', '-overlay', overlay, './shape', '-run', `^${TEST}$`, '-count=1'];
    const command = `go ${args.join(' ')}`;
    const r = spawnSync('go', args, { cwd: path.join(ROOT, 'cli'), encoding: 'utf8', timeout: 240000, maxBuffer: 8 * 1024 * 1024, env: { ...process.env, KOGEN_HOOK_CASE: mode, KOGEN_HOOK_OUTPUT: output } });
    const diagnostic = `${TEST}: ${command}; exit=${r.status}; ${r.error || ''}\n${r.stdout || ''}${r.stderr || ''}`;
    assert.equal(r.status, 0, diagnostic);
    const events = r.stdout.split('\n').filter(Boolean).map(s => JSON.parse(s));
    assert.equal(events.filter(e => e.Test === TEST && e.Action === 'pass').length, 1, `${diagnostic}\n${TEST} absent, skipped or did not pass exactly once`);
    assert.ok(fs.existsSync(output), `${diagnostic}\n${TEST} produced no observation`);
    const d = JSON.parse(fs.readFileSync(output, 'utf8'));
    assert.equal(d.mode, mode, `${TEST}: ${command}; wrong observation mode`);
    return d;
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
}
function controls(kind) {
  const refused = { round_reached: true, hook_ran: false, exit: 1, published: false, error: 'changed commit-msg core.hooksPath core.fsmonitor filter.audit.clean core.sshCommand' };
  const honest = { round_reached: true, hook_ran: false, exit: 0, published: true, error: '' };
  const names = ['commit-msg', 'core.hooksPath', 'core.fsmonitor', 'filter.audit.clean', 'core.sshCommand'];
  names.forEach(n => check(refused, n));
  check(honest, '');
  if (kind === 'good') { console.log('hook observer good'); return; }
  assert.equal(kind, 'bad');
  for (const name of names) {
    for (const patch of [{ round_reached: false }, { hook_ran: true }, { exit: 0 }, { published: true }, { error: 'unrelated failure' }]) {
      assert.throws(() => check({ ...refused, ...patch }, name), `observer accepted ${JSON.stringify(patch)}`);
    }
  }
  for (const patch of [{ round_reached: false }, { hook_ran: true }, { exit: 1 }, { published: false }, { error: 'failure' }]) {
    assert.throws(() => check({ ...honest, ...patch }, ''), `observer accepted ${JSON.stringify(patch)}`);
  }
  console.log('hook observer rejected bad fixtures');
  process.exitCode = 1;
}
if (require.main === module && process.argv[2] === '--control') {
  controls(process.argv[3]);
} else {
  const { When, Then } = require('@cucumber/cucumber');
  When('the hook custody Shape fixture performs {string}', { timeout: 250000 }, function (mode) { this.hookCustody = observe(mode); });
  Then('hook custody refuses naming {string} without publishing or executing a hook', function (name) { check(this.hookCustody, name); });
  Then('hook custody publishes unchanged without executing a hook', function () { check(this.hookCustody, ''); });
}
