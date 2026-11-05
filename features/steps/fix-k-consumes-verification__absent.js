'use strict';
// Observes, relative to the repository root, that the tests and expressions a kogen-verification review
// finding names are absent from this checkout and present in the kogen-verification version cli/go.mod pins.
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

// moduleDir returns the directory of module as `go list -m` resolves it in dir.
function moduleDir(module, dir) {
  const r = spawnSync('go', ['list', '-m', '-f', '{{.Dir}}', module], {
    cwd: path.join(root, dir),
    env: { ...process.env, GOFLAGS: '-trimpath', GOWORK: 'off' },
    encoding: 'utf8',
    timeout: 300000,
  });
  assert.equal(r.status, 0, `go list -m ${module} in ${dir}: ${r.error ? r.error.message : ''}${r.stderr}`);
  const found = String(r.stdout).trim();
  assert.ok(found && fs.statSync(found).isDirectory(), `go list -m ${module} gave no module directory: ${JSON.stringify(found)}`);
  return found;
}

Then('fix-k-consumes-verification: no Go test file under {string} defines {string}', function (dir, name) {
  const tests = files(path.join(root, dir), n => n.endsWith('_test.go'));
  assert.ok(tests.length > 0, `no *_test.go file found under ${dir}`);
  const definition = new RegExp(`^func ${name}\\(`, 'm');
  const defining = tests.filter(f => definition.test(fs.readFileSync(f, 'utf8'))).map(f => path.relative(root, f));
  assert.deepEqual(defining, [], `${name} is defined in ${defining.join(', ')}`);
});

Then('fix-k-consumes-verification: no Go file under {string} contains {string}', function (dir, text) {
  const sources = files(path.join(root, dir), n => n.endsWith('.go'));
  assert.ok(sources.length > 0, `no *.go file found under ${dir}`);
  const containing = sources.filter(f => fs.readFileSync(f, 'utf8').includes(text)).map(f => path.relative(root, f));
  assert.deepEqual(containing, [], `${JSON.stringify(text)} is in ${containing.join(', ')}`);
});

Then('fix-k-consumes-verification: no Markdown file in the checkout has a table column headed {string}', function (heading) {
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

Given('fix-k-consumes-verification: {string} requires {string} at {string}', function (file, module, version) {
  const text = fs.readFileSync(path.join(root, file), 'utf8');
  const versions = [...text.matchAll(/^\s*(?:require\s+)?(\S+)\s+(v\S+)/gm)].filter(m => m[1] === module).map(m => m[2]);
  assert.deepEqual(versions, [version], `${file} requires ${module} at ${JSON.stringify(versions)}`);
});

Then('fix-k-consumes-verification: in the module {string} that {string} resolves, {string} contains {string}', function (module, dir, file, text) {
  const full = path.join(moduleDir(module, dir), file);
  assert.ok(fs.existsSync(full), `${module} has no ${file}`);
  assert.ok(fs.readFileSync(full, 'utf8').includes(text), `${module} ${file} does not contain ${JSON.stringify(text)}`);
});

Then('fix-k-consumes-verification: in the module {string} that {string} resolves, {string} does not contain {string}', function (module, dir, file, text) {
  const full = path.join(moduleDir(module, dir), file);
  assert.ok(fs.existsSync(full), `${module} has no ${file}`);
  assert.equal(fs.readFileSync(full, 'utf8').includes(text), false, `${module} ${file} contains ${JSON.stringify(text)}`);
});
