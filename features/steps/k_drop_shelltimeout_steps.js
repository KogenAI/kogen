'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { When, Then } = require('@cucumber/cucumber');
const root = path.resolve(__dirname, '../..');
When('shelltimeout removal checks a project containing {string} with value {string}', { timeout: 180000 }, function (key, value) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-drop-shelltimeout-'));
  try {
    const git = spawnSync('git', ['init', '-q', dir], { encoding: 'utf8' });
    assert.equal(git.status, 0, git.stdout + git.stderr);
    fs.mkdirSync(path.join(dir, '.kogen'));
    fs.writeFileSync(path.join(dir, '.kogen/project.yaml'), fs.readFileSync(path.join(root, '.kogen/project.yaml'), 'utf8') + `\n${key}: ${value}\n`);
    const r = spawnSync('go', ['run', '.', 'doctor', '--quick', '--project', dir], { cwd: path.join(root, 'cli'), encoding: 'utf8', timeout: 150000, maxBuffer: 8388608 });
    assert.ifError(r.error);
    this.shelltimeoutDiagnostics = r.stdout + r.stderr;
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
Then('shelltimeout removal diagnostics contain {string}', function (expected) {
  assert.ok(this.shelltimeoutDiagnostics.includes(expected), this.shelltimeoutDiagnostics);
});
When('shelltimeout removal collects active option references', function () {
  const hits = [];
  const key = ['tool', 'shell', 'timeout', 'seconds'].join('_');
  function walk(relative) {
    for (const ent of fs.readdirSync(path.join(root, relative), { withFileTypes: true })) {
      const p = relative + '/' + ent.name;
      if (p === 'cli/third_party') continue;
      if (ent.isDirectory()) walk(p);
      else if (ent.isFile() && /\.(go|js|md|feature)$/.test(p) && fs.readFileSync(path.join(root, p), 'utf8').includes(key)) hits.push(p);
    }
  }
  for (const dir of ['cli', 'spec', 'docs', 'test/acceptance']) walk(dir);
  this.shelltimeoutReferences = hits.sort();
});
Then('shelltimeout removal reference paths are {string}', function (expected) {
  assert.deepEqual(this.shelltimeoutReferences, JSON.parse(expected));
});
