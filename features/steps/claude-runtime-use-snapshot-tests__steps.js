'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const slug = 'claude-runtime-use-snapshot-tests';
const root = path.resolve(__dirname, '../..');
const cli = path.join(root, 'cli');
const pkg = './internal/claudecode';
const pkgDir = path.join(cli, pkg);
const testPath = 'cli/internal/claudecode/update_test.go';
const usesBody = /^(func Uses\(\) \[\]RuntimeUse \{\n)[\s\S]*?^\}/m;
const snapshot = 'got := append([]RuntimeUse(nil), uses...)';

const mutations = {
  history: {
    'returning only the latest entry': 'if len(uses) == 0 { return nil }; return []RuntimeUse{uses[len(uses)-1]}',
    'reversing the entries': `${snapshot}; for i, j := 0, len(got)-1; i < j; i, j = i+1, j-1 { got[i], got[j] = got[j], got[i] }; return got`,
    ...Object.fromEntries(['Role', 'Version', 'Source', 'Path'].map(field => [
      `dropping ${field}`, `${snapshot}; for i := range got { got[i].${field} = "" }; return got`,
    ])),
  },
  overwrite: { 'returning the internal slice': 'return uses' },
  append: {
    // A plain append cannot extend another slice header. This buggy reusable view
    // restores the real prefix on each read but mistakes a caller-written tail for
    // a recorded entry. It isolates the append assertion from the overwrite one.
    'reporting a caller append as a role start': `
      n := len(uses)
      if len(kogenUsesView) != n+1 { kogenUsesView = make([]RuntimeUse, n+1) }
      copy(kogenUsesView, uses)
      if kogenUsesView[n] != (RuntimeUse{}) {
        got := append([]RuntimeUse(nil), kogenUsesView...)
        kogenUsesView[n] = RuntimeUse{}
        return got
      }
      return kogenUsesView[:n]
    `,
  },
};

function runPackage({ testBody, category, mutation } = {}) {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'claude-uses-'));
  try {
    const binary = path.join(tmp, 'claudecode.test');
    const args = ['test', '-trimpath', '-c', '-o', binary];
    const replacements = {};
    function overlay(name, body) {
      const file = path.join(tmp, name);
      fs.writeFileSync(file, body);
      replacements[path.join(pkgDir, name)] = file;
    }
    if (testBody !== undefined) overlay('update_test.go', testBody);
    if (mutation) {
      const source = fs.readFileSync(path.join(pkgDir, 'update.go'), 'utf8');
      assert.match(source, usesBody, 'Expected the Uses declaration in update.go');
      overlay('update.go', source.replace(usesBody, (_, declaration) =>
        `${declaration}\tusesMu.Lock()\n\tdefer usesMu.Unlock()\n\t${mutation}\n}`) +
        (category === 'append' ? '\nvar kogenUsesView []RuntimeUse\n' : ''));
    }
    if (Object.keys(replacements).length) {
      const overlayFile = path.join(tmp, 'overlay.json');
      fs.writeFileSync(overlayFile, JSON.stringify({ Replace: replacements }));
      args.push('-overlay', overlayFile);
    }
    args.push(pkg);
    const build = spawnSync('go', args, { cwd: cli, encoding: 'utf8', timeout: mutation ? 12000 : 85000 });
    if (build.error) throw build.error;
    assert.equal(build.status, 0, `Could not build ${pkg} tests:\n${build.stdout}${build.stderr}`);
    const run = spawnSync(binary, [], { cwd: pkgDir, encoding: 'utf8', timeout: 5000 });
    if (run.error) throw run.error;
    return { status: run.status, out: run.stdout + run.stderr };
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
}

function passed({ status, out }) {
  return status === 0 && /^PASS$/m.test(out);
}

function requirePass(run) {
  assert.ok(passed(run), `Expected ${pkg} tests to pass under the real Uses (exit ${run.status}):\n${run.out}`);
}

function survivors(category, testBody) {
  return Object.entries(mutations[category]).filter(([label, mutation]) => {
    const run = runPackage({ testBody, category, mutation });
    if (passed(run)) return true;
    assert.ok(run.status === 1 && /^FAIL$/m.test(run.out) && /^\s*--- FAIL: /m.test(run.out) &&
      /^\s+update_test\.go:\d+: /m.test(run.out) && !/^panic:/m.test(run.out),
    `Expected ${pkg} to reject ${label} by an assertion in update_test.go (exit ${run.status}):\n${run.out}`);
    return false;
  }).map(([label]) => label);
}

if (require.main === module) {
  const mode = process.argv[2];
  assert.ok(mode === 'good' || mode === 'bad', 'Expected observer control good or bad');
  const controls = require(path.join(root, '.kogen/intents', slug, 'controls.json'));
  for (const [i, category] of Object.keys(mutations).entries()) {
    const testBody = (mode === 'good' ? controls.correct : controls.wrong[i]).files[testPath];
    assert.equal(typeof testBody, 'string');
    requirePass(runPackage({ testBody }));
    const missed = survivors(category, testBody);
    assert.deepEqual(missed, mode === 'good' ? [] : Object.keys(mutations[category]), category);
  }
  console.log(mode === 'good' ? 'Uses assertions caught every mutation.' : 'Incomplete Uses tests let the corresponding mutations survive.');
  process.exitCode = mode === 'good' ? 0 : 1;
} else {
  const { Given, Then } = require('@cucumber/cucumber');
  let cleanPass = false;
  Given(`${slug}: the Claude Code package tests pass with the real Uses`, { timeout: 95000 }, function () {
    if (!cleanPass) requirePass(runPackage());
    cleanPass = true;
  });
  for (const [category, sentence] of Object.entries({
    history: 'the tests require both entries in recording order with role, version, source and path intact',
    overwrite: 'the tests detect a caller overwrite changing the next Uses result',
    append: 'the tests detect a caller append appearing in the next Uses result',
  })) {
    Then(`${slug}: ${sentence}`, { timeout: 110000 }, function () {
      const missed = survivors(category);
      assert.deepEqual(missed, [], `${pkg} tests passed despite ${missed.join(', ')}; add direct Uses coverage in update_test.go`);
    });
  }
}
