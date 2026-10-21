const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn, spawnSync } = require('node:child_process');
const ROOT = path.resolve(__dirname, '../..');
const same = (a, b) => { try { assert.deepEqual(a, b); return true; } catch { return false; } };
// These predicates judge real captured replay, not compiler stdout or a model's pass claim.
function replayCustody(d) {
  if (!d.windows.length || !d.expected.length || !d.files.length) return false;
  for (const input of d.windows) {
    const pending = new Set();
    for (const item of input) {
      if (item.type === 'function_call') { if (pending.has(item.call_id)) return false; pending.add(item.call_id); }
      if (item.type === 'function_call_output') { if (!pending.delete(item.call_id)) return false; }
    }
    if (pending.size) return false;
  }
  return d.expected.every(group => d.windows.some(w => {
    for (let i = 0; i <= w.length - group.length; i++) if (same(w.slice(i, i + group.length), group)) return true;
    return false;
  })) && d.files.every(f => f.file_mode === 384 && f.dir_mode === 448);
}
const controlScript = String.raw`
tmp = Kogen.tmp_path("continuity-control")
File.mkdir_p!(tmp)
File.chmod!(tmp,0o700)
try do
 literal = "  Δ🙂\r\n/path with spaces/診断.txt\nHTML title — personal suffix  "
 call = %{"type"=>"function_call","id"=>"native-control-call","call_id"=>"control-1","name"=>"write_file","arguments"=>JSON.encode!(%{"path"=>"native.txt","content"=>literal})}
 reasoning = %{"type"=>"reasoning","id"=>"native-control-reasoning","encrypted_content"=>"opaque+/==\nDo not decode Δ","summary"=>[]}
 message = %{"type"=>"message","id"=>"native-control-message","role"=>"assistant","phase"=>"commentary","content"=>[%{"type"=>"output_text","text"=>"UNFINISHED: exact native progress"}]}
 result = Kogen.Tools.run("write_file",%{"path"=>"native.txt","content"=>literal},%{root: tmp,protected: [],tools: ["write_file"]})
 if result != "ok" or File.read!(Path.join(tmp,"native.txt")) != literal, do: raise("native fixture did not write exact bytes")
 group = Enum.map([reasoning,message,call],&Kogen.Shape.replay_item/1) ++ [Kogen.Shape.output(call,result)]
 file = Path.join(tmp,"window.json")
 File.write!(file,JSON.encode!(%{"input"=>group}))
 File.chmod!(file,0o600)
 decoded = JSON.decode!(File.read!(file))["input"]
 receipt = %{windows: [decoded], expected: [group], files: [%{file_mode: Bitwise.band(File.stat!(file).mode,0o777),dir_mode: Bitwise.band(File.stat!(tmp).mode,0o777)}]}
 File.write!(System.fetch_env!("CONTINUITY_CONTROL"),JSON.encode!(receipt))
after
 File.rm_rf!(tmp)
end
`;
if (require.main === module && process.argv[2] === '--control') {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-continuity-control-'));
  try {
    const script = path.join(dir, 'control.exs'), receipt = path.join(dir, 'receipt.json');
    fs.writeFileSync(script, controlScript);
    const r = spawnSync('mix', ['run', script], { cwd: ROOT, env: { ...process.env, CONTINUITY_CONTROL: receipt }, encoding: 'utf8', timeout: 60000 });
    if (r.status !== 0 || !fs.existsSync(receipt)) throw new Error(r.stdout + r.stderr);
    const good = JSON.parse(fs.readFileSync(receipt, 'utf8'));
    assert.equal(replayCustody(good), true, 'actual native fixture must be known good');
    if (process.argv[3] === 'good') { process.stdout.write('accepted\n'); }
    else if (process.argv[3] === 'bad') {
      const mutations = [
        d => d.windows[0].pop(),
        d => d.windows[0][0].encrypted_content += 'changed',
        d => d.windows[0][1].phase = 'final',
        d => { const a = JSON.parse(d.windows[0][2].arguments); a.content = a.content.trim(); d.windows[0][2].arguments = JSON.stringify(a); },
        d => d.windows[0].reverse(),
        d => d.files[0].file_mode = 420,
        d => d.files[0].dir_mode = 493,
      ];
      for (const mutate of mutations) { const bad = structuredClone(good); mutate(bad); assert.equal(replayCustody(bad), false, 'counterexample accepted'); }
      process.stdout.write('rejected\n'); process.exitCode = 1;
    } else throw new Error('unknown control');
  } catch (e) { process.stderr.write(String(e) + '\n'); process.exitCode = 2; }
  finally { fs.rmSync(dir, { recursive: true, force: true }); }
} else {
  const { When, Then, AfterAll } = require('@cucumber/cucumber');
  let work, archivePromise;
  function run(file, args, options = {}) {
    return new Promise((resolve, reject) => {
      const child = spawn(file, args, { ...options, detached: true, stdio: ['ignore', 'pipe', 'pipe'] });
      let out = ''; child.stdout.on('data', b => { out += b; }); child.stderr.on('data', b => { out += b; });
      const timer = setTimeout(() => { try { process.kill(-child.pid, 'SIGKILL'); } catch {} }, 240000);
      child.on('error', e => { clearTimeout(timer); reject(e); });
      child.on('close', code => { clearTimeout(timer); resolve({ code, out }); });
    });
  }
  const driver = String.raw`
Code.require_file(Path.expand("test/support/integration_helpers.ex",File.cwd!()))
defmodule NativeContinuityExercise do
 use ExUnit.Case
 alias Kogen.{Intent, Shape}
 alias Kogen.Integration.{Helpers, FakeProvider}
 @tag timeout: 200_000
 test "observe native continuity" do
  spec=JSON.decode!(File.read!(System.fetch_env!("CONTINUITY_INPUT")))
  mode=System.fetch_env!("CONTINUITY_MODE")
  receipt = if mode == "measure" do
   if Code.ensure_loaded?(Kogen.WorkingContext) and function_exported?(Kogen.WorkingContext,:measure,1) do
    base=%{"model"=>"gpt-6.1-sol","input"=>[%{"role"=>"user","content"=>spec["literal"]}],"tools"=>[%{"name"=>"sample","type"=>"function"}],"store"=>false,"stream"=>true}
    initial=apply(Kogen.WorkingContext,:measure,[base])
    body=fn target -> Map.put(base,"padding",String.duplicate("x",target-byte_size(JSON.encode!(Map.put(base,"padding",""))))) end
    rows=Enum.map([spec["budget"]-1,spec["budget"],spec["budget"]+1],fn n -> apply(Kogen.WorkingContext,:measure,[body.(n)]) end)
    %{supported: true,boundary_bytes: Enum.map(rows,& &1.rendered_bytes),boundary_fits: Enum.map(rows,& &1.fits),complete_envelope: initial.rendered_bytes==byte_size(JSON.encode!(base)) and initial.input_budget_bytes==spec["budget"] and initial.output_reserve_tokens==spec["reserve"],unicode_exact: hd(base["input"])["content"]==spec["literal"],metadata_is_not_threshold: spec["last_completed_input"]==883138 and spec["rejected_request_usage"]==nil}
   else
    %{supported: false}
   end
  else
   suite=Helpers.setup_suite!()
   try do
    c=Helpers.project!(suite,[],staged_intent: false)
    try do
     if mode in ["provenance","refine-source","refuse-refine","source-drift"], do: provenance(c,spec,mode), else: growth(c,spec,mode)
    after
     Helpers.cleanup_case(c)
    end
   after
    Helpers.cleanup_suite(suite)
   end
  end
  File.write!(System.fetch_env!("CONTINUITY_RECEIPT"),JSON.encode!(receipt))
 end
 defp f(n,a), do: {:function,n,a}
 defp script(c,actions), do: Agent.update(c.server.state,fn s -> %{s|script: Enum.take(s.script,s.next) ++ List.duplicate(nil,max(s.next-length(s.script),0)) ++ actions} end)
 defp count(c), do: length(FakeProvider.provider_requests(c.server))
 defp git(c,a) do
  {o,0}=Helpers.git!(c,a); String.trim(o)
 end
 defp digest(b), do: :crypto.hash(:sha256,b) |> Base.encode16(case: :lower)
 defp put(c,p,b) do
  p=Path.join(c.repo,p); File.mkdir_p!(Path.dirname(p)); File.write!(p,b)
 end
 defp custody(c,slug), do: %{head: git(c,["rev-parse","HEAD"]),index: File.read!(Path.join(c.repo,".git/index")),approval: File.read(Intent.approval_path(c.repo,slug)),app: File.read!(Path.join(c.repo,"app.txt"))}
 defp approve(c,slug) do
  {out,5}=Helpers.run_kogen(c,["intent","approve",slug])
  [_,hash]=Regex.run(~r/SHA-256: ([a-f0-9]{64})/,out)
  {a,0}=Helpers.run_kogen(c,["intent","approve",slug,hash]); {out,hash,a}
 end
 defp cps(c), do: Path.wildcard(Path.join(c.repo,".kogen/local/runs/*/checkpoint.json")) |> Enum.sort()
 defp files(p) do
  if File.dir?(p), do: Enum.flat_map(File.ls!(p),&files(Path.join(p,&1))), else: if(File.regular?(p),do: [p],else: [])
 end
 defp archives(c), do: Path.wildcard(Path.join(c.repo,".kogen/local/runs/*/working-context/*/*.json")) |> Enum.sort()
 defp private?(paths), do: paths != [] and Enum.all?(paths,fn p -> Bitwise.band(File.stat!(p).mode,0o777)==0o600 and Bitwise.band(File.stat!(Path.dirname(p)).mode,0o777)==0o700 end)
 defp handoffs(requests) do
  for r <- requests, i <- r.json["input"] || [], is_binary(i["content"]), String.starts_with?(i["content"],"Local working-window reset\n"), do: JSON.decode!(String.replace_prefix(i["content"],"Local working-window reset\n",""))
 end
 defp growth(c,spec,mode) do
  if mode=="mandatory" do
   put(c,"README.md",String.duplicate("M",spec["mandatory_bytes"]))
   git(c,["add","README.md"]); git(c,["commit","-qm","Large mandatory instructions"])
   approve(c,"fixture")
   before=custody(c,"fixture"); n=count(c)
   {o,k}=Helpers.run_kogen(c,["intent","build","fixture"])
   %{refused: k != 0,no_model_on_refusal: count(c)==n,custody_unchanged: custody(c,"fixture")==before,actionable: o =~ "checkpoint" and o =~ "approval",budget_diagnostic: o =~ "candidate/context_budget_exceeded" and o =~ Integer.to_string(spec["budget"]) and o =~ Integer.to_string(spec["reserve"])}
  else
   literal=spec["literal"]
   md=Path.join(c.repo,Intent.intent_md("fixture"))
   File.write!(md,File.read!(md)<>"\nApproved exact literal:\n"<>literal<>"\n")
   approve(c,"fixture")
   before=custody(c,"fixture")
   external=Path.join(c.root,"archived-native-production.txt")
   File.write!(external,"native preserved production\n")
   context=Path.join(c.root,"reuse-context.txt")
   reuse=spec["reuse"]<>"\nAbsolute preserved native production: "<>external<>"\nSHA-256: "<>digest(File.read!(external))<>"\nOld check result: green for OLD candidate only. Do not import protected acceptance bytes.\n"
   File.write!(context,reuse)
   shell="cat '"<>external<>"' > app.txt; printf 'once\\n' >> .kogen/local/continuity-effects"
   groups=for owner <- ["build","review"], i <- 1..spec["turns"] do
    id=owner<>"-"<>Integer.to_string(i)
    payload=literal<>"\n"<>id<>"\n"<>String.duplicate("x",spec["payload_bytes"])
    call=%{"type"=>"function_call","id"=>"item-"<>id,"call_id"=>"call-"<>id,"name"=>"write_file","arguments"=>JSON.encode!(%{"path"=>"app.txt","content"=>payload})}
    msg=%{"type"=>"message","id"=>"message-"<>id,"role"=>"assistant","phase"=>"commentary","content"=>[%{"type"=>"output_text","text"=>owner<>" "<>spec["unfinished"]<>"\n"<>spec["finding"]}]}
    reasoning=%{"type"=>"reasoning","id"=>"reasoning-"<>id,"encrypted_content"=>spec["opaque"]<>id,"summary"=>[]}
    {owner,[reasoning,msg,call],Enum.map([reasoning,msg,call],&Shape.replay_item/1)++[Shape.output(call,"ok")]}
   end
   build=for {"build",items,_} <- groups, do: {:items,items}
   review=for {"review",items,_} <- groups, do: {:items,items}
   script(c,[f("shell",%{"command"=>shell})]++build++[f("finish",%{"summary"=>"current candidate ready"})]++review)
   n=count(c)
   {out,k}=Helpers.run_kogen(c,["intent","build","fixture","--context",context])
   requests=Enum.drop(FakeProvider.provider_requests(c.server),n)
   ap=archives(c)
   windows=Enum.map(ap,fn p -> JSON.decode!(File.read!(p))["input"] end)
   wire=Enum.map(requests,& &1.json["input"])
   replay=%{windows: windows++wire,expected: Enum.map(groups,&elem(&1,2)),files: Enum.map(ap,fn p -> %{file_mode: Bitwise.band(File.stat!(p).mode,0o777),dir_mode: Bitwise.band(File.stat!(Path.dirname(p)).mode,0o777)} end)}
   h=handoffs(requests)
   owners=Enum.map(h,& &1["owner"])
   resets=%{reset_build: "build" in owners,reset_review: "review" in owners}
   case cps(c) do
    [cp] ->
     id=Path.basename(Path.dirname(cp)); result=Path.join(Path.dirname(cp),"result.json"); original_result=File.read!(result)
     saved=List.last(requests)
     old=custody(c,"fixture")
     File.write!(context,"POISON replacement\n"); File.rm!(external)
     if mode=="archive-drift" and ap != [], do: File.write!(hd(ap),"{\"input\": []}\n")
     if mode=="grow-legacy" do
      doc=JSON.decode!(File.read!(cp))
      b=:erlang.binary_to_term(Base.decode64!(doc["state"]))
      b=Map.drop(b,[:working_context,:source_provenance])
      doc=Map.merge(doc,%{"version"=>2,"state"=>Base.encode64(:erlang.term_to_binary(b))})
      File.write!(cp,JSON.encode!(doc))
     end
     script(c,[f("submit_review",%{"verdict"=>"approve","findings"=>[]})])
     next=count(c)
     {resume,rk}=Helpers.run_kogen(c,["intent","resume",id])
     resumed=Enum.drop(FakeProvider.provider_requests(c.server),next)
     rejection=%{refused: rk != 0,no_model_on_refusal: resumed==[],custody_unchanged: custody(c,"fixture")==old,actionable: Regex.match?(~r/history|archive|checkpoint|unsupported|custody/i,resume)}
     same_owner=resumed != [] and hd(resumed).json["input"]==saved.json["input"] and Enum.member?(FakeProvider.review_requests(c.server),hd(resumed))
     committed=rk==0 and git(c,["rev-list","--count",before.head<>"..HEAD"])=="1"
     landed=files(Path.join(c.repo,".kogen/local/runs")) |> Enum.filter(&String.ends_with?(&1,"/result.json")) |> Enum.map(&(JSON.decode!(File.read!(&1)))) |> Enum.filter(&(&1["outcome"]=="landed"))
     fresh=rk==0 and resume =~ "landed" and Enum.any?(landed,fn r -> r["passes"]>=2 and r["reviews"]==1 end)
     legacy_refusal=mode=="grow-legacy" and rejection.refused and rejection.no_model_on_refusal and rejection.custody_unchanged and rejection.actionable
     common=Map.merge(resets,%{replay: replay,bounded: requests != [] and Enum.all?(requests,&(byte_size(&1.body)<=spec["budget"])),authority_exact: Enum.all?(requests,fn r -> FakeProvider.input_text(r) =~ literal and FakeProvider.input_text(r) =~ "# Testing rules" end),progress_exact: h != [] and Enum.all?(h,fn x -> t=JSON.encode!(x); t =~ spec["unfinished"] and t =~ spec["finding"] and x["candidate_tree"] != nil and x["approval_sha256"] != nil and x["checks"]["status"] in ["not_run","stale","failed"] end),review_independent: FakeProvider.review_requests(c.server) != [] and Enum.all?(FakeProvider.review_requests(c.server),fn r -> not String.contains?(JSON.encode!(r.json["input"]),"message-build-") end),private: private?(ap),no_commit_before_resume: k != 0 and old.head==before.head,completed_effect_once: File.read!(Path.join(c.repo,".kogen/local/continuity-effects"))=="once\n",old_result_unchanged: File.read!(result)==original_result,original_input_disposable: not File.exists?(external) and File.read!(context)=="POISON replacement\n",reuse_diagnostic_only: hd(requests).body =~ external and hd(requests).body =~ digest("native preserved production\n") and not String.contains?(git(c,["ls-tree","-r","--name-only","HEAD"]),"diagnostic-context"),same_saved_owner: same_owner,one_commit: committed,fresh_checks_review: fresh,legacy_refusal: legacy_refusal,resume_outcome_safe: (same_owner and committed and fresh) or legacy_refusal})
     if mode=="archive-drift", do: Map.merge(common,rejection), else: common
    _ -> Map.merge(resets,%{replay: replay,output: out,code: k})
   end
  end
 end
 defp provenance(c,spec,mode) do
  # The shared factory leaves its default Intent uncommitted; captured owns a different step.
  # Commit that unrelated fixture before Shape/approval so their HEAD binding stays current.
  git(c,["add",".kogen/intents/fixture","features/steps/integration_steps.js"])
  git(c,["commit","-qm","Commit unrelated provenance fixture baseline"])
  assert git(c,["status","--porcelain"])==""
  slug="captured"
  input=Path.join(c.root,"original request.txt")
  request=spec["request"]<>"\nSelected settled context:\n"<>spec["selected_context"]<>"\nWrong-example counterexample: "<>spec["wrong_example"]<>"\n"
  File.write!(input,request)
  question=%{"question"=>spec["question"],"options"=>[%{"label"=>"Keep exactly — Almir Δ🙂","recommended"=>true},%{"label"=>"Obsolete suffix"}]}
  dir=Intent.dir(slug); step="features/steps/captured.js"
  feature="Feature: Source fixture\n  Scenario: Approved scope stays bounded\n    Then the approved fixture stays bounded\n"
  body="const {Then}=require('@cucumber/cucumber');const fs=require('node:fs');const assert=require('node:assert/strict');Then('the approved fixture stays bounded',()=>assert.equal(fs.readFileSync('app.txt','utf8'),'baseline\\n'));\n"
  md="# Preserve bounded source scope\n\nSlug: #{slug}\nModel: not applicable — provenance fixture\nAcceptance:\n- #{dir}/acceptance.feature\n- #{step}\n\nKeep app.txt baseline. The private original cannot add a title suffix to this approved scope.\n\n## Decisions\n- Preserve approved scope. (source: request)\n\n## Source comparison\n- omitted: #{spec["omission"]}; source answer 1; contract has no title rule.\n- addressed: private source retrieval and no original-request override.\n\n## Tests\n- approved scope: actual file (scenario)\n\n## Feasibility\n- none\n"
  package=[%{"path"=>Intent.intent_md(slug),"content"=>md},%{"path"=>Intent.feature(slug),"content"=>feature},%{"path"=>step,"content"=>body}]
  script(c,[f("submit",%{"questions"=>[question]})])
  {q,qk}=Helpers.run_kogen(c,["intent","shape",slug,input]); assert qk==5,q
  answers=Path.join(c.root,"answers.txt"); File.write!(answers,spec["answer"])
  script(c,[f("submit",%{"files"=>package})])
  {shape,sk}=Helpers.run_kogen(c,["intent","shape",slug,answers]); assert sk==0,shape
  source=Path.join(c.repo,".kogen/local/provenance/#{slug}/current.json")
  if not File.regular?(source) do
   %{successful_source: false,output: shape}
  else
   bytes=File.read!(source); doc=JSON.decode!(bytes)
   {card,hash,_}=approve(c,slug)
   approval=File.read!(Intent.approval_path(c.repo,slug))
   basic=%{successful_source: true,exact_request: doc["request"]["text"]==request,exact_answer: Enum.any?(doc["rounds"] || [],fn r -> r["input"]==spec["answer"] and r["questions"]==[question] and JSON.encode!(r["answers"]) =~ "Almir" end),source_identity: doc["request"]["source_path"]==input and doc["request"]["sha256"]==digest(request) and doc["contract_sha256"]==hash,private: private?([source]),card_comparison: card =~ spec["omission"] and card =~ "provenance" and card =~ digest(bytes),card_no_raw_request: not String.contains?(card,request),approval_bound: approval =~ digest(bytes),source_untracked: not String.contains?(git(c,["ls-files"]),".kogen/local/provenance")}
   case mode do
    m when m in ["refine-source","refuse-refine"] ->
     correction=Path.join(c.root,"correction.txt"); File.write!(correction,spec["correction"])
     if mode=="refuse-refine", do: script(c,[f("submit_refinement",%{"constraint"=>"preserve original; cannot safely correct"})]), else: script(c,[f("submit_refinement",%{"files"=>[%{"path"=>Intent.intent_md(slug),"content"=>String.replace(md,"- omitted: "<>spec["omission"],"- addressed: "<>spec["correction"])<>"\nApproved title suffix: "<>spec["literal"]<>"\n"}]})])
     {o,k}=Helpers.run_kogen(c,["intent","refine",slug,hash,correction])
     now=File.read!(source); updated=JSON.decode!(now)
     prior=files(Path.dirname(source)) |> Enum.any?(fn p -> p != source and File.read!(p)==bytes end)
     if mode=="refuse-refine",do: Map.merge(basic,%{refine_safe: k != 0,prior_source_preserved: now==bytes,correction_exact: now==bytes,approval_safe: File.read!(Intent.approval_path(c.repo,slug))==approval}),else: Map.merge(basic,%{refine_safe: k==0,prior_source_preserved: prior,correction_exact: Enum.any?(updated["corrections"]||[],fn x -> (x["text"]==spec["correction"] or get_in(x,["request","text"])==spec["correction"]) and JSON.encode!(x) =~ hash end),approval_safe: not File.exists?(Intent.approval_path(c.repo,slug)),output: o})
    "source-drift" ->
     File.write!(source,bytes<>" ")
     before=custody(c,slug); n=count(c)
     {o,k}=Helpers.run_kogen(c,["intent","build",slug])
     Map.merge(basic,%{refused: k != 0,no_model_on_refusal: count(c)==n,custody_unchanged: custody(c,slug)==before,actionable: Regex.match?(~r/source|provenance/i,o)})
    _ ->
     File.write!(input,"POISON replacement"); File.rm!(answers)
     relative=Path.relative_to(source,c.repo)
     script(c,[f("read_file",%{"path"=>relative}),f("finish",%{"summary"=>"approved scope only"}),f("read_file",%{"path"=>relative}),f("submit_review",%{"verdict"=>"approve","findings"=>[]})])
     n=count(c); {o,k}=Helpers.run_kogen(c,["intent","build",slug])
     reqs=Enum.drop(FakeProvider.provider_requests(c.server),n); rev=FakeProvider.review_requests(c.server)
     text=Enum.map(reqs,&FakeProvider.input_text/1)
     outputs=FakeProvider.tool_outputs(c.server)
     escaped=JSON.encode!(request) |> String.slice(1..-2//1)
     retrieved=Enum.filter(outputs,&String.contains?(&1,escaped))
     tracked=git(c,["ls-tree","-r","--name-only","HEAD"])
     reference=fn r -> t=FakeProvider.input_text(r); t =~ relative or t =~ "source-provenance.json" end
     Map.merge(basic,%{build_retrieval: retrieved != [] and Enum.any?(reqs,fn r -> not Enum.member?(rev,r) and reference.(r) end),review_retrieval: Enum.any?(rev,reference) and length(retrieved)>=2,diagnostic_not_authority: Enum.any?(text,&Regex.match?(~r/diagnostic.*provenance|provenance.*diagnostic/is,&1)) and Enum.any?(text,&Regex.match?(~r/approved.*Intent/is,&1)),no_auto_scope: k==0 and File.read!(Path.join(c.repo,"app.txt"))=="baseline\n",source_untracked: not String.contains?(tracked,".kogen/local/provenance"),input_replacement_ignored: not Enum.any?(text,&String.contains?(&1,"POISON replacement")) and File.read!(source)==bytes,output: o})
   end
  end
 end
end
`;
  AfterAll(function () { if (work) fs.rmSync(work, { recursive: true, force: true }); });
  When('I exercise native continuity {string} with:', { timeout: 300000 }, async function (mode, json) {
    if (!archivePromise) archivePromise = (async () => {
      work = fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-continuity-'));
      const r = await run('/bin/sh', ['packaging/package.sh'], { cwd: ROOT });
      assert.equal(r.code, 0, r.out);
      const archive = r.out.split('\n').find(x => x.startsWith('/') && x.endsWith('.tar.gz'));
      assert.ok(archive && fs.existsSync(archive), r.out); return archive;
    })();
    const archive = await archivePromise;
    const dir = fs.mkdtempSync(path.join(work, 'case-'));
    try {
      const script = path.join(dir, 'continuity_test.exs'), input = path.join(dir, 'input.json'), receipt = path.join(dir, 'receipt.json');
      fs.writeFileSync(script, driver); fs.writeFileSync(input, json);
      const dirs = [];
      for (const name of ['mix', 'erl', 'go', 'node', 'npm', 'python3']) {
        const r = await run('mise', ['which', name], { cwd: ROOT }); assert.equal(r.code, 0, r.out); dirs.push(path.dirname(r.out.trim()));
      }
      const r = await run('mix', ['test', script], { cwd: ROOT, env: { ...process.env, PATH: [...dirs, process.env.PATH].join(path.delimiter), KOGEN_ARCHIVE: archive, CONTINUITY_MODE: mode, CONTINUITY_INPUT: input, CONTINUITY_RECEIPT: receipt } });
      assert.equal(r.code, 0, r.out); assert.ok(fs.existsSync(receipt), r.out);
      const d = JSON.parse(fs.readFileSync(receipt, 'utf8'));
      if (d.replay) { d.replay_custody = replayCustody(d.replay); delete d.replay; }
      this.nativeContinuity = d; await this.attach(JSON.stringify(d), 'application/json');
    } finally { fs.rmSync(dir, { recursive: true, force: true }); }
  });
  Then('the native continuity observations include:', function (json) {
    assert.ok(this.nativeContinuity, 'no actual native observations');
    for (const [key, expected] of Object.entries(JSON.parse(json))) assert.deepEqual(this.nativeContinuity[key], expected, `${key}: ${JSON.stringify(this.nativeContinuity)}`);
  });
}
