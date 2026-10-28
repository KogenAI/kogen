'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const ROOT = path.resolve(__dirname, '../..');
const decode = s => s.replaceAll('\\n', '\n');
function landed(d) {
  assert.equal(d.config_error, '', d.config_error);
  assert.equal(d.exit, 0, d.error);
  assert.equal(d.landed, true, d.error);
  assert.equal(d.continued, true, 'model did not continue after shell feedback');
}
function result(d, expected, prefix) {
  landed(d);
  if (prefix) assert.ok(d.result.startsWith(expected), JSON.stringify(d.result));
  else assert.equal(d.result, expected);
}
function interrupted(d) {
  assert.equal(d.config_error, '', d.config_error);
  assert.equal(d.exit, 130, d.error);
  assert.equal(d.landed, false);
  assert.ok(!d.result.startsWith('timed out after '));
}
function group(d) { assert.equal(d.group_absent_at_request, true, 'owned group remained at next provider request'); }
function config(d, outcome, key) {
  if (outcome === 'accepted') assert.equal(d.config_error, '');
  else { assert.notEqual(d.config_error, ''); assert.ok(d.config_error.includes(key), d.config_error); }
}
function control(kind) {
  const good = { config_error:'', exit:0, landed:true, continued:true, result:'timed out after 1s\nexit status: 143\n', group_absent_at_request:true };
  result(good, 'timed out after 1s\n', true); group(good);
  result({...good,result:'exit status: 7\nout\nerr\n'}, 'exit status: 7\nout\nerr\n', false);
  interrupted({...good,exit:130,landed:false,result:''});
  config(good,'accepted','tool_shell_timeout_seconds');
  config({...good,config_error:'tool_shell_timeout_seconds: positive integer required'},'refused','tool_shell_timeout_seconds');
  if (kind === 'good') { console.log('kshell observer accepts good fixtures'); return; }
  assert.equal(kind,'bad');
  for (const delta of [{config_error:'bad config'}, {exit:1}, {landed:false}, {continued:false}, {result:'exit status: 0\n'}]) {
    assert.throws(() => result({...good,...delta}, 'timed out after 1s\n', true));
  }
  assert.throws(() => group({...good,group_absent_at_request:false}));
  assert.throws(() => result({...good,result:'exit status: 7\nout\n'},'exit status: 7\nout\nerr\n',false));
  assert.throws(() => interrupted({...good,exit:130,landed:false}));
  assert.throws(() => config(good,'refused','tool_shell_timeout_seconds'));
  assert.throws(() => config({...good,config_error:'other key'},'refused','tool_shell_timeout_seconds'));
  console.log('kshell observer rejects bad fixtures'); process.exitCode=23;
}
if (process.argv[2] === '--control') control(process.argv[3]);
else {
  const { When, Then } = require('@cucumber/cucumber');
  function observe(mode, setting, command='') {
    const dir=fs.mkdtempSync(path.join(os.tmpdir(),'kogen-shellbound-'));
    try {
      const output=path.join(dir,'output.json'), overlay=path.join(dir,'overlay.json');
      fs.writeFileSync(overlay,JSON.stringify({Replace:{[path.join(ROOT,'cli/build/kshellbound_acceptance_test.go')]:path.join(__dirname,'kshellbound_driver.go')}}));
      const r=spawnSync('go',['test','-overlay',overlay,'./build','-run','^TestKShellboundObservation$','-count=1'],{
        cwd:path.join(ROOT,'cli'),encoding:'utf8',timeout:180000,maxBuffer:8*1024*1024,
        env:{...process.env,KSHELL_MODE:mode,KSHELL_SETTING:setting,KSHELL_COMMAND:decode(command),KSHELL_OUTPUT:output,GOWORK:'off'},
      });
      assert.ifError(r.error); assert.equal(r.status,0,r.stdout+r.stderr);
      const d=JSON.parse(fs.readFileSync(output,'utf8'));
      assert.equal(d.mode,mode);assert.equal(d.setting,setting);return d;
    } finally { fs.rmSync(dir,{recursive:true,force:true}); }
  }
  When(/^shellbound loads the setting (.+)$/, {timeout:240000}, function(value){this.kshell=observe('load',value);});
  Then('shellbound configuration is {word} naming {string}',function(outcome,key){config(this.kshell,outcome,key);});
  When('shellbound runs native {string} with setting {string} and command {string}',{timeout:240000},function(mode,setting,command){this.kshell=observe(mode,setting,command);});
  Then('shellbound lands with ordinary result {string}',function(s){result(this.kshell,decode(s),false);});
  Then('shellbound lands with result starting {string}',function(s){result(this.kshell,decode(s),true);});
  Then('shellbound advertises {string}',function(s){assert.ok(this.kshell.description.includes(s),this.kshell.description);});
  Then('shellbound observed the owned group absent at the next model request',function(){group(this.kshell);});
  Then('shellbound stops with interrupt status 130 and no timeout tool feedback',function(){interrupted(this.kshell);});
  Then('shellbound configured commands completed their three-second waits',function(){assert.equal(this.kshell.configured_completed,true);});
  Then('shellbound configuration guidance describes {string}, {string}, {string}, {string}, {string}, {string} and {string}',function(a,b,c,d,e,f,g){
    const text=fs.readFileSync(path.join(ROOT,'docs/configuration.md'),'utf8');
    const at=text.indexOf('tool_shell_timeout_seconds');assert.ok(at>=0,'missing setting documentation');
    const section=text.slice(Math.max(0,at-300),at+5000).toLowerCase();
    for(const w of [a,b,c,d,e,f,g])assert.ok(section.includes(w.toLowerCase()),'missing documented scope: '+w);
  });
  When('shellbound runs the specification and installed chapter 04 conformance',{timeout:600000},function(){
    this.kshellSpec=spawnSync('sh',['-c','(cd spec && sh check.sh) && (cd test/acceptance && npx cucumber-js --strict --tags "not @live" --require "steps/*.js" --require "support/*.js" ../../spec/features/04-building.feature)'],{cwd:ROOT,encoding:'utf8',timeout:550000,maxBuffer:16*1024*1024});
  });
  Then('shellbound conformance passes and includes caller-opt-in coverage',function(){
    assert.ifError(this.kshellSpec.error);assert.equal(this.kshellSpec.status,0,this.kshellSpec.stdout+this.kshellSpec.stderr);
    const feature=fs.readFileSync(path.join(ROOT,'spec/features/04-building.feature'),'utf8');
    assert.ok(feature.includes('tool_shell_timeout_seconds'),'chapter 04 must replay the new setting');
    assert.ok(/timed out after 1s/.test(feature),'chapter 04 must assert timeout feedback');
  });
}
