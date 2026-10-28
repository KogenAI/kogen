'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
function check(d, requests, outcome) {
  assert.equal(d.requests, requests);
  assert.equal(d.outcome, outcome);
  if (outcome === 'stopped') {
    assert.equal(d.exit, 1);
    assert.equal(d.head_same, true);
    assert.deepEqual(d.events.map(e => [e.role, e.limit, e.rounds]), [['build', 2, 2]]);
    assert.match(d.reason, /round/i);
    assert.match(d.reason, /2/);
  } else {
    assert.equal(d.exit, 0);
    assert.equal(d.head_same, false);
    assert.deepEqual(d.events, []);
  }
}
const driver = `package build
import (
 "encoding/json"
 "fmt"
 "os"
 "reflect"
 "testing"
)
func TestNRoundsObservation(t *testing.T) {
 e := newEnv(t)
 mode := os.Getenv("NR_MODE")
 e.prov.then(e.prov.calls("read_file", map[string]any{"path":"app.txt"}), e.prov.calls("read_file", map[string]any{"path":"app.txt"}))
 e.prov.then(landScript(e.prov)...)
 start := e.head()
 a := e.build(func(in *Input) {
  if mode == "default" { return }
  v := reflect.ValueOf(&in.Deps).Elem().FieldByName("NativeRoundLimits")
  if !v.IsValid() { t.Fatal("missing internal NativeRoundLimits setting") }
  limits := map[string]int{"build":2}
  if mode == "other-roles" { limits = map[string]int{"shape":2,"review":2} }
  v.Set(reflect.ValueOf(limits))
 })
 id := e.onlyRun()
 events := []map[string]any{}
 for _, ev := range e.events(id) { if ev["event"] == "native_round_limit" { events = append(events, ev) } }
 outcome := "landed"
 if a.exit != 0 { outcome = "stopped" }
 d := map[string]any{"requests":len(e.prov.requests()),"outcome":outcome,"exit":a.exit,"head_same":e.head()==start,"events":events,"reason":fmt.Sprint(a.err)+a.shown()}
 b, err := json.Marshal(d); if err != nil { t.Fatal(err) }
 if err := os.WriteFile(os.Getenv("NR_OUTPUT"), b, 0600); err != nil { t.Fatal(err) }
}
`;
function observe(mode) {
  const root = path.resolve(__dirname, '../..');
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'k-nrounds-'));
  try {
    const source = path.join(dir, 'driver.go');
    const overlay = path.join(dir, 'overlay.json');
    const output = path.join(dir, 'result.json');
    fs.writeFileSync(source, driver);
    fs.writeFileSync(overlay, JSON.stringify({Replace:{[path.join(root,'cli/build/nrounds_acceptance_test.go')]:source}}));
    const r = spawnSync('go', ['test','-overlay',overlay,'./build','-run','^TestNRoundsObservation$','-count=1'], {cwd:path.join(root,'cli'),encoding:'utf8',timeout:240000,maxBuffer:4194304,env:{...process.env,NR_MODE:mode,NR_OUTPUT:output}});
    assert.ifError(r.error);
    assert.equal(r.status, 0, r.stdout + r.stderr);
    return JSON.parse(fs.readFileSync(output,'utf8'));
  } finally { fs.rmSync(dir,{recursive:true,force:true}); }
}
if (require.main === module && process.argv[2] === '--control') {
  const stopped = {requests:2,outcome:'stopped',exit:1,head_same:true,events:[{role:'build',limit:2,rounds:2}],reason:'native round limit 2'};
  const landed = {requests:3,outcome:'landed',exit:0,head_same:false,events:[]};
  check(stopped,2,'stopped'); check(landed,3,'landed');
  if (process.argv[3] === 'good') console.log('observer accepted good');
  else {
    for (const mutate of [d=>d.requests=3,d=>d.exit=0,d=>d.head_same=false,d=>d.events=[],d=>d.events[0].role='review',d=>d.events[0].limit=3,d=>d.events[0].rounds=3,d=>d.reason='provider refused']) {
      const d=structuredClone(stopped); mutate(d); assert.throws(()=>check(d,2,'stopped'));
    }
    console.log('observer rejected bad'); process.exitCode=1;
  }
} else {
  const {When,Then}=require('@cucumber/cucumber');
  When('the internal round-limit Build fixture runs with mode {string}',{timeout:250000},function(mode){this.nr=observe(mode);});
  Then('the internal round-limit observation has requests {int} and outcome {string}',function(n,outcome){check(this.nr,n,outcome);});
}
