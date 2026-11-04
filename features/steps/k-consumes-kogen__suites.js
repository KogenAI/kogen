'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

// Go runs with the go-test check's flags and without a workspace, so the module's own go.mod decides.
const goEnv = () => ({ ...process.env, GOFLAGS: '-trimpath', GOWORK: 'off' });

function run(command, args, cwd) {
  const r = spawnSync(command, args, { cwd, env: goEnv(), encoding: 'utf8', maxBuffer: 64 * 1024 * 1024, timeout: 540000 });
  return { status: r.status, signal: r.signal, error: r.error && r.error.message, stdout: String(r.stdout || ''), stderr: String(r.stderr || '') };
}

let helperBinary = null;
// inventory runs the helper of k-consumes-kogen__inventory.js, built once per process outside the checkout, on a module directory.
function inventory(moduleDir) {
  if (!helperBinary) {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'k-consumes-kogen-inventory-'));
    fs.writeFileSync(path.join(dir, 'main.go'), require('./k-consumes-kogen__inventory.js').source);
    fs.writeFileSync(path.join(dir, 'go.mod'), 'module kogenconsumesinventory\n\ngo 1.27\n');
    const b = run('go', ['build', '-o', path.join(dir, 'inventory'), '.'], dir);
    assert.equal(b.status, 0, `building the inventory helper failed (${b.error || b.signal || ''}):\n${b.stdout}${b.stderr}`);
    helperBinary = path.join(dir, 'inventory');
  }
  const r = run(helperBinary, [moduleDir], moduleDir);
  assert.equal(r.status, 0, `inventory of ${moduleDir} failed (${r.error || r.signal || ''}):\n${r.stdout}${r.stderr}`);
  return JSON.parse(r.stdout);
}

// problems judges an inventory report; every entry starts with its kind.
function problems(report) {
  const out = [];
  for (const e of report.errors) out.push(`error: ${e}`);
  const used = Object.keys(report.used).sort();
  const dirs = Object.keys(report.suites).sort();
  for (const p of used) if (!dirs.includes(p)) out.push(`directories: kogen's non-test code uses ${p} but consumes/${p}/ does not exist`);
  for (const d of dirs) if (!used.includes(d)) out.push(`directories: consumes/${d}/ names no dependency that kogen's non-test code uses`);
  for (const p of used) {
    const s = report.suites[p];
    if (!s) { out.push(`coverage: ${p}: no suite, so none of ${report.used[p].join(', ')} is referenced`); continue; }
    if (s.tests < 1) out.push(`coverage: consumes/${p}: no Test function`);
    for (const m of s.missing) out.push(`coverage: consumes/${p} does not reference ${m}, which kogen's non-test code uses`);
  }
  for (const d of dirs) {
    const s = report.suites[d];
    if (!s.readme) out.push(`readme: consumes/${d}/README.md does not exist`);
    else for (const m of s.readme_missing) out.push(`readme: consumes/${d}/README.md does not list \`${m}\``);
    for (const x of s.extra) out.push(`extra: consumes/${d} references ${x}, which kogen's non-test code neither uses nor names in a used signature or type`);
    for (const i of s.forbidden_imports) out.push(`isolation: consumes/${d} imports ${i}, which is neither the standard library nor a Kogen dependency`);
    for (const k of s.skips) out.push(`isolation: consumes/${d} skips a test at ${k}`);
    for (const c of s.constraints) out.push(`isolation: consumes/${d} has a build-constrained file ${c}`);
    for (const h of s.host_paths) out.push(`isolation: consumes/${d} names a host path in ${h}`);
  }
  return out;
}

// judgeGoTest reads `go test -json` events and requires each package to pass with at least one test
// and no failed or skipped test.
function judgeGoTest(output, packages) {
  const events = [];
  for (const line of output.split('\n')) {
    if (!line.startsWith('{')) continue;
    try { events.push(JSON.parse(line)); } catch { /* not an event */ }
  }
  const out = [];
  for (const pkg of packages) {
    const mine = events.filter(e => e.Package === pkg);
    const final = mine.filter(e => !e.Test && ['pass', 'fail', 'skip'].includes(e.Action)).map(e => e.Action);
    if (!final.includes('pass')) out.push(`go test: ${pkg} did not pass (package result: ${final.join(',') || 'none'})`);
    const passed = mine.filter(e => e.Test && e.Action === 'pass').length;
    if (passed < 1) out.push(`go test: ${pkg} ran no passing test`);
    for (const e of mine.filter(x => x.Test && (x.Action === 'fail' || x.Action === 'skip'))) out.push(`go test: ${pkg} ${e.Test} ${e.Action}`);
  }
  return out;
}

