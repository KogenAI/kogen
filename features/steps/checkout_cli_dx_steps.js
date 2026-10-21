const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { When, Then, AfterAll } = require('@cucumber/cucumber');
const ROOT = path.resolve(__dirname, '../..');
let work, packaged;
function run(file, args, options = {}) {
  return new Promise((resolve, reject) => {
    const p = spawn(file, args, { ...options, detached: true, stdio: ['ignore', 'pipe', 'pipe'] });
    let out = '';
    p.stdout.on('data', b => { out += b; }); p.stderr.on('data', b => { out += b; });
    const timer = setTimeout(() => { try { process.kill(-p.pid, 'SIGKILL'); } catch {} }, 240000);
    p.on('error', e => { clearTimeout(timer); reject(e); });
    p.on('close', code => { clearTimeout(timer); resolve({ code, out }); });
  });
}
// Independent installed-CLI driver; maintained helpers supply packaging, Git and fake HTTP.
// Execute compiled prod modules with Elixir, not a Mix task: even prod Mix dependency
// resolution needs Hex in a clean HOME. A focused empty-HOME Elixir probe qualified this.
const driver = String.raw`
Code.require_file(Path.expand("test/support/integration_helpers.ex", File.cwd!()))
defmodule CheckoutCLIExercise do
  use ExUnit.Case
  alias Kogen.Integration.{Helpers, FakeProvider}
  @tag timeout: 210_000
  test "observe installed checkout CLI" do
    s=Helpers.setup_suite!()
    on_exit(fn -> Helpers.cleanup_suite(s) end)
    c=Helpers.project!(s,[],staged_intent: false)
    on_exit(fn -> Helpers.cleanup_case(c) end)
    mode=System.fetch_env!("DX_MODE")
    {out,code}=Helpers.run_kogen(c,["context"])
    receipt=case JSON.decode(out) do
      {:ok,%{"schema_version"=>1,"kind"=>"context"}=doc} when code == 0 ->
        assert is_map(doc["data"]), out
        Map.put(exercise(mode,c,doc),:supported,true)
      _ -> %{supported: false, output: out, code: code}
    end
    File.write!(System.fetch_env!("DX_RECEIPT"),JSON.encode!(receipt))
  end
  defp exercise("isolation",c,initial) do
    before=custody(c)
    empty=initial["data"]["active"] == nil and initial["data"]["last_built"] == nil
    nested=Path.join(c.repo,"nested/deep"); File.mkdir_p!(nested)
    {nd,0}=json(c,["context"],cd: nested)
    {outside,0}=json(c,["context"],cd: c.root)
    # Worktrees are test fixtures only, not a new product orchestration feature.
    git(c,["add",".kogen","features"]); git(c,["commit","-qm","fixture package"])
    wt=Path.join(c.root,"other-checkout"); git(c,["worktree","add","-q","-b","other",wt])
    {wd,0}=json(c,["context","--project",wt])
    {_,k}=Helpers.run_kogen(c,["intent","build","fixture"]); assert k != 0
    {a,0}=json(c,["context"])
    {w,0}=json(c,["context","--project",wt])
    File.write!(Path.join(c.repo,"app.txt"),"dirty, not activity\n")
    {dirty,0}=json(c,["context"])
    read_before=custody(c)
    {_,0}=json(c,["context"])
    %{outside: outside["checkout"] == nil and outside["error"] == nil and outside["data"]["project"] == false,
      empty: empty, nested: nd["checkout"] == initial["checkout"],
      worktreeIdentity: wd["checkout"]["id"] != initial["checkout"]["id"] and wd["checkout"]["root"] == Path.expand(wt),
      worktreeAbsence: a["data"]["last_built"] != nil and w["data"]["last_built"] == nil and w["data"]["active"] == nil,
      dirtyIsNotActive: dirty["data"]["active"] == nil and dirty["data"]["last_built"] == a["data"]["last_built"],
      readOnly: custody(c) == read_before and before.approval == read_before.approval}
  end
  defp exercise("attempts",c,_) do
    {o1,k1}=Helpers.run_kogen(c,["intent","build","fixture"])
    one=run_ids(c); assert length(one) == 1, o1; [id1]=one
    original=File.read!(runpath(c,id1,"result.json"))
    {o2,k2}=Helpers.run_kogen(c,["intent","build","fixture"])
    [id2]=run_ids(c)--one
    {ctx,0}=json(c,["context"])
    {listing,0}=json(c,["intent","list","--json","--limit","100"])
    rows=listing["data"]["items"]
    builds=Enum.filter(rows,&(&1["type"] == "build"))
    packages=Enum.filter(rows,&(&1["type"] == "intent"))
    paged=pages(c,nil,[],0)
    before=custody(c)
    {d,0}=json(c,["intent","inspect",id2,"--json"]); r=d["data"]
    inspect_clean=custody(c) == before
    approval=Kogen.Intent.approval_path(c.repo,"fixture"); bytes=File.read!(approval); File.rm!(approval)
    {_,reject}=Helpers.run_kogen(c,["intent","build","fixture"])
    {after_reject,0}=json(c,["context"])
    File.write!(approval,bytes)
    old2=File.read!(runpath(c,id2,"result.json"))
    {resume_out,resume_code}=Helpers.run_kogen(c,["intent","resume",id2])
    [id3]=run_ids(c)--[id1,id2]
    {rd,0}=json(c,["intent","inspect",id3,"--json"]); rr=rd["data"]
    {last,0}=json(c,["context"])
    %{twoAttempts: k1 != 0 and k2 != 0 and Enum.map(builds,& &1["run_id"]) == [id2,id1],
      packageSeparate: length(packages) == 1 and hd(packages)["approval_state"] == "current" and hd(packages)["package_state"] in ["valid","unknown"] and Enum.all?(builds,&is_binary(&1["state"])),
      pagination: paged == rows,
      failureInspection: r["run_id"] == id2 and r["slug"] == "fixture" and r["reason"] != nil and r["phase"] == "building" and r["state"] != "active" and is_list(r["verification"]) and is_list(r["reviews"]) and is_list(r["blockers"]) and r["locations"]["candidate"] == c.repo and r["locations"]["run_dir"] == Path.dirname(runpath(c,id2,"result.json")) and r["commit"] == nil and r["resume_status"] == "potentially_available" and r["next_command"] == resume_command(c,id2) and is_map(r["observations"]),
      lastStarted: ctx["data"]["last_built"] == %{"slug"=>"fixture","run_id"=>id2} and ctx["data"]["active"] == nil,
      rejectedDoesNotReplace: reject != 0 and after_reject["data"]["last_built"] == ctx["data"]["last_built"],
      resumeLineage: resume_code != 0 and resume_out =~ id3 and rr["resumed_from"] == id2 and rr["root_run"] == id2 and last["data"]["last_built"]["run_id"] == id3,
      originalResults: original == File.read!(runpath(c,id1,"result.json")) and old2 == File.read!(runpath(c,id2,"result.json")),
      inspectReadOnly: inspect_clean, receipt: o2 =~ id2 and o2 =~ "building" and o2 =~ "inspect" and o2 =~ c.repo}
  end
  defp exercise("lifecycle",c,_) do
    gate=Path.join(c.root,"verify-gate"); marker=Path.join(c.root,"verify-marker"); release=Path.join(c.root,"verify-release")
    step=Path.join(c.repo,"features/steps/integration_steps.js")
    original=File.read!(step)
    File.write!(step,original <> "\nconst fs=require('node:fs'); const {Before}=require('@cucumber/cucumber'); Before(function(){ if(fs.existsSync("<>JSON.encode!(gate)<>")){fs.writeFileSync("<>JSON.encode!(marker)<>",'waiting'); while(!fs.existsSync("<>JSON.encode!(release)<>")) Atomics.wait(new Int32Array(new SharedArrayBuffer(4)),0,0,20);}});\n")
    approve(c)
    sign(c)
    commit_marker=Path.join(c.root,"commit-marker"); commit_release=Path.join(c.root,"commit-release")
    Helpers.write_hook!(c,"touch "<>q(commit_marker)<>"; while ! test -f "<>q(commit_release)<>"; do sleep 0.02; done\n")
    File.write!(gate,"")
    owner=self()
    script(c,[{:pause,owner,f("write_file",%{"path"=>"app.txt","content"=>"builder work\n"})}, f("finish",%{"summary"=>"done"}), {:pause,owner,f("write_file",%{"path"=>"app.txt","content"=>"reviewer repair\n"})}, f("submit_review",%{"verdict"=>"approve","findings"=>[]})])
    p=Helpers.start_kogen(c,["intent","build","fixture"])
    peer=paused(); a=context(c); id=a["active"]["run_id"]; send(peer,:continue)
    Helpers.wait_for_file!(marker); b=context(c)
    File.write!(release,"")
    peer=paused(); d=context(c)
    File.rm!(marker); File.rm!(release); send(peer,:continue)
    Helpers.wait_for_file!(marker); e=context(c); File.write!(release,"")
    Helpers.wait_for_file!(commit_marker); h=context(c); File.write!(commit_release,"")
    {out,code}=Helpers.await_exit(p,"",30000)
    final=context(c); head=git(c,["rev-parse","HEAD"])
    {verified,vcode}=Helpers.git!(c,["verify-commit",head])
    {inspect_doc,0}=json(c,["intent","inspect",id,"--json"]); r=inspect_doc["data"]
    result=JSON.decode!(File.read!(runpath(c,id,"result.json")))
    %{phases: Enum.map([a,b,d,e,h],& &1["active"]["phase"]), passes: Enum.map([a,b,d,e,h],& &1["active"]["verification_pass"]),
      oneReviewerConversation: result["reviews"] == 1 and length(FakeProvider.review_requests(c.server)) == 2,
      oneSignedCommit: code == 0 and vcode == 0 and verified =~ "Good" and git(c,["show","HEAD:app.txt"]) == "reviewer repair" and out =~ "landed",
      idleRetainsLast: final["active"] == nil and final["last_built"] == %{"slug"=>"fixture","run_id"=>id},
      landedInspection: r["commit"] == head and r["state"] == "landed" and r["verification"] != [] and r["reviews"] != [] and r["resumed_from"] == nil and r["root_run"] == id,
      localNotCommitted: not String.contains?(git(c,["ls-tree","-r","--name-only","HEAD"]),".kogen/local/")}
  end
  defp exercise(mode,c,_) when mode in ["interrupt","core-crash","cli-death"] do
    marker=Path.join(c.repo,".kogen/local/pause")
    script(c,[f("shell",%{"command"=>"touch "<>q(marker)<>"; sleep 600"})])
    before=git(c,["rev-parse","HEAD"])
    p=Helpers.start_kogen(c,["intent","build","fixture"])
    Helpers.wait_for_file!(marker); active=context(c); id=active["active"]["run_id"]
    assert is_binary(id), inspect(active)
    case mode do
      "interrupt" -> Helpers.signal!(c,p,"INT")
      "cli-death" -> Helpers.signal!(c,p,"KILL")
      "core-crash" ->
        {:os_pid,pid}=Port.info(p,:os_pid)
        {table,0}=System.cmd("ps",["-axo","pid=,ppid=,comm="])
        children=String.split(table,"\n") |> Enum.filter(fn line -> case String.split(String.trim(line),~r/\s+/,parts: 3) do [_,parent,command] -> parent == to_string(pid) and String.contains?(command,"beam"); _ -> false end end)
        assert length(children) == 1, table
        [child|_]=String.split(String.trim(hd(children)),~r/\s+/)
        {_,0}=System.cmd("/bin/kill",["-KILL",child])
    end
    {out,code}=Helpers.await_exit(p,"",15000)
    stopped=wait_idle(c,System.monotonic_time(:millisecond)+15000)
    {doc,0}=json(c,["intent","inspect",id,"--json"]); r=doc["data"]
    %{observedActive: active["active"]["phase"] == "building", cleared: stopped["active"] == nil,
      lastRetained: stopped["last_built"]["run_id"] == id, noCommit: git(c,["rev-parse","HEAD"]) == before,
      inspectionStopped: r["state"] != "active" and r["phase"] == "building" and r["reason"] != nil,
      receipt: if(mode == "cli-death", do: r["locations"]["run_dir"] != nil and r["state"] == "interrupted", else: code == if(mode == "interrupt",do: 130,else: 70) and out =~ id and out =~ "inspect")}
  end
  defp exercise("invalid",c,_) do
    Helpers.run_kogen(c,["intent","build","fixture"])
    file=Path.join(c.repo,".kogen/local/context.json"); saved=File.read!(file)
    File.write!(file,"{broken")
    before=custody(c); {bad,0}=json(c,["context"])
    malformed=bad["data"]["integration_state"] == "invalid" and bad["data"]["active"] == nil
    unchanged=File.read!(file) == "{broken" and custody(c) == before
    File.rm!(file); {missing,0}=json(c,["context"])
    absent=not File.exists?(file)
    File.write!(file,saved)
    %{malformedSafe: malformed, missingSafe: missing["data"]["active"] == nil and missing["data"]["integration_state"] == "missing", noReconstruction: missing["data"]["last_built"] == nil and absent, readOnly: unchanged}
  end
  defp exercise("preflight",c,_) do
    trace=Path.join(c.root,"executed")
    configure_setup(c,"echo unexpected >> "<>q(trace))
    approve(c); File.rm(trace)
    before=custody(c); n=count(c)
    {green,gcode}=json(c,["intent","preflight","fixture","--json"])
    read_only=custody(c) == before
    File.write!(Path.join(c.repo,"app.txt"),"dirty\n")
    dirty_before=custody(c); {dirty,dcode}=json(c,["intent","preflight","fixture","--json"])
    read_only=read_only and custody(c) == dirty_before
    File.write!(Path.join(c.repo,"app.txt"),before.app)
    ap=Kogen.Intent.approval_path(c.repo,"fixture"); approval=JSON.decode!(File.read!(ap)); File.write!(ap,JSON.encode!(Map.put(approval,"sha256",String.duplicate("0",64))))
    bad_before=custody(c); {changed,ccode}=json(c,["intent","preflight","fixture","--json"])
    read_only=read_only and custody(c) == bad_before; File.write!(ap,before.approval)
    lock=Path.join(c.repo,".kogen/local/build.lock"); assert :ok == Kogen.Lock.acquire(lock)
    try do
      locked_before=custody(c); lock_before=File.ls!(lock)
      {conflict,fcode}=json(c,["intent","preflight","fixture","--json"])
      %{green: gcode == 0 and green["data"]["ready"] == true and Enum.map(green["data"]["checks"],& &1["name"]) == ["configuration","package","approval","cleanliness","conflict"],
        scopeHonest: is_list(green["data"]["limitations"]) and Regex.match?(~r/setup.*checks|checks.*setup/is,JSON.encode!(green["data"]["limitations"])),
        dirtyBlocked: dcode == 1 and dirty["data"]["ready"] == false and JSON.encode!(dirty["data"]["blockers"]) =~ "app.txt",
        approvalBlocked: ccode == 1 and changed["data"]["ready"] == false and JSON.encode!(changed["data"]["blockers"]) =~ "approval",
        conflictBlocked: fcode == 1 and conflict["data"]["ready"] == false and JSON.encode!(conflict["data"]["blockers"]) =~ "build_running",
        readOnly: read_only and custody(c) == locked_before and File.ls!(lock) == lock_before,
        noCommandsOrProvider: not File.exists?(trace) and n == count(c)}
    after Kogen.Lock.release(lock) end
  end
  defp exercise("fast",c,_) do
    Helpers.run_kogen(c,["intent","build","fixture"]); [id]=run_ids(c)
    legacy="00000000"; File.mkdir_p!(Path.dirname(runpath(c,legacy,"log.jsonl")))
    File.write!(runpath(c,legacy,"result.json"),JSON.encode!(%{"slug"=>"fixture","build"=>legacy,"outcome"=>"failed"}))
    {completion,0}=Helpers.run_kogen(c,["completion","zsh"])
    scriptfile=Path.join(c.root,"_kogen"); File.write!(scriptfile,completion)
    {syntax,syntax_code}=System.cmd("zsh",["-n",scriptfile]); assert syntax_code == 0, syntax
    {intents,0}=Helpers.run_kogen(c,["__complete","build"])
    {resumes,0}=Helpers.run_kogen(c,["__complete","resume"])
    n=count(c); base=measure(c)
    for x <- 1..2000 do
      dir=Path.join(c.repo,".kogen/local/runs/history-#{x}"); File.mkdir_p!(dir); File.write!(Path.join(dir,"log.jsonl"),String.duplicate("not a summary\n",16))
    end
    accumulated=measure(c)
    runs=Path.join(c.repo,".kogen/local/runs"); backup=runs<>"-saved"; File.rename!(runs,backup)
    {_,0}=System.cmd("mkfifo",[runs])
    core=Path.join(c.suite.prefix,"lib/kogen/lib/release/bin/kogen"); File.rename!(core,core<>".saved")
    try do
      {context,0}=json(c,["context"])
      {candidates,0}=Helpers.run_kogen(c,["__complete","resume"])
      blocked=measure(c)
      samples=System.fetch_env!("DX_SAMPLES") |> String.to_integer()
      p95=System.fetch_env!("DX_P95") |> String.to_integer(); maximum=System.fetch_env!("DX_MAX") |> String.to_integer()
      timings=%{platform: :os.type() |> inspect(), samples: samples, baseline: base, accumulated: accumulated, blocked: blocked}
      %{completionSyntax: syntax_code == 0 and completion =~ "_kogen" and completion =~ "__complete",
        intentCandidates: Enum.any?(String.split(intents,"\n"),&String.starts_with?(&1,"fixture\t")),
        resumeCandidates: Enum.any?(String.split(resumes,"\n"),&(String.starts_with?(&1,id<>"\t") and String.contains?(&1,"fixture"))),
        unsupportedExcluded: not String.contains?(resumes,legacy), noCoreOrHistory: context["data"]["last_built"]["run_id"] == id and candidates == resumes,
        noProvider: n == count(c), measuredWithinBudget: Enum.all?([base,accumulated,blocked],fn group -> Enum.all?(Map.values(group),&(&1.p95 <= p95 and &1.max <= maximum)) end), measurementsRecorded: true, timings: timings}
    after
      File.rename!(core<>".saved",core); File.rm!(runs); File.rename!(backup,runs)
    end
  end
  defp exercise("errors",c,_) do
    {list,0}=json(c,["intent","list","--json"])
    {unknown,k}=json(c,["intent","inspect","ffffffff","--json"])
    limits=Enum.map(["0","101","x"],fn n -> {d,k}=json(c,["intent","list","--json","--limit",n]); k == 2 and d["error"]["reason"] == "invalid_argument" end)
    {bad,bk}=json(c,["context","--project",Path.join(c.root,"absent")])
    {human,hk}=Helpers.run_kogen(c,["intent","list"])
    package=Path.join(c.repo,".kogen/intents"); File.rename!(package,package<>"-saved")
    {empty,ek}=json(c,["intent","list","--json"]); File.rename!(package<>"-saved",package)
    %{versioned: Enum.all?([list,unknown,bad,empty],&(&1["schema_version"] == 1 and Map.has_key?(&1,"checkout") and Map.has_key?(&1,"data") and Map.has_key?(&1,"error"))),
      emptyList: ek == 0 and empty["data"]["items"] == [] and empty["data"]["next_cursor"] == nil,
      unknownRun: k == 1 and unknown["error"]["reason"] == "run_not_found", invalidLimits: Enum.all?(limits),
      unavailableProject: bk == 3 and bad["error"]["reason"] == "project_unavailable",
      humanOutput: hk == 0 and human =~ "fixture" and not String.starts_with?(String.trim(human),"{")}
  end
  defp json(c,args,opts \\ []) do
    {out,k}=Helpers.run_kogen(c,args,opts)
    case JSON.decode(out) do {:ok,m} when is_map(m) -> {m,k}; _ -> flunk("expected one JSON object for #{inspect(args)} (#{k}): #{out}") end
  end
  defp context(c) do {d,0}=json(c,["context"]); d["data"] end
  defp count(c), do: length(FakeProvider.provider_requests(c.server))
  defp f(n,a), do: {:function,n,a}
  defp script(c,tail), do: Agent.update(c.server.state,fn s -> %{s|script: Enum.take(s.script,s.next) ++ tail} end)
  defp git(c,args) do {o,0}=Helpers.git!(c,args); String.trim(o) end
  defp q(s), do: Kogen.Init.shell_quote(s)
  defp resume_command(c,id), do: "kogen intent resume #{id} --project "<>q(c.repo)
  defp runpath(c,id,file), do: Path.join([c.repo,".kogen/local/runs",id,file])
  defp run_ids(c), do: Path.wildcard(Path.join(c.repo,".kogen/local/runs/*/result.json")) |> Enum.map(&(Path.dirname(&1) |> Path.basename()))
  defp custody(c) do
    files=Path.wildcard(Path.join(c.repo,".kogen/local/**/*")) |> Enum.filter(&File.regular?/1) |> Enum.map(&{Path.relative_to(&1,c.repo),File.read!(&1)}) |> Map.new()
    %{head: git(c,["rev-parse","HEAD"]), index: File.read!(Path.join(git(c,["rev-parse","--absolute-git-dir"]),"index")), approval: File.read!(Kogen.Intent.approval_path(c.repo,"fixture")), app: File.read!(Path.join(c.repo,"app.txt")), local: files}
  end
  defp approve(c) do
    {out,k}=Helpers.run_kogen(c,["intent","approve","fixture"]); assert k == 5, out
    [_,hash]=Regex.run(~r/SHA-256: ([0-9a-f]{64})/,out)
    {out,k}=Helpers.run_kogen(c,["intent","approve","fixture",hash]); assert k == 0, out
  end
  defp configure_setup(c,command) do
    path=Path.join(c.repo,".kogen/project.yaml"); config=Kogen.Config.load!(c.repo)
    File.write!(path,Kogen.Config.render(%{setup: [command],fix: config.fix,checks: Enum.map(config.checks,fn {n,r}->%{name: n,run: r} end),protect: config.protect,acceptance: %{run: config.acceptance_run,steps_dir: config.steps_dir}}))
    git(c,["add",".kogen/project.yaml"]); git(c,["commit","-qm","fixture setup"])
  end
  defp pages(c,cursor,acc,n) do
    assert n < 20, "pagination did not terminate"
    args=["intent","list","--json","--limit","1"] ++ if(cursor,do: ["--cursor",cursor],else: [])
    {doc,0}=json(c,args); d=doc["data"]; rows=acc++d["items"]
    if d["next_cursor"] == nil, do: rows, else: pages(c,d["next_cursor"],rows,n+1)
  end
  defp paused do receive do {:provider_paused,peer}->peer after 15000->flunk("provider did not reach pause") end end
  defp wait_idle(c,deadline) do
    data=context(c)
    if data["active"] == nil, do: data, else: (assert System.monotonic_time(:millisecond)<deadline; Process.sleep(20); wait_idle(c,deadline))
  end
  defp measure(c) do
    samples=System.fetch_env!("DX_SAMPLES") |> String.to_integer()
    for {label,args} <- [{:context,["context"]},{:completion,["__complete","resume"]}], into: %{} do
      times=for _ <- 1..samples do
        t=System.monotonic_time(:microsecond)
        {out,k}=Helpers.run_kogen(c,args); assert k == 0, out
        (System.monotonic_time(:microsecond)-t)/1000
      end |> Enum.sort()
      {label,%{p50: Enum.at(times,div(samples,2)),p95: Enum.at(times,ceil(samples*0.95)-1),max: List.last(times)}}
    end
  end
  defp sign(c) do
    key=Path.join(c.root,"signing"); {_,0}=System.cmd("/usr/bin/ssh-keygen",["-q","-t","ed25519","-N","","-f",key])
    allowed=Path.join(c.root,"allowed-signers"); File.write!(allowed,"kogen-integration@example.invalid "<>File.read!(key<>".pub"))
    for pair <- [["gpg.format","ssh"],["user.signingkey",key],["commit.gpgsign","true"],["gpg.ssh.allowedSignersFile",allowed]], do: git(c,["config"|pair])
  end
end
`;
AfterAll(function () { if (work) fs.rmSync(work, { recursive: true, force: true }); });
async function exercise(world, mode, samples = 20, p95 = 100, max = 500) {
  if (!packaged) packaged = (async () => {
    work = fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-checkout-cli-'));
    const result = await run('/bin/sh', ['packaging/package.sh'], { cwd: ROOT });
    assert.equal(result.code, 0, result.out);
    const archive = result.out.split('\n').find(x => x.startsWith('/') && x.endsWith('.tar.gz'));
    assert.ok(archive && fs.existsSync(archive), result.out); return archive;
  })();
  const archive = await packaged;
  const temp = fs.mkdtempSync(path.join(work, 'case-'));
  try {
    const script = path.join(temp, 'checkout_cli_test.exs'), receipt = path.join(temp, 'receipt.json');
    fs.writeFileSync(script, driver);
    const dirs = [];
    for (const name of ['elixir', 'mix', 'erl', 'go', 'node', 'npm', 'python3']) {
      const r = await run('mise', ['which', name], { cwd: ROOT });
      assert.equal(r.code, 0, r.out); dirs.push(path.dirname(r.out.trim()));
    }
    // packaging/setup has already compiled _build/prod; elixir does not resolve Mix deps.
    const result = await run('elixir', ['-pa', path.join(ROOT, '_build/prod/lib/kogen/ebin'), '-e', 'Application.ensure_all_started(:kogen); ExUnit.start(); Code.require_file(System.fetch_env!("DX_DRIVER"))'], { cwd: ROOT, env: { ...process.env, PATH: [...dirs, process.env.PATH].join(path.delimiter), KOGEN_ARCHIVE: archive, DX_DRIVER: script, DX_MODE: mode, DX_RECEIPT: receipt, DX_SAMPLES: String(samples), DX_P95: String(p95), DX_MAX: String(max) } });
    assert.equal(result.code, 0, result.out);
    assert.ok(fs.existsSync(receipt), result.out);
    world.checkoutCLI = JSON.parse(fs.readFileSync(receipt, 'utf8'));
    await world.attach(JSON.stringify(world.checkoutCLI), 'application/json');
  } finally { fs.rmSync(temp, { recursive: true, force: true }); }
}
When('I exercise checkout CLI facts in mode {string}', { timeout: 300000 }, async function (mode) { await exercise(this, mode); });
When('I exercise checkout CLI facts in mode {string} with {int} samples and p95 budget {int} and maximum {int} milliseconds', { timeout: 300000 }, async function (mode, samples, p95, max) { await exercise(this, mode, samples, p95, max); });
Then('the checkout CLI observations are:', function (table) {
  assert.ok(this.checkoutCLI, 'no installed observations');
  for (const [key, raw] of table.raw()) assert.deepEqual(this.checkoutCLI[key], JSON.parse(raw), `${key}: ${JSON.stringify(this.checkoutCLI)}`);
});
