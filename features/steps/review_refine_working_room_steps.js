const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawn, spawnSync } = require('node:child_process');
const ROOT = path.resolve(__dirname, '../..');
const same = (a, b) => { try { assert.deepEqual(a, b); return true; } catch { return false; } };
function replayCustody(d) {
  if (!d || !d.expected.length || !d.files.length) return false;
  const windows = [];
  for (const f of d.files) {
    const bytes = Buffer.from(f.bytes, 'base64');
    if (f.mode !== 384 || f.dir_mode !== 448 || crypto.createHash('sha256').update(bytes).digest('hex') !== f.sha256) return false;
    try { windows.push(JSON.parse(bytes).input || []); } catch { return false; }
  }
  windows.push(...d.requests);
  for (const w of windows) {
    const pending = new Set();
    for (const i of w) {
      if (i.type === 'function_call') { if (pending.has(i.call_id)) return false; pending.add(i.call_id); }
      if (i.type === 'function_call_output' && !pending.delete(i.call_id)) return false;
    }
    if (pending.size) return false;
  }
  const seen = [];
  for (const w of windows) for (const i of w) if (i.type === 'function_call' && !seen.includes(i.call_id)) seen.push(i.call_id);
  const wanted = d.expected.flatMap(g => g.filter(i => i.type === 'function_call').map(i => i.call_id));
  if (!same(seen.filter(id => wanted.includes(id)), wanted)) return false;
  return d.expected.every(g => windows.some(w => w.some((_, n) => same(w.slice(n, n + g.length), g))));
}
const control = String.raw`
r = Kogen.tmp_path("working-room-control")
File.mkdir_p!(r); File.chmod!(r,0o700)
try do
 File.write!(Path.join(r,"literal.txt"),"  Δ🙂\r\n/path with spaces/診断.txt\n  ")
 calls=for n <- 1..2, do: %{"type"=>"function_call","id"=>"fc#{n}","call_id"=>"c#{n}","name"=>"read_file","arguments"=>JSON.encode!(%{"path"=>"literal.txt"})}
 items=[%{"type"=>"reasoning","id"=>"r","encrypted_content"=>"opaque+/==\nDo not decode Δ","summary"=>[]},%{"type"=>"message","id"=>"m","role"=>"assistant","phase"=>"commentary","content"=>[%{"type"=>"output_text","text"=>"Unfinished native observation"}]}]++calls
 group=Enum.map(items,&Kogen.Shape.replay_item/1)++Enum.map(calls,fn c -> Kogen.Shape.output(c,Kogen.Tools.run(c["name"],JSON.decode!(c["arguments"]),%{root: r,protected: [],tools: ["read_file"]})) end)
 bytes=JSON.encode!(%{version: 1,owner: "refine",input: group,previous: nil})<>"\n"
 p=Path.join(r,"1.json"); File.write!(p,bytes); File.chmod!(p,0o600)
 File.write!(System.fetch_env!("ROOM_RECEIPT"),JSON.encode!(%{requests: [],expected: [group],files: [%{bytes: Base.encode64(File.read!(p)),sha256: Kogen.WorkingContext.hash(bytes),mode: Bitwise.band(File.stat!(p).mode,0o777),dir_mode: Bitwise.band(File.stat!(r).mode,0o777)}]}))
after File.rm_rf!(r) end
`;
if (require.main === module && process.argv[2] === '--control') {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'working-room-control-'));
  try {
    const file = path.join(dir, 'control.exs'), receipt = path.join(dir, 'receipt.json'); fs.writeFileSync(file, control);
    const r = spawnSync('mix', ['run', file], { cwd: ROOT, env: { ...process.env, ROOM_RECEIPT: receipt }, encoding: 'utf8', timeout: 60000 });
    if (r.status !== 0) throw new Error(r.stdout + r.stderr);
    const good = JSON.parse(fs.readFileSync(receipt, 'utf8')); assert.equal(replayCustody(good), true);
    if (process.argv[3] === 'good') process.stdout.write('accepted\n');
    else if (process.argv[3] === 'bad') {
      const rewrite = (d, edit) => { const doc = JSON.parse(Buffer.from(d.files[0].bytes, 'base64')); edit(doc.input); d.files[0].bytes = Buffer.from(JSON.stringify(doc)).toString('base64'); d.files[0].sha256 = crypto.createHash('sha256').update(Buffer.from(d.files[0].bytes, 'base64')).digest('hex'); };
      for (const mutate of [d => rewrite(d, w => w.pop()), d => rewrite(d, w => { w[0].encrypted_content += 'changed'; }), d => rewrite(d, w => { w[1].phase = 'final'; }), d => rewrite(d, w => { w[2].arguments += ' '; }), d => rewrite(d, w => w.reverse()), d => { d.files[0].sha256 = '0'.repeat(64); }, d => { d.files[0].mode = 420; }, d => { d.files[0].dir_mode = 493; }]) {
        const bad = structuredClone(good); mutate(bad); assert.equal(replayCustody(bad), false, 'counterexample accepted');
      }
      process.stdout.write('rejected\n'); process.exitCode = 1;
    } else throw new Error('unknown control');
  } catch (e) { process.stderr.write(String(e) + '\n'); process.exitCode = 2; }
  finally { fs.rmSync(dir, { recursive: true, force: true }); }
} else {
  const { Given, When, Then, AfterAll } = require('@cucumber/cucumber');
  let work, archivePromise;
  function run(file, args, options = {}) {
    return new Promise((resolve, reject) => {
      const child = spawn(file, args, { ...options, detached: true, stdio: ['ignore', 'pipe', 'pipe'] }); let out = '';
      child.stdout.on('data', b => { out += b; }); child.stderr.on('data', b => { out += b; });
      const timer = setTimeout(() => { try { process.kill(-child.pid, 'SIGKILL'); } catch {} }, 240000);
      child.on('error', e => { clearTimeout(timer); reject(e); }); child.on('close', code => { clearTimeout(timer); resolve({ code, out }); });
    });
  }
  const driver = String.raw`
ExUnit.start(autorun: false)
Code.require_file("test/support/integration_helpers.ex")
defmodule WorkingRoomExercise do
 alias Kogen.Integration.{Helpers,FakeProvider}
 alias Kogen.{Config,Intent,Shape,Tools,WorkingContext,Run}
 def f(n,a), do: {:function,n,a}
 def script(c,actions), do: Agent.update(c.server.state,fn s -> %{s|script: Enum.take(s.script,s.next)++actions,next: min(s.next,length(s.script))} end)
 def put(c,p,b) do
  p=Path.join(c.repo,p); File.mkdir_p!(Path.dirname(p)); File.write!(p,b)
 end
 def git(c,a) do
  {o,0}=Helpers.git!(c,a); String.trim(o)
 end
 def sha(c), do: Intent.hash(c.repo,Intent.baseline(c.repo,"fixture",Config.load!(c.repo)))
 def approve(c) do
  {o,0}=Helpers.run_kogen(c,["intent","approve","fixture",sha(c)]); o
 end
 def package(c), do: Map.new([Intent.intent_md("fixture"),Intent.feature("fixture"),"features/steps/integration_steps.js"],&{&1,File.read!(Path.join(c.repo,&1))})
 def custody(c), do: %{head: git(c,["rev-parse","HEAD"]),index: File.read!(Path.join(c.repo,".git/index")),approval: File.read(Intent.approval_path(c.repo,"fixture")),package: package(c)}
 def lines(p) do
  case File.read(p) do {:ok,b}->String.split(b,"\n",trim: true)|>Enum.map(&JSON.decode!/1); _->[] end
 end
 def events(c), do: Path.wildcard(Path.join(c.repo,".kogen/local/refinements/*/events.ndjson")) |> Enum.flat_map(&lines/1)
 def refs(c) do
  cp=Path.wildcard(Path.join(c.repo,".kogen/local/runs/*/checkpoint.json")) |> Enum.flat_map(fn p ->
   case Run.decode_checkpoint(File.read!(p)) do {:ok,_,b}->get_in(b.working_context,["review",:history])||[]; _->[] end
  end)
  es=for e <- events(c),is_map(e["archive"]),do: e["archive"]
  Enum.uniq_by(cp++es,& &1["path"])
 end
 def files(rs) do
  Enum.flat_map(rs,fn ref ->
   case File.read(ref["path"]) do
    {:ok,b}->[%{path: ref["path"],bytes: Base.encode64(b),sha256: ref["sha256"],mode: Bitwise.band(File.stat!(ref["path"]).mode,0o777),dir_mode: Bitwise.band(File.stat!(Path.dirname(ref["path"])).mode,0o777)}]
    _->[]
   end
  end)
 end
 def growth(c,spec,owner,range) do
  Enum.map(range,fn n ->
   calls=for j <- 1..spec["read_batch"], do: %{"type"=>"function_call","id"=>"fc-#{owner}-#{n}-#{j}","call_id"=>"call-#{owner}-#{n}-#{j}","name"=>"read_file","arguments"=>JSON.encode!(%{"path"=>"pad.txt"})}
   items=[%{"type"=>"reasoning","id"=>"rs-#{owner}-#{n}","encrypted_content"=>spec["opaque"]<>Integer.to_string(n),"summary"=>[]},%{"type"=>"message","id"=>"m-#{owner}-#{n}","role"=>"assistant","phase"=>"commentary","content"=>[%{"type"=>"output_text","text"=>"Unfinished #{owner} observation #{n}; unresolved findings and exact authority remain, not a new approval."}]}]++calls
   expected=Enum.map(items,&Shape.replay_item/1)++Enum.map(calls,fn call ->
    result=Tools.run("read_file",JSON.decode!(call["arguments"]),%{root: c.repo,protected: [],tools: ["read_file"]})
    Shape.output(call,if(owner=="refine",do: result,else: Tools.cut(result)))
   end)
   {{:items,items},expected}
  end)
 end
 def wait(port,out \\ "") do
  receive do
   {:provider_paused,pid}->{:paused,pid,out}
   {^port,{:data,b}}->wait(port,out<>b)
   {^port,{:exit_status,k}}->{:done,k,out}
  after 25000 -> raise("fixture timed out before paused provider") end
 end
 def damage(p,mode,c) do
  cond do
   String.ends_with?(mode,"missing")->File.rm!(p)
   String.ends_with?(mode,"symlink")->b=File.read!(p); q=Path.join(c.root,"replacement.json"); File.write!(q,b); File.rm!(p); File.ln_s!(q,p)
   String.ends_with?(mode,"mode")->File.chmod!(p,0o644)
   true->File.write!(p," ",[:append])
  end
 end
 def bounded(rs,s), do: rs != [] and Enum.all?(rs,&(byte_size(&1.body)<=s["budget"]))
 def authority(rs,phase \\ :refine) do
  stable=fn r ->
   case Enum.find(r.json["input"],&(&1["role"]=="user")) do
    %{"content"=>[first|_]} when phase==:review -> first
    message -> message
   end
  end
  case rs do
   [r|_]->a=stable.(r); a != nil and Enum.all?(rs,&(stable.(&1)==a))
   _->false
  end
 end
 def output_text(rs), do: for(r<-rs,i<-r.json["input"],i["type"]=="function_call_output",is_binary(i["output"]),do: i["output"]) |> Enum.join("\n")
 def count_trace(p) do
  case File.read(p) do {:ok,b}->length(String.split(b,"\n",trim: true)); _->0 end
 end
 def main do
  input=JSON.decode!(File.read!(System.fetch_env!("ROOM_INPUT"))); s=input["spec"]; packet=input["packet"]; mode=System.fetch_env!("ROOM_MODE")
  result=if mode=="measure" do
   role=%{model: "fixture",effort: "high"}
   base=Kogen.ChatGPT.request_body(role,"policy",[%{"role"=>"user","content"=>s["literal"]}],[])
   body=fn n -> empty=Map.put(base,"padding",""); Map.put(empty,"padding",String.duplicate("x",n-byte_size(JSON.encode!(empty)))) end
   bs=Enum.map([s["budget"]-1,s["budget"],s["budget"]+1],body)
   ms=Enum.map(bs,&WorkingContext.measure/1)
   %{bytes: Enum.map(ms,& &1.rendered_bytes),fits: Enum.map(ms,& &1.fits),reserve: Enum.map(ms,& &1.output_reserve_tokens),complete_rendered: Enum.zip(bs,ms)|>Enum.all?(fn {b,m}->byte_size(JSON.encode!(b))==m.rendered_bytes end)}
  else
   suite=Helpers.setup_suite!()
   try do
    c=Helpers.project!(suite,[],staged_intent: false)
    try do
     put(c,"pad.txt",String.duplicate("p",s["read_bytes"]))
     if String.starts_with?(mode,"review"),do: review(c,s,packet,mode),else: refine(c,s,packet,mode)
    after Helpers.cleanup_case(c) end
   after Helpers.cleanup_suite(suite) end
  end
  File.write!(System.fetch_env!("ROOM_RECEIPT"),JSON.encode!(result))
 end
 def review(c,s,packet,mode) do
  put(c,"README.md","# Fixture project\n"<>String.duplicate("r",s["review_readme_bytes"])<>"\n")
  put(c,"docs/development.md",String.duplicate("d",s["review_docs_bytes"])<>"\n")
  put(c,"seed-knowledge.txt",String.duplicate("k",s["review_added_bytes"])<>"\n")
  git(c,["add","README.md","docs/development.md","seed-knowledge.txt","pad.txt"]); git(c,["commit","-qm","Seed maintained documents"])
  p=Intent.intent_md("fixture"); put(c,p,File.read!(Path.join(c.repo,p))<>"\nReported source packet (diagnostic, no migration scope):\n"<>packet<>"\nExact literal:\n"<>s["literal"])
  approve(c); before=custody(c)
  edit="printf '\\nreview-edit\\n' >> README.md; printf '\\nreview-edit\\n' >> docs/development.md; cp seed-knowledge.txt knowledge_live.ex"
  script(c,[f("shell",%{"command"=>edit}),f("finish",%{"summary"=>"builder-only-sentinel; candidate complete"}),{:http,503,%{"error"=>%{"message"=>"local scripted overload","code"=>"server_error"}}}])
  {out,k}=Helpers.run_kogen(c,["intent","build","fixture"])
  [cp]=Path.wildcard(Path.join(c.repo,".kogen/local/runs/*/checkpoint.json")); id=Path.basename(Path.dirname(cp)); old_result=File.read!(Path.join(Path.dirname(cp),"result.json"))
  first=List.last(FakeProvider.review_requests(c.server))
  inline=first != nil and byte_size(first.body)<=s["budget"] and String.contains?(FakeProvider.input_text(first),"# Full text of every changed or added file") and not String.contains?(FakeProvider.input_text(first),"# Pinned complete candidate source evidence")
  groups=growth(c,s,"review",1..8)
  script(c,Enum.map(groups,&elem(&1,0))++[{:pause,self(),f("read_file",%{"path"=>"pad.txt"})}])
  n=length(FakeProvider.provider_requests(c.server)); port=Helpers.start_kogen(c,["intent","resume",id])
  {resume,code,delivered,damage_count}=case wait(port) do
   {:done,k,o}->{o,k,false,nil}
   {:paused,pid,o}->
    rs=refs(c)
    if mode=="review-damage" do
     target=Enum.find(rs,&String.contains?(&1["path"],"working-context")) || List.first(rs)
     if target,do: damage(target["path"],mode,c)
     count=length(FakeProvider.provider_requests(c.server)); send(pid,:continue); {tail,k}=Helpers.await_exit(port,"",30000); {o<>tail,k,false,count}
    else
     parts=Enum.filter(rs,fn r -> case JSON.decode(File.read!(r["path"])) do {:ok,d}->is_map(d["review_source"]); _->false end end)
     reads=Enum.map(parts,&f("read_file",%{"path"=>&1["path"]}))
     script(c,reads++[f("write_file",%{"path"=>"app.txt","content"=>"reviewer repaired\n"}),f("submit_review",%{"verdict"=>"approve","findings"=>[]})])
     send(pid,:continue); {tail,k}=Helpers.await_exit(port,"",40000)
     rr=FakeProvider.review_requests(c.server)
     original_source=Enum.find(first.json["input"],&(&1["role"]=="user"))["content"] |> Enum.at(1) |> Map.fetch!("text")
     recovered=Enum.map_join(parts,fn ref -> JSON.decode!(File.read!(ref["path"]))["review_source"]["text"] end)
     delivered=parts != [] and recovered==original_source and Enum.all?(parts,fn ref -> expected="1\t"<>String.trim_trailing(File.read!(ref["path"]),"\n"); Enum.any?(rr,fn r -> Enum.any?(r.json["input"],&(&1["type"]=="function_call_output" and &1["output"]==expected)) end) end)
     {o<>tail,k,delivered,nil}
    end
  end
  rr=FakeProvider.review_requests(c.server); resumed=Enum.drop(FakeProvider.provider_requests(c.server),n); after_state=custody(c)
  result=%{initial_inline_fit: inline,resumed_saved_review: k != 0 and first != nil and resumed != [] and hd(resumed).json["input"]==first.json["input"],success: code==0,source_relocated: Enum.any?(refs(c),&String.contains?(&1["path"],"review-source")),all_source_delivered: delivered,authority_exact: authority(rr,:review),bounded: bounded(rr,s),independent: rr != [] and Enum.all?(rr,fn r -> not String.contains?(JSON.encode!(r.json["input"]),"builder-only-sentinel") end),old_result_unchanged: File.read!(Path.join(Path.dirname(cp),"result.json"))==old_result,one_commit: git(c,["rev-list","--count",before.head<>"..HEAD"])=="1",final_repair_verified: code==0 and File.read!(Path.join(c.repo,"app.txt"))=="reviewer repaired\n" and Enum.any?(Path.wildcard(Path.join(c.repo,".kogen/local/runs/*/result.json")),fn p -> d=JSON.decode!(File.read!(p)); d["outcome"]=="landed" and d["passes"]>=2 and d["reviews"]==1 end),custody_refused: code != 0 and Regex.match?(~r/custody|resume_refused/,resume),no_inference_after_damage: damage_count != nil and length(FakeProvider.provider_requests(c.server))==damage_count,no_commit: after_state.head==before.head,approval_unchanged: after_state.approval==before.approval,output: out<>resume}
  if mode=="review-resume",do: Map.put(result,:replay,%{files: files(refs(c)),requests: Enum.map(rr,& &1.json["input"]),expected: Enum.map(groups,&elem(&1,1))}),else: result
 end
 def refine(c,s,packet,mode) do
  put(c,"README.md","# Fixture project\n"<>String.duplicate("R",s["refine_readme_bytes"])<>"\n"<>s["literal"])
  trace=Path.join(c.root,"readiness-count")
  config=Config.load!(c.repo)
  command="if grep -q 'Scenario:' \"$KOGEN_ACCEPTANCE_FEATURES\"; then printf 'run\\n' >> '#{trace}'; fi; "<>config.acceptance_run
  put(c,Config.path(),Config.render(%{setup: [],fix: [],checks: [],protect: config.protect,acceptance: %{run: command,steps_dir: config.steps_dir}}))
  git(c,["add","README.md","pad.txt",Config.path()]); git(c,["commit","-qm","Seed Refine authority and readiness trace"])
  approve(c); before=custody(c); before_trace=count_trace(trace)
  md=Intent.intent_md("fixture"); ft=Intent.feature("fixture"); js="features/steps/integration_steps.js"
  bad=before.package[md]<>"\n## Decisions\n- Keep retained correction.\n"
  good=String.replace(bad,"- Keep retained correction.","- Keep retained correction. (source: request)")
  feature=String.replace(before.package[ft],"Feature: Integration fixture","Feature: Retained native correction")
  step=String.replace(before.package[js],"if (!this.fixtureAvailable)","throw new Error('working-room legitimate product red');\n  if (!this.fixtureAvailable)")
  submit=fn fs -> f("submit_refinement",%{"files"=>fs}) end
  proposed=submit.([%{"path"=>md,"content"=>bad},%{"path"=>ft,"content"=>feature},%{"path"=>js,"content"=>step}])
  correction=packet<>"\nKeep exact correction literal:\n"<>s["literal"]<>if(mode=="refine-irreducible",do: String.duplicate("M",600000),else: "")
  request=Path.join(c.root,"correction.md"); File.write!(request,correction)
  groups=growth(c,s,"refine",1..s["turns"]); more=growth(c,s,"refine",(s["turns"]+1)..(s["turns"]+8))
  finish=submit.([%{"path"=>md,"content"=>good}])
  actions=cond do
   mode=="refine-irreducible"->[finish]
   mode=="refine-invalids"->[f("submit_refinement",%{"files"=>[]}),f("submit_refinement",%{"files"=>[]})]++Enum.map(groups,&elem(&1,0))++[f("submit_refinement",%{"files"=>[]}),finish]
   String.starts_with?(mode,"refine-damage")->[proposed]++Enum.map(groups,&elem(&1,0))++[{:pause,self(),finish}]
   true->[proposed]++Enum.map(groups,&elem(&1,0))++[submit.([%{"path"=>md,"content"=>"POISON"},%{"path"=>"app.txt","content"=>"unsafe"}]),finish]++Enum.map(more,&elem(&1,0))++[finish]
  end
  script(c,actions); n=length(FakeProvider.provider_requests(c.server))
  {out,k,damage_count}=if String.starts_with?(mode,"refine-damage") do
   port=Helpers.start_kogen(c,["intent","refine","fixture",sha(c),request])
   case wait(port) do
    {:done,k,o}->{o,k,nil}
    {:paused,pid,o}->target=List.first(refs(c)); if target,do: damage(target["path"],mode,c); count=length(FakeProvider.provider_requests(c.server)); send(pid,:continue); {tail,k}=Helpers.await_exit(port,"",30000); {o<>tail,k,count}
   end
  else
   {o,k}=Helpers.run_kogen(c,["intent","refine","fixture",sha(c),request]); {o,k,nil}
  end
  rs=Enum.drop(FakeProvider.provider_requests(c.server),n); es=events(c); resets=Enum.filter(es,&(&1["event"]=="working_context_reset")); after_state=custody(c); text=output_text(rs)
  stop=Enum.find(es,&(&1["event"]=="working_context_stop"))
  unsent=if stop && is_map(stop["archive"]) && File.regular?(stop["archive"]["path"]) do
   ref=stop["archive"]; b=File.read!(ref["path"]); d=JSON.decode!(b)
   stop["owner"]=="refine" and stop["input_budget_bytes"]==s["budget"] and stop["output_reserve_tokens"]==s["reserve"] and stop["measured_bytes"]>s["budget"] and WorkingContext.hash(b)==ref["sha256"] and Bitwise.band(File.stat!(ref["path"]).mode,0o777)==0o600 and Bitwise.band(File.stat!(Path.dirname(ref["path"])).mode,0o777)==0o700 and String.contains?(JSON.encode!(d["input"]),String.duplicate("M",600000))
  else false end
  valid_events=resets != [] and Enum.with_index(resets,1)|>Enum.all?(fn {e,i}->e["owner"]=="refine" and e["generation"]==i and e["before_bytes"]>s["budget"] and e["after_bytes"]<=s["budget"] and e["after_bytes"]<e["before_bytes"] and e["input_budget_bytes"]==s["budget"] and e["output_reserve_tokens"]==s["reserve"] and Enum.any?(rs,&(byte_size(&1.body)==e["after_bytes"])) end)
  result=%{success: k==0,reset_happened: resets != [],at_least_three_resets: length(resets)>=3,authority_exact: authority(rs),bounded: bounded(rs,s),complete_package: after_state.package==Map.merge(before.package,%{md=>good,ft=>feature,js=>step}),unsafe_not_retained: File.read!(Path.join(c.repo,"app.txt"))=="baseline\n" and not String.contains?(after_state.package[md],"POISON"),red_observed: String.contains?(text,"Readiness observations") and String.contains?(text,"working-room legitimate product red"),one_candidate_readiness: count_trace(trace)-before_trace==1,approval_revoked: not File.exists?(Intent.approval_path(c.repo,"fixture")) and Enum.any?(Path.wildcard(Path.join(c.repo,".kogen/local/refinements/*/revoked-approval.json")),&(File.read!(&1)==elem(before.approval,1))),head_index_unchanged: after_state.head==before.head and after_state.index==before.index,package_unchanged: after_state.package==before.package,approval_unchanged: after_state.approval==before.approval,invalid_limit_preserved: k != 0 and String.contains?(out,"shape/refinement_invalid") and length(rs)==s["turns"]+3,custody_refused: k != 0 and String.contains?(out,"candidate/context_custody_invalid"),no_inference_after_damage: damage_count != nil and length(FakeProvider.provider_requests(c.server))==damage_count,irreducible_refused: k != 0 and String.contains?(out,"candidate/context_budget_exceeded"),no_inference: rs==[],unsent_retained: unsent,actionable_nonresume: String.contains?(out,"working-context") and not String.contains?(out,"kogen intent resume") and Regex.match?(~r/identical|unchanged/i,out),reset_events_valid: valid_events,output: out}
  if mode=="refine-growth",do: Map.put(result,:replay,%{files: files(refs(c)),requests: Enum.map(rs,& &1.json["input"]),expected: Enum.map(groups++more,&elem(&1,1))}),else: result
 end
end
WorkingRoomExercise.main()
`;
  Given('the working-room source packet:', function (packet) { this.roomPacket = packet; });
  Given('the working-room local fixture parameters:', function (json) { this.roomSpec = JSON.parse(json); });
  AfterAll(function () { if (work) fs.rmSync(work, { recursive: true, force: true }); });
  When('I exercise native working room {string}', { timeout: 300000 }, async function (mode) {
    if (!archivePromise) archivePromise = (async () => {
      work = fs.mkdtempSync(path.join(os.tmpdir(), 'native-working-room-'));
      const r = await run('/bin/sh', ['packaging/package.sh'], { cwd: ROOT }); assert.equal(r.code, 0, r.out);
      const archive = r.out.split('\n').find(x => x.startsWith('/') && x.endsWith('.tar.gz')); assert.ok(archive && fs.existsSync(archive), r.out); return archive;
    })();
    const archive = await archivePromise, dir = fs.mkdtempSync(path.join(work, 'case-'));
    try {
      const file = path.join(dir, 'driver.exs'), input = path.join(dir, 'input.json'), receipt = path.join(dir, 'receipt.json');
      fs.writeFileSync(file, driver); fs.writeFileSync(input, JSON.stringify({ packet: this.roomPacket, spec: this.roomSpec }));
      const dirs = [];
      for (const name of ['mix', 'erl', 'go', 'node', 'npm', 'python3']) { const r = await run('mise', ['which', name], { cwd: ROOT }); assert.equal(r.code, 0, r.out); dirs.push(path.dirname(r.out.trim())); }
      const r = await run('mix', ['run', file], { cwd: ROOT, env: { ...process.env, PATH: [...dirs, process.env.PATH].join(path.delimiter), KOGEN_ARCHIVE: archive, ROOM_MODE: mode, ROOM_INPUT: input, ROOM_RECEIPT: receipt } });
      assert.equal(r.code, 0, r.out); assert.ok(fs.existsSync(receipt), r.out);
      const data = JSON.parse(fs.readFileSync(receipt, 'utf8'));
      if (data.replay) { data.replay_custody = replayCustody(data.replay); delete data.replay; }
      this.roomResult = data; await this.attach(JSON.stringify(data), 'application/json');
    } finally { fs.rmSync(dir, { recursive: true, force: true }); }
  });
  Then('the native working-room observations include:', function (json) {
    for (const [name, expected] of Object.entries(JSON.parse(json))) assert.deepEqual(this.roomResult[name], expected, `${name}: ${JSON.stringify(this.roomResult)}`);
  });
}
