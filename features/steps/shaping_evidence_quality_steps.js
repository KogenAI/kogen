const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { Given, When, Then } = require('@cucumber/cucumber');
const REPO = path.resolve(__dirname, '../..');
let exercise, exerciseInput;

// Independent protected harness. Installation/HTTP transport helpers are reused,
// never the implementation's obligation parser, validator, or test assertions.
const driver = String.raw`
ExUnit.start(autorun: false)
Code.require_file("test/support/integration_helpers.ex")
alias Kogen.{Config, Intent, Git, Snapshot, Integration.Helpers, Integration.FakeProvider}
System.delete_env("KOGEN_ARCHIVE")
spec = File.read!(System.fetch_env!("QUALITY_INPUT")) |> JSON.decode!()
suite = Helpers.setup_suite!()
original = """
"Repair unsupported cache capability fallback" - that means our shaping process isn't good, right?
Aren't we supposed to do probing during shaping? We wasted hours and hours basically for something that could have been figured out during shaping with a couple of curl calls, right?
So what's the status of cache now?
Are we even used those endpoints mentioned in the docs?
There are multiple login routes and multiple API endpoints for conversations.
So, are using proper ones?

For the Studio stuff, what's the problem? Were we not thorough enough during some of the phases? How come you've had to verify outside Kogen shaping, build, and review to find out that Kogen build of Studio wasn't thorough? These are all Kogen issues - we gotta fix them.
What else did we encounter in this conversation? What other Kogen issues?
"""
try do
 results = for mode <- ~w(ordinary capability masked counterexamples binding refine), into: %{} do
  c = Helpers.project!(suite, [], staged_intent: false)
  try do
   put = fn p, bytes ->
    full = Path.join(c.repo,p)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full,bytes)
   end
   read_record = fn slug ->
    case File.read(Path.join(c.repo,".kogen/local/readiness/#{slug}.json")) do
     {:ok,b} -> JSON.decode!(b)
     _ -> %{}
    end
   end
   lines = fn p -> case File.read(p) do {:ok,b} -> String.split(b,"\n",trim: true); _ -> [] end end
   trace = Path.join(c.root,"controls.trace")
   acceptance_trace = Path.join(c.root,"acceptance.trace")
   config = Config.load!(c.repo)
   run = "if grep -q 'Scenario:' \"$KOGEN_ACCEPTANCE_FEATURES\"; then printf 'run\\n' >> '#{acceptance_trace}'; fi; " <> config.acceptance_run
   put.(Config.path(),Config.render(%{setup: [],fix: [],checks: [],protect: config.protect,acceptance: %{run: run,steps_dir: config.steps_dir}}))
   route_bytes = JSON.encode!(spec["capability"])
   put.("route.json",route_bytes)
   put.("route.cjs","const fs=require('node:fs');const s=fs.readFileSync('route.json','utf8');console.log(s);process.exit(JSON.parse(s).error?#{spec["rejection_exit"]}:0);\n")
   selected = hd(spec["cases"])
   control_bytes = fn item -> JSON.encode!(Map.new(~w(good bad),fn k -> {k,Map.put(item[k],"kind",item["id"])} end)) end
   put.("controls.json",control_bytes.(selected))
   Helpers.git!(c,["add",Config.path(),"route.json","route.cjs","controls.json"])
   Helpers.git!(c,["commit","-qm","Configure local evidence controls"])
   initial_head = Git.head(c.repo)
   initial_index = File.read!(Path.join(c.repo,".git/index"))
   slug = if mode=="refine",do: "fixture",else: "quality-#{mode}"
   md = Intent.intent_md(slug)
   ft = Intent.feature(slug)
   observer = if mode=="refine",do: "features/steps/integration_steps.js",else: "features/steps/quality.js"
   observer_body = fn flawed ->
    """
    const fs=require('node:fs'); const assert=require('node:assert/strict');
    const flawed=#{flawed};
    function equal(a,b){try{assert.deepEqual(a,b);return true;}catch{return false;}}
    function observe(d){
      switch(d.kind){
        case 'json-object': {const a=JSON.parse(d.actual_json),b=JSON.parse(d.expected_json);return flawed ? JSON.stringify(a)===JSON.stringify(b) : equal(a,b);}
        case 'json-array': return flawed ? equal([...d.actual].sort(),[...d.expected].sort()) : equal(d.actual,d.expected);
        case 'json-string': return flawed ? d.actual.replaceAll(' ','')===d.expected.replaceAll(' ','') : d.actual===d.expected;
        case 'oklch': {const m=d.actual.match(flawed ? /^rgb\\((\\d+)/ : /^oklch\\(([0-9.]+)/); return !!m && Number(m[1])<=d.maximum;}
        case 'markdown': return d.actual.includes(flawed ? d.raw : d.rendered);
        case 'search': {const event=flawed?d.events.at(-1):d.events.find(e=>e.action==='search');return event.results.includes(d.query);}
        case 'history': return d.actual.actor===(flawed?'guessed-user':d.seed.actor);
        case 'cold-output': return (flawed?d.stdout:d.payload)===d.expected;
        case 'legacy-84-plus-one': return flawed ? equal(d.actual.data.totals,d.expected.data.totals) : equal(d.actual,d.expected);
        default: throw new Error('unknown local control '+d.kind);
      }
    }
    const fixture=()=>JSON.parse(fs.readFileSync('controls.json','utf8'));
    if(require.main===module){const ok=observe(fixture()[process.argv[2]]);process.stdout.write(ok?'accepted\\n':'rejected\\n');process.exit(ok?0:1);}
    else {const {Given,Then}=require('@cucumber/cucumber');
      Given('the requested product is not implemented',()=>{throw new Error('legitimate missing product');});
      Then('the protected observer accepts the good fixture',()=>{assert.equal(observe(fixture().good),true);});
    }
    """
   end
   good_body = observer_body.(false)
   bad_body = observer_body.(true)
   command = fn text -> "printf 'control\\n' >> '#{trace}'; " <> text end
   observer_obligation = fn suffix ->
    %{"id"=>"protected-observer","kind"=>"observer","inputs"=>["controls.json"],"observers"=>[observer],"checks"=>Enum.map(~w(good bad),fn name -> Map.merge(spec[name],%{"name"=>name,"command"=>command.("node #{observer} #{name}"<>suffix)}) end)}
   end
   route_obligation = fn honest ->
    %{"id"=>"target-route","kind"=>"capability","inputs"=>["route.json","route.cjs"],"observers"=>[],"checks"=>[%{"name"=>"support","command"=>command.("node route.cjs"),"exit"=>if(honest,do: spec["rejection_exit"],else: 0),"output"=>if(honest,do: route_bytes<>"\n",else: "supported\n")} ]}
   end
   text = fn obligations ->
    feasibility = if obligations==[],do: "- none",else: Enum.map_join(obligations,"\n",&("- evidence: "<>JSON.encode!(&1)))
    "# Qualify the local evidence fixture\n\nSlug: #{slug}\nModel: not applicable — local fixture controls\nAcceptance:\n- #{ft}\n- #{observer}\n\n## Decisions\n- Use bounded local controls. (source: request)\n\n## Tests\n- missing product and observer controls: actual commands (regression)\n\n## Feasibility\n#{feasibility}\n"
   end
   feature = "Feature: Actual local observer\n  Scenario: Missing product masks a later protected assertion\n    Given the requested product is not implemented\n    Then the protected observer accepts the good fixture\n"
   pkg = fn obligations,body -> [%{"path"=>md,"content"=>text.(obligations)},%{"path"=>ft,"content"=>feature},%{"path"=>observer,"content"=>body}] end
   write_pkg = fn files -> Enum.each(files,fn f -> put.(f["path"],f["content"]) end) end
   sub = fn tool,files -> {:function,tool,%{"files"=>files}} end
   ack = fn tool -> sub.(tool,[%{"path"=>ft,"content"=>feature}]) end
   script = fn actions ->
    Agent.update(c.server.state,fn s ->
     consumed = Enum.take(s.script,s.next)
     # Default refusals consume cursor positions beyond the scripted list.
     padding = List.duplicate(nil,max(s.next-length(consumed),0))
     %{s|script: consumed++padding++actions}
    end)
   end
   request = Path.join(c.root,"request.txt")
   request_bytes = original<>"\nKnown supplied counterexamples (exercise in acceptance):\n"<>JSON.encode!(spec["cases"])<>"\nRequire truthful external pixel handoff; no native image capability is asserted.\n"
   File.write!(request,request_bytes)
   invoke = fn args -> Helpers.run_kogen(c,args) end
   count = fn -> length(lines.(trace)) end
   card = fn -> invoke.(["intent","approve",slug]) end
   hash = fn -> Intent.hash(c.repo,Intent.baseline(c.repo,slug,Config.load!(c.repo))) end
   record_path = Path.join(c.repo,".kogen/local/readiness/#{slug}.json")
   proof = fn obligations ->
    r=read_record.(slug)
    actual=r["feasibility"]||[]
    identities = fn paths -> Map.new(paths,fn p -> {p,Kogen.ShapeContext.hash(File.read!(Path.join(c.repo,p)))} end) end
    r["sha256"]==hash.() and r["head"]==Git.head(c.repo) and r["candidate_tree"]==Snapshot.tree(c.repo,Git.head(c.repo),[]) and
    length(actual)==length(obligations) and Enum.zip(actual,obligations)|>Enum.all?(fn {a,d} ->
      a["id"]==d["id"] and a["kind"]==d["kind"] and a["inputs"]==identities.(d["inputs"]) and a["observers"]==identities.(d["observers"]) and
      is_list(a["checks"]) and length(a["checks"])==length(d["checks"]) and Enum.zip(a["checks"],d["checks"])|>Enum.all?(fn {ac,dc} -> Map.take(ac,~w(name command exit output))==dc and ac["timed_out"]==false end)
    end)
   end
   red = fn -> Enum.any?(read_record.(slug)["scenarios"]||[],&(&1["status"]=="failed" and String.contains?(&1["detail"]||"","legitimate missing product"))) end
   feedback = fn ->
    case List.last(FakeProvider.provider_requests(c.server)) do
     nil -> []
     request -> for item <- request.json["input"]||[], item["type"]=="function_call_output", do: item["output"]||""
    end
   end
   refused = fn id -> Enum.count(feedback.(),&(String.contains?(&1,"not ready") and String.contains?(&1,id)))>=2 end
   results = cond do
    mode in ~w(ordinary capability masked) ->
     obligations = case mode do "ordinary" -> []; "capability" -> [route_obligation.(true)]; _ -> [observer_obligation.("")] end
     actions = case mode do
      "ordinary" -> [sub.("submit",pkg.([],good_body)),ack.("submit")]
      "capability" -> [sub.("submit",pkg.([route_obligation.(false)],good_body)),ack.("submit"),sub.("submit",[%{"path"=>md,"content"=>text.(obligations)}]),ack.("submit")]
      "masked" -> [sub.("submit",pkg.(obligations,bad_body)),ack.("submit"),sub.("submit",[%{"path"=>observer,"content"=>good_body}]),ack.("submit")]
     end
     script.(actions)
     {out,status}=invoke.(["intent","shape",slug,request])
     before_card=length(lines.(acceptance_trace))
     no_approval=not File.exists?(Intent.approval_path(c.repo,slug))
     {_,card_status}=card.()
     {_,approve_status}=invoke.(["intent","approve",slug,hash.()])
     requests=FakeProvider.provider_requests(c.server)
     inputs=Enum.map_join(requests,"\n",&FakeProvider.input_text/1)
     policy_text = fn request ->
      developer = for item <- request.json["input"]||[], item["role"]=="developer",
        block <- item["content"]||[], block["type"]=="input_text", is_binary(block["text"]), do: block["text"]
      Enum.join([request.json["instructions"]||""|developer],"\n")
     end
     instructions=Enum.map_join(requests,"\n",policy_text)|>String.downcase()
     events=Path.join(c.repo,".kogen/local/shaping/#{slug}/events.ndjson")|>lines.()|>Enum.map(&JSON.decode!/1)
     all_feedback=Enum.join(feedback.(),"\n")
     id=if mode=="capability",do: "target-route",else: "protected-observer"
     %{"shape exit"=>status,"card exit"=>card_status,"exact approval exit"=>approve_status,
       "acceptance executions"=>length(lines.(acceptance_trace)),"acceptance before card"=>before_card,
       "feasibility probe executions"=>Enum.count(events,&(&1["event"]=="probe_result")),
       "Shape did not approve"=>no_approval,"complete request delivered"=>String.contains?(inputs,request_bytes),
       "critical guidance delivered"=>Enum.all?(spec["guidance"],&String.contains?(instructions,&1)),
       "unchanged acknowledgment refused"=>refused.(id),"diagnostic names failed obligation"=>String.contains?(all_feedback,id),
       "actual rejection returned"=>String.contains?(all_feedback,"invalid_parameter") and String.contains?(all_feedback,"prompt_cache_options") and String.contains?(all_feedback,to_string(spec["rejection_exit"])),
       "corrected observer published"=>File.read(Path.join(c.repo,observer))=={:ok,good_body},
       "exact proof"=>proof.(obligations),"product red retained"=>red.(),"output"=>out}
    mode=="counterexamples" ->
     cases=for item<-spec["cases"],into: %{} do
      put.("controls.json",control_bytes.(item))
      obligations=[observer_obligation.("")]
      write_pkg.(pkg.(obligations,bad_body))
      File.rm(record_path)
      {bad_output,bad_status}=card.()
      invalid=bad_status not in [0,5] and String.contains?(bad_output,"protected-observer")
      write_pkg.(pkg.(obligations,good_body))
      n=count.()
      {good_output,good_status}=card.()
      {item["id"],%{"faulty observer refused"=>invalid,"corrected observer ready"=>good_status==5,"both controls executed"=>count.()-n==2,"exact proof"=>proof.(obligations),"bad output"=>bad_output,"good output"=>good_output}}
     end
     %{"cases"=>cases}
    mode=="binding" ->
     obligations=[observer_obligation.("")]
     write_pkg.(pkg.(obligations,good_body))
     n=count.(); card.(); first=count.()-n
     initial=proof.(obligations)
     measured=fn action -> action.(); n=count.(); card.(); count.()-n end
     repeat=measured.(fn -> :ok end)
     n=count.(); invoke.(["intent","approve",slug,hash.()]); approve=count.()-n
     observer_change=measured.(fn -> put.(observer,good_body<>"\n// final observer bytes changed\n") end)
     input_change=measured.(fn -> put.("controls.json",control_bytes.(selected)<>"\n") end)
     next=[observer_obligation.(" ")]
     command_change=measured.(fn -> put.(md,text.(next)) end)
     forged=measured.(fn ->
      r=read_record.(slug)
      f=r["feasibility"]||[]
      changed=case f do [entry|rest] -> checks=entry["checks"]||[]; altered=case checks do [check|tail] -> [Map.put(check,"output","forged")|tail]; _ -> [] end; [Map.put(entry,"checks",altered)|rest]; _ -> [] end
      File.write!(record_path,JSON.encode!(Map.put(r,"feasibility",changed)))
     end)
     missing=measured.(fn -> File.write!(record_path,JSON.encode!(Map.delete(read_record.(slug),"feasibility"))) end)
     head=measured.(fn -> Helpers.git!(c,["commit","--allow-empty","-qm","Move evidence fixture HEAD"]) end)
     %{"initial proof"=>initial,"controls on first card"=>first,"controls on exact repeat"=>repeat,"controls on exact approval"=>approve,
       "controls after observer change"=>observer_change,"controls after input change"=>input_change,"controls after command change"=>command_change,
       "controls after forged outcome"=>forged,"controls after missing proof"=>missing,"controls after HEAD change"=>head,"final exact proof"=>proof.(next)}
    mode=="refine" ->
     obligations=[observer_obligation.("")]
     original_pkg=pkg.(obligations,good_body)
     write_pkg.(original_pkg)
     {_,0}=invoke.(["intent","approve",slug,hash.()])
     approval=Intent.approval_path(c.repo,slug)
     raw=File.read!(approval)
     original_hash=hash.()
     changed_text=String.replace(text.(obligations),"# Qualify","# Requalify")
     script.([sub.("submit_refinement",[%{"path"=>md,"content"=>changed_text},%{"path"=>observer,"content"=>bad_body}]),ack.("submit_refinement")])
     {bad_out,bad_status}=invoke.(["intent","refine",slug,original_hash,request])
     preserved=Enum.all?(original_pkg,fn f -> File.read(Path.join(c.repo,f["path"]))=={:ok,f["content"]} end)
     approval_preserved=File.read(approval)=={:ok,raw}
     refused_ack=refused.("protected-observer")
     final_body=good_body<>"\n// requalified final bytes\n"
     script.([sub.("submit_refinement",[%{"path"=>md,"content"=>changed_text},%{"path"=>observer,"content"=>final_body}]),ack.("submit_refinement")])
     {good_out,good_status}=invoke.(["intent","refine",slug,original_hash,request])
     archived=Path.wildcard(Path.join(c.repo,".kogen/local/refinements/*/revoked-approval.json"))
     %{"bad refinement refused"=>bad_status != 0,"unchanged acknowledgment refused"=>refused_ack,
       "original package preserved"=>preserved,"original approval preserved"=>approval_preserved,
       "good refinement exit"=>good_status,"qualified refinement published"=>File.read(Path.join(c.repo,observer))=={:ok,final_body} and File.read(Path.join(c.repo,md))=={:ok,changed_text},
       "exact proof"=>proof.(obligations),"approval revoked not replaced"=>not File.exists?(approval) and Enum.any?(archived,&(File.read!(&1)==raw)),"bad output"=>bad_out,"good output"=>good_out}
   end
   {mode,Map.put(results,"unchanged caller index and HEAD",File.read!(Path.join(c.repo,".git/index"))==initial_index and Git.head(c.repo)==initial_head)}
  after
   Helpers.cleanup_case(c)
  end
 end
 IO.puts("SHAPING_EVIDENCE_QUALITY="<>JSON.encode!(results))
after
 Helpers.cleanup_suite(suite)
end
ExUnit.run()
`;

