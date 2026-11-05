'use strict';
// Observes, relative to the repository root, that the tests and README table a kogen-executor review
// finding names are absent from this checkout and from the kogen-executor version cli/go.mod pins.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { Given, Then } = require('@cucumber/cucumber');

const root = path.resolve(__dirname, '../..');
const skipped = new Set(['.git', 'node_modules', '.kogen', 'dist']);

// files lists every regular file under dir whose name passes keep, skipping the folders in skipped.
function files(dir, keep) {
  const found = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      if (!skipped.has(entry.name)) found.push(...files(full, keep));
    } else if (entry.isFile() && keep(entry.name)) {
      found.push(full);
    }
  }
  return found;
}

Then('fix-k-consumes-executor: no Go test file under {string} defines {string}', function (dir, name) {
  const tests = files(path.join(root, dir), n => n.endsWith('_test.go'));
  assert.ok(tests.length > 0, `no *_test.go file found under ${dir}`);
  const definition = new RegExp(`^func ${name}\\(`, 'm');
  const defining = tests.filter(f => definition.test(fs.readFileSync(f, 'utf8'))).map(f => path.relative(root, f));
  assert.deepEqual(defining, [], `${name} is defined in ${defining.join(', ')}`);
});

Then('fix-k-consumes-executor: no Markdown file in the checkout has a table column headed {string}', function (heading) {
  const markdown = files(root, n => n.endsWith('.md'));
  assert.ok(markdown.length > 0, 'no Markdown file found');
  const hits = [];
  for (const f of markdown) {
    fs.readFileSync(f, 'utf8').split('\n').forEach((line, i) => {
      if (!/^\s*\|/.test(line)) return;
      if (line.split('|').map(c => c.trim()).includes(heading)) hits.push(`${path.relative(root, f)}:${i + 1}`);
    });
  }
  assert.deepEqual(hits, [], `a table column "${heading}" is in ${hits.join(', ')}`);
});

Given('fix-k-consumes-executor: {string} requires {string} at {string}', function (file, module, version) {
  const text = fs.readFileSync(path.join(root, file), 'utf8');
  const versions = [...text.matchAll(/^\s*(?:require\s+)?(\S+)\s+(v\S+)/gm)].filter(m => m[1] === module).map(m => m[2]);
  assert.deepEqual(versions, [version], `${file} requires ${module} at ${JSON.stringify(versions)}`);
});

Then('fix-k-consumes-executor: the module {string} that {string} resolves has no {string} directory', function (module, dir, sub) {
  const r = spawnSync('go', ['list', '-m', '-f', '{{.Dir}}', module], {
    cwd: path.join(root, dir),
    env: { ...process.env, GOFLAGS: '-trimpath', GOWORK: 'off' },
    encoding: 'utf8',
    timeout: 300000,
  });
  assert.equal(r.status, 0, `go list -m ${module} in ${dir}: ${r.error ? r.error.message : ''}${r.stderr}`);
  const moduleDir = String(r.stdout).trim();
  assert.ok(moduleDir && fs.statSync(moduleDir).isDirectory(), `go list -m ${module} gave no module directory: ${JSON.stringify(moduleDir)}`);
  assert.equal(fs.existsSync(path.join(moduleDir, sub)), false, `${module} at ${moduleDir} has ${sub}/`);
});