function goTestSuites(moduleDir, producers) {
  const mod = run('go', ['list', '-m'], moduleDir);
  assert.equal(mod.status, 0, `go list -m failed:\n${mod.stdout}${mod.stderr}`);
  const module = mod.stdout.trim();
  const packages = producers.map(p => `${module}/consumes/${p}`);
  const list = run('go', ['list', './...'], moduleDir);
  const test = run('go', ['test', '-count=1', '-json', ...producers.map(p => `./consumes/${p}`)], moduleDir);
  return { packages, list, test };
}

module.exports = { inventory, problems, judgeGoTest, goTestSuites };

if (!process.env.K_CONSUMES_KOGEN_CONTROL) {
  const { When, Then } = require('@cucumber/cucumber');
  const cli = path.resolve(__dirname, '../../cli');
  const of = (kind, all) => all.filter(p => p.startsWith(`${kind}: `));
  const column = table => table.raw().map(row => row[0]);

  When('k-consumes-kogen: I run go test in cli on the consumes suites of', { timeout: 600000 }, function (table) {
    this.kck = { producers: column(table), ...goTestSuites(cli, column(table)) };
  });
  Then('k-consumes-kogen: kogen\'s normal Go test command in cli lists every one of those suites', function () {
    const { list, packages } = this.kck;
    assert.equal(list.status, 0, `go list ./... failed:\n${list.stdout}${list.stderr}`);
    const listed = list.stdout.split('\n').map(l => l.trim());
    const absent = packages.filter(p => !listed.includes(p));
    assert.deepEqual(absent, [], `go list ./... in cli does not list ${absent.join(', ')}:\n${list.stdout}`);
  });
  Then('k-consumes-kogen: every one of those suites passes with at least one test and no failed or skipped test', function () {
    const { test, packages } = this.kck;
    const found = judgeGoTest(test.stdout, packages);
    assert.deepEqual(found, [], `go test -count=1 -json ./consumes/... exited ${test.status}:\n${found.join('\n')}\n${test.stderr}${test.stdout.slice(-20000)}`);
    assert.equal(test.status, 0, `go test exited ${test.status} (${test.error || test.signal || ''}):\n${test.stderr}`);
  });

  When('k-consumes-kogen: I take the dependency inventory of kogen\'s non-test code and its consumes suites', { timeout: 600000 }, function () {
    this.kci = inventory(cli);
    this.kcp = problems(this.kci);
    assert.deepEqual(of('error', this.kcp), [], 'the inventory could not type-check every package');
  });
  Then('k-consumes-kogen: kogen\'s non-test code uses exactly these Kogen dependencies', function (table) {
    assert.deepEqual(Object.keys(this.kci.used).sort(), column(table).sort());
  });
  Then('k-consumes-kogen: kogen\'s non-test code uses exactly these identifiers of {string}', function (producer, table) {
    assert.deepEqual(this.kci.used[producer], column(table));
  });
  for (const [kind, sentence] of [
    ['directories', 'the consumes directories are exactly the dependencies kogen\'s non-test code uses'],
    ['coverage', 'every identifier kogen\'s non-test code uses from a dependency is referenced in that dependency\'s consumes suite'],
    ['readme', 'every consumes suite README lists every identifier kogen\'s non-test code uses from its dependency'],
    ['extra', 'every consumes suite references only what kogen\'s non-test code uses from its dependency'],
    ['isolation', 'every consumes suite imports only the standard library and Kogen dependencies and has no skip, build constraint or host path'],
  ]) {
    Then(`k-consumes-kogen: ${sentence}`, function () {
      const found = of(kind, this.kcp);
      assert.deepEqual(found, [], found.join('\n'));
    });
  }
}
