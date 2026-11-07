'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {spawnSync} = require('node:child_process');
const H = require('./go_driver_support.js');
const NEXT = 'Next: kogen intent shape <slug> <request-file>';
function observe(r, expected) {
  assert.equal(r.code, expected.exit, r.out);
  const lines = r.out.trimEnd().split('\n');
  const readiness = lines.filter(l => /^(ok|fail) (install|git|config|models) - /.test(l));
  assert.deepEqual(readiness.map(l => l.split(' - ')[0]), expected.readiness, r.out);
  assert.deepEqual(lines.filter(l => l.startsWith('Next:')), expected.next, r.out);
  if (expected.next.includes(NEXT)) assert.equal(lines.at(-1), NEXT, r.out);
  if (expected.readiness.includes('fail models')) {
    assert.match(lines.at(-1), /^  fix: kogen provider login chatgpt$/);
    assert.match(r.out, /fail models - shape: chatgpt has no stored login; build: chatgpt has no stored login; review: chatgpt has no stored login/);
  }
}
function docSuffix(doc, names, suffix) {
  for (const name of names) {
    const opening = '```' + name + '\n';
    const start = doc.indexOf(opening);
    assert.notEqual(start, -1, name);
    const body = doc.slice(start + opening.length).split('\n```')[0];
    assert.deepEqual(body.split('\n').slice(-suffix.length), suffix, name);
  }
}
if (require.main === module) {
  const e = {exit:0, readiness:['ok install','ok git','ok config','ok models'], next:[NEXT]};
  const suffix = ['ok install - <version>; node, cucumber and quint run','ok git - repository <repo>','ok config - .kogen/project.yaml is valid','ok models - shape, build, review ready',NEXT];
  const good = {code:0,out:suffix.join('\n')+'\n'};
  try {
    observe(good,e);
    observe({code:0,out:'ok install - installed\nok git - repo\nok config - valid\nfail models - shape: chatgpt has no stored login; build: chatgpt has no stored login; review: chatgpt has no stored login\n  fix: kogen provider login chatgpt\n'}, {exit:0,readiness:['ok install','ok git','ok config','fail models'],next:[]});
    for (const next of ['Next: set commands.acceptance in .kogen/project.yaml', "Next: add the project's checks to commands.checks in .kogen/project.yaml"]) observe({code:0,out:next+'\n'+suffix.slice(0,4).join('\n')+'\n'}, {...e,next:[next]});
    docSuffix('```output init\n'+suffix.join('\n')+'\n```\n```text without-chatgpt-init\n'+suffix.join('\n')+'\n```', ['output init','text without-chatgpt-init'],suffix);
    if (process.argv[2] === 'bad') observe({...good,out:good.out+NEXT+'\n'},e);
    console.log('accepted');
  } catch (_) { console.log('rejected'); process.exitCode=1; }
} else {
  const {Given,When,Then,After} = require('@cucumber/cucumber');
  const prefix = 'k-cli-init-success-names-first-intent-command: ';
  Given(prefix+'a local init fixture {string}', {timeout:240000}, async function(mode) {
    this.initSuite = await H.setupSuite();
    this.initRoot = fs.mkdtempSync(path.join(os.tmpdir(),'init-next-'));
    this.initRepo = path.join(this.initRoot,'repo'); this.initHome=path.join(this.initRoot,'home');
    fs.mkdirSync(this.initRepo); fs.mkdirSync(this.initHome);
    this.initEnv={PATH:process.env.PATH,HOME:this.initHome,GIT_CONFIG_GLOBAL:path.join(this.initHome,'.gitconfig'),GIT_CONFIG_NOSYSTEM:'1'};
    const git=(...args)=>{ const r=spawnSync('git',args,{cwd:this.initRepo,env:this.initEnv,encoding:'utf8'}); assert.equal(r.status,0,r.stderr); };
    git('init','-q','--initial-branch=main'); git('config','user.name','Init Fixture'); git('config','user.email','init@example.invalid'); git('config','commit.gpgsign','false'); git('config','core.hooksPath','/dev/null');
    fs.writeFileSync(path.join(this.initRepo,'README.md'),'# Fixture\n');
    fs.mkdirSync(path.join(this.initRepo,'.kogen'));
    const acceptance = mode==='no acceptance' ? '' : '  acceptance:\n    run: "node -e \\\"process.exit(0)\\\""\n    steps_dir: features/steps\n';
    const checks=mode==='no checks' ? '  checks: []\n' : '  checks:\n    - {name: app, run: "test -f README.md"}\n';
    fs.writeFileSync(path.join(this.initRepo,'.kogen/project.yaml'),'version: 1\ncommands:\n  setup: []\n  fix: []\n'+checks+acceptance+'protect: []\n');
    fs.writeFileSync(path.join(this.initRepo,'.kogen/models.yaml'),'models:\n  shape: {provider: chatgpt, model: gpt-6.1-sol, effort: high}\n  build: {provider: chatgpt, model: gpt-6.1-sol, effort: medium}\n  review: {provider: chatgpt, model: gpt-6.1-sol, effort: high}\n');
    git('add','.'); git('commit','-qm','baseline');
    if (mode!=='no login') H.seedCredentials({home:this.initHome});
    const check=spawnSync('/bin/sh',['-c','test -f README.md'],{cwd:this.initRepo}); assert.equal(check.status,0);
  });
  When(prefix+'init runs {int} times', {timeout:240000}, function(count) {
    this.initResults=[];
    for(let i=0;i<count;i++) {
      const r=spawnSync(this.initSuite.release,['init'],{cwd:this.initRepo,env:this.initEnv,encoding:'utf8',timeout:60000});
      assert.ifError(r.error); this.initResults.push({code:r.status,out:r.stdout,err:r.stderr});
    }
  });
  Then(prefix+'every run has this report:',function(doc){ const expected=JSON.parse(doc); for(const r of this.initResults) observe(r,expected); });
  Then(prefix+'the guide init blocks end like the real report:',function(doc){
    const r=this.initResults.at(-1); assert.equal(r.code,0,r.out+r.err);
    const suffix=r.out.trimEnd().split('\n').filter(l=>/^(ok|fail) (install|git|config|models) - |^Next:/.test(l)).map(l=>l.replace(this.initRepo,'<repo>').replace(/^ok install - .*; node, cucumber and quint run$/,'ok install - <version>; node, cucumber and quint run'));
    assert.deepEqual(suffix,doc.split('\n'));
    docSuffix(fs.readFileSync(path.resolve(__dirname,'../../docs/getting-started.md'),'utf8'),['output init','text without-chatgpt-init'],suffix);
  });
  After(function(){ if(this.initRoot) fs.rmSync(this.initRoot,{recursive:true,force:true}); if(this.initSuite) H.cleanupSuite(this.initSuite); });
}
