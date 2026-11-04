const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const assert = require('node:assert/strict');
const root = path.resolve(__dirname, '../..');
function run(cwd, command, args) {
  const r = spawnSync(command, args, { cwd, encoding: 'utf8', env: { ...process.env, GOFLAGS: '-trimpath' }, timeout: 100000, maxBuffer: 16 * 1024 * 1024 });
  if (r.error || r.status !== 0) throw new Error(`${command} ${args.join(' ')}: ${r.error || r.status}\n${r.stdout}\n${r.stderr}`);
  return r.stdout;
}
function observe(cwd, name, expected) {
  const args = ['test', '-json', '-count=1', '-run', `^${name}$`, '.'];
  const r = spawnSync('go', args, { cwd: path.join(cwd, 'cli'), encoding: 'utf8', env: { ...process.env, GOFLAGS: '-trimpath' }, timeout: 100000, maxBuffer: 16 * 1024 * 1024 });
  const diagnostic = `${name}: go ${args.join(' ')} in cli; exit=${r.status}, error=${r.error || 'none'}\n${r.stdout}\n${r.stderr}`;
  let rows;
  try { rows = r.stdout.split('\n').filter(Boolean).map(x => JSON.parse(x)); } catch { throw new Error(diagnostic); }
  assert(!r.error, diagnostic);
  assert.equal(rows.filter(x => x.Test === name && x.Action === 'run').length, 1, `${name}: absent or zero runs; ${diagnostic}`);
  assert.equal(rows.filter(x => x.Test === name && x.Action === expected).length, 1, `${name}: absent, skipped or wrong outcome; ${diagnostic}`);
  assert.equal(r.status, expected === 'pass' ? 0 : 1, diagnostic);
  return rows.filter(x => x.Test === name && x.Action === 'output').map(x => x.Output).join('');
}
function copy() {
  const dest = fs.mkdtempSync(path.join(os.tmpdir(), 'adoption-pins-'));
  run(root, 'sh', ['-c', 'tar -cf - --exclude=node_modules LICENSE NOTICE cli packaging docs test/acceptance/fixtures/claude | tar -xf - -C "$1"', 'sh', dest]);
  return dest;
}
function injectBuildPin(dest, version) {
  const f = path.join(dest, 'packaging/package.sh');
  const text = fs.readFileSync(f, 'utf8');
  fs.writeFileSync(f, text.replace(/\n/, `\n(cd "$(dirname "$0")/../cli" && go get github.com/KogenAI/kogen-build@${version}) >&2\n`));
}
async function check(kind, value, expected) {
  const dest = copy();
  try {
    if (kind === 'loop') {
      const checkout = path.join(dest, 'loop-checkout');
      run(dest, 'git', ['clone', '-q', 'https://github.com/KogenAI/kogen-loop.git', checkout]);
      run(checkout, 'git', ['checkout', '-q', value]);
      run(dest, 'sh', ['packaging/sync-kogen-loop.sh', checkout]);
      observe(dest, 'TestResearchRemovalDefaults', expected);
    } else {
      if (kind === 'pin') run(path.join(dest, 'cli'), 'go', ['get', `github.com/KogenAI/kogen-build@${value}`]);
      if (kind === 'mismatch') injectBuildPin(dest, value);
      if (kind === 'replacement') run(path.join(dest, 'cli'), 'go', ['mod', 'edit', `-replace=github.com/KogenAI/kogen-build=github.com/KogenAI/kogen-build@${value}`]);
      const output = observe(dest, 'TestAssemblyUsesThePinnedComponents', expected);
      if (expected === 'fail') assert.match(output, /github\.com\/KogenAI\/kogen-build/, 'TestAssemblyUsesThePinnedComponents: failure must identify the mismatched/replaced component');
    }
  } finally { fs.rmSync(dest, { recursive: true, force: true }); }
}
if (require.main === module && process.argv[2] === '--control') {
  try {
    observe(root, process.argv[3] === 'good' ? 'TestResearchRemovalDefaults' : 'AdoptionNoSuchTest', 'pass');
    console.log('observer accepted');
  } catch { console.log('observer rejected'); process.exitCode = 1; }
} else {
  const { Then, setDefaultTimeout } = require('@cucumber/cucumber');
  setDefaultTimeout(115000);
  Then('k-adoption-tests-follow-pins: assembly with {word} {string} must {word}', async function (kind, value, expected) { await check(kind, value, expected); });
  Then('k-adoption-tests-follow-pins: research defaults with loop {string} must {word}', async function (revision, expected) { await check('loop', revision, expected); });
}
