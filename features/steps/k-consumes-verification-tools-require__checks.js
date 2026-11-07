'use strict';
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const root = path.resolve(__dirname, '../..');
const cli = path.join(root, 'cli');
function fixture(text) {
  assert.match(text, /write\(install,\s*"node",\s*"#!\/bin\/sh\\nexit 0\\n",\s*(?:0755|0o755)\)/, 'TestInitReadinessNext node stand-in must retain its script and use mode 0755');
}
function command(args, env, cwd = cli) {
  const r = spawnSync('go', args, { cwd, env, encoding: 'utf8', timeout: 230000, maxBuffer: 64 * 1024 * 1024 });
  return { ...r, what: `go ${args.join(' ')} in ${cwd}`, rows: (r.stdout || '').split('\n').filter(x => x.startsWith('{')).map(x => JSON.parse(x)) };
}
function judge(r, names) {
  for (const name of names) {
    const events = r.rows.filter(x => x.Test === name);
    const result = events.filter(x => ['pass', 'fail', 'skip'].includes(x.Action)).map(x => x.Action);
    const detail = `${name}: ${r.what}; exit=${r.status}; outcome=${result.join(',') || 'absent (ran zero times)'}; error=${r.error || 'none'}\n${r.stdout || ''}${r.stderr || ''}`;
    assert.equal(events.filter(x => x.Action === 'run').length, 1, detail);
    assert.deepEqual(result, ['pass'], detail);
  }
  assert(!r.error && r.status === 0, `${names.join(', ')}: ${r.what}; exit=${r.status}; error=${r.error || 'none'}\n${r.stdout || ''}${r.stderr || ''}`);
  assert(r.rows.some(x => !x.Test && x.Action === 'pass'), `${names.join(', ')}: ${r.what}; package did not pass`);
}
function environment() {
  const env = { ...process.env, GOFLAGS: '-trimpath' };
  for (const k of ['KOGEN_ACCEPTANCE_FEATURES', 'KOGEN_ACCEPTANCE_REPORT']) delete env[k];
  return env;
}
function strictModule(dir) {
  const env = environment();
  const located = spawnSync('go', ['list', '-m', '-f', '{{.Dir}}', 'github.com/KogenAI/kogen-verification'], { cwd: cli, env, encoding: 'utf8' });
  assert.equal(located.status, 0, `locate pinned verification: ${located.stderr}`);
  const mod = path.join(dir, 'verification');
  fs.cpSync(located.stdout.trim(), mod, { recursive: true });
  const file = path.join(mod, 'verify/env.go');
  fs.chmodSync(file, 0o644);
  let text = fs.readFileSync(file, 'utf8');
  assert.equal(text.split('if !isRegular(t.Node) {').length, 2, 'strict compatibility fixture requires the inspected pinned Require condition');
  text = text.replace('if !isRegular(t.Node) {', 'if st, err := os.Stat(t.Node); err != nil || !st.Mode().IsRegular() || st.Mode().Perm()&0o111 == 0 {').replace('node is not available at ', 'node unavailable: ');
  fs.writeFileSync(file, text);
  const alternate = path.join(dir, 'contract.mod');
  fs.copyFileSync(path.join(cli, 'go.mod'), alternate);
  fs.copyFileSync(path.join(cli, 'go.sum'), path.join(dir, 'contract.sum'));
  const edited = spawnSync('go', ['mod', 'edit', `-modfile=${alternate}`, `-replace=github.com/KogenAI/kogen-verification=${mod}`, `-replace=github.com/KogenAI/kogen-loop=${path.join(cli, 'third_party/kogen-loop')}`], { cwd: cli, env, encoding: 'utf8' });
  assert.equal(edited.status, 0, `alternate module: ${edited.stderr}`);
  env.GOFLAGS += ` -modfile=${alternate}`;
  return env;
}
function controls(kind) {
  const data = JSON.parse(fs.readFileSync(path.join(root, '.kogen/intents/k-consumes-verification-tools-require/controls.json'), 'utf8'));
  const file = 'cli/init_readiness_test.go';
  fixture(data.correct.files[file]);
  const real = command(['test', '-json', '-count=1', '-run', '^TestToolsFields$', './consumes/kogen-verification'], environment());
  judge(real, ['TestToolsFields']);
  if (kind === 'good') { console.log('observer accepted'); return; }
  const rejects = f => { try { f(); return false; } catch { return true; } };
  assert(rejects(() => fixture(data.wrong[0].files[file])));
  for (const action of ['skip', 'fail']) {
    const changed = { ...real, rows: real.rows.map(x => x.Test === 'TestToolsFields' && x.Action === 'pass' ? { ...x, Action: action } : x) };
    assert(rejects(() => judge(changed, ['TestToolsFields'])));
  }
  assert(rejects(() => judge({ ...real, rows: [] }, ['TestToolsFields'])));
  assert(rejects(() => judge({ ...real, status: 1 }, ['TestToolsFields'])));
  console.log('observer rejected');
  process.exitCode = 1;
}
if (require.main === module && process.argv[2] === '--control') {
  controls(process.argv[3]);
} else {
  const { Then } = require('@cucumber/cucumber');
  Then('k-consumes-verification-tools-require: the existing init node fixture uses executable mode 0755', function () {
    fixture(fs.readFileSync(path.join(cli, 'init_readiness_test.go'), 'utf8'));
  });
  Then('k-consumes-verification-tools-require: the approval and tool consumer tests retain their outcomes under both Require contracts:', { timeout: 280000 }, function (table) {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-tools-require-'));
    try {
      for (const env of [environment(), strictModule(dir)]) {
        for (const [pkg, filter, names] of table.rows()) {
          judge(command(['test', '-json', '-count=1', '-run', filter, pkg], env), names.split(','));
        }
      }
    } finally { fs.rmSync(dir, { recursive: true, force: true }); }
  });
}
