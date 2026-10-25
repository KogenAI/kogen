'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const H = require('./go_driver_support');
const {isDeepStrictEqual: same} = require('node:util');
const CONTROL = {headers:['accept','authorization','connection','content-length','content-type','conversation_id','host','session_id'],authorization:'Bearer fake-integration-access-token',route:'/v1/responses',model:'gpt-6.1-sol',build_effort:'medium',other_effort:'high',include:['reasoning.encrypted_content'],forbidden:['prompt_cache_options','prompt_cache_retention','previous_response_id','conversation'],exits:[5,5,0,4,0]};
const expectedReplay = tag => [
  {type:'reasoning',id:'rs_'+tag,encrypted_content:'OPAQUE_'+tag,summary:[]},
  {type:'message',id:'msg_'+tag,role:'assistant',phase:'commentary',content:[{type:'output_text',text:'Inspect '+tag}]},
  {type:'function_call',id:'fc_'+tag,call_id:'call_'+tag,name:'read_file',arguments:JSON.stringify({path:tag==='build'||tag==='review'?'app.txt':'README.md'})}
];
function seed(tag) { return {items:expectedReplay(tag)}; }
function bool(f) { try { f(); return true; } catch { return false; } }
function headers(r,id,c) {
  assert.equal(typeof id,'string');assert.ok(id.length>0&&id.length<=64);
  assert.equal(r.headers.session_id,id);assert.equal(r.headers.conversation_id,id);
  assert.deepEqual(Object.keys(r.headers).sort(),c.headers);
  assert.equal(r.headers.authorization,c.authorization);assert.equal(r.headers.accept,'text/event-stream');
  assert.equal(r.headers['content-type'],'application/json');assert.equal(r.path,c.route);
}
function journal(x,c) {
  const groups = ['shape','cold','refine','build','review'].map(g=>x.records.filter(r=>r.group===g));
  const keys = groups.map(rs=>rs[0]?.json.prompt_cache_key);
  return {
    headers: bool(()=>{for(const r of x.records)headers(r,r.json.prompt_cache_key,c);}),
    stable: groups.every(rs=>rs.length>=2&&rs.every(r=>r.json.prompt_cache_key===rs[0].json.prompt_cache_key&&same(r.json.tools,rs[0].json.tools)&&r.json.instructions===rs[0].json.instructions)),
    isolated: keys.every(Boolean)&&new Set(keys).size===5,
    wire: x.records.every(r=>r.json.model===c.model&&r.json.reasoning.effort===(r.group==='build'?c.build_effort:c.other_effort)&&r.json.store===false&&r.json.stream===true&&same(r.json.include,c.include)&&!c.forbidden.some(k=>k in r.json)&&!JSON.stringify(r.json).includes('prompt_cache_breakpoint')),
    replay: groups.every((rs,i)=>{const tag=['shape','cold','refine','build','review'][i],want=expectedReplay(tag);return rs.some(r=>{const input=r.json.input,at=input.findIndex(z=>z.id==='rs_'+tag);return at>=0&&same(input.slice(at,at+3),want)&&input[at+3]?.type==='function_call_output'&&input[at+3]?.call_id==='call_'+tag&&typeof input[at+3]?.output==='string'&&input[at+3].output.includes(tag==='build'?'baseline':tag==='review'?'candidate':'Fixture project');});}),
    reset: x.resets>0&&groups[0].length>=42,
    retry_resume: groups[3].length===5&&groups[3][0].body===groups[3][1].body&&groups[3][2].body===groups[3][3].body,
    independent: groups[4].length>=2&&!JSON.stringify(groups[4][0].json.input).includes('OPAQUE_build'),
    authority: same(x.exits,c.exits)&&x.commits===1&&x.app==='candidate\n'&&!x.approval&&x.trace.includes('setup')&&x.trace.includes('check')
  };
}
async function nativeJourney() {
  const suite=await H.setupSuite(); let ctx;
  try {
    ctx=await H.project(suite,[],{stagedIntent:false});const c=ctx;
    const trace=path.join(c.root,'trace');fs.writeFileSync(trace,'');
    H.configure(c,{setup:[`printf setup >> '${trace}'`],checks:[{name:'fixture',run:`printf check >> '${trace}'; test -s app.txt`}]});
    fs.writeFileSync(path.join(c.repo,'padding.txt'),'P'.repeat(16000));
    await H.git(c,['add','-A']);await H.git(c,['commit','-qm','Seed affinity fixture']);
    const records=[],exits=[];
    const capture=(from,group)=>{for(const r of c.server.providerRequests().slice(from))records.push({...r,group});};
    async function call(args,script,group){c.server.setScript(script);const n=c.server.providerRequests().length;const r=await H.runKogen(c,args);capture(n,group);return r;}
    const question=H.fn('submit',{questions:[{question:'Preserve fixture?',options:[{label:'Preserve',recommended:true}]}]});
    const request=path.join(c.root,'request.md');fs.writeFileSync(request,'Preserve fixture text.');
    let r=await call(['intent','shape','affinity-shape',request],[seed('shape'),...Array.from({length:40},()=>H.fn('read_file',{path:'padding.txt'})),question],'shape');exits.push(r.code);assert.equal(r.code,5,r.out);
    r=await call(['intent','shape','affinity-cold',request],[seed('cold'),question],'cold');exits.push(r.code);assert.equal(r.code,5,r.out);
    const approved=await H.approve(c);
    const correction=path.join(c.root,'correction.md');fs.writeFileSync(correction,'Rename the feature to Affinity fixture, preserving steps and behavior.');
    const ft=H.featurePath('fixture'),feature=fs.readFileSync(path.join(c.repo,ft),'utf8').replace('Feature: Integration fixture','Feature: Affinity fixture');
    r=await call(['intent','refine','fixture',approved.hash,correction],[seed('refine'),H.fn('submit_refinement',{files:[{path:ft,content:feature}]})],'refine');exits.push(r.code);assert.equal(r.code,0,r.out);
    await H.git(c,['add','-A']);await H.git(c,['commit','-qm','Retain affinity fixture']);await H.approve(c);
    const head=await H.git(c,['rev-parse','HEAD']);
    const refusal={http:[400,{error:{type:'invalid_request_error',code:'invalid_parameter',param:'session_id',message:'synthetic session header refusal'}}]};
    r=await call(['intent','build','fixture'],[{http:[503,{error:{code:'server_error'}}]},seed('build'),refusal],'build');exits.push(r.code);assert.equal(r.code,4,r.out);
    const dirs=H.runDirs(c);assert.equal(dirs.length,1);const id=path.basename(dirs[0]);
    c.server.setScript([H.fn('write_file',{path:'app.txt',content:'candidate\n'}),H.fn('finish',{summary:'Preserve fixture'}),seed('review'),H.fn('submit_review',{verdict:'approve',findings:[]})]);
    const n=c.server.providerRequests().length;
    r=await H.runKogen(c,['intent','resume',id]);exits.push(r.code);assert.equal(r.code,0,r.out);
    let review=false;for(const req of c.server.providerRequests().slice(n)){if(req.json.tools.some(t=>t.name==='submit_review'))review=true;records.push({...req,group:review?'review':'build'});}
    const resets=H.listFiles(path.join(c.repo,'.kogen/local/shaping/affinity-shape')).filter(p=>p.endsWith('events.ndjson')).flatMap(p=>fs.readFileSync(p,'utf8').split('\n').filter(Boolean).map(JSON.parse)).filter(e=>e.event==='working_context_reset').length;
    return {records,exits,resets,commits:Number(await H.git(c,['rev-list','--count',head+'..HEAD'])),app:fs.readFileSync(path.join(c.repo,'app.txt'),'utf8'),approval:fs.existsSync(H.approvalPath(c.repo,'fixture')),trace:fs.readFileSync(trace,'utf8')};
  } finally {await H.cleanupCase(ctx);H.cleanupSuite(suite);}
}
async function compatibility(mode) {
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'chatgpt-affinity-'));
  const error=mode==='key'?{type:'invalid_request_error',code:'invalid_parameter',param:'prompt_cache_key',message:'prompt_cache_key is not supported on this model'}:{type:'invalid_request_error',code:'invalid_parameter',param:'session_id',message:'synthetic session header refusal'};
  const server=await new H.FakeProvider([{http:[400,{error}]},seed('compat'),{text:'completed'}]).start();
  try {
    const creds=path.join(dir,'.kogen/credentials');fs.mkdirSync(creds,{recursive:true});
    fs.writeFileSync(path.join(creds,'chatgpt.json'),JSON.stringify({client_id:'oaiapp_affinity_fixture',access_token:'fake-integration-access-token',refresh_token:'fake-refresh',expires_at:Math.floor(Date.now()/1000)+3600}));
    const config=path.join(dir,'config.json'),receipt=path.join(dir,'receipt.json');
    fs.writeFileSync(config,JSON.stringify({home:dir,url:`http://127.0.0.1:${server.port}`,provider:'chatgpt',model:'gpt-6.1-sol',effort:'high',mode:'refusal',authority:{policy:'COMPAT_AUTHORITY',contract:'COMPAT_CONTRACT',tool_result:'COMPAT_TOOL_RESULT'}}));
    const driver=await H.driverProgram('all_provider_cache'),r=await driver([config,receipt],{env:{KOGEN_AUTH_URL:`http://127.0.0.1:${server.port}`}});assert.equal(r.code,0,r.out);
    return {mode,records:server.providerRequests(),result:JSON.parse(fs.readFileSync(receipt,'utf8'))};
  } finally {await server.stop();fs.rmSync(dir,{recursive:true,force:true});}
}
function compat(x,c) {
  const rs=x.records,ps=x.result.rows.map(r=>r.provider);
  return {
    headers:bool(()=>{assert.equal(ps.length,rs.length);rs.forEach((r,i)=>headers(r,ps[i].conversation_id,c));}),
    requests:rs.length,outcomes:x.result.results.map(r=>r.outcome),statuses:ps.map(r=>r.cache.status),
    fallback:bool(()=>{assert.equal(rs.length,3);const b=structuredClone(rs[0].json);assert.ok(b.prompt_cache_key);delete b.prompt_cache_key;assert.deepEqual(rs[1].json,b);assert.ok(!('prompt_cache_key'in rs[2].json));assert.equal(new Set(ps.map(r=>r.conversation_id)).size,1);assert.equal(ps[0].operation_id,ps[1].operation_id);assert.notEqual(ps[1].operation_id,ps[2].operation_id);}),
    replay:bool(()=>{const b=rs[2].json.input,at=b.findIndex(r=>r.id==='rs_compat');assert.deepEqual(b.slice(at,at+3),expectedReplay('compat'));assert.equal(b[at+3].call_id,'call_compat');assert.equal(b[at+3].output,'COMPAT_TOOL_RESULT:call_compat');assert.deepEqual(rs[2].json.tools,rs[1].json.tools);assert.equal(rs[2].json.instructions,rs[1].json.instructions);}),
    accounting:bool(()=>{assert.equal(ps.length,rs.length);assert.equal(new Set(ps.map(r=>r.attempt_id)).size,rs.length);const failed=ps.filter(r=>r.outcome==='failed');assert.equal(failed.length,1);assert.equal(failed[0].usage_state,'unknown');assert.ok(Object.values(failed[0].usage).every(v=>v===null));assert.equal(failed[0].cache.applied_mode,null);assert.equal(failed[0].cache.applied_ttl,null);assert.ok(ps.every(r=>r.cache.applied_ttl===null));if(x.mode==='header'){assert.equal(rs.length,1);assert.equal(ps[0].cache.status,'requested');}else{assert.ok(ps.every(r=>r.cache.status==='unsupported'));assert.ok(ps.slice(1).every(r=>r.outcome==='completed'));}})
  };
}
function allTrue(o,keys){for(const k of keys)assert.equal(o[k],true,k+': '+JSON.stringify(o));}
async function controls(mode) {
  // Actual local CLI lifecycle/replay is the known fixture. Overlay ONLY the two
  // proposed routing headers on its recordings to qualify the observer, not the product.
  const x=await nativeJourney();for(const r of x.records){r.headers.session_id=r.json.prompt_cache_key;r.headers.conversation_id=r.json.prompt_cache_key;}
  const keys=Object.keys(journal(x,CONTROL));allTrue(journal(x,CONTROL),keys);
  const mutations=[
    y=>{delete y.records.at(-1).headers.session_id;},
    y=>{y.records.at(-1).headers.conversation_id='wrong';},
    y=>{y.records[1].json.prompt_cache_key='per-request';},
    y=>{y.records[1].json.tools.reverse();y.records[1].json.tools.push({name:'extra'});},
    y=>{y.records[0].json.prompt_cache_options={mode:'implicit'};},
    y=>{for(const r of y.records)for(const i of r.json.input)if(i.type==='reasoning')i.encrypted_content='changed';},
    y=>{y.resets=0;},y=>{y.records.find(r=>r.group==='build').body='changed';},
    y=>{y.records.find(r=>r.group==='review').json.input.push({type:'reasoning',encrypted_content:'OPAQUE_build'});},
    y=>{y.commits=0;},y=>{y.approval=true;},y=>{y.exits[2]=4;}
  ];
  for(const mutate of mutations){const y=structuredClone(x);mutate(y);assert.ok(Object.values(journal(y,CONTROL)).some(v=>v===false),'observer must reject mutation');}
  for(const kind of ['key','header']){
    const y=await compatibility(kind),ps=y.result.rows.map(r=>r.provider);y.records.forEach((r,i)=>{r.headers.session_id=ps[i].conversation_id;r.headers.conversation_id=ps[i].conversation_id;});
    allTrue(compat(y,CONTROL),kind==='key'?['headers','fallback','replay','accounting']:['headers','accounting']);
    for(const mutate of [z=>{z.records.at(-1).headers.session_id='lost';},z=>{z.result.rows[0].provider.usage.input=0;},...(kind==='key'?[z=>{z.records[2].json.prompt_cache_key='resurrected';},z=>{z.records[2].json.input.at(-1).output='changed';}]:[])]){const z=structuredClone(y);mutate(z);assert.ok(['headers','accounting',...(kind==='key'?['fallback','replay']:[])].some(k=>compat(z,CONTROL)[k]===false));}
  }
  if(mode==='bad')delete x.records.at(-1).headers.session_id;
  const ok=Object.values(journal(x,CONTROL)).every(Boolean);process.stdout.write(ok?'accepted\n':'rejected\n');process.exitCode=ok?0:1;
}
if(require.main===module){controls(process.argv[3]).catch(e=>{console.error(e.message);process.exitCode=2;});}
else {
  const {Given,When,Then}=require('@cucumber/cucumber');
  Given('the ChatGPT affinity wire expectations:',function(doc){this.affinityWire=JSON.parse(doc);});
  When('I record the ChatGPT affinity CLI lifecycle',{timeout:240000},async function(){this.affinity=journal(await nativeJourney(),this.affinityWire);});
  When('I record ChatGPT affinity compatibility {string}',{timeout:60000},async function(mode){this.affinity=compat(await compatibility(mode),this.affinityWire);});
  Then('the ChatGPT affinity observations are:',function(table){for(const[k,v]of table.raw())assert.deepEqual(this.affinity[k],JSON.parse(v),k+': '+JSON.stringify(this.affinity));});
}
