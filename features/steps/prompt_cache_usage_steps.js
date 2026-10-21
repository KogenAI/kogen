const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawn } = require('node:child_process');
const { Given, When, Then, After } = require('@cucumber/cucumber');
const ROOT = path.resolve(__dirname, '../..');
const PRIVATE = ['OPAQUE_CACHE_REASONING', 'PRIVATE_TOOL_BODY', 'fake-access', 'fake-refresh', 'RAW_PROMPT_SECRET'];
function command(file, args, cwd, env = {}) {
  return new Promise((resolve, reject) => {
    const p = spawn(file, args, { cwd, detached: true, stdio: ['ignore','pipe','pipe'], env: { ...process.env, ERL_FLAGS: '+S 2:2 +SDcpu 1 +SDio 1', ...env } });
    let out = '';
    p.stdout.on('data', b => { out += b; }); p.stderr.on('data', b => { out += b; });
    const timer = setTimeout(() => { try { process.kill(-p.pid, 'SIGKILL'); } catch {} }, 240000);
    p.once('error', e => { clearTimeout(timer); reject(e); });
    p.once('close', code => { clearTimeout(timer); resolve({ code, out }); });
  });
}
function temp(world) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'prompt-cache-usage-'));
  (world.cacheTemps ||= []).push(dir); return dir;
}
After(function () { for (const dir of this.cacheTemps || []) fs.rmSync(dir, { recursive: true, force: true }); });
const nativeDriver = String.raw`
ExUnit.start(autorun: false)
Code.require_file("test/support/integration_helpers.ex")
alias Kogen.Integration.{Helpers, FakeProvider}
alias Kogen.{ChatGPT, ShapeEvidence, Error}
[mode, receipt] = System.argv()
usage = %{"input_tokens"=>100,"input_tokens_details"=>%{"cached_tokens"=>20,"cache_write_tokens"=>30,"cache_write_tokens_details"=>%{"ttl_30m_tokens"=>30,"ttl_12h_tokens"=>0}},"output_tokens"=>10,"output_tokens_details"=>%{"reasoning_tokens"=>4}}
reasoning = fn label -> %{"type"=>"reasoning","id"=>"reason_"<>label,"summary"=>[],"encrypted_content"=>"OPAQUE_CACHE_REASONING_"<>label} end
message = fn label -> %{"type"=>"message","id"=>"msg_"<>label,"role"=>"assistant","phase"=>"commentary","content"=>[%{"type"=>"output_text","text"=>"phase "<>label,"annotations"=>[]}]} end
call = fn name,args,label -> %{"type"=>"function_call","id"=>"fc_"<>label,"call_id"=>"call_"<>label,"name"=>name,"arguments"=>JSON.encode!(args),"status"=>"completed"} end
response = fn label,items -> {:events,[%{"type"=>"response.completed","response"=>%{"id"=>"resp_"<>label,"status"=>"completed","model"=>"gpt-6.1-sol","service_tier"=>"default","output"=>items,"usage"=>usage,"prompt_cache_diagnostics"=>%{"type"=>"cache_miss","reason"=>"tools_changed","comparison_reusable_tokens"=>80,"cache_missed_tokens"=>80}}}]} end
question = %{"questions"=>[%{"question"=>"Choose caching fixture?","options"=>[%{"label"=>"Keep complete","recommended"=>true}]}]}
read = fn label -> [reasoning.(label),message.(label),call.("read_file",%{"path"=>"app.txt"},label)] end
if mode in ["shape","build-resume"] do
 suite=Helpers.setup_suite!()
 script=if mode == "shape" do
  [response.("question",[call.("submit",question,"question")]),response.("shape1",read.("shape1")),response.("shape2",[call.("submit",question,"shape2")])]
 else
  [response.("build1",[reasoning.("build1"),message.("build1"),call.("write_file",%{"path"=>"app.txt","content"=>"candidate-fresh\n"},"build1")]),
   response.("build2",[call.("finish",%{},"build2")]),
   response.("review1",read.("review1")),
   response.("review2",[reasoning.("review2"),message.("review2"),call.("submit_review",%{"verdict"=>"changes","findings"=>[%{"path"=>"app.txt","line"=>1,"severity"=>"blocking","message"=>"unresolved fixture finding"}]},"review2")]),
   response.("review3",[call.("submit_review",%{"verdict"=>"approve","findings"=>[]},"review3")])]
 end
 c=Helpers.project!(suite,script,staged_intent: false)
 try do
  start_head=Kogen.Git.head(c.repo)
  result=if mode == "shape" do
   request=Path.join(c.root,"original.txt"); File.write!(request,"ORIGINAL_CACHE_AUTHORITY: preserve every byte of this original.\n")
   {o1,k1}=Helpers.run_kogen(c,["intent","shape","cache-shape",request])
   answer=Path.join(c.root,"answer.txt"); File.write!(answer,"1: a\n")
   {o2,k2}=Helpers.run_kogen(c,["intent","shape","cache-shape",answer])
   %{exit_codes: [k1,k2],output: o1<>o2}
  else
   {o1,k1}=Helpers.run_kogen(c,["intent","build","fixture"])
   [log]=Path.wildcard(Path.join(c.repo,".kogen/local/runs/*/log.jsonl")); id=Path.basename(Path.dirname(log))
   result_path=Path.join(Path.dirname(log),"result.json"); original=File.read!(result_path)
   blocked=Kogen.Git.head(c.repo)==start_head and original =~ "review_blocked" and File.regular?(Kogen.Intent.approval_path(c.repo,"fixture"))
   {o2,k2}=Helpers.run_kogen(c,["intent","resume",id])
   %{exit_codes: [k1,k2],output: o1<>o2,prior_result_unchanged: original==File.read!(result_path),blocker_preserved_until_resume: blocked,landed_after_review: k2==0 and Kogen.Git.head(c.repo)!=start_head}
  end
  reqs=FakeProvider.provider_requests(c.server)|>Enum.drop(1)|>Enum.map(& &1.json)
  files=Path.wildcard(Path.join(c.repo,".kogen/local/runs/*/log.jsonl")) ++ Path.wildcard(Path.join(c.repo,".kogen/local/shaping/*/events.ndjson"))
  rows=Enum.flat_map(files,fn f -> File.read!(f)|>String.split("\n",trim: true)|>Enum.map(&JSON.decode!/1) end)
  analytical=Enum.filter(rows,&(&1["event"] in ["provider_attempt","provider_call","request"]))
  File.write!(receipt,JSON.encode!(Map.merge(result,%{payloads: reqs,attempts: analytical})))
 after
  Helpers.cleanup_case(c); Helpers.cleanup_suite(suite)
 end
else
 home=Kogen.tmp_path("cache-capability")
 File.mkdir_p!(Path.join(home,".kogen/credentials"))
 File.write!(Path.join(home,".kogen/credentials/chatgpt.json"),JSON.encode!(%{client_id: "oaiapp_fixture",access_token: "fake-access",refresh_token: "fake-refresh",expires_at: System.system_time(:second)+3600}))
 refusal=if mode == "unrelated-refusal", do: %{"error"=>%{"code"=>"subscription_sharing_unsupported_capability","param"=>"model","message"=>"model unavailable"}}, else: %{"error"=>%{"code"=>"subscription_sharing_unsupported_capability","param"=>"prompt_cache_options","message"=>"unsupported cache option"}}
 ok=response.("capability",[message.("capability")])
 script=case mode do
  "unsupported-option" -> [{:http,400,refusal},ok]
  "unrelated-refusal" -> [{:http,400,refusal}]
  "legacy-model" -> [ok]
 end
 server=FakeProvider.start(script)
 try do
  :persistent_term.put(:kogen_caller,%{env: %{"HOME"=>home,"KOGEN_PROVIDER_URL"=>"http://127.0.0.1:#{server.port}"}})
  ShapeEvidence.start(Path.join(home,"evidence"))
  model=%{model: if(mode=="legacy-model",do: "gpt-5.4",else: "gpt-6.1-sol"),effort: "medium"}
  result=try do
   r=ShapeEvidence.provider("shape",nil,"fixture",[],model,fn -> ChatGPT.respond(model,"RAW_PROMPT_SECRET stable policy",[%{"role"=>"user","content"=>"dynamic suffix"}],[]) end)
   %{outcome: "completed",response: Map.drop(r,[:items])}
  rescue e in Error -> %{outcome: e.class<>"/"<>e.reason} end
  rows=Path.join(home,"evidence/events.ndjson")|>File.read!()|>String.split("\n",trim: true)|>Enum.map(&JSON.decode!/1)
  File.write!(receipt,JSON.encode!(Map.merge(result,%{payloads: Enum.map(FakeProvider.provider_requests(server),& &1.json),attempts: rows})))
 after
  FakeProvider.stop(server); File.rm_rf!(home)
 end
end
`;
function allBlocks(payload) { return (payload?.input || []).flatMap(m => Array.isArray(m.content) ? m.content : []); }
function markers(payload) { return allBlocks(payload).filter(b => b.prompt_cache_breakpoint); }
function safePolicy(p) {
  const ms = markers(p);
  return p?.store === false && p.stream === true && !Object.hasOwn(p,'instructions') && p.prompt_cache_options?.mode === 'implicit' && p.prompt_cache_options?.ttl === '30m' && ms.length >= 1 && ms.length <= 3 && ms.every(b => b.type === 'input_text' && b.prompt_cache_breakpoint.mode === 'explicit') && (p.input || []).some(m => m.role === 'developer' && Array.isArray(m.content) && m.content.some(b => b.prompt_cache_breakpoint));
}
function forbidden(ps) { return ps.some(p => ['previous_response_id','conversation','truncation','prompt_cache_retention','prompt_cache_key'].some(k => Object.hasOwn(p,k)) || p.prompt_cache_options?.prewarm === true); }
function prefixEqual(a,b) {
  return !!a && !!b && JSON.stringify(a.tools) === JSON.stringify(b.tools) && JSON.stringify(a.input) === JSON.stringify((b.input || []).slice(0,a.input.length));
}
function replayIn(p,label) {
  const items=p?.input || [];
  const n=items.findIndex(x => x.type==='reasoning' && x.id==='reason_'+label && x.encrypted_content==='OPAQUE_CACHE_REASONING_'+label && Array.isArray(x.summary));
  const m=items[n+1], f=items[n+2], o=items[n+3];
  return n>=0 && m?.type==='message' && m.id==='msg_'+label && m.role==='assistant' && m.phase==='commentary' && m.content?.[0]?.type==='output_text' && m.content[0].text==='phase '+label && f?.type==='function_call' && f.call_id==='call_'+label && typeof f.arguments==='string' && o?.type==='function_call_output' && o.call_id===f.call_id;
}
function metadata(rows) {
  return rows.filter(r => r.provider).map(r => r.provider);
}
When('I exercise prompt reuse through native {string}', { timeout: 250000 }, async function(mode) {
  assert.ok(['shape','build-resume','unsupported-option','legacy-model','unrelated-refusal'].includes(mode));
  const dir=temp(this), script=path.join(dir,'driver.exs'), receipt=path.join(dir,'receipt.json');
  fs.writeFileSync(script,nativeDriver);
  const r=await command('mix',['run','--no-deps-check',script,mode,receipt],ROOT);
  assert.equal(r.code,0,r.out); assert.ok(fs.existsSync(receipt),r.out);
  const result=JSON.parse(fs.readFileSync(receipt,'utf8')), ps=result.payloads;
  const md=metadata(result.attempts || []);
  const observed={ ...result, requests: ps.length, forbidden_state_fields: forbidden(ps), comparison_ids: ps.map(p => p.prompt_cache_options?.comparison_response_id ?? null), supported_policy: ps.length>0 && ps.every(safePolicy) };
  if (mode==='shape') {
    const input=JSON.stringify(ps[1]?.input);
    observed.complete_original_and_answer=input.includes('ORIGINAL_CACHE_AUTHORITY: preserve every byte of this original.') && input.includes('Choose caching fixture?') && input.includes('Keep complete');
    observed.stable_prefix_and_tools=prefixEqual(ps[1],ps[2]); observed.exact_replay_order=replayIn(ps[2],'shape1');
  } else if (mode==='build-resume') {
    observed.stable_prefix_and_tools=prefixEqual(ps[0],ps[1]) && prefixEqual(ps[2],ps[3]) && prefixEqual(ps[3],ps[4]);
    observed.exact_replay_order=replayIn(ps[1],'build1') && replayIn(ps[3],'review1') && (ps[4]?.input || []).some(i=>i.encrypted_content==='OPAQUE_CACHE_REASONING_review2' && i.type==='reasoning');
    const rev=JSON.stringify(ps[2]);
    observed.reviewer_independent=!rev.includes('OPAQUE_CACHE_REASONING_build1') && !rev.includes('call_build1') && !rev.includes('resp_build');
    observed.review_fresh_candidate=rev.includes('candidate-fresh') && rev.includes('Preserve the fixture') && rev.includes('acceptance');
  }
  observed.metadata_retained=md.length>=ps.length && md.filter(x=>x.outcome==='completed').every(x => x.provider_response_id?.startsWith('resp_') && x.usage?.write===30 && x.usage.write_30m===30 && x.usage.write_12h===0 && x.cache?.diagnostics?.reason==='tools_changed' && typeof x.operation_id==='string' && typeof x.attempt_id==='string' && typeof x.conversation_id==='string' && x.fingerprints?.policy?.sha256?.length===64 && Number.isInteger(x.fingerprints.policy.bytes));
  observed.analytical_secrets_absent=PRIVATE.every(s=>!JSON.stringify(result.attempts).includes(s));
  observed.first_has_cache_policy=!!ps[0]?.prompt_cache_options;
  observed.last_has_cache_policy=!!ps.at(-1)?.prompt_cache_options;
  observed.compatibility_visible=mode==='unrelated-refusal' ? md.some(x=>x.outcome==='failed' && x.usage?.input==null) : md.some(x=>x.cache?.status==='unsupported' || x.cache?.status==='unknown');
  this.cacheObservation=observed;
});
Then('the prompt reuse observations are:', function(table) {
  const errors=[];
  for (const [k,v] of table.raw()) { try { assert.deepEqual(this.cacheObservation[k],JSON.parse(v),k); } catch(e) { errors.push(e.message); } }
  assert.deepEqual(errors,[],JSON.stringify(this.cacheObservation));
});
function writeJSON(file,data) { fs.mkdirSync(path.dirname(file),{recursive:true}); fs.writeFileSync(file,JSON.stringify(data)+'\n'); }
function seedRow(row,index,run,slug) {
  const phase=row.phase || 'build', at=row.at || `2026-10-21T10:00:${String(index).padStart(2,'0')}Z`;
  const usage=Object.fromEntries(['input','cached','write','write_30m','write_12h','output','reasoning'].map(k=>[k,row[k] ?? null]));
  if (row.legacy) return {event:'request',at,role:phase,model:'gpt-6.1-sol',effort:phase==='review'?'high':'medium',usage:Object.fromEntries(['input','cached','output','reasoning'].map(k=>[k,row[k] ?? null])),wall_ms:10};
  return {event:'provider_attempt',at,provider:{operation_id:`op_${run}_${index}`,attempt_id:`attempt_${run}_${index}`,conversation_id:`conversation_${run}_${phase}`,timestamp:at,phase,role:phase,run_id:run,slug,provider_response_id:row.id ?? null,provider_request_id:null,configured_model:'gpt-6.1-sol',effective_model:'gpt-6.1-sol',configured_effort:phase==='review'?'high':'medium',effective_effort:null,requested_service_tier:null,effective_service_tier:null,requested_reasoning_context:null,effective_reasoning_context:null,cache:{configured_mode:'implicit',applied_mode:'implicit',configured_ttl:'30m',applied_ttl:null,status:'applied',boundaries:[],comparison_response_id:null,diagnostics:null},fingerprints:{policy:null,tools:null,schema:null,contract:null,prefix:null},usage,usage_state:row.outcome==='failed'?'unknown':'known',outcome:row.outcome || 'completed',error:null,wall_ms:10,ttft_ms:null}};
}
function snapshots(root) {
  const result={};
  function walk(dir) { for(const ent of fs.readdirSync(dir,{withFileTypes:true})) { const p=path.join(dir,ent.name); if(ent.isDirectory()) walk(p); else if(ent.isFile()) result[path.relative(root,p)]=crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex'); } }
  walk(root); return result;
}
Given('retained usage files for prompt reuse:', { timeout: 60000 }, async function(text) {
  const data=JSON.parse(text), root=temp(this), repo=path.join(root,'repo'); fs.mkdirSync(repo);
  this.cacheRepo=repo; this.cacheCLI=path.join(root,'kogen');
  const built=await command('go',['build','-o',this.cacheCLI,'.'],path.join(ROOT,'cli')); assert.equal(built.code,0,built.out);
  for(const args of [['init','-q'],['config','user.name','Usage Fixture'],['config','user.email','usage@example.invalid']]) { const r=await command('git',args,repo,{GIT_CONFIG_GLOBAL:'/dev/null',GIT_CONFIG_NOSYSTEM:'1'}); assert.equal(r.code,0,r.out); }
  writeJSON(path.join(repo,'.kogen/project.yaml'),{version:1});
  fs.writeFileSync(path.join(repo,'app.txt'),'baseline\n');
  for(const args of [['add','.'],['commit','-qm','fixture']]) { const r=await command('git',args,repo,{GIT_CONFIG_GLOBAL:'/dev/null',GIT_CONFIG_NOSYSTEM:'1'}); assert.equal(r.code,0,r.out); }
  for(const [id,run] of Object.entries(data.runs || {})) {
    const dir=path.join(repo,'.kogen/local/runs',id), slug=run.slug || 'cache-fixture'; fs.mkdirSync(dir,{recursive:true});
    const rows=(run.rows || []).map((row,i)=>seedRow(row,i,id,slug));
    rows.push({event:'tool_call',at:'2026-10-21T10:00:59Z',output:'PRIVATE_TOOL_BODY RAW_PROMPT_SECRET OPAQUE_CACHE_REASONING'});
    fs.writeFileSync(path.join(dir,'log.jsonl'),rows.map(JSON.stringify).join('\n')+'\n');
    writeJSON(path.join(dir,'result.json'),{build:id,slug,outcome:'stopped',resumed_from:run.parent || null,root_build:run.parent || id,usage:{input:999999,cached:999999,output:999999,reasoning:999999},attempt_usage:{input:999999,cached:999999,output:999999,reasoning:999999}});
    writeJSON(path.join(dir,'review-1.json'),{usage:{input:999999,cached:999999,output:999999,reasoning:999999}});
    fs.mkdirSync(path.join(dir,'checkpoint.json')); // A directory trap: routine reports must not open/decode it.
  }
  if(data.shape) {
    const dir=path.join(repo,'.kogen/local/shaping/cache-shape'); fs.mkdirSync(dir,{recursive:true});
    fs.writeFileSync(path.join(dir,'events.ndjson'),data.shape.map((r,i)=>JSON.stringify({event:'provider_call',role:'shape',configured_model:'gpt-6.1-sol',configured_effort:'high',status:'completed',at:r.at || '2026-10-21T11:00:00Z',started_ms:i*10,wall_ms:10,usage:{input:r.input,cached:r.cached,output:r.output,reasoning:r.reasoning}})).join('\n')+'\n');
  }
  if(data.decoys) {
    for(const p of ['test/acceptance/fixtures/repo/.kogen/local/runs/deadbeef','archive/copy/.kogen/local/runs/deadbeef','.kogen/local/runs/11111111/archive/.kogen/local/runs/deadbeef']) {
      const d=path.join(repo,p); fs.mkdirSync(d,{recursive:true}); fs.writeFileSync(path.join(d,'log.jsonl'),JSON.stringify(seedRow({legacy:true,input:999999,cached:999999,output:1,reasoning:0},0,'deadbeef','decoy'))+'\n');
    }
  }
  this.cacheBefore=snapshots(repo);
});
When('I run prompt reuse usage with arguments:', { timeout: 60000 }, async function(text) {
  this.cacheArgs=JSON.parse(text);
  const r=await command(this.cacheCLI,['intent','usage',...this.cacheArgs],this.cacheRepo,{HOME:path.dirname(this.cacheRepo),GIT_CONFIG_GLOBAL:'/dev/null',GIT_CONFIG_NOSYSTEM:'1'});
  this.cacheReportRun=r;
  try { this.cacheReport=JSON.parse(r.out); } catch { this.cacheReport=null; }
});
function atPath(value,key) { return key.split('.').reduce((v,k)=>v?.[k],value); }
Then('the prompt reuse report has:', function(table) {
  assert.equal(this.cacheReportRun.code,0,this.cacheReportRun.out);
  assert.ok(this.cacheReport,this.cacheReportRun.out);
  for(const [k,v] of table.raw()) assert.deepEqual(atPath(this.cacheReport,k),JSON.parse(v),k+'\n'+this.cacheReportRun.out);
});
Then('prompt reuse reporting is read only and excludes private content', { timeout: 60000 }, async function() {
  assert.deepEqual(snapshots(this.cacheRepo),this.cacheBefore);
  assert.ok(PRIVATE.every(s=>!this.cacheReportRun.out.includes(s)),this.cacheReportRun.out);
  const args=this.cacheArgs.filter(a=>a!=='--json');
  const human=await command(this.cacheCLI,['intent','usage',...args],this.cacheRepo,{HOME:path.dirname(this.cacheRepo),GIT_CONFIG_GLOBAL:'/dev/null',GIT_CONFIG_NOSYSTEM:'1'});
  assert.equal(human.code,0,human.out);
  assert.match(human.out,/local|retained/i); assert.match(human.out,/unknown|known|requests/i);
  assert.ok(PRIVATE.every(s=>!human.out.includes(s)),human.out);
  assert.doesNotMatch(human.out,/\$\s*\d|\b\d+(?:\.\d+)?%\s+(?:weekly|quota)/i);
  assert.deepEqual(snapshots(this.cacheRepo),this.cacheBefore);
});
