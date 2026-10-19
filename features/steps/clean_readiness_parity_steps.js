const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { When, Then } = require('@cucumber/cucumber');
const REPO = path.resolve(__dirname, '../..');
let exercise;

// Independent frozen harness: use installed CLI, real bundled Cucumber and local
// generated imports. Helpers provides transport/installation, not test assertions.
const driver = String.raw`
ExUnit.start(autorun: false)
Code.require_file("test/support/integration_helpers.ex")
alias Kogen.{Config, Intent, Snapshot, Git, Integration.Helpers, Integration.FakeProvider}
System.delete_env("KOGEN_ARCHIVE")
suite = Helpers.setup_suite!()
try do
 results = for mode <- ~w(shape-negative shape-setup refine refine-red card-negative approve-negative cache scratch-mutation root-drift), into: %{} do
  c = Helpers.project!(suite, [], staged_intent: false)
  # Node and the installed CLI use physical cwd; compare the same path spelling
  # on macOS (/var is a symlink to /private/var), not lexical aliases.
  {physical, 0} = System.cmd("/bin/pwd", ["-P"], cd: c.repo)
  c = %{c | repo: String.trim(physical)}
  try do
   put = fn p, bytes ->
    full = Path.join(c.repo, p)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, bytes)
   end
   trace = Path.join(c.root, "acceptance.jsonl")
   setup_trace = Path.join(c.root, "setup.jsonl")
   probe_trace = Path.join(c.root, "probe-ok")
   read_lines = fn p ->
    case File.read(p) do
     {:ok, bytes} -> String.split(bytes, "\n", trim: true) |> Enum.map(&JSON.decode!/1)
     _ -> []
    end
   end
   old_config = Config.load!(c.repo)
   declared = mode not in ~w(shape-negative refine-red card-negative approve-negative)
   put.(".gitignore", File.read!(Path.join(c.repo, ".gitignore")) <> "\nnode_modules/\n_build/\n")
   put.("_build/tracked.txt", "tracked ignored bytes\n")
   put.("candidate.sh", "#!/bin/sh\nprintf 'exact\\n'\n")
   File.chmod!(Path.join(c.repo, "candidate.sh"), 0o755)
   put.(".guard", "protected baseline\n")
   bootstrap = "const fs=require('node:fs'); const cold=!fs.existsSync('node_modules/parity-local/index.cjs')&&!fs.existsSync('_build/result.cjs'); fs.appendFileSync(#{JSON.encode!(setup_trace)},JSON.stringify({cwd:process.cwd(),cold})+'\\n'); if(#{declared}) {fs.mkdirSync('node_modules/parity-local',{recursive:true}); fs.mkdirSync('_build',{recursive:true}); fs.writeFileSync('node_modules/parity-local/index.cjs','module.exports=42;'); fs.writeFileSync('_build/result.cjs','module.exports=42;');}\n"
   put.("bootstrap.cjs", bootstrap)
   put.("runner.cjs", """
   const fs=require('node:fs'); const {spawnSync,execFileSync}=require('node:child_process');
   const feature=fs.readFileSync(process.env.KOGEN_ACCEPTANCE_FEATURES,'utf8');
   if(/Scenario(?: Outline)?:/.test(feature)) {
    const g=(...a)=>execFileSync('git',a,{encoding:'utf8'}).trim();
    fs.appendFileSync(#{JSON.encode!(trace)},JSON.stringify({cwd:process.cwd(),dep:fs.existsSync('node_modules/parity-local/index.cjs'),build:fs.existsSync('_build/result.cjs'),git:g('rev-parse','--is-inside-work-tree')==='true',tracked:fs.readFileSync('_build/tracked.txt','utf8'),mode:!!(fs.statSync('candidate.sh').mode&0o111),env:process.env.PARITY_CALLER,app:fs.readFileSync('app.txt','utf8')})+'\\n');
    if(#{mode == "root-drift"}) fs.writeFileSync(#{JSON.encode!(Path.join(c.repo, "app.txt"))},'external drift\\n');
   }
   const r=spawnSync(process.env.KOGEN_NODE,[process.env.KOGEN_CUCUMBER+'/@cucumber/cucumber/bin/cucumber.js','--strict','--require','features/steps/*.js','--format','message:'+process.env.KOGEN_ACCEPTANCE_REPORT,process.env.KOGEN_ACCEPTANCE_FEATURES],{stdio:'inherit',env:{...process.env,NODE_PATH:process.env.KOGEN_CUCUMBER}});
   process.exit(r.status===null?99:r.status);
   """)
   config_text = Config.render(%{setup: [~s("$KOGEN_NODE" bootstrap.cjs)], fix: [], checks: [], protect: [".guard"], acceptance: %{run: ~s("$KOGEN_NODE" runner.cjs), steps_dir: old_config.steps_dir}})
   put.(Config.path(), config_text)
   Helpers.git!(c, ["add", Config.path(), ".gitignore", "bootstrap.cjs", "runner.cjs", "candidate.sh", ".guard"])
   Helpers.git!(c, ["add", "-f", "_build/tracked.txt"])
   Helpers.git!(c, ["commit", "-qm", "Configure local parity fixture"])
   c = %{c | env: Map.put(c.env, "PARITY_CALLER", "caller-value")}
   slug = if String.starts_with?(mode, "shape"), do: "parity-shaped", else: "fixture"
   md = Intent.intent_md(slug)
   ft = Intent.feature(slug)
   step = if slug == "fixture", do: "features/steps/integration_steps.js", else: "features/steps/parity_steps.js"
   feature = "Feature: Local bootstrap\n  Scenario: Actual generated imports\n    Then the local generated modules return forty two\n"
   body = "const {Then}=require('@cucumber/cucumber'); const assert=require('node:assert/strict'); Then('the local generated modules return forty two',()=>{assert.equal(require('../../node_modules/parity-local/index.cjs'),42);assert.equal(require('../../_build/result.cjs'),42);});\n"
   text = "# Check local bootstrap parity\n\nSlug: #{slug}\nModel: not applicable — local fixture wiring\nAcceptance:\n- #{ft}\n- #{step}\n\n## Decisions\n- Use local imports. (source: request)\n\n## Tests\n- bootstrap imports: actual modules (regression)\n\n## Feasibility\n- none\n"
   pkg = [%{"path"=>md,"content"=>text},%{"path"=>ft,"content"=>feature},%{"path"=>step,"content"=>body}]
   put.("node_modules/parity-local/index.cjs", "module.exports=42;")
   put.("_build/result.cjs", "module.exports=42;")
   evidence = Path.join(c.repo, ".kogen/local/readiness/#{slug}.json")
   approval = Intent.approval_path(c.repo, slug)
   File.rm(approval)
   hash = fn -> Intent.hash(c.repo, Intent.baseline(c.repo, slug, Config.load!(c.repo))) end
   invoke = fn args -> Helpers.run_kogen(c, args) end
   script = fn actions -> Agent.update(c.server.state, &%{&1 | script: Enum.take(&1.script, &1.next) ++ actions}) end
   request = Path.join(c.root,"request.md")
   File.write!(request,"Inspect actual diagnostics and qualify only the fixture contract.")
   sub = fn tool, files -> {:function, tool, %{"files"=>files}} end
   count = fn -> length(read_lines.(trace)) end
   setups = fn -> length(read_lines.(setup_trace)) end
   record = fn -> case File.read(evidence) do {:ok,b} -> JSON.decode!(b); _ -> %{} end end
   clean_record = fn ->
    r=record.()
    r["version"] == 3 and r["candidate_tree"] == Snapshot.tree(c.repo,Git.head(c.repo),[]) and r["head"] == Git.head(c.repo) and r["sha256"] == hash.()
   end
   original_index = File.read!(Path.join(c.repo,".git/index"))
   original_head = Git.head(c.repo)
   base_runs = count.()
   base_setups = setups.()
   {out,status,extra} = cond do
    String.starts_with?(mode,"shape") ->
     actions=[{:function,"probe",%{"command"=>"node -e 'if(require(\"./node_modules/parity-local/index.cjs\")!==42||require(\"./_build/result.cjs\")!==42)process.exit(9)' && printf ok > '#{probe_trace}'"}},sub.("submit",pkg),{:function,"read_file",%{"path"=>ft}},sub.("submit",[Enum.at(pkg,1)])]
     script.(actions)
     {o,s}=invoke.(["intent","shape",slug,request]); {o,s,%{}}
    mode in ~w(refine refine-red) ->
     Enum.each(pkg,fn f -> put.(f["path"],f["content"]) end)
     {_,0}=invoke.(["intent","approve",slug,hash.()])
     raw=File.read!(approval)
     changed_text=String.replace(text,"# Check local", "# Clarify local")
     changed_body=body <> "// accumulated proposal\n"
     before=count.(); bs=setups.()
     bad=String.replace(changed_text,"(source: request)","(missing source)")
     actions=[sub.("submit_refinement",[%{"path"=>md,"content"=>bad},%{"path"=>step,"content"=>changed_body}]),sub.("submit_refinement",[%{"path"=>md,"content"=>changed_text}]),{:function,"read_file",%{"path"=>ft}},sub.("submit_refinement",[%{"path"=>ft,"content"=>feature}])]
     script.(actions)
     {o,s}=invoke.(["intent","refine",slug,hash.(),request])
     [audit]=Path.wildcard(Path.join(c.repo,".kogen/local/refinements/*/original-readiness.json"))
     ar=JSON.decode!(File.read!(audit))
     archived=Path.wildcard(Path.join(c.repo,".kogen/local/refinements/*/revoked-approval.json"))
     ex=%{"accumulated package published"=>File.read!(Path.join(c.repo,md))==changed_text and File.read!(Path.join(c.repo,step))==changed_body,"original retained"=>ar["status"]=="hit" and ar["source"]=="retained","candidate setup executions"=>setups.()-bs,"raw approval archived"=>Enum.any?(archived,&(File.read!(&1)==raw)),"acceptance executions"=>count.()-before}
     {o,s,ex}
    mode=="cache" ->
     Enum.each(pkg,fn f -> put.(f["path"],f["content"]) end)
     invoke.(["intent","approve",slug])
     ck=clean_record.()
     measured=fn action -> action.(); n=count.(); invoke.(["intent","approve",slug]); count.()-n end
     entries=[
      {"exact repeat executions",fn -> :ok end},
      {"ignored change executions",fn -> put.("node_modules/parity-local/index.cjs","module.exports=99;"); put.("_build/result.cjs","module.exports=99;") end},
      {"legacy executions",fn -> File.write!(evidence,JSON.encode!(Map.put(record.(),"version",2))) end},
      {"nonignored addition executions",fn -> put.("new-input.txt","one\n") end},
      {"nonignored content executions",fn -> put.("new-input.txt","two\n") end},
      {"nonignored deletion executions",fn -> File.rm!(Path.join(c.repo,"new-input.txt")) end},
      {"mode change executions",fn -> File.chmod!(Path.join(c.repo,"candidate.sh"),0o644) end},
      {"head change executions",fn -> Helpers.git!(c,["commit","--allow-empty","-qm","Move fixture HEAD"]) end},
      {"protected change executions",fn -> put.(".guard","new baseline\n") end},
      {"declaration change executions",fn -> put.(Config.path(),String.replace(config_text,"bootstrap.cjs", "bootstrap.cjs ")) end}
     ]
     ex=Map.new(entries,fn {k,a}->{k,measured.(a)} end)
     File.write!(evidence,JSON.encode!(Map.put(record.(),"version",2)))
     bs=setups.()
     script.([sub.("submit_refinement",[%{"path"=>md,"content"=>text<>"\nClarified fixture.\n"}])])
     {o,s}=invoke.(["intent","refine",slug,hash.(),request])
     [audit]=Path.wildcard(Path.join(c.repo,".kogen/local/refinements/*/original-readiness.json"))
     ar=JSON.decode!(File.read!(audit))
     ex=Map.merge(ex,%{"clean record"=>ck and clean_record.(),"legacy original miss"=>ar["status"]=="miss","legacy original setup executions"=>ar["setup_executions"],"fresh candidate setup executions"=>setups.()-bs-(ar["setup_executions"]||0)})
     {o,s,ex}
    true ->
     Enum.each(pkg,fn f -> put.(f["path"],f["content"]) end)
     if mode=="scratch-mutation",do: put.("bootstrap.cjs",bootstrap<>"require('node:fs').writeFileSync('app.txt','mutated input\\n');\n")
     File.rm(evidence)
     args=if mode=="approve-negative",do: ["intent","approve",slug,hash.()],else: ["intent","approve",slug]
     {o,s}=invoke.(args); {o,s,%{}}
   end
   runs=read_lines.(trace)
   last=List.last(runs)||%{}
   final_setup=List.last(read_lines.(setup_trace))||%{}
   scenarios=record.()["scenarios"]||[]
   diag=FakeProvider.tool_outputs(c.server)|>Enum.join("\n")
   clean_dirs=Enum.filter(runs++read_lines.(setup_trace),&(&1["cwd"] != c.repo))
   results=%{
    "final dependency present"=>last["dep"],"final build present"=>last["build"],"final disposable"=>last["cwd"] != nil and last["cwd"] != c.repo,
    "setup started cold"=>final_setup["cold"]==true and final_setup["cwd"] != c.repo,
    "accounted failed"=>status in [0,5] and Enum.any?(scenarios,&(&1["status"]=="failed")),
    "all passed"=>status==0 and scenarios != [] and Enum.all?(scenarios,&(&1["status"]=="passed")),
    "diagnostic inspected"=>String.contains?(diag,"Readiness observations") and String.contains?(diag,"Cannot find module") and Enum.any?(FakeProvider.provider_requests(c.server),fn req -> Enum.any?(req.json["input"]||[],&(&1["type"]=="function_call_output" and String.contains?(&1["output"]||"","Actual generated imports"))) end),
    "warm probe succeeded"=>File.read(probe_trace)=={:ok,"ok"},
    "exact inputs and env"=>last["git"]==true and last["tracked"]=="tracked ignored bytes\n" and last["mode"]==true and last["env"]=="caller-value" and last["app"]=="baseline\n",
    "acceptance executions"=>count.()-base_runs,"clean record"=>clean_record.(),
    "caller index unchanged"=>File.read!(Path.join(c.repo,".git/index"))==original_index,
    "caller custody"=>File.read!(Path.join(c.repo,".git/index"))==original_index and Git.head(c.repo)==original_head and File.read!(Path.join(c.repo,"app.txt"))=="baseline\n" and File.exists?(approval)==(mode=="approve-negative"),
    "disposable cleaned"=>clean_dirs != [] and Enum.all?(clean_dirs,&(not File.exists?(&1["cwd"]))),
    "refused"=>status not in [0,5],"no clean evidence"=>not File.exists?(evidence),"no approval"=>not File.exists?(approval),
    "root effect honest"=>File.read!(Path.join(c.repo,"app.txt"))==(if mode=="root-drift",do: "external drift\n",else: "baseline\n"),
    "output"=>out,"status"=>status,"setup executions"=>setups.()-base_setups
   }|>Map.merge(extra)
   {mode,results}
  after
   Helpers.cleanup_case(c)
  end
 end
 IO.puts("CLEAN_READINESS_PARITY="<>JSON.encode!(results))
after
 Helpers.cleanup_suite(suite)
end
ExUnit.run()
`;
function runExercise() {
  return new Promise((resolve, reject) => {
    const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'clean-readiness-driver-'));
    const file = path.join(temp, 'driver.exs');
    fs.writeFileSync(file, driver);
    const env = { ...process.env, ERL_FLAGS: process.env.ERL_FLAGS || '+S 2:2 +SDcpu 1 +SDio 1' };
    delete env.KOGEN_ARCHIVE;
    const child = spawn('mix', ['run', file], { cwd: REPO, env, detached: true, stdio: ['ignore', 'pipe', 'pipe'] });
    let output = '';
    child.stdout.on('data', b => { output += b; });
    child.stderr.on('data', b => { output += b; });
    const timer = setTimeout(() => { try { process.kill(-child.pid, 'SIGKILL'); } catch {} }, 280000);
    child.on('error', e => { clearTimeout(timer); fs.rmSync(temp, { recursive: true, force: true }); reject(e); });
    child.on('close', code => {
      clearTimeout(timer); fs.rmSync(temp, { recursive: true, force: true });
      try {
        assert.equal(code, 0, output);
        const line = output.split('\n').find(s => s.startsWith('CLEAN_READINESS_PARITY='));
        assert.ok(line, output);
        resolve(JSON.parse(line.slice('CLEAN_READINESS_PARITY='.length)));
      } catch (e) { reject(e); }
    });
  });
}
When('I qualify clean readiness parity in mode {string}', { timeout: 300000 }, async function (mode) {
  if (!exercise) exercise = runExercise();
  const all = await exercise;
  assert.ok(Object.hasOwn(all, mode), mode);
  this.cleanReadinessParity = all[mode];
});
Then('the clean readiness parity observations are:', function (table) {
  const failures = [];
  for (const [key, raw] of table.raw()) {
    const expected = JSON.parse(raw);
    try { assert.deepEqual(this.cleanReadinessParity[key], expected); }
    catch { failures.push(`${key}: expected ${raw}, got ${JSON.stringify(this.cleanReadinessParity[key])}`); }
  }
  assert.deepEqual(failures, [], JSON.stringify(this.cleanReadinessParity, null, 2));
});
