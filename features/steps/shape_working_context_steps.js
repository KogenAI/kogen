const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawn, spawnSync } = require('node:child_process');
const ROOT = path.resolve(__dirname, '../..');
const equal = (a, b) => { try { assert.deepEqual(a, b); return true; } catch { return false; } };
function replayCustody(d) {
  if (!d || !d.windows.length || !d.groups.length || !d.files.length) return false;
  for (const w of d.windows) {
    const pending = new Set();
    for (const i of w) {
      if (i.type === 'function_call') { if (pending.has(i.call_id)) return false; pending.add(i.call_id); }
      if (i.type === 'function_call_output' && !pending.delete(i.call_id)) return false;
    }
    if (pending.size) return false;
  }
  const firstSeen = [];
  for (const w of d.windows) for (const i of w) if (i.type === 'function_call' && !firstSeen.includes(i.call_id)) firstSeen.push(i.call_id);
  const ordered = d.groups.flatMap(g => g.filter(i => i.type === 'function_call').map(i => i.call_id));
  const observed = firstSeen.filter(id => ordered.includes(id));
  if (!equal(observed, ordered)) return false;
  return d.groups.every(g => d.windows.some(w => w.some((_, n) => equal(w.slice(n, n + g.length), g)))) && d.files.every(f => f.mode === 384 && f.dir_mode === 448 && crypto.createHash('sha256').update(Buffer.from(f.bytes, 'base64')).digest('hex') === f.sha256);
}
const control = String.raw`
root = Kogen.tmp_path("shape-window-control")
File.mkdir_p!(root)
File.chmod!(root, 0o700)
try do
 File.write!(Path.join(root,"literal.txt"), "  Δ🙂\r\n/path with spaces/診断.txt\n  ")
 ctx = %{root: root, protected: [], tools: ["read_file"]}
 calls = for n <- 1..2, do: %{"type"=>"function_call","id"=>"fc#{n}","call_id"=>"c#{n}","name"=>"read_file","arguments"=>JSON.encode!(%{"path"=>"literal.txt"})}
 rs = %{"type"=>"reasoning","id"=>"r","encrypted_content"=>"opaque+/==\nΔ","summary"=>[]}
 msg = %{"type"=>"message","id"=>"m","role"=>"assistant","phase"=>"commentary","content"=>[%{"type"=>"output_text","text"=>"Unfinished fixture observation"}]}
 group = Enum.map([rs,msg]++calls,&Kogen.Shape.replay_item/1) ++ Enum.map(calls,fn c -> Kogen.Shape.output(c,Kogen.Tools.run(c["name"],JSON.decode!(c["arguments"]),ctx)) end)
 bytes = JSON.encode!(%{"input"=>group})<>"\n"
 p = Path.join(root,"archive.json"); File.write!(p,bytes); File.chmod!(p,0o600)
 data = %{windows: [JSON.decode!(File.read!(p))["input"]],groups: [group],files: [%{mode: Bitwise.band(File.stat!(p).mode,0o777),dir_mode: Bitwise.band(File.stat!(root).mode,0o777),bytes: Base.encode64(File.read!(p)),sha256: Kogen.WorkingContext.hash(bytes)}]}
 File.write!(System.fetch_env!("SHAPE_WINDOW_RECEIPT"),JSON.encode!(data))
after
 File.rm_rf!(root)
end
`;
if (require.main === module && process.argv[2] === '--control') {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'shape-window-control-'));
  try {
    const file = path.join(dir, 'control.exs'), receipt = path.join(dir, 'receipt.json'); fs.writeFileSync(file, control);
    const r = spawnSync('mix', ['run', file], { cwd: ROOT, env: { ...process.env, SHAPE_WINDOW_RECEIPT: receipt }, encoding: 'utf8', timeout: 60000 });
    if (r.status !== 0) throw new Error(r.stdout + r.stderr);
    const good = JSON.parse(fs.readFileSync(receipt, 'utf8')); assert.equal(replayCustody(good), true);
    if (process.argv[3] === 'good') process.stdout.write('accepted\n');
    else if (process.argv[3] === 'bad') {
      for (const mutate of [d => d.windows[0].pop(), d => d.windows[0][0].encrypted_content += 'changed', d => d.windows[0][1].phase = 'final', d => d.windows[0][2].arguments += ' ', d => d.windows[0].reverse(), d => d.files[0].bytes += 'eA==', d => d.files[0].mode = 420, d => d.files[0].dir_mode = 493]) {
        const bad = structuredClone(good); mutate(bad); assert.equal(replayCustody(bad), false, 'counterexample accepted');
      }
      process.stdout.write('rejected\n'); process.exitCode = 1;
    } else throw new Error('unknown control');
  } catch (e) { process.stderr.write(String(e) + '\n'); process.exitCode = 2; }
  finally { fs.rmSync(dir, { recursive: true, force: true }); }
} else {
  const { Given, When, Then, AfterAll } = require('@cucumber/cucumber');
  let work, archivePromise;
  function run(file, args, opts = {}) {
    return new Promise((resolve, reject) => {
      const child = spawn(file, args, { ...opts, detached: true, stdio: ['ignore', 'pipe', 'pipe'] }); let out = '';
      child.stdout.on('data', b => { out += b; }); child.stderr.on('data', b => { out += b; });
      const timer = setTimeout(() => { try { process.kill(-child.pid, 'SIGKILL'); } catch {} }, 240000);
      child.on('error', e => { clearTimeout(timer); reject(e); }); child.on('close', code => { clearTimeout(timer); resolve({ code, out }); });
    });
  }
  const driver = String.raw`
ExUnit.start(autorun: false)
Code.require_file("test/support/integration_helpers.ex")
defmodule ShapeWindowExercise do
 alias Kogen.Integration.{Helpers,FakeProvider}
 alias Kogen.{Intent,Config,Shape,Tools,WorkingContext}
 def f(n,a), do: {:function,n,a}
 def script(c,actions), do: Agent.update(c.server.state, &%{&1 | script: Enum.take(&1.script,&1.next) ++ actions})
 def reqs(c), do: FakeProvider.provider_requests(c.server) |> Enum.filter(fn r -> Enum.any?(r.json["tools"] || [], &(&1["name"]=="submit")) end)
 def lines(p) do
  case File.read(p) do
   {:ok,t} -> String.split(t,"\n",trim: true) |> Enum.map(&JSON.decode!/1)
   _ -> []
  end
 end
 def file(c,p,b) do
  p=Path.join(c.repo,p); File.mkdir_p!(Path.dirname(p)); File.write!(p,b)
 end
 def snapshot(c) do
  {h,0}=Helpers.git!(c,["rev-parse","HEAD"])
  %{head: h,index: File.read!(Path.join(c.repo,".git/index")),config: File.read!(Path.join(c.repo,Config.path())),app: File.read!(Path.join(c.repo,"app.txt")),approval: File.read(Intent.approval_path(c.repo,"fixture"))}
 end
 def items(n,inspect) do
  calls=for j <- 1..2 do
   args=if inspect, do: %{"path"=>"pad#{j}.txt"}, else: %{"command"=>"printf '%s' '"<>String.duplicate("x",18000)<>"'"}
   %{"type"=>"function_call","id"=>"fc-#{n}-#{j}","call_id"=>"call-#{n}-#{j}","name"=>if(inspect,do: "read_file",else: "probe"),"arguments"=>JSON.encode!(args)}
  end
  [%{"type"=>"reasoning","id"=>"rs-#{n}","encrypted_content"=>"opaque+/==\n#{n} Δ","summary"=>[]},%{"type"=>"message","id"=>"m-#{n}","role"=>"assistant","phase"=>"commentary","content"=>[%{"type"=>"output_text","text"=>"Unfinished native design observation #{n}; preserve whole scope, not a new approval."}]}]++calls
 end
 def grow(range,inspect), do: Enum.map(range,fn n -> {:items,items(n,inspect)} end)
 def png do
  chunk=fn t,b -> <<byte_size(b)::32>><>t<>b<><<:erlang.crc32(t<>b)::32>> end
  <<137,80,78,71,13,10,26,10>><>chunk.("IHDR",<<1::32,1::32,8,2,0,0,0>> )<>chunk.("IDAT",:zlib.compress(<<0,10,20,30>>))<>chunk.("IEND",<<>>)
 end
 def main do
  spec=JSON.decode!(File.read!(System.fetch_env!("SHAPE_WINDOW_INPUT")))
  mode=System.fetch_env!("SHAPE_WINDOW_MODE")
  suite=Helpers.setup_suite!()
  try do
   c=Helpers.project!(suite,[],staged_intent: false)
   try do
    slug="window-case"; state_dir=Path.join(c.repo,".kogen/local/shaping/#{slug}")
    trace=Path.join(c.root,"readiness-count")
    config=Config.load!(c.repo)
    command="if grep -q 'Scenario:' \"$KOGEN_ACCEPTANCE_FEATURES\"; then printf 'run\\n' >> '#{trace}'; fi; "<>config.acceptance_run
    file(c,Config.path(),Config.render(%{setup: [],fix: [],checks: [],protect: config.protect,acceptance: %{run: command,steps_dir: config.steps_dir}}))
    {_,0}=Helpers.git!(c,["add",Config.path()]); {_,0}=Helpers.git!(c,["commit","-qm","Trace Shape readiness"])
    for j <- 1..2, do: file(c,"pad#{j}.txt",String.duplicate("p#{j}",14000)<>"\n")
    file(c,"selected.png",png())
    # Commit the discovery corpus so the candidate is stable, including image metadata.
    {_,0}=Helpers.git!(c,["add","pad1.txt","pad2.txt","selected.png"]); {_,0}=Helpers.git!(c,["commit","-qm","Seed discovery corpus"])
    before=snapshot(c)
    input=Path.join(c.root,"request.txt")
    request=JSON.encode!(spec)<>if(mode=="irreducible",do: "\n"<>String.duplicate("M",600000),else: "")
    File.write!(input,request)
    mdpath=Intent.intent_md(slug); ftpath=Intent.feature(slug); helper="features/steps/window_case.js"
    url="http://127.0.0.1:#{c.server.port}/docs/missing"
    md="# Preserve whole fixture scope\n\nSlug: #{slug}\nModel: not applicable — fixture has no product state\nAcceptance:\n- #{ftpath}\n- #{helper}\n\nKeep the whole requested scope, without automatic splitting.\n\n## Decisions\n- Preserve the complete request. (source: request)\n\n## Source comparison\n- addressed: complete source packet remains the native request; this is only a plumbing fixture.\n\n## Tests\n- Missing product: actual scenario (regression)\n\n## Feasibility\n- none\n"
    md=if mode=="growth",do: md<>"- documentation-lookup: unsupported #{url}\n",else: md
    ft="Feature: Whole fixture scope\n  Scenario: Observe real missing behavior\n    Then the whole window fixture is implemented\n"
    js="const { Then } = require('@cucumber/cucumber');\nThen('the whole window fixture is implemented', function () { throw new Error('legitimate whole-scope product red'); });\n"
    all=[%{"path"=>mdpath,"content"=>md},%{"path"=>ftpath,"content"=>ft},%{"path"=>helper,"content"=>js}]
    question=%{"question"=>spec["fixture_question"],"options"=>[%{"label"=>"Retained fixture label","recommended"=>true}]}
    input=if mode=="growth" do
     script(c,[f("submit",%{"questions"=>[question]})])
     {o,5}=Helpers.run_kogen(c,["intent","shape",slug,input])
     if not String.contains?(o,spec["fixture_question"]),do: raise("question fixture did not run")
     input=Path.join(c.root,"answers.txt"); File.write!(input,spec["fixture_answer"])
     input
    else
     input
    end
    start_count=length(reqs(c))
    actions=case mode do
     "irreducible" -> [f("submit",%{"questions"=>[question]})]
     "growth" ->
      docs=for n <- 1..6 do
       if rem(n,2)==0,do: f("documentation",%{"operation"=>"fetch","base"=>"http://127.0.0.1:#{c.server.port}/docs","url"=>url}),else: f("documentation",%{"operation"=>"search","base"=>"http://127.0.0.1:#{c.server.port}/docs","query"=>"local continuity #{n}"})
      end
      probes=for n <- 1..3,do: f("probe",%{"command"=>"printf 'probe-#{n}\\n'"})
      [f("read_file",%{"path"=>"README.md"})]++docs++probes++[f("view_image",%{"path"=>"selected.png"}),f("submit",%{"files"=>[hd(all)]})]++grow(1..40,true)++[f("submit",%{"files"=>[%{"path"=>helper,"content"=>"POISON"},%{"path"=>"../escape","content"=>"unsafe"}]}),f("submit",%{"files"=>tl(all)})]++grow(41..80,true)++[f("submit",%{"files"=>[%{"path"=>ftpath,"content"=>ft}]})]
     "inspection" -> grow(1..40,false)++List.duplicate(f("submit",%{"files"=>all}),3)
     "documents" ->
      forged=List.update_at(all,0,&Map.update!(&1,"content",fn text -> text<>"- documentation-lookup: retrieved #{url}\n" end))
      grow(1..40,true)++List.duplicate(f("submit",%{"files"=>forged}),3)
     "invalids" -> [f("submit",%{"files"=>[]}),f("submit",%{"files"=>[]})]++grow(1..40,true)++[f("submit",%{"files"=>[]}),f("submit",%{"questions"=>[question]})]
     _ -> grow(1..40,true)++[{:pause,self(),f("read_file",%{"path"=>"README.md"})},f("submit",%{"questions"=>[question]})]
    end
    script(c,actions)
    {out,status,damaged_count}=if String.starts_with?(mode,"damage-") do
     port=Helpers.start_kogen(c,["intent","shape",slug,input])
     damage=receive do
      {:provider_paused,pid} ->
       events=lines(Path.join(state_dir,"events.ndjson")); reset=Enum.find(events,&(&1["event"]=="working_context_reset"))
       if reset do
        p=get_in(reset,["archive","path"])
        case mode do
         "damage-changed" -> File.write!(p," ",[:append])
         "damage-missing" -> File.rm!(p)
         "damage-symlink" -> bytes=File.read!(p); replacement=Path.join(c.root,"replacement.json"); File.write!(replacement,bytes); File.rm!(p); File.ln_s!(replacement,p)
         "damage-mode" -> File.chmod!(p,0o644)
        end
       end
       n=length(reqs(c)); send(pid,:continue); n
     after
      15000 -> nil
     end
     {o,k}=Helpers.await_exit(port,"",30000); {o,k,damage}
    else
     {o,k}=Helpers.run_kogen(c,["intent","shape",slug,input]); {o,k,nil}
    end
    requests=Enum.drop(reqs(c),start_count)
    events=lines(Path.join(state_dir,"events.ndjson"))
    resets=Enum.filter(events,&(&1["event"]=="working_context_reset"))
    safe_files=Enum.flat_map(resets,fn e ->
     ref=e["archive"] || %{}; p=ref["path"]
     if is_binary(p) and File.regular?(p) do
      bytes=File.read!(p)
      [%{path: p,bytes: Base.encode64(bytes),sha256: ref["sha256"],mode: Bitwise.band(File.stat!(p).mode,0o777),dir_mode: Bitwise.band(File.stat!(Path.dirname(p)).mode,0o777),doc: JSON.decode!(bytes)}]
     else [] end
    end)
    # Damaged custody need not be parseable; only success exercises the archive observer.
    windows=Enum.map(safe_files,& &1.doc["input"])++Enum.map(requests,& &1.json["input"])
    texts=Enum.map(requests,&FakeProvider.input_text/1)
    bounded=Enum.all?(requests,&(byte_size(&1.body)<=524288))
    absent=not File.exists?(Path.join(c.repo,mdpath)) and not File.exists?(Path.join(c.repo,".kogen/local/provenance/#{slug}/current.json"))
    base=%{reset_happened: resets != [],bounded_requests: bounded,no_publication: absent,checkout_authority_unchanged: snapshot(c)==before}
    result=case mode do
     "growth" ->
      expected=for n <- 1..80 do
       group=items(n,true)
       Enum.map(group,&Shape.replay_item/1)++Enum.filter(group,&(&1["type"]=="function_call")) |> then(fn prefix ->
        # Drop the duplicate calls introduced only for enumeration, then append real native read results.
        Enum.take(prefix,length(group))++Enum.map(Enum.filter(group,&(&1["type"]=="function_call")),fn call -> Shape.output(call,Tools.run(call["name"],JSON.decode!(call["arguments"]),%{root: c.repo,protected: [],tools: ["read_file"]})) end)
       end)
      end
      archive_windows=Enum.map(safe_files,& &1.doc["input"])
      image_outputs=fn ws -> for w <- ws,i <- w,i["type"]=="function_call_output",is_list(i["output"]),Enum.any?(i["output"],&(&1["type"]=="input_image")),do: i end
      images=image_outputs.(Enum.map(requests,& &1.json["input"]))
      docpath=Path.join(c.repo,".kogen/local/provenance/#{slug}/current.json")
      source=case File.read(docpath) do {:ok,b}->JSON.decode!(b); _ -> %{} end
      ready=Kogen.Readiness.cached(c.repo,slug,Config.load!(c.repo))
      count=case File.read(trace) do {:ok,b}->length(String.split(b,"\n",trim: true)); _ -> 0 end
      outputs=for w <- windows,i <- w,i["type"]=="function_call_output",is_binary(i["output"]),do: i["output"]
      first=List.first(requests)
      authority=if first,do: Enum.find(first.json["input"],&(&1["role"]=="user")),else: nil
      event_contract=Enum.with_index(resets,1) |> Enum.all?(fn {e,n}->e["owner"]=="shape" and e["generation"]==n and e["input_budget_bytes"]==524288 and e["output_reserve_tokens"]==131072 and is_integer(e["before_bytes"]) and e["before_bytes"]>524288 and e["after_bytes"]<=524288 and e["after_bytes"]<e["before_bytes"] and Enum.any?(requests,fn r -> byte_size(r.body)==e["after_bytes"] end) end)
      linked=Enum.with_index(safe_files) |> Enum.all?(fn {f,n}->f.doc["version"]==1 and f.doc["owner"]=="shape" and f.doc["previous"]==if(n==0,do: nil,else: Map.take(Enum.at(safe_files,n-1),[:path,:sha256]) |> Map.new(fn {k,v}->{Atom.to_string(k),v} end)) end)
      docs=lines(Path.join(state_dir,"documentation.ndjson"))
      Map.merge(base,%{success: status==0,at_least_three_resets: length(resets)>=3,event_contract: event_contract and linked,authority_exact: authority != nil and Enum.all?(requests,fn r -> Enum.member?(r.json["input"],authority) end) and Enum.any?(texts,&String.contains?(&1,"Local working-window reset")),source_exact: get_in(source,["request","text"])==request and get_in(source,["request","source_path"])==Path.join(c.root,"request.txt"),qa_exact: Enum.any?(source["rounds"]||[],fn r->r["questions"]==[question] and r["input"]==spec["fixture_answer"] end),complete_package: Enum.all?(all,fn f->File.read(Path.join(c.repo,f["path"]))=={:ok,f["content"]} end) and ready != nil,unsafe_not_retained: not File.exists?(Path.join(c.root,"escape")) and File.read(Path.join(c.repo,helper))=={:ok,js},one_readiness_execution: count==1,actual_red_observed: Enum.any?(outputs,&(String.contains?(&1,"Readiness observations") and String.contains?(&1,"legitimate whole-scope product red"))),documentation_retained: length(docs)==6 and Enum.all?(docs,&(&1["status"]=="unsupported")) and Enum.count(events,&(&1["event"]=="documentation_lookup"))==6 and length(Regex.scan(~r/kogen: documentation result:/,out))==6,three_probes: length(Regex.scan(~r/kogen: probe result:/,out))==3,archived_image_exact: images != [] and Enum.all?(images,&Enum.member?(image_outputs.(archive_windows),&1)),replay: %{windows: windows,groups: expected,files: Enum.map(safe_files,&Map.drop(&1,[:doc]))},no_shape_approval: not File.exists?(Intent.approval_path(c.repo,slug))})
     "irreducible" ->
      stop=Enum.find(events,&(&1["event"]=="working_context_stop"))
      custody=if stop do
       p=get_in(stop,["archive","path"])
       if is_binary(p) and File.regular?(p) do
        b=File.read!(p); d=JSON.decode!(b)
        stop["owner"]=="shape" and stop["input_budget_bytes"]==524288 and stop["output_reserve_tokens"]==131072 and stop["measured_bytes"]>524288 and stop["mandatory_bytes"]>524288 and get_in(stop,["archive","sha256"])==WorkingContext.hash(b) and JSON.encode!(d["input"]) =~ String.duplicate("M",600000) and Bitwise.band(File.stat!(p).mode,0o777)==0o600 and Bitwise.band(File.stat!(Path.dirname(p)).mode,0o777)==0o700
       else false end
      else false end
      Map.merge(base,%{stopped_before_inference: status != 0 and requests==[] and String.contains?(out,"candidate/context_budget_exceeded"),stop_custody_exact: custody,actionable_nonresume: String.contains?(out,"working-context") and not String.contains?(out,"kogen intent resume") and Regex.match?(~r/identical|unchanged/i,out)})
     m when m in ["inspection","documents","invalids"] ->
      expected=case m do "inspection"->"shape/uninspected"; "documents"->"shape/undocumented"; _ -> "non-empty" end
      seen=Enum.any?(texts,&String.contains?(&1,expected)) or String.contains?(out,expected)
      counter=if m=="invalids",do: length(requests)==43,else: true
      Map.merge(base,%{gate_preserved: status != 0 and seen and counter})
     _ -> Map.merge(base,%{custody_refused: status != 0 and String.contains?(out,"candidate/context_custody_invalid"),no_inference_after_damage: damaged_count != nil and length(reqs(c))==damaged_count})
    end
    File.write!(System.fetch_env!("SHAPE_WINDOW_RECEIPT"),JSON.encode!(result))
   after
    Helpers.cleanup_case(c)
   end
  after
   Helpers.cleanup_suite(suite)
  end
 end
end
ShapeWindowExercise.main()
`;
  Given('the Shape continuity source packet:', function (json) { this.shapeWindowSource = JSON.parse(json); });
  AfterAll(function () { if (work) fs.rmSync(work, { recursive: true, force: true }); });
  When('I exercise installed Shape windows {string}', { timeout: 300000 }, async function (mode) {
    if (!archivePromise) archivePromise = (async () => {
      work = fs.mkdtempSync(path.join(os.tmpdir(), 'shape-window-'));
      const r = await run('/bin/sh', ['packaging/package.sh'], { cwd: ROOT }); assert.equal(r.code, 0, r.out);
      const archive = r.out.split('\n').find(x => x.startsWith('/') && x.endsWith('.tar.gz')); assert.ok(archive && fs.existsSync(archive), r.out); return archive;
    })();
    const archive = await archivePromise, dir = fs.mkdtempSync(path.join(work, 'case-'));
    try {
      const file = path.join(dir, 'driver.exs'), input = path.join(dir, 'input.json'), receipt = path.join(dir, 'receipt.json');
      fs.writeFileSync(file, driver); fs.writeFileSync(input, JSON.stringify(this.shapeWindowSource));
      const dirs = [];
      for (const name of ['mix', 'erl', 'go', 'node', 'npm', 'python3']) { const r = await run('mise', ['which', name], { cwd: ROOT }); assert.equal(r.code, 0, r.out); dirs.push(path.dirname(r.out.trim())); }
      const r = await run('mix', ['run', file], { cwd: ROOT, env: { ...process.env, PATH: [...dirs, process.env.PATH].join(path.delimiter), KOGEN_ARCHIVE: archive, SHAPE_WINDOW_MODE: mode, SHAPE_WINDOW_INPUT: input, SHAPE_WINDOW_RECEIPT: receipt } });
      assert.equal(r.code, 0, r.out); assert.ok(fs.existsSync(receipt), r.out);
      const data = JSON.parse(fs.readFileSync(receipt, 'utf8'));
      if (data.replay) { data.replay_custody = replayCustody(data.replay); delete data.replay; }
      this.shapeWindowResult = data; await this.attach(JSON.stringify(data), 'application/json');
    } finally { fs.rmSync(dir, { recursive: true, force: true }); }
  });
  Then('the Shape window observations include:', function (json) {
    for (const [name, expected] of Object.entries(JSON.parse(json))) assert.deepEqual(this.shapeWindowResult[name], expected, `${name}: ${JSON.stringify(this.shapeWindowResult)}`);
  });
}
