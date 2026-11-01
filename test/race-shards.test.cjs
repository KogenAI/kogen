'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const cp = require('node:child_process');
const { partition } = require('./race-shards.cjs');
const runner = path.join(__dirname, 'race-shards.cjs');

test('partition sorts singleton names and anchors escaped expressions', () => {
  const shards = partition(['TestAB', 'TestA', 'ExampleX.y']);
  assert.deepEqual(shards.map(s => s.name), ['ExampleX.y', 'TestA', 'TestAB']);
  assert.deepEqual(shards.map(s => s.run), ['^ExampleX\\.y$', '^TestA$', '^TestAB$']);
  assert.equal(partition([]).length, 0);
});

test('real race packages preserve execution, timeout, vet and failures', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'race-runner-test-'));
  const write = (name, text) => { const file = path.join(dir, name); fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, text); };
  const run = (...patterns) => cp.spawnSync(process.execPath, [runner, ...patterns], { cwd: dir, encoding: 'utf8' });
  try {
    write('go.mod', 'module example.test/fixture\n\ngo 1.27\n');
    write('empty/empty.go', 'package empty\n');
    write('raceonly/race_test.go', '//go:build race\n\npackage raceonly\nimport ("testing"; "os")\nfunc TestRaceOnly(t *testing.T) { os.WriteFile("race-ran", []byte("yes"), 0600) }\n');
    write('good/good_test.go', `package good
import ("testing"; "time"; "os"; "fmt")
func TestOne(t *testing.T) { d,ok:=t.Deadline(); if !ok || time.Until(d)<9*time.Minute || time.Until(d)>10*time.Minute { t.Fatal("timeout",d,ok) }; if _,err:=os.Stat("marker"); err!=nil { t.Fatal(err) }; t.Run("sub",func(t *testing.T){}) }
func TestOneMore(t *testing.T) {}
func FuzzSeed(f *testing.F) { f.Add("seed"); f.Fuzz(func(t *testing.T, s string) { if s!="seed" { t.Fatal(s) }; if err:=os.WriteFile("fuzz-ran", []byte(s),0600); err!=nil { t.Fatal(err) } }) }
func Hello() {}
func ExampleHello() { os.WriteFile("example-ran", []byte("yes"),0600); fmt.Println("hello"); // Output: hello
}
`);
    write('good/marker', '');
    const ok = run('./empty', './good', './raceonly');
    assert.equal(ok.status, 0, ok.stderr);
    const rows = ok.stdout.trim().split('\n').map(JSON.parse);
    assert.deepEqual(rows.map(r => r.tests[0]), ['ExampleHello', 'FuzzSeed', 'TestOne', 'TestOneMore', 'TestRaceOnly']);
    assert.ok(rows.every(r => ['example.test/fixture/good', 'example.test/fixture/raceonly'].includes(r.package) && r.status === 0 && r.elapsedSeconds > 0));
    assert.equal(fs.readFileSync(path.join(dir, 'raceonly/race-ran'), 'utf8'), 'yes');
    assert.match(ok.stderr, /PASS/);
    assert.equal(fs.readFileSync(path.join(dir, 'good/fuzz-ran'), 'utf8'), 'seed');
    assert.equal(fs.readFileSync(path.join(dir, 'good/example-ran'), 'utf8'), 'yes');
    write('bad/bad_test.go', 'package bad\nimport "testing"\nfunc TestFail(t *testing.T){t.Fatal("shard failure")}\n');
    const failed = run('./bad');
    assert.notEqual(failed.status, 0);
    assert.match(failed.stderr, /shard failure/);
    const row = JSON.parse(failed.stdout.trim());
    assert.equal(row.tests[0], 'TestFail'); assert.notEqual(row.status, 0); assert.ok(row.elapsedSeconds > 0);
    write('broken/broken.go', 'package broken\nvar x = missing\n');
    const broken = run('./broken');
    assert.notEqual(broken.status, 0); assert.match(broken.stderr, /missing/);
    write('vet/vet_test.go', 'package vet\nimport ("testing"; "fmt")\nfunc TestVet(t *testing.T){fmt.Printf("%d", "wrong")}\n');
    const vet = run('./vet');
    assert.notEqual(vet.status, 0); assert.match(vet.stderr, /Printf/);
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});
