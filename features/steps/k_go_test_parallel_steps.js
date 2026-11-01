'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');
const ROOT = path.resolve(__dirname, '../..');
const fixture = `package fixture
import (
 "encoding/json"
 "fmt"
 "os"
 "path/filepath"
 "testing"
 "time"
 "kogen/testproc"
)
func note(t *testing.T, phase, tmp string) {
 t.Helper()
 b, err := json.Marshal(map[string]any{"test":t.Name(),"phase":phase,"pid":os.Getpid(),"tmp":tmp})
 if err != nil { t.Fatal(err) }
 p := filepath.Join(os.Getenv("FIXTURE_LOG"),fmt.Sprintf("%s-%s.json",t.Name(),phase))
 if _, err := os.Stat(p); err == nil { t.Fatal("duplicate body: "+p) }
 if err := os.WriteFile(p,b,0600); err != nil { t.Fatal(err) }
}
func body(t *testing.T) {
 before := os.Getenv("FIXTURE_VALUE")
 if !testproc.Isolate(t,"FIXTURE_VALUE="+t.Name()) {
  if os.Getenv("FIXTURE_VALUE") != before { t.Fatal("child changed parent environment") }
  note(t,"parent","")
  return
 }
 tmp := t.TempDir()
 t.Setenv("TMPDIR",tmp)
 t.Setenv("FIXTURE_MUTATION",t.Name())
 if os.Getenv("FIXTURE_VALUE") != t.Name() { t.Fatal("child environment missing") }
 note(t,"child",tmp)
 if t.Name() == "TestOutcome" {
  switch os.Getenv("FIXTURE_MODE") {
  case "fail": t.Fatal("isolated failure 1414")
  case "skip": t.Skip("isolated skip 3141")
  }
  t.Run("nested",func(t *testing.T) {
   pid := os.Getpid()
   if !testproc.Isolate(t,"FIXTURE_VALUE=nested") { t.Fatal("nested isolation forked") }
   if os.Getpid()!=pid || os.Getenv("FIXTURE_VALUE")!="nested" { t.Fatal("nested environment") }
  })
  if os.Getenv("FIXTURE_VALUE")!=t.Name() { t.Fatal("nested environment outlived cleanup") }
  return
 }
 deadline := time.Now().Add(10*time.Second)
 other := "TestA"
 if t.Name()==other { other="TestB" }
 for {
  if _,err := os.Stat(filepath.Join(os.Getenv("FIXTURE_LOG"),other+"-child.json")); err==nil { break }
  if time.Now().After(deadline) { t.Fatal("independent isolated tests did not overlap") }
  time.Sleep(10*time.Millisecond)
 }
 if os.Getenv("FIXTURE_MUTATION")!=t.Name() || os.Getenv("TMPDIR")!=tmp { t.Fatal("shared environment") }
}
func TestA(t *testing.T) { body(t) }
func TestB(t *testing.T) { body(t) }
func TestOutcome(t *testing.T) { body(t) }
`;
function observe(r, expected) {
 const diagnostic = `go test -race -count=1 -json -parallel=4 ./...; required TestA, TestB, TestOutcome; exit=${r.code}\n${r.output}`;
 assert.equal(r.code, expected.exit, diagnostic);
 for (const [name, outcome] of Object.entries(expected.tests)) {
  const ends = r.events.filter(e => e.Test === name && ['pass','fail','skip'].includes(e.Action));
  assert.deepEqual(ends.map(e => e.Action), [outcome], `${name}: absent, skipped, duplicated or wrong result; ${diagnostic}`);
  const child = r.records.filter(e => e.test===name && e.phase==='child');
  assert.equal(child.length,1,`${name}: child body did not run exactly once; ${diagnostic}`);
  assert.equal(child[0].alive,false,`${name}: child process survived; ${diagnostic}`);
  assert.equal(child[0].tmpExists,false,`${name}: temporary files survived; ${diagnostic}`);
 }
 const children = r.records.filter(e=>e.phase==='child');
 assert.equal(new Set(children.map(e=>e.pid)).size,3,`TestA, TestB, TestOutcome: bodies shared a process; ${diagnostic}`);
 const parents = r.records.filter(e=>e.phase==='parent');
 for(const p of parents) assert.ok(!children.some(c=>c.pid===p.pid),`${p.test}: body ran in parent; ${diagnostic}`);
 assert.ok(parents.some(p=>p.test==='TestA') && parents.some(p=>p.test==='TestB'),`TestA, TestB: parent did not return; ${diagnostic}`);
 assert.deepEqual(r.leftovers,[],`TestA, TestB, TestOutcome: leaked scratch files; ${diagnostic}`);
 if(expected.message) assert.ok(r.output.includes(expected.message),`TestOutcome: missing child diagnostic ${expected.message}; ${diagnostic}`);
}
function control(bad) {
 const expected={exit:0,tests:{TestA:'pass',TestB:'pass',TestOutcome:'pass'}};
 const good={code:0,output:'',events:Object.keys(expected.tests).map(Test=>({Test,Action:'pass'})),records:[...Object.keys(expected.tests).map((test,i)=>({test,phase:'child',pid:100+i,alive:false,tmpExists:false})),...['TestA','TestB','TestOutcome'].map(test=>({test,phase:'parent',pid:99}))],leftovers:[]};
 observe(good,expected);
 // Independent mutations reach every deeper observer even when baseline import failure masks them.
 for(const mutate of [r=>{r.events=[];},r=>{r.records[0].alive=true;},r=>{r.records[1].tmpExists=true;},r=>{r.records[1].pid=100;},r=>{r.records[3].pid=100;},r=>{r.records=r.records.filter(e=>e.phase!=='parent');},r=>{r.leftovers=['leak'];}]) {
  const r=structuredClone(good); mutate(r); assert.throws(()=>observe(r,expected));
 }
 const r=structuredClone(good);
 if(bad) r.records[2].alive=true;
 try { observe(r,expected); console.log('observer accepted good'); }
 catch { console.log('observer rejected bad'); process.exitCode=1; }
}
async function run(mode) {
 const dir=fs.mkdtempSync(path.join(os.tmpdir(),'kogen-parallel-'));
 const log=path.join(dir,'log'), tmp=path.join(dir,'tmp');
 fs.mkdirSync(log); fs.mkdirSync(tmp);
 fs.writeFileSync(path.join(dir,'go.mod'),`module fixture.invalid/parallel\n\ngo 1.27.2\n\nrequire kogen v0.0.0\nreplace kogen => ${JSON.stringify(path.join(ROOT,'cli'))}\n`);
 fs.writeFileSync(path.join(dir,'fixture_test.go'),fixture);
 const env={...process.env,GOMAXPROCS:'4',TMPDIR:tmp,FIXTURE_LOG:log,FIXTURE_MODE:mode};
 for(const key of ['KOGEN_TESTPROC','FIXTURE_VALUE','FIXTURE_MUTATION','GOTMPDIR']) delete env[key];
 let child;
 try {
  const result=await new Promise((resolve,reject)=>{
   child=spawn('go',['test','-race','-count=1','-json','-parallel=4','./...'],{cwd:dir,env,detached:true});
   let output='';
   const timer=setTimeout(()=>{try{process.kill(-child.pid,'SIGKILL');}catch{}},90000);
   child.stdout.on('data',b=>{output+=b;}); child.stderr.on('data',b=>{output+=b;});
   child.on('error',e=>{clearTimeout(timer);reject(e);});
   child.on('close',code=>{clearTimeout(timer);resolve({code,output});});
  });
  result.events=result.output.split('\n').flatMap(line=>{try{return [JSON.parse(line)];}catch{return [];}});
  result.records=fs.readdirSync(log).map(n=>JSON.parse(fs.readFileSync(path.join(log,n),'utf8'))).map(r=>{
   let alive=false;
   if(r.phase==='child') {try{process.kill(r.pid,0);alive=true;}catch{}}
   return {...r,alive,tmpExists:r.tmp ? fs.existsSync(r.tmp):false};
  });
  result.leftovers=fs.readdirSync(tmp);
  return result;
 } finally {
  if(child?.pid) {try{process.kill(-child.pid,'SIGKILL');}catch{}}
  fs.rmSync(dir,{recursive:true,force:true});
 }
}
if(require.main===module && process.argv[2]==='--control') control(process.argv[3]==='bad');
else {
 const {When,Then}=require('@cucumber/cucumber');
 When('I exercise isolated Go tests in mode {string}',{timeout:105000},async function(mode){this.parallelResult=await run(mode);});
 Then('the isolated Go test observations are:',function(raw){observe(this.parallelResult,JSON.parse(raw));});
}
