'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const H = require('./go_driver_support.js');
const slug = 'move-fixture';
const dir = `.kogen/intents/${slug}`;
const helper = 'features/steps/move_steps.js';
let suite;
const put = (c,p,b) => { const f=path.join(c.repo,p); fs.mkdirSync(path.dirname(f),{recursive:true}); fs.writeFileSync(f,b); };
const read = (c,p) => fs.readFileSync(path.join(c.repo,p),'utf8');
const marker = c => read(c,`.kogen/local/approvals/${slug}.json`);
const head = c => H.git(c,['rev-parse','HEAD']);
async function invoke(c,args) { return H.runKogen(c,args,{timeout:45000}); }
function ok(r) { assert.equal(r.code,0,r.out); }
function hash(r) { const m=/SHA-256: ([a-f0-9]{64})/.exec(r.out); assert.ok(m,r.out); return m[1]; }
function packageFiles() {
  return {
    [`${dir}/intent.md`]: `# Implement the move fixture

Slug: ${slug}
Model: not applicable — single file output
Acceptance:
- ${dir}/acceptance.feature
- ${helper}

Write implemented followed by a newline to app.txt.

## Decisions
- Keep the existing commands. (source: request)

## Source comparison
- addressed: request to write implemented newline to app.txt; contract outcome and acceptance.

## Tests
- app output: real file assertion (scenario)

## Feasibility
- none
`,
    [`${dir}/acceptance.feature`]: 'Feature: Move fixture\n  Scenario: Implement the output\n    Then the move output is implemented\n',
    [helper]: "const {Then}=require('@cucumber/cucumber'); const fs=require('node:fs'); const assert=require('node:assert/strict'); Then('the move output is implemented',()=>assert.equal(fs.readFileSync('app.txt','utf8'),'implemented\\n'));\n"
  };
}
async function seed(mode) {
  if (!suite) suite=await H.setupSuite();
  const c=await H.project(suite,[],{stagedIntent:false});
  try {
    const pkg=packageFiles();
    const request=path.join(c.root,'request.md'); fs.writeFileSync(request,'Write implemented followed by a newline to app.txt.\n');
    c.server.script.push(H.fn('read_file',{path:'app.txt'}),H.fn('read_file',{path:'.kogen/project.yaml'}),H.fn('submit',{files:Object.entries(pkg).map(([path,content])=>({path,content}))}),H.fn('read_file',{path:'app.txt'}),H.fn('submit',{files:[{path:helper,content:pkg[helper]}]}));
    ok(await invoke(c,['intent','shape',slug,request]));
    await H.git(c,['add','-A']); await H.git(c,['commit','-qm','Commit unchanged Intent package']);
    const card=await invoke(c,['intent','approve',slug]); assert.equal(card.code,5,card.out);
    ok(await invoke(c,['intent','approve',slug,hash(card)]));
    const a=await head(c), approvalA=marker(c);
    const source=read(c,`.kogen/local/provenance/${slug}/current.json`);
    const other=path.join(c.root,'other');
    await H.git(c,['worktree','add','-q','-b','landed',other,a]);
    const bctx={...c,repo:other};
    put(bctx,'other.txt','landed parallel work\n');
    if(mode==='pass') put(bctx,'app.txt','implemented\n');
    if(mode==='conflict') put(bctx,`${dir}/intent.md`,pkg[`${dir}/intent.md`].replace('Write implemented','Write another output'));
    await H.git(bctx,['add','-A']); await H.git(bctx,['commit','-qm','Land parallel work']);
    const b=await head(bctx);
    if(mode==='switch') await H.git(c,['switch','-q','-c','moved',b]);
    else await H.git(c,['reset','--hard',b]);
    if(mode==='unsafe') fs.writeFileSync(path.join(c.repo,`.kogen/local/provenance/${slug}/current.json`),source+' ');
    return {c,pkg,a,b,approvalA,source};
  } catch(e) { await H.cleanupCase(c); throw e; }
}
async function run(mode) {
  const s=await seed(mode), {c,a,b,approvalA,pkg}=s;
  try {
    const before=await head(c), requests=c.server.providerRequests().length;
    const blocked=await invoke(c,['intent','build',slug]);
    const evidence={a,b,approvalA,blocked,afterBlocked:await head(c),requestsBefore:requests,requestsAfter:c.server.providerRequests().length,markerAfterBlocked:marker(c)};
    const card=await invoke(c,['intent','approve',slug]);
    Object.assign(evidence,{mode,card,markerAfterCard:marker(c),headAfterCard:await head(c)});
    if(['switch','reset'].includes(mode) && card.code===5) {
      const h=hash(card);
      const approved=await invoke(c,['intent','approve',slug,h]);
      evidence.approved=approved;
      evidence.approvalB=marker(c);
      evidence.unchanged=Object.entries(pkg).every(([p,v])=>read(c,p)===v);
      // The source originals remain diagnostic data; no Shape or provider request is needed to reapprove.
      evidence.requestsAfterApprove=c.server.providerRequests().length;
      if(approved.code===0) {
        c.server.script.push(H.fn('write_file',{path:'app.txt',content:'implemented\n'}),H.fn('finish',{summary:'Implemented approved output'}),H.fn('submit_review',{verdict:'approve',findings:[]}));
        evidence.build=await invoke(c,['intent','build',slug]);
        evidence.finalHead=await head(c); evidence.app=read(c,'app.txt');
        evidence.consumed=!fs.existsSync(H.approvalPath(c.repo,slug));
        evidence.reviewed=c.server.reviewRequests().length>0;
      }
    }
    assert.equal(before,b);
    return evidence;
  } finally { await H.cleanupCase(c); }
}
function observe(e,mode) {
  assert.notEqual(e.a,e.b,'fixture needs distinct Git bases');
  assert.notEqual(e.blocked.code,0,e.blocked.out);
  assert.match(e.blocked.out,/base/i,'Build must explain base mismatch');
  assert.ok(e.blocked.out.includes(`kogen intent approve ${slug}`),e.blocked.out);
  assert.equal(e.afterBlocked,e.b,'refusal must not commit');
  assert.equal(e.requestsAfter,e.requestsBefore,'stale approval must not invoke a provider');
  assert.equal(e.markerAfterBlocked,e.approvalA,'refusal must preserve approval');
  assert.equal(e.markerAfterCard,e.approvalA,'card/refusal must not approve');
  assert.equal(e.headAfterCard,e.b,'card/refusal must not commit');
  if(['switch','reset'].includes(mode)) {
    assert.equal(e.card.code,5,e.card.out);
    assert.ok(e.card.out.includes(e.a)&&e.card.out.includes(e.b),'card must identify approved and current base');
    assert.match(e.card.out,/1 fail now/,'card must show current scenario failure');
    assert.ok(e.card.out.includes('Implement the output'),e.card.out);
    const h=hash(e.card); assert.ok(e.card.out.includes(`kogen intent approve ${slug} ${h}`));
    ok(e.approved); assert.notEqual(e.approvalB,e.approvalA,'new approval must record new base');
    assert.ok(JSON.stringify(JSON.parse(e.approvalA)).includes(e.a),'A approval must record full base');
    assert.ok(JSON.stringify(JSON.parse(e.approvalB)).includes(e.b),'B approval must record full base');
    assert.equal(e.unchanged,true,'reapproval must not reshape package');
    assert.equal(e.requestsAfterApprove,e.requestsBefore,'reapproval must be offline');
    ok(e.build); assert.match(e.build.out,/landed move-fixture/);
    assert.notEqual(e.finalHead,e.b); assert.equal(e.app,'implemented\n'); assert.equal(e.reviewed,true); assert.equal(e.consumed,true);
  } else {
    assert.notEqual(e.card.code,0,e.card.out); assert.notEqual(e.card.code,5,e.card.out);
    if(mode==='pass') { assert.match(e.card.out,/pass|implemented/i); assert.ok(e.card.out.includes(`kogen intent refine ${slug}`),e.card.out); }
    if(mode==='conflict') { assert.match(e.card.out,/chang|conflict/i); assert.ok(e.card.out.includes(`kogen intent refine ${slug}`)||e.card.out.includes(`kogen intent shape ${slug}`),e.card.out); }
    if(mode==='unsafe') { assert.match(e.card.out,/source_provenance_changed/); assert.match(e.card.out,/restore/i); assert.ok(e.card.out.includes(`kogen intent approve ${slug}`),e.card.out); }
  }
}
// Observer-only controls: structured CLI transcripts, not claimed product qualification.
// Each bad control independently damages a later lifecycle predicate, so early base red cannot mask it.
function control(which) {
  const a='a'.repeat(40),b='b'.repeat(40),h='c'.repeat(64);
  const e={a,b,approvalA:JSON.stringify({base:a}),blocked:{code:1,out:`base changed; kogen intent approve ${slug}`},afterBlocked:b,requestsBefore:0,requestsAfter:0,markerAfterBlocked:JSON.stringify({base:a}),markerAfterCard:JSON.stringify({base:a}),headAfterCard:b,card:{code:5,out:`Approved base ${a}; current base ${b}\nSHA-256: ${h}\nScenarios: 1 (1 fail now)\nImplement the output\nkogen intent approve ${slug} ${h}`},approved:{code:0,out:'approved'},approvalB:JSON.stringify({base:b}),unchanged:true,requestsAfterApprove:0,build:{code:0,out:'landed move-fixture'},finalHead:'d'.repeat(40),app:'implemented\n',reviewed:true,consumed:true};
  observe(e,'reset');
  if(which==='good') return;
  for(const [key,value] of [['requestsAfter',1],['markerAfterCard','changed'],['unchanged',false],['requestsAfterApprove',1],['reviewed',false],['consumed',false],['app','baseline\n'],['finalHead',b],['approvalB',JSON.stringify({base:a})],['card',{code:5,out:e.card.out.replace('1 fail now','1 pass now')}]]) {
    let rejected=false; try { observe({...e,[key]:value},'reset'); } catch(err) { if(!(err instanceof assert.AssertionError)) throw err; rejected=true; }
    assert.ok(rejected,`control failed to detect ${key}`);
  }
  throw new assert.AssertionError({message:'known-bad transcripts rejected'});
}
if(require.main===module) {
  try { control(process.argv[2]); process.stdout.write('accepted\n'); }
  catch(e) { if(!(e instanceof assert.AssertionError)) throw e; process.stdout.write('rejected\n'); process.exitCode=1; }
} else {
  const {When,Then,AfterAll}=require('@cucumber/cucumber');
  When('I move the approved native Intent using {string}',{timeout:110000},async function(mode){ this.rebaseEvidence=await run(mode); });
  Then('the approval rebase outcome is {string}',function(mode){observe(this.rebaseEvidence,mode);});
  AfterAll(()=>{if(suite) H.cleanupSuite(suite);});
}
