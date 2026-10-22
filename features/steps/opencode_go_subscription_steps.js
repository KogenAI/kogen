const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { isDeepStrictEqual: same } = require('node:util');
const { FakeServers } = require('../../test/acceptance/support/fake-servers');
const ROOT = path.resolve(__dirname, '../..');
const GO_PATH = '/inference/go/openai/v1/chat/completions';
const safe = f => { try { return f() !== false; } catch { return false; } };

// This observer judges actual outbound Go records. The control uses the same bytes,
// the retained scalar-reasoning shape and local synthetic text, never a real account.
function goObserver(records) {
  return safe(() => {
    assert.ok(records.length >= 3);
    const groups = new Map();
    for (const r of records) {
      assert.equal(r.path, GO_PATH); assert.equal(r.method, 'POST');
      assert.match(r.headers['user-agent'], /^kogen\//);
      assert.ok(r.headers['x-opencode-session']);
      const b = r.body;
      assert.equal(b.model, 'kimi-k3'); assert.equal(b.stream, false); assert.equal(b.store, false);
      for (const k of ['input','instructions','include','previous_response_id','conversation','prompt_cache_options','prompt_cache_key','truncation']) assert.ok(!Object.hasOwn(b,k), k);
      assert.equal(b.messages[0].role, 'system');
      assert.ok(b.tools?.length > 0 && b.tools.every(t => t.type === 'function' && t.function?.name));
      (groups.get(r.phase) || groups.set(r.phase, []).get(r.phase)).push(r);
    }
    const sessions = [];
    for (const rs of groups.values()) {
      const sid = rs[0].headers['x-opencode-session']; sessions.push(sid);
      for (const r of rs) assert.equal(r.headers['x-opencode-session'], sid);
      for (let i = 0; i + 1 < rs.length; i++) {
        const a = rs[i], b = rs[i+1];
        assert.deepEqual(b.body.tools, a.body.tools);
        assert.deepEqual(b.body.messages.slice(0,a.body.messages.length), a.body.messages);
        assert.ok(a.sent, 'fixture must retain the actual supplied response');
        const at = a.body.messages.length;
        assert.deepEqual(b.body.messages[at], a.sent, 'raw assistant replay changed');
        for (const call of a.sent.tool_calls || []) {
          const outputs = b.body.messages.slice(at+1).filter(m => m.role === 'tool' && m.tool_call_id === call.id);
          assert.equal(outputs.length, 1, 'one real output per call');
        }
      }
    }
    assert.equal(new Set(sessions).size, sessions.length, 'owners share routing identity');
  });
}
function controls(bad) {
  const raw = { role:'assistant', content:null, reasoning:'synthetic scalar', reasoning_details:[{type:'reasoning.text',index:0,text:'synthetic scalar'}], tool_calls:[{id:'call_control',type:'function',function:{name:'read_file',arguments:'{"path":"app.txt"}'}}] };
  const base = {model:'kimi-k3',stream:false,store:false,messages:[{role:'system',content:'policy'},{role:'user',content:'contract'}],tools:[{type:'function',function:{name:'read_file',parameters:{type:'object'}}}]};
  const rec = (phase,sid,body,sent) => ({phase,path:GO_PATH,method:'POST',headers:{'user-agent':'kogen/control','x-opencode-session':sid},body,sent});
  const next = structuredClone(base); next.messages.push(structuredClone(raw),{role:'tool',tool_call_id:'call_control',content:'actual local fixture result'});
  if (bad) { delete next.messages[2].reasoning; delete next.messages[2].reasoning_details; }
  return [rec('build','one',base,raw),rec('build','one',next,{role:'assistant',content:'done'}),rec('review','two',structuredClone(base),raw)];
}
if (require.main === module) {
  assert.equal(process.argv[2], '--control');
  const accepted = goObserver(controls(process.argv[3] === 'bad'));
  process.stdout.write(accepted ? 'accepted\n' : 'rejected\n');
  process.exitCode = accepted ? 0 : 1;
} else {
  const { Given, When, Then, After, AfterAll } = require('@cucumber/cucumber');
  const temps = [];
  let installed;
  function temp() { const d = fs.mkdtempSync(path.join(os.tmpdir(),'kogen-go-subscription-')); temps.push(d); return d; }
  function write(p,s) { fs.mkdirSync(path.dirname(p),{recursive:true}); fs.writeFileSync(p,s); }
  function command(file,args,cwd,env={},input='') {
    return new Promise((resolve,reject) => {
      const p = spawn(file,args,{cwd,detached:true,env:{...process.env,ERL_FLAGS:'+S 2:2 +SDcpu 1 +SDio 1',...env},stdio:['pipe','pipe','pipe']});
      let out=''; const timer=setTimeout(()=>{try{process.kill(-p.pid,'SIGKILL');}catch{}},180000);
      p.stdout.on('data',b=>{out+=b;}); p.stderr.on('data',b=>{out+=b;}); p.stdin.on('error',()=>{}); p.stdin.end(input);
      p.once('error',e=>{clearTimeout(timer);reject(e);}); p.once('close',code=>{clearTimeout(timer);resolve({code,out});});
    });
  }
  async function must(file,args,cwd,env,input) { const r=await command(file,args,cwd,env,input); assert.equal(r.code,0,r.out); return r.out; }
  async function install() {
    if (!installed) installed=(async()=>{
      const d=temp(), extract=path.join(d,'extract'); fs.mkdirSync(extract);
      const platform=process.platform==='darwin'?'darwin-arm64':'linux-amd64';
      const names=fs.readdirSync(path.join(ROOT,'dist')).filter(n=>n.endsWith(`-${platform}.tar.gz`)).map(n=>path.join(ROOT,'dist',n)).sort((a,b)=>fs.statSync(b).mtimeMs-fs.statSync(a).mtimeMs);
      assert.ok(names.length,'setup must build the current archive');
      await must('tar',['-xzf',names[0],'-C',extract],ROOT);
      const release=path.join(extract,fs.readdirSync(extract)[0]), prefix=path.join(d,'prefix'), home=path.join(d,'home'); fs.mkdirSync(home);
      await must('sh',[path.join(release,'install.sh'),'--prefix',prefix],ROOT,{HOME:home});
      return path.join(prefix,'bin/kogen');
    })();
    return installed;
  }
  const runner = 'NODE_PATH="$KOGEN_CUCUMBER" "$KOGEN_NODE" "$KOGEN_CUCUMBER/@cucumber/cucumber/bin/cucumber.js" --strict --require "features/steps/*.js" --format "message:$KOGEN_ACCEPTANCE_REPORT" "$KOGEN_ACCEPTANCE_FEATURES"';
  function yaml(models) { return `version: 1\ncommands:\n  setup: []\n  fix: []\n  checks: []\n  acceptance:\n    run: '${runner}'\n    steps_dir: features/steps\nprotect: []\nmodels:\n${['shape','build','review'].map(r=>`  ${r}: {provider: ${models.provider||'opencode-go'}, model: ${models.model||'kimi-k3'}, effort: ${models.effort||'high'}}`).join('\n')}\nshape_workers:\n  enabled: false\n`; }
  function fixtureIntent(title='Preserve the Go fixture') { return `# ${title}\n\nSlug: fixture\nModel: not applicable — a text fixture has no meaningful state\nAcceptance:\n- .kogen/intents/fixture/acceptance.feature\n- features/steps/fixture_steps.js\n\nPreserve app.txt as baseline or the requested Go candidate.\n\n## Decisions\n- Preserve the fixture (source: request)\n\n## Source comparison\n- addressed: fixture request; contract prose and acceptance preserve app.txt.\n\n## Tests\n- preserve the fixture: installed fixture scenario (scenario)\n\n## Feasibility\n- none\n`; }
  async function context(world) {
    const d=temp(), home=path.join(d,'home'), repo=path.join(d,'repo'); fs.mkdirSync(home); fs.mkdirSync(repo);
    const fake=new FakeServers(); await fake.start(); world.goFake=fake;
    const env={HOME:home,GIT_CONFIG_NOSYSTEM:'1',GIT_CONFIG_GLOBAL:path.join(home,'.gitconfig'),KOGEN_PROVIDER_URL:fake.providerUrl,KOGEN_AUTH_URL:fake.authUrl,OPENCODE_API_KEY:world.goInput.borrowed,XAI_API_KEY:world.goInput.borrowed}; write(env.GIT_CONFIG_GLOBAL,'');
    write(path.join(repo,'README.md'),'# Local Go fixture\n'); write(path.join(repo,'app.txt'),'baseline\n'); write(path.join(repo,'.gitignore'),'.kogen/local/\n'); write(path.join(repo,'.kogen/project.yaml'),yaml({}));
    write(path.join(repo,'.kogen/intents/fixture/intent.md'),fixtureIntent());
    write(path.join(repo,'.kogen/intents/fixture/acceptance.feature'),'Feature: Local fixture\n  Scenario: Preserve text\n    Then the Go fixture is present\n');
    write(path.join(repo,'features/steps/fixture_steps.js'),`const {Then}=require('@cucumber/cucumber'); const fs=require('node:fs'); Then('the Go fixture is present',()=>{if(!['baseline\\n','Go candidate\\n'].includes(fs.readFileSync('app.txt','utf8'))) throw Error('fixture changed incorrectly');});\n`);
    for (const args of [['init','-q','--initial-branch=main'],['config','user.name','Go Fixture'],['config','user.email','go-fixture@example.invalid'],['add','.'],['commit','-q','-m','fixture baseline']]) await must('git',args,repo,env);
    const bin=await install(), records=[], held=new Set(); let phase='shape';
    fake.handleAuth=async(req,res)=>{ records.push({path:req.url,method:req.method,headers:req.headers,phase:'AUTH'}); res.writeHead(500);res.end('{}'); };
    return {d,home,repo,env,bin,fake,records,held,phase:()=>phase,setPhase:p=>{phase=p;}, cli:(args,input)=>command(bin,args,repo,env,input),git:args=>must('git',args,repo,env)};
  }
  function callsMessage(calls,label) { return {role:'assistant',content:null,reasoning:'SYNTHETIC_PRIVATE_REASONING_'+label,reasoning_details:[{type:'reasoning.text',index:0,text:'SYNTHETIC_PRIVATE_REASONING_'+label}],tool_calls:calls.map(([name,args],i)=>({id:`call_${label}_${i}`,type:'function',function:{name,arguments:JSON.stringify(args)}}))}; }
  function completed(res,raw,input,id) { res.writeHead(200,{'content-type':'application/json','x-request-id':'request_'+id}); res.end(JSON.stringify({id:'response_'+id,object:'chat.completion',model:input.model,choices:[{index:0,message:raw,finish_reason:raw.tool_calls?.length?'tool_calls':'stop'}],usage:input.usage})); }
  async function decode(req) { const chunks=[];for await(const b of req)chunks.push(b);return JSON.parse(Buffer.concat(chunks).toString()); }
  async function login(c,input) { return c.cli(['provider','login','opencode-go'],input.key+'\n'); }
  function credential(c) { return path.join(c.home,'.kogen/credentials/opencode-go.json'); }
  function publicSafe(input,output) { return [input.key,input.borrowed,'SYNTHETIC_PRIVATE_REASONING'].every(s=>!JSON.stringify(output).includes(s)); }
  const native=String.raw`
[cfg, receipt] = System.argv()
c = JSON.decode!(File.read!(cfg))
:persistent_term.put(:kogen_caller, %{env: %{"HOME" => c["home"], "KOGEN_PROVIDER_URL" => c["url"]}, install_root: File.cwd!(), cwd: File.cwd!()})
System.put_env("RELEASE_ROOT", c["home"])
File.write!(Path.join(c["home"], "VERSION"), "kogen fixture (local)\n")
role = %{provider: c["provider"] || "opencode-go", model: c["model"], effort: c["effort"]}
tools = [%{"type" => "function", "name" => "read_file", "description" => "Read the fixture", "parameters" => %{"type" => "object", "properties" => %{"path" => %{"type" => "string"}}, "required" => ["path"], "additionalProperties" => false}, "strict" => true}]
base = [%{"role" => "user", "content" => c["contract"]}]
mode = c["mode"]
r = cond do
 mode == "config" or mode == "preset" ->
  try do
   config = Kogen.Config.parse!(File.read!(c["yaml"]), c["yaml"])
   %{outcome: "parsed", roles: Enum.map(~w(shape build review), fn name -> v=config.models[name]; [Kogen.Provider.name(v),v.model,v.effort] end), workers: config.shape_workers.enabled}
  rescue e in Kogen.Error -> %{outcome: e.class <> "/" <> e.reason} end
 mode == "budget" ->
  render = fn s -> Kogen.ChatGPT.request_body(role,c["policy"],[%{"role"=>"user","content"=>s}],tools) end
  overhead = byte_size(JSON.encode!(render.("")))
  bodies = Enum.map([524287,524288,524289],fn n -> render.(String.duplicate("x",n-overhead)) end)
  ms = Enum.map(bodies,&Kogen.WorkingContext.measure/1)
  %{body_is_chat: Enum.all?(bodies,&(is_list(&1["messages"]) and not Map.has_key?(&1,"input"))), bytes: Enum.map(ms,& &1.rendered_bytes), fits: Enum.map(ms,& &1.fits), reserve: Enum.map(ms,& &1.output_reserve_tokens)}
 true ->
  Process.put(:provider_conversation_scope,"local-build")
  input = if c["image"] == "true", do: base ++ [%{"type"=>"function_call_output","call_id"=>"image","output"=>[%{"type"=>"input_text","text"=>"{}"},%{"type"=>"input_image","image_url"=>"data:image/png;base64,synthetic"}]}], else: base
  if role.provider == "supergrok" do
   dir=Path.join(c["home"],".kogen/credentials");File.mkdir_p!(dir)
   File.write!(Path.join(dir,"supergrok.json"),JSON.encode!(%{client_id: "fixture",referrer: "kogen",access_token: "SYNTHETIC_SG_ACCESS",refresh_token: "SYNTHETIC_SG_REFRESH",expires_at: System.system_time(:second)+3600,scope: "api:access"}))
  end
  invoke = fn items ->
   t=System.monotonic_time(:millisecond)
   try do
    v=Kogen.ChatGPT.respond(role,c["policy"],items,tools,response_budget_ms: String.to_integer(c["budget"] || "15000"))
    %{outcome: "completed",value: v,metadata: Process.get(:provider_attempt_metadata),elapsed: System.monotonic_time(:millisecond)-t}
   rescue e in Kogen.Error -> %{outcome: e.class<>"/"<>e.reason,detail: e.detail,value: nil,metadata: Process.get(:provider_attempt_metadata),elapsed: System.monotonic_time(:millisecond)-t} end
  end
  first=invoke.(input)
  results=if first.outcome == "completed" do
   replay=Enum.map(first.value.items,&Kogen.Shape.replay_item/1)|>Enum.reject(&is_nil/1)
   call=Enum.find(first.value.items,&(&1["type"]=="function_call"))
   next=input++replay++[Kogen.Shape.output(call,"PRIVATE_TOOL_BODY")]
   saved=:erlang.term_to_binary(Process.get(:prompt_cache_states,%{}))
   Process.delete(:prompt_cache_states)
   Process.put(:prompt_cache_states,:erlang.binary_to_term(saved,[:safe]))
   second=invoke.(next)
   Process.put(:provider_conversation_scope,"local-independent-review")
   [first,second,invoke.(base)]
  else [first] end
  %{results: results}
end
File.write!(receipt,JSON.encode!(r))
`;
  async function nativeRun(c,input,settings) {
    const config=path.join(c.d,'native.json'),script=path.join(c.d,'native.exs'),receipt=path.join(c.d,'receipt.json');
    write(config,JSON.stringify({...input,...settings,home:c.home,url:c.fake.providerUrl})); write(script,native);
    const r=await command('mix',['run','--no-deps-check',script,config,receipt],ROOT); assert.equal(r.code,0,r.out); return JSON.parse(fs.readFileSync(receipt,'utf8'));
  }
  Given('the Go subscription fixture inputs:',function(doc){this.goInput=JSON.parse(doc);});
  When('I exercise the Go subscription {string}',{timeout:240000},async function(mode){await exercise(this,mode,{});});
  When('I exercise the Go subscription {string} with:',{timeout:240000},async function(mode,t){await exercise(this,mode,Object.fromEntries(t.raw()));});
  async function exercise(w,mode,settings) {
    const input=w.goInput,c=await context(w); w.goContext=c;
    let outputs=[];
    if(mode==='login') {
      const l=await login(c,input);outputs.push(l.out);
      const p=credential(c),before=fs.existsSync(p)?fs.readFileSync(p):null;
      const list=await c.cli(['provider','list']);outputs.push(list.out);
      const empty=await c.cli(['provider','login','opencode-go'],'\n');outputs.push(empty.out);
      w.goObserved={login_exit:l.code,login_line:l.out.split('\n').find(s=>s==='opencode-go: key saved (not verified)')||null,list_exit:list.code,list_line:list.out.split('\n').find(s=>s.startsWith('opencode-go:'))||null,empty_exit:empty.code,empty_message:empty.out.includes('provider/login_failed: no OpenCode Go key supplied; saved login unchanged'),previous_bytes_kept:before!==null&&fs.readFileSync(p).equals(before),credential:before?JSON.parse(before):null,modes:before?[p,path.dirname(p),path.dirname(path.dirname(p))].map(f=>fs.statSync(f).mode&511):[],requests:c.records.length,no_public_secret:publicSafe(input,outputs)};return;
    }
    if(mode==='missing-login') {
      write(path.join(c.home,'.pi/agent/auth.json'),JSON.stringify({'opencode-go':{key:input.borrowed}}));
      const req=path.join(c.d,'request.txt');write(req,'Preserve the Go fixture.');
      const r=await c.cli(['intent','shape','missing-go',req]);
      w.goObserved={exit:r.code,login_guidance:r.out.includes('provider/login:')&&r.out.includes('kogen provider login opencode-go'),requests:c.records.length,no_public_secret:publicSafe(input,r.out)};return;
    }
    if(mode==='config') {
      const f=path.join(c.d,'invalid.yaml');write(f,yaml(settings));
      w.goObserved={...await nativeRun(c,input,{...settings,mode,yaml:f}),requests:c.records.length};return;
    }
    if(mode==='budget') {w.goObserved=await nativeRun(c,input,{mode});return;}
    if(mode==='workflow') {
      const l=await login(c,input); outputs.push(l.out);
      let phaseCounts={};
      c.fake.handleProvider=async(req,res)=>{
        const body=await decode(req),phase=c.phase(),n=(phaseCounts[phase]=(phaseCounts[phase]||0)+1);
        const r={phase,path:req.url,method:req.method,headers:req.headers,body};c.records.push(r);
        let raw;
        if(phase==='shape') raw=n===1?callsMessage([['read_file',{path:'README.md'}]],'shape1'):callsMessage([['submit',{questions:[{question:'Preserve the Go fixture?',options:[{label:'Preserve it',recommended:true}]}]}]],'shape2');
        if(phase==='refine') raw=n===1?callsMessage([['read_file',{path:'README.md'}]],'refine1'):callsMessage([['submit_refinement',{files:[{path:'.kogen/intents/fixture/intent.md',content:fixtureIntent('Keep the Go fixture')}]}]],'refine2');
        if(phase==='build') raw=n===1?callsMessage([['read_file',{path:'app.txt'}]],'build1'):callsMessage([['write_file',{path:'app.txt',content:'Go candidate\n'}],['finish',{summary:'done'}]],'build2');
        if(phase==='review') raw=n===1?callsMessage([['read_file',{path:'app.txt'}]],'review1'):callsMessage([['submit_review',n===2?{verdict:'changes',findings:[{path:'app.txt',line:1,severity:'blocking',message:'Retained fixture blocker: explicitly resume for fresh verification.'}]}:{verdict:'approve',findings:[]}]],'review'+n);
        assert.ok(raw,'unexpected workflow phase');r.sent=raw;completed(res,raw,input,phase+n);
      };
      const req=path.join(c.d,'request.txt');write(req,'ORIGINAL_GO_SOURCE_AUTHORITY: preserve the fixture, use the native source tools.');
      c.setPhase('shape');const shape=await c.cli(['intent','shape','go-source',req]);outputs.push(shape.out);
      const card0=await c.cli(['intent','approve','fixture']); const hash0=/SHA-256: ([0-9a-f]{64})/.exec(card0.out)?.[1];assert.ok(hash0,card0.out);
      const correction=path.join(c.d,'correction.txt');write(correction,'Change the fixture title to Keep the Go fixture, preserving every behavior.');
      c.setPhase('refine');const refine=await c.cli(['intent','refine','fixture',hash0,correction]);outputs.push(refine.out);
      const card=await c.cli(['intent','approve','fixture']); const hash=/SHA-256: ([0-9a-f]{64})/.exec(card.out)?.[1];assert.ok(hash,card.out);
      const approve=await c.cli(['intent','approve','fixture',hash]);outputs.push(approve.out);
      // The refined package belongs to approval, not the candidate change being built.
      await c.git(['add','.kogen/intents/fixture','features/steps/fixture_steps.js']);await c.git(['commit','-q','-m','fixture intent']);
      // Approval binds HEAD; obtain it again after the fixture package commit.
      const recard=await c.cli(['intent','approve','fixture']);const rehash=/SHA-256: ([0-9a-f]{64})/.exec(recard.out)?.[1];assert.ok(rehash,recard.out);await c.cli(['intent','approve','fixture',rehash]);
      const head=(await c.git(['rev-parse','HEAD'])).trim();
      c.setPhase('build');
      // Review begins during the same CLI invocation; dispatch from its real tool set.
      const handle=c.fake.handleProvider;
      c.fake.handleProvider=async(req,res)=>{
        const chunks=[];for await(const b of req)chunks.push(b);const bytes=Buffer.concat(chunks),body=JSON.parse(bytes.toString());
        const names=(body.tools||[]).map(t=>t.function?.name||t.name);if(names.includes('submit_review'))c.setPhase('review');
        const {Readable}=require('node:stream');const replay=Readable.from([bytes]);replay.url=req.url;replay.method=req.method;replay.headers=req.headers;await handle(replay,res);
      };
      const build=await c.cli(['intent','build','fixture']);outputs.push(build.out);
      const runRoot=path.join(c.repo,'.kogen/local/runs');const ids=fs.existsSync(runRoot)?fs.readdirSync(runRoot).filter(n=>fs.existsSync(path.join(runRoot,n,'result.json'))):[];assert.equal(ids.length,1,build.out);
      const id=ids[0],result=path.join(runRoot,id,'result.json'),before=fs.readFileSync(result);
      const blocked=(await c.git(['rev-parse','HEAD'])).trim()===head&&before.toString().includes('review_blocked');
      c.setPhase('review');const resume=await c.cli(['intent','resume',id]);outputs.push(resume.out);
      const usage=await c.cli(['intent','usage','--json']);outputs.push(usage.out);
      const attempts=[];for(const rid of fs.readdirSync(runRoot)){const p=path.join(runRoot,rid,'log.jsonl');if(fs.existsSync(p))for(const s of fs.readFileSync(p,'utf8').split('\n').filter(Boolean)){const r=JSON.parse(s);if(r.event==='provider_attempt')attempts.push(r);}}
      const reviews=c.records.filter(r=>r.phase==='review'),builders=c.records.filter(r=>r.phase==='build');
      const reviewText=JSON.stringify(reviews[0]?.body||{}),builderSecrets=builders.map(r=>r.sent?.reasoning).filter(Boolean);
      w.goObserved={exits:[shape.code,refine.code,approve.code,build.code,resume.code],phases:c.records.map(r=>r.phase),wire_and_replay:goObserver(c.records),source_retrieval:JSON.stringify(c.records.filter(r=>r.phase==='shape')).includes('ORIGINAL_GO_SOURCE_AUTHORITY')&&JSON.stringify(c.records.filter(r=>r.phase==='shape')[1]?.body).includes('Local Go fixture'),reviewer_independent:reviews.length===3&&builderSecrets.every(s=>!reviewText.includes(s)),review_contains_candidate:reviewText.includes('Go candidate'),prior_result_unchanged:fs.readFileSync(result).equals(before),blocked_without_commit:blocked,committed_candidate:resume.code===0&&(await c.git(['show','HEAD:app.txt']))==='Go candidate\n',one_commit:(await c.git(['rev-list','--count',head+'..HEAD'])).trim()==='1',usage_exit:usage.code,go_usage_present:usage.code===0&&usage.out.includes('opencode-go')&&attempts.length>0&&attempts.every(r=>r.provider.provider==='opencode-go'),no_public_secret:publicSafe(input,[outputs,attempts])};return;
    }
    assert.ok(['transport','supergrok-cache'].includes(mode));
    const l=await login(c,input);outputs.push(l.out);
    const sg=mode==='supergrok-cache',rejected=new Set();let semantic=0;
    c.fake.handleProvider=async(req,res)=>{
      const body=await decode(req); const r={phase:semantic>=2?'review':'build',path:req.url,method:req.method,headers:req.headers,body};c.records.push(r);
      if(settings.hold==='true'){c.held.add(res);res.on('close',()=>c.held.delete(res));return;}
      if(settings.status){res.writeHead(Number(settings.status),{'content-type':'application/json'});res.end(JSON.stringify({error:{code:settings.code,type:'invalid_request_error',message:'synthetic refusal'}}));return;}
      if(sg){
        const key=body.prompt_cache_key;
        if(settings.reject_key==='true'&&key&&!rejected.has(key)){rejected.add(key);res.writeHead(400,{'content-type':'application/json'});res.end(JSON.stringify({error:{code:'unsupported_parameter',param:'prompt_cache_key',message:'unsupported cache key'}}));return;}
        const items=semantic===1?[{type:'message',id:'m',role:'assistant',content:[{type:'output_text',text:'done'}]}]:[{type:'reasoning',id:'reason_'+semantic,summary:[],encrypted_content:'SYNTHETIC_PRIVATE_REASONING_ENCRYPTED'},{type:'function_call',call_id:'call_read',name:'read_file',arguments:'{"path":"app.txt"}'}];
        r.sent=items;res.writeHead(200,{'content-type':'text/event-stream'});res.end('data: '+JSON.stringify({type:'response.completed',response:{id:'response_'+semantic,status:'completed',output:items,usage:{input_tokens:100,input_tokens_details:{cached_tokens:20},output_tokens:10,output_tokens_details:{reasoning_tokens:4}}}})+'\n\n');semantic++;return;
      }
      let raw=semantic===1?{role:'assistant',content:'completed'}:structuredClone(input.raw);r.sent=raw;
      if(settings.completion==='malformed-tool')raw.tool_calls[0].function.arguments='{';
      const finish=settings.completion==='length'?'length':raw.tool_calls?.length?'tool_calls':'stop';
      res.writeHead(200,{'content-type':'application/json','x-request-id':'request_'+semantic});res.end(JSON.stringify({id:'response_'+semantic,object:'chat.completion',model:input.model,choices:settings.completion==='missing-choice'?[]:[{index:0,message:raw,finish_reason:finish}],usage:input.usage}));semantic++;
    };
    const r=await nativeRun(c,input,{...settings,mode,provider:sg?'supergrok':'opencode-go',model:sg?'grok-4.7':settings.model||input.model,effort:settings.effort||input.effort});
    await new Promise(resolve=>setTimeout(resolve,100));
    const results=r.results,md=results.map(x=>x.metadata).filter(Boolean),first=results[0],base=c.records[0];
    const withoutKey=b=>{const v=structuredClone(b);delete v.prompt_cache_key;return v;};
    let fallback=true;for(let i=0;i+1<c.records.length;i++)if(c.records[i].body.prompt_cache_key&&!c.records[i+1].body.prompt_cache_key)fallback&&=same(withoutKey(c.records[i].body),c.records[i+1].body);
    w.goObserved={outcomes:results.map(x=>x.outcome),requests:c.records.length,wire_and_replay:goObserver(c.records),effort_wire:base?.body.reasoning_effort??null,normalized_usage:first.value?.usage,unknown_write_and_effort:md.length===3&&md.every(m=>m.effective_effort===null&&m.cache.applied_ttl===null&&m.usage.write===null),only_go_route:c.records.every(x=>x.path===GO_PATH),failed_unknown:md.length>0&&md.every(m=>m.outcome==='failed'&&m.usage.input===null&&m.usage.cached===null),no_public_secret:publicSafe(input,[outputs,md]),no_completed_items:results.every(x=>!x.value),no_tool_effect:fs.readFileSync(path.join(c.repo,'app.txt'),'utf8')==='baseline\n',external_image_handoff:/extern|prepar|pixel/i.test(first.detail||''),bounded:first.elapsed>=200&&first.elapsed<1500,sockets_closed:c.held.size===0,key_flags:c.records.map(x=>!!x.body.prompt_cache_key),stable_routing:sg&&safe(()=>{const successful=c.records.filter(x=>x.sent);assert.equal(successful.length,3);const keys=successful.map(x=>x.body.prompt_cache_key);if(settings.reject_key!=='true'){assert.ok(keys[0]);assert.equal(keys[0],keys[1]);assert.notEqual(keys[1],keys[2]);}else{assert.equal(rejected.size,2);assert.deepEqual(keys,[undefined,undefined,undefined]);}return true;}),cache_only_fallback:fallback,encrypted_replay:sg&&c.records.filter(x=>x.sent)[1]?.body.input.some(x=>x.encrypted_content==='SYNTHETIC_PRIVATE_REASONING_ENCRYPTED')};
  }
  When('I parse the Go subscription preset {string}',{timeout:240000},async function(name){const c=await context(this);this.goContext=c;const f=path.join(ROOT,'docs/presets',name+'.yaml');assert.ok(fs.existsSync(f),'missing preset '+f);this.goObserved=await nativeRun(c,this.goInput,{mode:'preset',yaml:f});});
  When('I read the Go subscription guidance',function(){this.goGuidance=['README.md','docs/configuration.md','docs/usage.md'].map(f=>fs.readFileSync(path.join(ROOT,f),'utf8')).join('\n');});
  Then('the Go subscription guidance contains:',function(t){for(const [s]of t.raw())assert.ok(this.goGuidance.includes(s),'missing guidance '+s);});
  Then('the Go subscription observations include:',function(t){const errors=[];for(const[k,v]of t.raw()){try{assert.deepEqual(this.goObserved[k],JSON.parse(v),k);}catch(e){errors.push(e.message);}}assert.deepEqual(errors,[],JSON.stringify(this.goObserved));});
  After(async function(){if(this.goContext)for(const s of this.goContext.held)s.destroy();if(this.goFake)await this.goFake.close();});
  AfterAll(function(){for(const d of temps)fs.rmSync(d,{recursive:true,force:true});});
}
