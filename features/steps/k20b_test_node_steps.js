'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { Given, When, Then } = require('@cucumber/cucumber');

const ROOT = path.resolve(__dirname, '../..');

Given('a node shim first on PATH that fails when HOME differs from the original HOME', function () {
  this.k20b = { dir: fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-k20b-')) };
  const d = this.k20b.dir;
  fs.chmodSync(d, 0o700);
  const log = path.join(d, 'shim.log');
  const q = s => "'" + s.replace(/'/g, "'\\''") + "'";
  const script = '#!/bin/sh\n' +
    'if [ "$HOME" != ' + q(process.env.HOME || '') + ' ]; then echo bad >> ' + q(log) + '; echo "node shim: no node version under this HOME" >&2; exit 99; fi\n' +
    'echo ok >> ' + q(log) + '\n' +
    'exec ' + q(process.execPath) + ' "$@"\n';
  const bin = path.join(d, 'bin');
  fs.mkdirSync(bin);
  fs.writeFileSync(path.join(bin, 'node'), script, { mode: 0o755 });
  this.k20b.bin = bin;
  this.k20b.log = log;
});

When('go test runs the untrusted-document shape test with that PATH and no KOGEN_NODE', { timeout: 290000 }, function () {
  const env = { ...process.env, PATH: this.k20b.bin + path.delimiter + (process.env.PATH || '') };
  delete env.KOGEN_NODE;
  const r = spawnSync('go', ['test', './shape', '-run', '^TestShapeDoesNotLetAnUntrustedDocumentDirectTheDecisions$', '-count=1'], {
    cwd: path.join(ROOT, 'cli'), encoding: 'utf8', timeout: 280000, maxBuffer: 8 * 1024 * 1024, env,
  });
  assert.ifError(r.error);
  this.k20b.result = r;
});

Then('the go test run passes', function () {
  const r = this.k20b.result;
  try {
    assert.equal(r.status, 0, `go test failed:\n${r.stdout}\n${r.stderr}`);
  } finally {
    if (!fs.existsSync(this.k20b.log)) fs.writeFileSync(this.k20b.log, '');
  }
});

Then('the shim was invoked at least once and never under a different HOME', function () {
  const lines = fs.readFileSync(this.k20b.log, 'utf8').split('\n').filter(Boolean);
  try {
    assert.ok(lines.includes('ok'), 'the PATH node was never resolved by the test package');
    assert.ok(!lines.includes('bad'), 'a fixture ran the shim under a different HOME');
  } finally {
    fs.rmSync(this.k20b.dir, { recursive: true, force: true });
  }
});
