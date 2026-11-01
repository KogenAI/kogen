'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const cp = require('node:child_process');
const names = ['TestAlpha', 'TestAlphaMore', 'TestParallel'];
function observe(rows, audit, calls) {
  const compiles = calls.filter(a => a[0] === 'test' && a.includes('-c'));
  assert.equal(compiles.length, 1, 'compile fixture once per pass');
  assert.ok(compiles[0].includes('-race'), 'compile with race');
  const shards = rows.filter(r => r.type === 'shard');
  assert.equal(shards.length, names.length, 'one fixed singleton shard per top-level test');
  assert.deepEqual(shards.flatMap(r => r.tests).sort(), names.slice().sort(), 'exact partition');
  for (const r of shards) {
    assert.equal(typeof r.package, 'string');
    assert.equal(r.status, 0, 'shard succeeds');
    assert.ok(Number.isFinite(r.elapsedSeconds) && r.elapsedSeconds > 0 && r.elapsedSeconds < 180, 'record shard wall time under three minutes');
  }
  assert.deepEqual(audit.slice().sort(), [...names, 'TestAlpha/child'].sort(), 'every fixture test and subtest actually executed exactly once');
}
function control(bad) {
  const rows = names.map(n => ({ type: 'shard', package: 'fixture', tests: [n], status: 0, elapsedSeconds: 0.1 }));
  const audit = [...names, 'TestAlpha/child'];
  if (bad) audit.pop();
  try { observe(rows, audit, [['test', '-c', '-race', '.']]); }
  catch { console.log('observer rejected control'); process.exitCode = 1; return; }
  console.log('observer accepted control');
}
if (require.main === module) {
  control(process.argv[2] === 'bad');
} else {
  const { When, Then } = require('@cucumber/cucumber');
  When('I run two fixture passes through the fixed race shard runner', { timeout: 115000 }, function () {
    const root = path.resolve(__dirname, '../..');
    const runner = path.join(root, 'test/race-shards.cjs');
    assert.ok(fs.existsSync(runner), 'missing test/race-shards.cjs');
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-race-fixture-'));
    this.shardResults = [];
    try {
      fs.writeFileSync(path.join(dir, 'go.mod'), 'module fixture\n\ngo 1.27.2\n');
      fs.writeFileSync(path.join(dir, 'fixture_test.go'), `package fixture
import ("testing"; "os"; "fmt")
func record(t *testing.T) { t.Helper(); f,e:=os.OpenFile(os.Getenv("SHARD_AUDIT"),os.O_APPEND|os.O_CREATE|os.O_WRONLY,0600); if e!=nil {t.Fatal(e)}; defer f.Close(); fmt.Fprintln(f,t.Name()) }
func TestAlpha(t *testing.T) { record(t); t.Run("child",record) }
func TestAlphaMore(t *testing.T) { record(t) }
func TestParallel(t *testing.T) { t.Parallel(); record(t) }
`);
      const realGo = cp.execFileSync('which', ['go'], { encoding: 'utf8' }).trim();
      const bin = path.join(dir, 'bin'); fs.mkdirSync(bin);
      const callLog = path.join(dir, 'calls');
      fs.writeFileSync(path.join(bin, 'go'), `#!${process.execPath}\nconst fs=require('node:fs'),cp=require('node:child_process');const a=process.argv.slice(2);fs.appendFileSync(${JSON.stringify(callLog)},JSON.stringify(a)+'\\n');const r=cp.spawnSync(${JSON.stringify(realGo)},a,{stdio:'inherit',env:process.env});process.exit(r.status===null?1:r.status);\n`, { mode: 0o755 });
      const started = Date.now();
      for (let pass = 0; pass < 2; pass++) {
        const audit = path.join(dir, 'audit');
        fs.writeFileSync(audit, ''); fs.writeFileSync(callLog, '');
        const r = cp.spawnSync(process.execPath, [runner, '.'], { cwd: dir, env: { ...process.env, PATH: bin + path.delimiter + process.env.PATH, SHARD_AUDIT: audit }, encoding: 'utf8', timeout: 110000 - (Date.now() - started), maxBuffer: 4 * 1024 * 1024 });
        assert.equal(r.error, undefined, `fixture runner failed: ${r.error}`);
        assert.equal(r.status, 0, `fixture runner failed: ${r.stdout}\n${r.stderr}`);
        this.shardResults.push({ rows: r.stdout.trim().split('\n').filter(Boolean).map(JSON.parse), audit: fs.readFileSync(audit, 'utf8').trim().split('\n'), calls: fs.readFileSync(callLog, 'utf8').trim().split('\n').map(JSON.parse) });
      }
      this.shardElapsed = (Date.now() - started) / 1000;
    } finally { fs.rmSync(dir, { recursive: true, force: true }); }
  });
  Then('each pass compiles once and runs the exact fixture partition with shard wall times below {int} seconds within {int} seconds total', function (shardLimit, totalLimit) {
    assert.equal(shardLimit, 180); assert.equal(totalLimit, 120);
    assert.equal(this.shardResults.length, 2);
    for (const r of this.shardResults) observe(r.rows, r.audit, r.calls);
    assert.ok(this.shardElapsed < totalLimit, 'fixture acceptance exceeds approval limit');
  });
}
