const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const cp = require('node:child_process');
const { Given, Then } = require('@cucumber/cucumber');
const root = path.resolve(__dirname, '../..');
const P = 'package-docs-list-matches-observer: ';
const COPY = /\bcp((?: docs\/\S+)+) "\$work\/docs\/"/;
const TUPLE = /^SHIPPED_DOCS = \(([^)]*)\)/m;
const SCRIPT = 'packaging/package.sh';
const OBSERVER = 'features/steps/release_archive_public_modes.py';
const TESTFILE = 'cli/package_docs_list_test.go';

function at(world, rel) { return path.join(world.pdlTree, rel); }
function copyIndex(lines) { return lines.findIndex(l => COPY.test(l) && !l.trim().startsWith('#')); }
function scriptNames(world) {
  const lines = fs.readFileSync(at(world, SCRIPT), 'utf8').split('\n');
  const i = copyIndex(lines);
  assert.ok(i >= 0, 'scratch script has no docs copy line');
  return { lines, i, names: lines[i].match(COPY)[1].trim().split(/\s+/).map(f => f.slice('docs/'.length)) };
}
function setScript(world, names) {
  const s = scriptNames(world);
  s.lines[s.i] = s.lines[s.i].replace(COPY, () => 'cp' + names.map(n => ' docs/' + n).join('') + ' "$work/docs/"');
  fs.writeFileSync(at(world, SCRIPT), s.lines.join('\n'));
}
function observerNames(world) {
  const m = fs.readFileSync(at(world, OBSERVER), 'utf8').match(TUPLE);
  assert.ok(m, 'scratch observer has no SHIPPED_DOCS tuple');
  return [...m[1].matchAll(/'([^']+)'/g)].map(x => x[1]);
}
function setObserver(world, names) {
  const text = fs.readFileSync(at(world, OBSERVER), 'utf8');
  fs.writeFileSync(at(world, OBSERVER), text.replace(TUPLE, () => 'SHIPPED_DOCS = (' + names.map(n => "'" + n + "'").join(', ') + ')'));
}

Given(P + 'a scratch tree holds the real release script, observer and docs', function () {
  const tree = fs.mkdtempSync(path.join(os.tmpdir(), 'pdl-tree-'));
  fs.mkdirSync(path.join(tree, 'cli'));
  fs.mkdirSync(path.join(tree, 'packaging'));
  fs.mkdirSync(path.join(tree, 'features/steps'), { recursive: true });
  fs.copyFileSync(path.join(root, SCRIPT), path.join(tree, SCRIPT));
  fs.copyFileSync(path.join(root, OBSERVER), path.join(tree, OBSERVER));
  fs.cpSync(path.join(root, 'docs'), path.join(tree, 'docs'), { recursive: true });
  this.pdlTree = tree;
  assert.ok(scriptNames(this).names.length > 0, 'real script copies no docs');
  assert.ok(observerNames(this).length > 0, 'real observer lists no docs');
});
Given(P + 'the scratch observer drops {string}', function (name) {
  const names = observerNames(this);
  assert.ok(names.includes(name), 'observer does not list ' + name);
  setObserver(this, names.filter(n => n !== name));
});
Given(P + 'the scratch observer adds {string}', function (name) { setObserver(this, [...observerNames(this), name]); });
Given(P + 'the scratch observer renames {string} to {string}', function (from, to) {
  const names = observerNames(this);
  assert.ok(names.includes(from), 'observer does not list ' + from);
  setObserver(this, names.map(n => (n === from ? to : n)));
});
Given(P + 'the scratch script adds {string} to its docs copy line', function (name) { setScript(this, [...scriptNames(this).names, name]); });
Given(P + 'the scratch docs folder has no {string}', function (name) { fs.rmSync(at(this, 'docs/' + name), { force: true }); });
Given(P + 'the scratch lists are reversed and repeat their first name', function () {
  const a = scriptNames(this).names;
  const b = observerNames(this);
  setScript(this, [...a].reverse().concat(a[0]));
  setObserver(this, [...b].reverse().concat(b[0]));
});
Given(P + 'the scratch script loses its docs copy line', function () {
  const s = scriptNames(this);
  s.lines.splice(s.i, 1);
  fs.writeFileSync(at(this, SCRIPT), s.lines.join('\n'));
});
Given(P + 'the scratch script gets a second docs copy line', function () {
  const s = scriptNames(this);
  s.lines.splice(s.i, 0, s.lines[s.i]);
  fs.writeFileSync(at(this, SCRIPT), s.lines.join('\n'));
});
Given(P + 'the scratch observer loses its SHIPPED_DOCS tuple', function () {
  const text = fs.readFileSync(at(this, OBSERVER), 'utf8');
  assert.ok(TUPLE.test(text), 'observer has no tuple to remove');
  fs.writeFileSync(at(this, OBSERVER), text.replace(TUPLE, () => 'OTHER = ()'));
});

let built;
function testBinary() {
  if (built) return built;
  const file = path.join(root, TESTFILE);
  assert.ok(fs.existsSync(file), TESTFILE + ' does not exist');
  const names = [...fs.readFileSync(file, 'utf8').matchAll(/^func (Test\w+)\(/gm)].map(m => m[1]);
  assert.ok(names.length > 0, TESTFILE + ' defines no Test function');
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'pdl-bin-'));
  const bin = path.join(dir, 'cli.test');
  const r = cp.spawnSync('go', ['test', '-c', '-o', bin, '.'], { cwd: path.join(root, 'cli'), encoding: 'utf8' });
  assert.equal(r.status, 0, 'go test -c failed in cli:\n' + r.stdout + r.stderr);
  built = { bin, names };
  return built;
}
function runTests(world) {
  const b = testBinary();
  const r = cp.spawnSync(b.bin, ['-test.v', '-test.run', '^(' + b.names.join('|') + ')$'], { cwd: path.join(world.pdlTree, 'cli'), encoding: 'utf8' });
  return { status: r.status, output: (r.stdout || '') + (r.stderr || '') };
}

Then(P + 'the new docs list tests pass on the scratch tree', { timeout: 110000 }, function () {
  const r = runTests(this);
  assert.equal(r.status, 0, 'tests in ' + TESTFILE + ' failed on the scratch tree:\n' + r.output);
  assert.match(r.output, /--- PASS: /, 'no test of ' + TESTFILE + ' ran:\n' + r.output);
  assert.doesNotMatch(r.output, /no tests to run/);
});
Then(P + 'the new docs list tests reject the scratch tree with {string}', { timeout: 110000 }, function (text) {
  const r = runTests(this);
  assert.notEqual(r.status, 0, 'tests in ' + TESTFILE + ' passed although the scratch tree is wrong; expected output with ' + JSON.stringify(text) + ':\n' + r.output);
  assert.match(r.output, /--- FAIL: /, 'no test of ' + TESTFILE + ' failed:\n' + r.output);
  assert.ok(r.output.includes(text), 'output lacks ' + JSON.stringify(text) + ':\n' + r.output);
});
