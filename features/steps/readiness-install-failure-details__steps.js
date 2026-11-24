'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { Given, When, Then, After, AfterAll } = require('@cucumber/cucumber');
const observe = require('./readiness-install-failure-details__driver/observe.cjs');
const prefix = 'readiness-install-failure-details: ';
const root = path.resolve(__dirname, '../..');
let buildDir;
let binary;
function run(command, args, cwd) {
  const r = spawnSync(command, args, { cwd, encoding: 'utf8', timeout: 100000, maxBuffer: 4 * 1024 * 1024 });
  assert.ifError(r.error);
  assert.equal(r.status, 0, `${command} ${args.join(' ')}: ${r.stdout}\n${r.stderr}`);
  return r.stdout;
}
Given(prefix + 'configured version commands have outcomes {string}, {int}, {int}', function (node, cucumber, quint) {
  assert.ok(['missing', 'ok'].includes(node));
  this.installDir = fs.mkdtempSync(path.join(os.tmpdir(), 'install-details-'));
  this.paths = { node: path.join(this.installDir, 'a runtime'), cucumber: path.join(this.installDir, 'b modules'), quint: path.join(this.installDir, 'c script') };
  fs.mkdirSync(path.join(this.paths.cucumber, '@cucumber/cucumber/bin'), { recursive: true });
  fs.mkdirSync(path.join(this.installDir, 'home'));
  if (node === 'ok') fs.writeFileSync(this.paths.node, '#!/bin/sh\nif [ "$1" = "--version" ]; then exit 0; fi\nexec /bin/sh "$@"\n', { mode: 0o755 });
  for (const [file, status] of [[path.join(this.paths.cucumber, '@cucumber/cucumber/bin/cucumber.js'), cucumber], [this.paths.quint, quint]]) {
    fs.writeFileSync(file, `#!/bin/sh\necho PRIVATE_SUBPROCESS_OUTPUT\nexit ${status}\n`, { mode: 0o755 });
  }
});
When(prefix + 'the install report is produced through readiness', { timeout: 115000 }, function () {
  if (!binary) {
    buildDir = fs.mkdtempSync(path.join(os.tmpdir(), 'install-details-build-'));
    binary = path.join(buildDir, 'report');
    run('go', ['build', '-o', binary, path.join(__dirname, 'readiness-install-failure-details__driver/main.go')], path.join(root, 'cli'));
  }
  this.report = JSON.parse(run(binary, [this.installDir, path.join(this.installDir, 'home'), this.paths.node, this.paths.cucumber, this.paths.quint], root));
});
Then(prefix + 'the report identifies exactly these failing tools with configured paths and statuses:', function (table) {
  const expected = {};
  for (const row of table.hashes()) expected[row.tool] = Number(row.status);
  assert.deepEqual(Object.keys(expected).sort(), ['cucumber', 'node', 'quint']);
  observe(this.report, this.paths, expected);
});
After(function () { if (this.installDir) fs.rmSync(this.installDir, { recursive: true, force: true }); });
AfterAll(function () { if (buildDir) fs.rmSync(buildDir, { recursive: true, force: true }); });
