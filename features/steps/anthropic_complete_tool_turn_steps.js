'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const H = require('./go_driver_support');
const ROOT = path.resolve(__dirname, '../..');
const KEY = 'SYNTHETIC_059_PRIVATE_KEY';
const MODEL = 'claude-sonnet-5-5';
const THINK = "Need the helper's current text before editing.";
const SIGNATURE = 'c3ludGhldGljLXNpZ25hdHVyZQ==';
const put = (p, s) => { fs.mkdirSync(path.dirname(p), {recursive:true}); fs.writeFileSync(p, s); };
const tool = (id='toolu_synthetic_01', name='read_file', input={path:'lib/helper.go'}) => ({type:'tool_use', id, name, input});
const thinking = () => ({type:'thinking', thinking:THINK, signature:SIGNATURE});
const evt = (type, rest={}) => `event: ${type}\ndata: ${JSON.stringify({type,...rest})}\n\n`;
function fixture(kind) {
  const blocks = [thinking(), tool()];
  if (kind==='rich') blocks.splice(1,0,{type:'redacted_thinking',data:'SYNTHETIC_059_REDACTED'},{type:'text',text:'SYNTHETIC_059_RESPONSE_TEXT'});
  if (kind==='rich') blocks.push(tool('toolu_synthetic_00','read_file',{path:'README.md'}));
  if (kind==='text') return [{type:'text',text:'Complete local answer'}];
  if (kind==='empty') return [];
  const extra = {
    'array-input': {...tool('later'),input:[]},
    'blank-name': tool('later',' '),
    'blank-id': tool(' '),
    'invalid-name': tool('later','bad\nname'),
    'invalid-id': tool('bad\nid'),
    'duplicate-id': tool(),
    'server-tool': {type:'server_tool_use',id:'server',name:'web_search',input:{}},
    'unknown-block': {type:'unknown_action'},
    'unsigned-thinking': {type:'thinking',thinking:'unsigned'},
    'missing-redacted': {type:'redacted_thinking'},
  }[kind];
  if (extra) blocks.push(extra);
  return blocks;
}
function wire(blocks, stop, kind='one') {
  let out = evt('message_start',{message:{id:'msg_synthetic_01',type:'message',role:'assistant',model:MODEL,content:[],stop_reason:null,usage:{input_tokens:12,cache_read_input_tokens:48000,cache_creation_input_tokens:300,output_tokens:1}}});
  blocks.forEach((b,i) => {
    const index = kind==='gap' && i===1 ? 2 : i;
    const start = structuredClone(b);
    if (b.type==='tool_use') start.input={};
    if (b.type==='thinking') { start.thinking=''; start.signature=''; }
    out += evt('content_block_start',{index,content_block:start});
    if (b.type==='thinking') {
      out += evt('content_block_delta',{index,delta:{type:'thinking_delta',thinking:b.thinking}});
      if (b.signature) out += evt('content_block_delta',{index,delta:{type:'signature_delta',signature:b.signature}});
    }
    if (b.type==='tool_use') out += evt('content_block_delta',{index,delta:{type:'input_json_delta',partial_json:kind==='malformed-input' ? '{bad' : JSON.stringify(b.input)}});
    out += evt('content_block_stop',{index});
  });
  if (kind==='error-event') out += evt('error',{error:{type:'overloaded_error',message:KEY}});
  if (kind==='malformed-frame' || kind==='unreadable') out += 'data: {broken\n\n';
  if (kind==='cut' || kind==='unreadable') return out;
  out += evt('message_delta',{delta:{stop_reason:stop,stop_sequence:null},usage:{output_tokens:812}});
  if (kind==='changed-stop') out += evt('message_delta',{delta:{stop_reason:'tool_use'},usage:{output_tokens:812}});
  out += evt('message_stop');
  if (kind==='after-stop') out += evt('content_block_stop',{index:1});
  return out;
}
async function server(handle) {
  const records=[], errors=[];
  const s=http.createServer(async(req,res)=>{try{
    const chunks=[]; for await (const b of req) chunks.push(b);
    const body=JSON.parse(Buffer.concat(chunks).toString());
    const r={body,path:req.url,headers:req.headers}; records.push(r);
    const response=handle(r,records.length);
    res.writeHead(200,{'content-type':'text/event-stream'}); res.end(response);
  } catch(e) { errors.push(e.message); res.writeHead(500); res.end('{}'); }});
  await new Promise(resolve=>s.listen(0,'127.0.0.1',resolve));
  return {records,errors,url:`http://127.0.0.1:${s.address().port}`,close:()=>new Promise(resolve=>{s.closeAllConnections();s.close(resolve);})};
}
function route(records) {
  for (const r of records) {
    assert.equal(r.path,'/v1/messages');
    assert.equal(r.headers['x-api-key'],KEY);
    assert.equal(r.body.model,MODEL);
  }
}
function safe(records) {
  const raw=JSON.stringify(records);
  for (const secret of [KEY,THINK,SIGNATURE,'SYNTHETIC_059_REDACTED','SYNTHETIC_059_RESPONSE_TEXT','Complete local answer','lib/helper.go']) assert.ok(!raw.includes(secret),'payload leaked into attempt record: '+secret);
}
function replay(records,blocks,results) {
  const ms=records[1].body.messages;
  const assistants=ms.filter(m=>m.role==='assistant');
  assert.equal(assistants.length,1,'assistant must replay once');
  assert.deepEqual(assistants[0].content,blocks,'opaque ordered blocks changed');
  const at=ms.indexOf(assistants[0]);
  assert.equal(ms[at+1].role,'user');
  const actual=structuredClone(ms[at+1].content);
  // The existing cache breakpoint belongs to the newest user block, not opaque assistant blocks.
  for (const b of actual) delete b.cache_control;
  assert.deepEqual(actual,results,'tool results must be complete, grouped and in call order');
}
function observe(o,e) {
  assert.deepEqual(o.errors,[]);
  route(o.requests);
  assert.equal(o.requests.length,e.requests);
  const first=o.receipt.results[0];
  assert.equal(first.outcome,e.outcome);
  assert.equal(first.records.length,e.attempts);
  const calls=(first.items||[]).filter(x=>x.type==='function_call').map(x=>({id:x.call_id,name:x.name,input:JSON.parse(x.arguments)}));
  assert.deepEqual(calls,e.calls);
  assert.equal(first.value,e.outcome==='completed');
  for (const r of first.records) {
    assert.equal(r.anthropic_stop_reason,e.stop);
    assert.equal(r.anthropic_end_turn_tool_use,e.marker);
    assert.equal(r.outcome,e.outcome==='completed'?'completed':'failed');
  }
  safe(o.receipt.results.flatMap(r=>r.records));
  if (e.outcome!=='completed') {
    assert.equal(o.receipt.results.length,1);
    assert.equal((first.items||[]).length,0,'invalid batch exposed items');
    return;
  }
  const text=(first.items||[]).flatMap(x=>x.content||[]).filter(x=>x.type==='output_text').map(x=>x.text).join('');
  if (e.text!==undefined) assert.equal(text,e.text);
  if (!calls.length) { assert.equal(o.receipt.results.length,1); return; }
  assert.equal(o.receipt.results.length,3);
  for (const r of o.receipt.results) { assert.equal(r.outcome,'completed'); assert.equal(r.records.length,1); }
  replay(o.requests,o.blocks,calls.map(c=>({type:'tool_result',tool_use_id:c.id,content:'LOCAL_TOOL_RESULT:'+c.id})));
  assert.deepEqual(o.requests[2].body.messages,o.requests[0].body.messages,'independent conversation inherited history');
  const raw=first.items.find(x=>x.anthropic_message)?.anthropic_message;
  assert.deepEqual(raw,{role:'assistant',content:o.blocks});
}
async function transport(kind,stop) {
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'kogen-059-transport-'));
  const blocks=fixture(kind);
  const s=await server((r,n)=>{assert.ok(n<=5,'unexpected retry/fallback');return n===1 || ['cut','unreadable'].includes(kind) ? wire(blocks,stop,kind) : wire([{type:'text',text:'Followup complete'}],'end_turn','text');});
  try {
    put(path.join(dir,'.kogen/credentials/anthropic.json'),JSON.stringify({provider:'anthropic',api_key:KEY}));
    const req=path.join(dir,'request.json'),receipt=path.join(dir,'receipt.json');
    put(req,JSON.stringify({home:dir,url:s.url,provider:'anthropic',model:MODEL,effort:'medium',mode:'transport'}));
    const driver=await H.driverProgram('claude-api-key');
    const r=await driver([req,receipt]); assert.equal(r.code,0,r.out);
    return {receipt:JSON.parse(fs.readFileSync(receipt,'utf8')),requests:s.records,errors:s.errors,blocks};
  } finally { await s.close();fs.rmSync(dir,{recursive:true,force:true}); }
}
let suite;
const runner='NODE_PATH="$KOGEN_CUCUMBER" "$KOGEN_NODE" "$KOGEN_CUCUMBER/@cucumber/cucumber/bin/cucumber.js" --strict --require "features/steps/*.js" --format "message:$KOGEN_ACCEPTANCE_REPORT" "$KOGEN_ACCEPTANCE_FEATURES"';
async function build() {
  if (!suite) suite=await H.setupSuite();
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'kogen-059-build-')),repo=path.join(dir,'repo'),home=path.join(dir,'home'),trace=path.join(dir,'trace');
  fs.mkdirSync(repo);fs.mkdirSync(home);put(trace,'');
  const blocks=fixture('one'); let builds=0,reviews=0;
  const s=await server((r,n)=>{
    assert.ok(n<=4,'unexpected extra inference');
    const isReview=(r.body.tools||[]).some(t=>t.name==='submit_review');r.phase=isReview?'review':'build';
    let bs,stop='tool_use';
    if (!isReview) { builds++;if(builds===1){bs=blocks;stop='end_turn';}else {bs=[tool('write','write_file',{path:'lib/helper.go',content:'candidate\n'}),tool('finish','finish',{summary:'done'})];} }
    else {reviews++;bs=reviews===1?[tool('review_read','read_file',{path:'lib/helper.go'})]:[tool('review_approve','submit_review',{verdict:'approve',findings:[]})];}
    return wire(bs,stop);
  });
  const env={...process.env,HOME:home,GIT_CONFIG_NOSYSTEM:'1',GIT_CONFIG_GLOBAL:path.join(home,'.gitconfig'),KOGEN_PROVIDER_URL:s.url,KOGEN_AUTH_URL:s.url,KOGEN_059_TRACE:trace};
  const run=async(file,args,input)=>{const r=await H.run(file,args,{cwd:repo,env,input,timeout:180000});assert.equal(r.timed,false,r.out);return r;};
  const git=async args=>{const r=await run('git',args);assert.equal(r.code,0,r.out);return r.out;};
  const cli=(args,input)=>run(suite.release,args,input);
  try {
    put(env.GIT_CONFIG_GLOBAL,'');
    put(path.join(repo,'README.md'),'# Local KOGEN-059 fixture\n');
    put(path.join(repo,'lib/helper.go'),'baseline\n');
    put(path.join(repo,'.gitignore'),'.kogen/local/\n');
    put(path.join(repo,'.kogen/project.yaml'),`version: 1\ncommands:\n  setup: ['printf setup\\n >> "$KOGEN_059_TRACE"']\n  fix: []\n  checks:\n    - {name: fixture-check, run: 'printf check\\n >> "$KOGEN_059_TRACE"'}\n  acceptance:\n    run: '${runner}'\n    steps_dir: features/steps\nprotect: []\nmodels:\n  shape: {provider: anthropic, model: ${MODEL}, effort: medium}\n  build: {provider: anthropic, model: ${MODEL}, effort: medium}\n  review: {provider: anthropic, model: ${MODEL}, effort: medium}\nshape_workers:\n  enabled: false\n`);
    put(path.join(repo,'.kogen/intents/fixture/intent.md'),'# Update the local helper fixture\n\nSlug: fixture\nModel: not applicable — fixture text only\nAcceptance:\n- .kogen/intents/fixture/acceptance.feature\n- features/steps/fixture_steps.js\n\nChange lib/helper.go from baseline to candidate.\n\n## Decisions\n- Update fixture text (source: request)\n\n## Source comparison\n- addressed: fixture text request; scenario preserves readable fixture.\n\n## Tests\n- Fixture remains readable: local acceptance (scenario)\n\n## Feasibility\n- none\n');
    put(path.join(repo,'.kogen/intents/fixture/acceptance.feature'),'Feature: Fixture\n  Scenario: Readable fixture\n    Then the 059 fixture is readable\n');
    put(path.join(repo,'features/steps/fixture_steps.js'),`const {Then}=require('@cucumber/cucumber');const fs=require('node:fs');Then('the 059 fixture is readable',()=>{fs.appendFileSync(process.env.KOGEN_059_TRACE,'acceptance\\n');if(!['baseline\\n','candidate\\n'].includes(fs.readFileSync('lib/helper.go','utf8')))throw Error('bad fixture');});\n`);
    for (const args of [['init','-q','--initial-branch=main'],['config','user.name','Kogen Fixture'],['config','user.email','fixture@example.invalid'],['add','.'],['commit','-qm','baseline']]) await git(args);
    const login=await cli(['provider','login','anthropic'],KEY+'\n');assert.equal(login.code,0,login.out);
    const card=await cli(['intent','approve','fixture']);assert.equal(card.code,5,card.out);
    const hash=/SHA-256: ([0-9a-f]{64})/.exec(card.out)?.[1];assert.ok(hash,card.out);
    const approved=await cli(['intent','approve','fixture',hash]);assert.equal(approved.code,0,approved.out);
    const head=(await git(['rev-parse','HEAD'])).trim();put(trace,'');
    const result=await cli(['intent','build','fixture']);
    const runs=path.join(repo,'.kogen/local/runs');
    const logs=fs.existsSync(runs)?fs.readdirSync(runs).flatMap(n=>{const p=path.join(runs,n,'log.jsonl');return fs.existsSync(p)?fs.readFileSync(p,'utf8').trim().split('\n').filter(Boolean).map(JSON.parse):[];}):[];
    const records=logs.filter(x=>x.event==='provider_attempt').map(x=>x.provider);
    return {exit:result.code,diagnostic:result.out,errors:s.errors,requests:s.records,blocks,records,commits:(await git(['rev-list','--count',head+'..HEAD'])).trim(),candidate:await git(['show','HEAD:lib/helper.go']),trace:fs.readFileSync(trace,'utf8'),approval_consumed:!fs.existsSync(path.join(repo,'.kogen/local/approvals/fixture.json'))};
  } finally {await s.close();fs.rmSync(dir,{recursive:true,force:true});}
}
function observeBuild(o,e) {
  assert.equal(o.exit,e.exit,o.diagnostic);
  assert.deepEqual(o.errors,[]);
  assert.equal(o.commits,e.commits);
  assert.equal(o.candidate,e.candidate);
  assert.equal(o.approval_consumed,e.approval_consumed);
  route(o.requests);
  assert.deepEqual(o.requests.map(r=>r.phase),e.phases);
  assert.deepEqual(o.records.map(r=>r.anthropic_stop_reason),e.stops);
  assert.deepEqual(o.records.map(r=>r.anthropic_end_turn_tool_use),e.markers);
  assert.ok(o.records.every(r=>r.outcome==='completed'));
  safe(o.records);
  for (const gate of e.gates) assert.ok(o.trace.includes(gate),'missing '+gate);
  const ms=o.requests[1].body.messages,assistant=ms.filter(m=>m.role==='assistant');
  assert.equal(assistant.length,1);assert.deepEqual(assistant[0].content,o.blocks);
  const at=ms.indexOf(assistant[0]);assert.equal(ms[at+1].role,'user');
  const results=ms[at+1].content.filter(b=>b.type==='tool_result');
  assert.equal(results.length,1);assert.equal(results[0].tool_use_id,'toolu_synthetic_01');
  assert.ok(JSON.stringify(results[0].content).includes('baseline'),'read_file was not executed');
  assert.ok(!JSON.stringify(o.requests[2].body.messages).includes(SIGNATURE),'independent reviewer inherited builder thinking');
}
// Same final observers as acceptance; controls reach replay, telemetry and landing checks
// without requiring the unimplemented classifier. These are oracle controls, not product greens.
function controls(bad) {
  const blocks=fixture('one'),base={role:'user',content:'contract'},record={outcome:'completed',anthropic_stop_reason:'end_turn',anthropic_end_turn_tool_use:true};
  const req=body=>({path:'/v1/messages',headers:{'x-api-key':KEY},body:{model:MODEL,...body}});
  const results=[{type:'tool_result',tool_use_id:'toolu_synthetic_01',content:'LOCAL_TOOL_RESULT:toolu_synthetic_01'}];
  const requests=[req({messages:[base]}),req({messages:[base,{role:'assistant',content:structuredClone(blocks)},{role:'user',content:results}]}),req({messages:[base]})];
  const first={outcome:'completed',value:true,records:[record],items:[{type:'message',content:[],anthropic_message:{role:'assistant',content:structuredClone(blocks)}},{type:'function_call',call_id:'toolu_synthetic_01',name:'read_file',arguments:'{"path":"lib/helper.go"}'}]};
  const o={errors:[],blocks,requests,receipt:{results:[first,{outcome:'completed',records:[structuredClone(record)]},{outcome:'completed',records:[structuredClone(record)]}]}};
  const e={outcome:'completed',requests:3,attempts:1,stop:'end_turn',marker:true,calls:[{id:'toolu_synthetic_01',name:'read_file',input:{path:'lib/helper.go'}}]};
  const be={exit:0,commits:'1',candidate:'candidate\n',phases:['build','build','review','review'],stops:['end_turn','tool_use','tool_use','tool_use'],markers:[true,false,false,false],gates:['setup','acceptance','check'],approval_consumed:true};
  const bo={exit:0,errors:[],blocks,requests:[...structuredClone(requests),req({messages:[base]})],records:be.stops.map((s,i)=>({outcome:'completed',anthropic_stop_reason:s,anthropic_end_turn_tool_use:be.markers[i]})),commits:'1',candidate:'candidate\n',trace:'setup acceptance check',approval_consumed:true};
  bo.requests.forEach((r,i)=>r.phase=be.phases[i]);bo.requests[1].body.messages[2].content[0].content='baseline\n';
  observe(o,e);observeBuild(bo,be);
  const rich=structuredClone(o),re=structuredClone(e);
  rich.blocks=fixture('rich');rich.requests[1].body.messages[1].content=structuredClone(rich.blocks);
  rich.receipt.results[0].items[0].anthropic_message.content=structuredClone(rich.blocks);
  const second=tool('toolu_synthetic_00','read_file',{path:'README.md'});
  re.calls.push({id:second.id,name:second.name,input:second.input});
  rich.receipt.results[0].items.push({type:'function_call',call_id:second.id,name:second.name,arguments:JSON.stringify(second.input)});
  rich.requests[1].body.messages[2].content.push({type:'tool_result',tool_use_id:second.id,content:'LOCAL_TOOL_RESULT:'+second.id});observe(rich,re);
  // Also qualify rejection's no-exposure observer independently of a success assertion.
  const no={errors:[],requests:[req({})],blocks:[],receipt:{results:[{outcome:'provider/invalid_response',value:false,items:[],records:[{outcome:'failed',anthropic_stop_reason:null,anthropic_end_turn_tool_use:false}]}]}};
  const ne={outcome:'provider/invalid_response',requests:1,attempts:1,stop:null,marker:false,calls:[]};observe(no,ne);
  if (!bad) {process.stdout.write('accepted\n');return;}
  const rejected=(original,expect,fn,mutate)=>{const copy=structuredClone(original);mutate(copy);assert.throws(()=>fn(copy,expect),'observer accepted a known-bad fixture');};
  for (const mutate of [
    x=>x.receipt.results[0].items[1].arguments='{"path":"wrong"}',
    x=>x.receipt.results[0].records[0].anthropic_stop_reason='tool_use',
    x=>x.receipt.results[0].records[0].anthropic_end_turn_tool_use=false,
    x=>x.receipt.results[0].records.push({...record}),
    x=>x.receipt.results[0].records[0].payload=THINK,
    x=>x.requests[1].body.messages[1].content[0].signature='changed',
    x=>x.requests[1].body.messages[2].content=[],
    x=>x.requests[1].body.messages.push(structuredClone(x.requests[1].body.messages[1])),
    x=>x.requests[2].body.messages.push({role:'assistant',content:blocks}),
    x=>x.receipt.results.pop(),
  ]) rejected(o,e,observe,mutate);
  rejected(rich,re,observe,x=>x.requests[1].body.messages[1].content.reverse());
  rejected(rich,re,observe,x=>x.requests[1].body.messages[2].content.pop());
  rejected(no,ne,observe,x=>x.receipt.results[0].items=[{type:'function_call',call_id:'leak',name:'read_file',arguments:'{}'}]);
  for (const mutate of [
    x=>x.exit=4,x=>x.commits='0',x=>x.candidate='baseline\n',x=>x.approval_consumed=false,
    x=>x.trace='setup acceptance',x=>x.requests[2].phase='build',x=>x.records[0].anthropic_end_turn_tool_use=false,
    x=>x.records[0].anthropic_stop_reason='tool_use',x=>x.records[0].payload=KEY,
    x=>x.requests[1].body.messages[1].content[0].signature='changed',
    x=>x.requests[1].body.messages[2].content[0].content='not read',
  ]) rejected(bo,be,observeBuild,mutate);
  process.stdout.write('rejected\n');process.exitCode=1;
}
if (require.main===module) {
  try {assert.equal(process.argv[2],'control');controls(process.argv[3]==='bad');}catch(e){console.error(e.message);process.exitCode=2;}
} else {
  const {When,Then,AfterAll}=require('@cucumber/cucumber');
  When('I exercise Anthropic complete tool turn {string} ending {string}',{timeout:180000},async function(kind,stop){this.anthropic059=await transport(kind,stop);});
  Then('the Anthropic complete tool observations are:',function(doc){observe(this.anthropic059,JSON.parse(doc));});
  When('I build with a packaged Anthropic complete tool turn',{timeout:240000},async function(){this.anthropic059build=await build();});
  Then('the packaged Anthropic complete tool Build has:',function(doc){observeBuild(this.anthropic059build,JSON.parse(doc));});
  AfterAll(()=>{if(suite){H.cleanupSuite(suite);suite=null;}});
}