function runExercise(input) {
  return new Promise((resolve, reject) => {
    const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'shaping-evidence-quality-'));
    const script = path.join(temp, 'driver.exs');
    const fixture = path.join(temp, 'input.json');
    fs.writeFileSync(script, driver);
    fs.writeFileSync(fixture, input);
    const env = { ...process.env, QUALITY_INPUT: fixture, ERL_FLAGS: process.env.ERL_FLAGS || '+S 2:2 +SDcpu 1 +SDio 1' };
    delete env.KOGEN_ARCHIVE;
    const child = spawn('mix', ['run', script], { cwd: REPO, env, detached: true, stdio: ['ignore', 'pipe', 'pipe'] });
    let output = '';
    child.stdout.on('data', b => { output += b; });
    child.stderr.on('data', b => { output += b; });
    const timer = setTimeout(() => { try { process.kill(-child.pid, 'SIGKILL'); } catch {} }, 280000);
    child.on('error', e => { clearTimeout(timer); fs.rmSync(temp, { recursive: true, force: true }); reject(e); });
    child.on('close', code => {
      clearTimeout(timer); fs.rmSync(temp, { recursive: true, force: true });
      try {
        assert.equal(code, 0, output);
        const line = output.split('\n').find(s => s.startsWith('SHAPING_EVIDENCE_QUALITY='));
        assert.ok(line, output);
        resolve(JSON.parse(line.slice('SHAPING_EVIDENCE_QUALITY='.length)));
      } catch (e) { reject(e); }
    });
  });
}
Given('the shaping evidence controls:', function (raw) {
  this.qualityInput = JSON.stringify(JSON.parse(raw));
});
When('I qualify native shaping evidence in mode {string}', { timeout: 300000 }, async function (mode) {
  if (!exercise) { exerciseInput = this.qualityInput; exercise = runExercise(exerciseInput); }
  assert.equal(this.qualityInput, exerciseInput, 'all scenarios must use the same complete controls');
  const results = await exercise;
  assert.ok(Object.hasOwn(results, mode), mode);
  this.qualityResult = results[mode];
});
Then('the shaping evidence observations are:', function (table) {
  const failures = [];
  for (const [key, raw] of table.raw()) {
    try { assert.deepEqual(this.qualityResult[key], JSON.parse(raw)); }
    catch { failures.push(`${key}: expected ${raw}, observed ${JSON.stringify(this.qualityResult[key])}`); }
  }
  assert.deepEqual(failures, [], JSON.stringify(this.qualityResult, null, 2));
});
Then('each evidence counterexample has these observations:', function (table) {
  const expectedCases = JSON.parse(this.qualityInput).cases.map(c => c.id);
  assert.deepEqual(Object.keys(this.qualityResult.cases).sort(), expectedCases.sort());
  const failures = [];
  for (const [id, observations] of Object.entries(this.qualityResult.cases)) {
    for (const [key, raw] of table.raw()) {
      try { assert.deepEqual(observations[key], JSON.parse(raw)); }
      catch { failures.push(`${id}: ${key}: expected ${raw}, observed ${JSON.stringify(observations[key])}`); }
    }
  }
  assert.deepEqual(failures, [], JSON.stringify(this.qualityResult, null, 2));
});
