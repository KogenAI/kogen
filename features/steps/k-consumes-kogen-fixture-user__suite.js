const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');

function observe(helper, preflight, property) {
  if (property === 'identity') {
    const identity = helper.match(/f\.git\("config", "user.name", "([^"]+)"\)/);
    const title = helper.match(/const intentMD = "# ([^\\"]+)/);
    assert.ok(identity && title, 'fixture Git identity and Intent title must be observable');
    assert.ok(!title[1].toLowerCase().includes(identity[1].toLowerCase()), `fixture title ${title[1]} contains Git user.name ${identity[1]}`);
  } else {
    const beforeApproval = preflight.split('f.approve(f.card(), "")')[0];
    assert.ok(!/len\(blockers\)\s*!=\s*1|blockers\[0\]/.test(beforeApproval), 'preflight approval blocker assertion must not require singleton cardinality or index zero');
    assert.ok(beforeApproval.includes('approval_changed'), 'preflight must still assert the approval_changed blocker');
  }
}
function sources() {
  return [fs.readFileSync('cli/consumes/kogen-shaping/helper_test.go', 'utf8'), fs.readFileSync('cli/consumes/kogen-shaping/preflight_test.go', 'utf8')];
}
if (process.argv.includes('--control-good') || process.argv.includes('--control-bad')) {
  let [helper, preflight] = sources();
  // Explicit known-good source fixture and known-bad reproducer, independent of candidate state.
  helper = helper.replace(/f\.git\("config", "user.name", "[^"]+"\)/, 'f.git("config", "user.name", "Kogen Test Owner")');
  preflight = preflight.replace(' || len(blockers) != 1', '').replace('blockers[0]', 'blocker');
  if (process.argv.includes('--control-bad')) {
    helper = helper.replace('"user.name", "Kogen Test Owner"', '"user.name", "Fixture"');
    preflight = preflight.replace('if data["slug"] != slug', 'if len(blockers) != 1 || data["slug"] != slug');
  }
  let failures = 0;
  for (const property of ['identity', 'blockers']) {
    try { observe(helper, preflight, property); } catch (_) { failures++; }
  }
  console.log(`observer failures: ${failures}`);
  process.exit(failures ? 1 : 0);
} else {
  const { Then, setDefaultTimeout } = require('@cucumber/cucumber');
  const { spawnSync } = require('node:child_process');
  const os = require('node:os');
  setDefaultTimeout(110000);
  Then('k-consumes-kogen-fixture-user: the fixture title excludes its Git user name', function () {
    observe(...sources(), 'identity');
  });
  Then('k-consumes-kogen-fixture-user: the approval blocker assertion is not singleton or positional', function () {
    observe(...sources(), 'blockers');
  });
  Then('k-consumes-kogen-fixture-user: the shaping consumes suite passes with coordinator {string}', function (version) {
    const cwd = path.resolve('cli');
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-fixture-user-'));
    const mod = path.join(dir, 'check.mod');
    const run = args => {
      const result = spawnSync('go', args, { cwd, encoding: 'utf8', timeout: 100000, env: { ...process.env, GOWORK: 'off' } });
      assert.equal(result.status, 0, `go ${args.join(' ')}: ${result.error || ''}\n${result.stdout || ''}${result.stderr || ''}`);
    };
    try {
      fs.copyFileSync(path.join(cwd, 'go.mod'), mod);
      fs.copyFileSync(path.join(cwd, 'go.sum'), path.join(dir, 'check.sum'));
      if (version !== 'pinned') run(['mod', 'edit', `-modfile=${mod}`, `-require=github.com/KogenAI/kogen-coordinator@${version}`]);
      run(['test', '-mod=mod', `-modfile=${mod}`, '-count=1', './consumes/kogen-shaping/...']);
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });
}
