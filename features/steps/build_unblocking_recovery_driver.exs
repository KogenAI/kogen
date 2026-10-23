ExUnit.start(autorun: false)
Code.require_file("test/support/integration_helpers.ex")

defmodule UnblockingExercise do
  import ExUnit.Assertions
  alias Kogen.{Config, Intent, Snapshot, Tools}
  alias Kogen.Integration.{Helpers, FakeProvider}

  def hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  def put(root, path, bytes) do
    p = Path.join(root, path)
    File.mkdir_p!(Path.dirname(p))
    File.write!(p, bytes)
  end
  def git(c, args) do
    {out, 0} = Helpers.git!(c, args)
    String.trim(out)
  end
  def count(c), do: length(FakeProvider.provider_requests(c.server))
  def call(name, args), do: {:function, name, args}
  def script(c, tail) do
    Agent.update(c.server.state, fn s ->
      used = Enum.take(s.script, s.next)
      %{s | script: used ++ List.duplicate(nil, max(0, s.next - length(used))) ++ tail}
    end)
  end
  def invoke(c, args), do: Helpers.run_kogen(c, args)
  def contract(c), do: Intent.hash(c.repo, Intent.baseline(c.repo, "fixture", Config.load!(c.repo)))
  def approval(c), do: Intent.approval_path(c.repo, "fixture")
  def custody(c) do
    %{head: git(c, ["rev-parse", "HEAD"]), tree: Snapshot.tree(c.repo, git(c, ["rev-parse", "HEAD"]), []),
      index: File.read!(Path.join(c.repo, ".git/index")), approval: File.read(approval(c))}
  end
  def tree_entry(c, tree, path) do
    {out, 0} = Helpers.git!(c, ["ls-tree", tree, "--", ":(literal)" <> path])
    case String.split(String.trim(out), ~r/\s+/, parts: 4) do
      [mode, "blob", object, _] ->
        {bytes, 0} = Helpers.git!(c, ["cat-file", "blob", object])
        {%{"mode" => mode, "sha256" => hash(bytes)}, bytes}
      _ -> {nil, nil}
    end
  end
  def files(dir) do
    File.ls!(dir) |> Enum.sort() |> Enum.flat_map(fn n ->
      p = Path.join(dir, n)
      case File.lstat!(p).type do
        :directory -> Enum.map(files(p), &Path.join(n, &1))
        :regular -> [n]
        _ -> flunk("unsafe archive entry #{p}")
      end
    end)
  end
  def private!(dir) do
    assert Bitwise.band(File.stat!(dir).mode, 0o777) == 0o700
    for n <- File.ls!(dir) do
      p = Path.join(dir, n)
      if File.dir?(p), do: private!(p), else: assert(Bitwise.band(File.lstat!(p).mode, 0o777) == 0o600)
    end
  end
  # Independent archive observer: never calls production recovery code or its tests.
  def archive!(dir, expected) do
    m = JSON.decode!(File.read!(Path.join(dir, "manifest.json")))
    assert Map.take(m, Map.keys(expected.meta)) == expected.meta
    assert m["changes"] == expected.changes
    actual_files = files(dir) -- ["manifest.json"]
    entries = m["artifacts"]
    assert is_list(entries)
    assert Enum.map(entries, & &1["path"]) == Enum.sort(actual_files)
    assert length(Enum.uniq_by(entries, & &1["path"])) == length(entries)
    for e <- entries, do: assert(e["sha256"] == hash(File.read!(Path.join(dir, e["path"]))))
    for {p, bytes} <- expected.bytes, do: assert(File.read!(Path.join(dir, p)) == bytes, "archive bytes: #{p}")
    data = Enum.filter(actual_files, &String.starts_with?(&1, ["before/", "candidate/"]))
    assert Enum.sort(data) == (Map.keys(expected.bytes) |> Enum.filter(&String.starts_with?(&1, ["before/", "candidate/"])) |> Enum.sort())
    private!(dir)
    true
  end
  def control(which) do
    root = Path.join(System.tmp_dir!(), "unblocking-observer-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    bytes = %{"candidate/binary file" => <<0, 255, 13, 10>>, "before/deleted" => "old\n", "approval.json" => "retained\n"}
    changes = [%{"path" => "binary file", "before" => nil, "after" => %{"mode" => "100755", "sha256" => hash(bytes["candidate/binary file"])}}]
    meta = %{"version" => 1, "classification" => "BUILDER-REPORTED", "build" => "01234567"}
    try do
      for {p, b} <- bytes, do: put(root, p, b)
      artifacts = for p <- Enum.sort(Map.keys(bytes)), do: %{"path" => p, "sha256" => hash(bytes[p])}
      put(root, "manifest.json", JSON.encode!(Map.merge(meta, %{"changes" => changes, "artifacts" => artifacts})))
      for p <- files(root), do: File.chmod!(Path.join(root, p), 0o600)
      for p <- [root, Path.join(root, "before"), Path.join(root, "candidate")], do: File.chmod!(p, 0o700)
      if which == "bad", do: put(root, "candidate/binary file", <<0, 254, 13, 10>>)
      try do
        archive!(root, %{meta: meta, bytes: bytes, changes: changes})
        IO.puts("ARCHIVE_ACCEPTED")
        0
      rescue
        _ in ExUnit.AssertionError -> IO.puts("ARCHIVE_REJECTED"); 1
      end
    after
      File.rm_rf(root)
    end
  end
  def step(fixed) do
    expected = if fixed, do: "A\\n", else: "baseline\\n"
    """
    const fs=require('node:fs'); const assert=require('node:assert/strict');
    const observe=s=>s==='#{expected}';
    if(require.main===module){const ok=observe(process.argv[2]==='good'?'A\\n':'baseline\\n');process.stdout.write(ok?'accepted\\n':'rejected\\n');process.exit(ok?0:1);}
    else {const {Given,Then}=require('@cucumber/cucumber');Given('the fixture is available',()=>{});Then('the acceptance check passes',()=>assert.equal(observe(fs.readFileSync('app.txt','utf8')),true));}
    """
  end
  def declaration(observer, bad_exit \\ 1, good_exit \\ 0) do
    %{"id" => "fixture-observer", "kind" => "observer", "inputs" => [], "observers" => [observer], "checks" => [
      %{"name" => "good", "command" => "node #{observer} good", "exit" => good_exit, "output" => "accepted\n"},
      %{"name" => "bad", "command" => "node #{observer} bad", "exit" => bad_exit, "output" => "rejected\n"}]}
  end
  def md(evidence \\ []) do
    lines = if evidence == [], do: "- none", else: Enum.map_join(evidence, "\n", &("- evidence: " <> JSON.encode!(&1)))
    """
    # Write the requested production text

    Slug: fixture
    Model: not applicable — local text replacement
    Acceptance:
    - .kogen/intents/fixture/acceptance.feature
    - features/steps/integration_steps.js

    Write exactly A followed by a newline to app.txt. Preserve valuable production work for inspection. A protected expectation for baseline contradicts this request.

    ## Decisions
    - Preserve exact authority. (source: request)

    ## Source comparison
    - addressed: requested A newline; contract outcome and acceptance.

    ## Tests
    - requested text: real file observation (scenario)

    ## Feasibility
    #{lines}
    """
  end
  def configure(c, mode) do
    cfg = Config.load!(c.repo)
    check = "printf 'check\\n' >> .kogen/local/check-trace; test -f app.txt"
    check = if mode == "startup-stop", do: "exit 1", else: check
    rendered = Config.render(%{setup: ["mkdir -p .kogen/local; printf 'setup\\n' >> .kogen/local/setup-trace"], fix: [], checks: [%{name: "fixture-check", run: check}], protect: [], acceptance: %{run: cfg.acceptance_run, steps_dir: cfg.steps_dir}})
    put(c.repo, Config.path(), rendered)
    put(c.repo, "binary file", <<0, 1, 255, 10>>)
    put(c.repo, "deleted.txt", "original deleted file\n")
    put(c.repo, "executable.sh", "#!/bin/sh\nexit 0\n")
    git(c, ["add", Config.path(), "binary file", "deleted.txt", "executable.sh"])
    git(c, ["commit", "-qm", "Configure recovery fixture"])
    put(c.repo, Intent.intent_md("fixture"), md())
    put(c.repo, "features/steps/integration_steps.js", step(false))
    {out, code} = invoke(c, ["intent", "approve", "fixture", contract(c)])
    assert code == 0, out
  end
  def run(mode) do
    suite = Helpers.setup_suite!()
    try do
      c = Helpers.project!(suite, [], staged_intent: false)
      try do
        cond do
          mode == "fixture-lifecycle" -> fixture_lifecycle(c)
          mode == "guidance" -> guidance(c)
          mode in ["polarity", "masked-controls"] -> controls(c, mode)
          true -> recovery(c, mode)
        end
      after
        Helpers.cleanup_case(c)
      end
    after
      Helpers.cleanup_suite(suite)
    end
  end
  def guidance(c) do
    request = Path.join(c.root, "request.md")
    File.write!(request, "Investigate a risky protected acceptance driver.\n")
    invoke(c, ["intent", "shape", "new-unblocking", request])
    shape = List.last(FakeProvider.provider_requests(c.server))
    invoke(c, ["intent", "refine", "fixture", contract(c), request])
    refine = List.last(FakeProvider.provider_requests(c.server))
    has = fn r ->
      t = JSON.encode!(Map.take(r.json, ["instructions", "input"])) |> String.downcase()
      String.contains?(t, "must declare") and String.contains?(t, "observer") and String.contains?(t, "masked") and String.contains?(t, "nonzero")
    end
    %{"Shape guidance" => has.(shape), "Refine guidance" => has.(refine)}
  end
  def controls(c, mode) do
    observer = "features/steps/integration_steps.js"
    ft = Intent.feature("fixture")
    put(c.repo, ft, "Feature: Masked fixture\n  Scenario: Product red masks observer\n    Given the product is absent\n    Then the deep observer is correct\n")
    if mode == "polarity" do
      body = """
      if(require.main===module){const good=process.argv[2]==='good';process.stdout.write(good?'accepted\\n':'rejected\\n');process.exit(good?0:1);}
      else{const {Given,Then}=require('@cucumber/cucumber');Given('the product is absent',()=>{throw Error('unimplemented product')});Then('the deep observer is correct',()=>{});}
      """
      put(c.repo, observer, body)
      card = fn ds -> put(c.repo, Intent.intent_md("fixture"), md(ds)); invoke(c, ["intent", "approve", "fixture"]) end
      zero = declaration(observer,0,0) |> Map.update!("checks", fn [g,_] -> [g,Map.put(g,"name","bad")] end)
      nonzero = declaration(observer,1,1) |> Map.update!("checks", fn [_,b] -> [Map.put(b,"name","good"),b] end)
      {o1,k1} = card.([zero])
      {o2,k2} = card.([nonzero])
      support = %{"id"=>"local-rejection","kind"=>"capability","inputs"=>[],"observers"=>[],"checks"=>[%{"name"=>"support","command"=>"printf 'rejected\\n'; exit 23","exit"=>23,"output"=>"rejected\n"}]}
      {o3,k3} = card.([support, declaration(observer)])
      %{"bad-zero refused"=>k1 == 1 and o1 =~ "observer", "good-nonzero refused"=>k2 == 1 and o2 =~ "observer", "rejected capability supported"=>k3 == 5 and not (o3 =~ "not_ready"), "corrected observer ready"=>k3 == 5}
    else
      # An unchanged approved local fixture is needed to reach the transport.
      cursor = Helpers.project!(c.suite, [], staged_intent: false)
      s = try do
        script(cursor, [{:http,503,%{"error"=>%{"message"=>"local cursor retry","code"=>"server_error"}}}])
        invoke(cursor, ["intent", "build", "fixture"])
        Agent.get(cursor.server.state, & &1)
      after
        Helpers.cleanup_case(cursor)
      end
      assert s.next > length(s.script)
      tail = ["first replay", "second replay"]
      wrong = Enum.at(Enum.take(s.script,s.next) ++ tail, s.next)
      padded = Enum.take(s.script,s.next) ++ List.duplicate(nil,s.next-length(s.script)) ++ tail
      assert Enum.at(padded,s.next) == "first replay"
      long = Path.join(c.root,"long.txt"); File.write!(long,String.duplicate("x",20000))
      full = Tools.run("read_file",%{"path"=>long},%{root: c.repo,tools: ["read_file"]})
      assert full != Tools.cut(full)
      {good_token,_} = Code.eval_string("input = [:authority]; input != []")
      {bad_token,_} = Code.eval_string("input = [:authority]; input!=[]")
      {good_scope,_} = Code.eval_string("input = [:authority]; input = if true do input ++ [:exchange] else input end; input")
      {bad_scope,_} = Code.eval_string("input = [:authority]; if true do input = input ++ [:exchange]; input end; input")
      protocol = Path.join(c.root,"protocol.cjs"); File.write!(protocol,"console.log('fixture')\n")
      {_,right_extension}=System.cmd("node",[protocol],stderr_to_stdout: true)
      {_,wrong_extension}=System.cmd("node",[Path.join(c.root,"protocol.py")],stderr_to_stdout: true)
      # Obtain consumed approval from a genuine landed installed Build.
      other = Helpers.project!(c.suite, [], staged_intent: false)
      absent = try do
        sign(other)
        script(other,[call("finish",%{"summary"=>"complete fixture"}),call("submit_review",%{"verdict"=>"approve","findings"=>[]})])
        {o,k}=invoke(other,["intent","build","fixture"]); assert k == 0, o
        File.exists?(approval(other))
      after
        Helpers.cleanup_case(other)
      end
      cases = [
        {"retry cursor beyond script","first replay",wrong},
        {"full Refine tool output",full,Tools.cut(full)},
        {"landed approval absence",absent,true},
        {"comparison tokenization",good_token,bad_token},
        {"outer input scope",Enum.map(good_scope,&Atom.to_string/1),Enum.map(bad_scope,&Atom.to_string/1)},
        {"generated protocol extension",right_extension,wrong_extension}]
      for {name,good,bad} <- cases, into: %{} do
        # Final protected step bytes accept actual good data and reject actual bad data.
        body = fn flawed ->
          expected = JSON.encode!(if flawed,do: bad,else: good)
          good_json=JSON.encode!(good); bad_json=JSON.encode!(bad)
          """
          const assert=require('node:assert/strict');const expect=#{expected};
          function observe(v){try{assert.deepEqual(v,expect);return true}catch{return false}}
          if(require.main===module){const ok=observe(process.argv[2]==='good'?#{good_json}:#{bad_json});process.stdout.write(ok?'accepted\\n':'rejected\\n');process.exit(ok?0:1)}
          else{const {Given,Then}=require('@cucumber/cucumber');Given('the product is absent',()=>{throw Error('unimplemented product')});Then('the deep observer is correct',()=>assert.equal(observe(#{good_json}),true))}
          """
        end
        ds=[declaration(observer)]
        put(c.repo,Intent.intent_md("fixture"),md(ds)); put(c.repo,observer,body.(true))
        {bad_out,bad_code}=invoke(c,["intent","approve","fixture"])
        put(c.repo,observer,body.(false))
        {good_out,good_code}=invoke(c,["intent","approve","fixture"])
        r=JSON.decode!(File.read!(Path.join(c.repo,".kogen/local/readiness/fixture.json")))
        proof=r["feasibility"] || []
        exact=case proof do
          [p] -> p["observers"] == %{observer=>hash(body.(false))} and Enum.map(p["checks"],&Map.take(&1,~w(name command exit output))) == hd(ds)["checks"] and Enum.all?(p["checks"],&(&1["timed_out"]==false))
          _ -> false
        end
        {name,%{wrongRefused: bad_code==1 and bad_out =~ "fixture-observer",correctedReady: good_code==5 and not(good_out =~ "not_ready"),exactProof: exact,productRed: Enum.any?(r["scenarios"]||[],&(&1["status"]=="failed" and String.contains?(&1["detail"]||"","unimplemented product")))}}
      end
    end
  end
  def recovery(c, mode) do
    configure(c, mode)
    original = custody(c)
    original_hash = contract(c)
    if mode == "login-stop", do: File.rm!(Path.join(c.home,".kogen/credentials/chatgpt.json"))
    stopping = mode in ["startup-stop","login-stop","provider-stop","non-blocker"]
    if mode in ["provider-stop","non-blocker"] do
      script(c,[{:http,400,%{"error"=>%{"message"=>"scripted provider refusal","code"=>"invalid_request_error"}}}])
    else
      script(c,[call("shell",%{"command"=>"printf 'A\\n' > app.txt; printf '\\000\\376new' > 'binary file'; rm deleted.txt; chmod +x executable.sh; printf valuable > 'valuable new.txt'"}),call("finish",%{"summary"=>"production implemented"}),call("report_blocker",%{"paths"=>["features/steps/integration_steps.js"],"reason"=>"step expects baseline although approved outcome is A newline","evidence"=>"finish acceptance fails after app.txt becomes A; protected comparison still expects baseline"})])
    end
    sleeper = if stopping, do: Port.open({:spawn_executable,System.find_executable("sleep")},[:binary,:exit_status,{:args,[~c"120"]}]), else: nil
    try do
      {first, first_code}=invoke(c,["intent","build","fixture"])
      results=Path.wildcard(Path.join(c.repo,".kogen/local/runs/*/result.json"))
      result_path=List.last(results)
      id=if result_path,do: Path.basename(Path.dirname(result_path)),else: "01234567"
      run_dir=Path.join(c.repo,".kogen/local/runs/#{id}")
      cp=Path.join(run_dir,"checkpoint.json")
      archive=Path.join(c.root,"preserved candidate")
      if stopping do
        before=custody(c); n=count(c)
        {out,k}=invoke(c,["intent","recover",id,"--output",archive])
        {:os_pid,pid}=Port.info(sleeper,:os_pid)
        {_,alive}=System.cmd("/bin/kill",["-0",Integer.to_string(pid)],stderr_to_stdout: true)
        reason=case mode do "startup-stop"->"environment/check_failing"; "login-stop"->"provider/login"; _->"provider/" end
        %{"recovery exit"=>k,"no archive published"=>not File.exists?(Path.join(archive,"manifest.json")),"honest stop"=>first_code != 0 and first =~ reason,"unchanged checkout"=>custody(c)==before and before==original,"native recovery refusal"=>k==1 and Regex.match?(~r/candidate\/recovery_(refused|unsupported)/,out),"no recovery inference"=>count(c)==n,"unrelated process alive"=>alive==0,"output"=>out,"first"=>first}
      else
        assert first_code == 1 and first =~ "candidate/build_blocked", first
        stopped=custody(c)
        doc=JSON.decode!(File.read!(cp))
        {:ok,_,b}=Kogen.Run.decode_checkpoint(File.read!(cp))
        history=Map.new(files(run_dir),fn p->{p,File.read!(Path.join(run_dir,p))} end)
        changes=Snapshot.changed(c.repo,b.start_tree,doc["candidate"]) |> Enum.reject(&(&1 in b.baseline)) |> Enum.sort()
        {change_rows,data}=Enum.map_reduce(changes,%{},fn p,acc ->
          {before,bbytes}=tree_entry(c,b.start_tree,p); {aft,abytes}=tree_entry(c,doc["candidate"],p)
          acc=if before,do: Map.put(acc,"before/"<>p,bbytes),else: acc
          acc=if aft,do: Map.put(acc,"candidate/"<>p,abytes),else: acc
          {%{"path"=>p,"before"=>before,"after"=>aft},acc}
        end)
        expected=%{meta: %{"version"=>1,"build"=>id,"slug"=>"fixture","project"=>c.repo,"start_head"=>original.head,"start_tree"=>b.start_tree,"candidate_tree"=>doc["candidate"],"contract_sha256"=>original_hash,"classification"=>"BUILDER-REPORTED"},changes: change_rows,bytes: Map.merge(data,%{"checkpoint.json"=>File.read!(cp),"result.json"=>File.read!(result_path),"approval.json"=>File.read!(approval(c)),"index-at-start"=>original.index})}
        archive=case mode do "inside-output"->Path.join(c.repo,"archive"); _->archive end
        case mode do
          "candidate-drift"->put(c.repo,"unrelated.txt","do not discard\n")
          "index-drift"->git(c,["add","app.txt"])
          "approval-drift"->File.write!(approval(c),File.read!(approval(c))<>"\n")
          "head-drift"->git(c,["commit","--allow-empty","-qm","Move HEAD"])
          "baseline-drift"->File.write!(Path.join(c.repo,"features/steps/integration_steps.js"),step(false)<>"\n// drift\n")
          "missing-checkpoint"->File.rm!(cp)
          "legacy-checkpoint"->File.write!(cp,JSON.encode!(Map.put(doc,"version",2)))
          "existing-output"->File.mkdir!(archive); put(archive,"sentinel","do not overwrite")
          _->:ok
        end
        before=custody(c); n=count(c)
        {out,k}=invoke(c,["intent","recover",id,"--output",archive])
        if mode != "recover" do
          %{"recovery exit"=>k,"native recovery refusal"=>Regex.match?(~r/candidate\/recovery_(refused|unsupported)/,out),"unchanged checkout"=>custody(c)==before,"no recovery inference"=>count(c)==n,"no archive published"=>not File.exists?(Path.join(archive,"manifest.json")) and (mode != "existing-output" or File.read!(Path.join(archive,"sentinel"))=="do not overwrite"),"output"=>out}
        else
          if k != 0 do
            %{"recovery exit"=>k,"output"=>out}
          else
            archive_ok=archive!(archive,expected)
            assert JSON.decode!(File.read!(Path.join(archive,"blocker.json"))) == b.blocker
            context=File.read!(Path.join(archive,"context.md"))
            correction=File.read!(Path.join(archive,"correction.md"))
            assert byte_size(context) in 1..262144
            assert Enum.all?([context,correction],&(String.contains?(&1,archive) and String.contains?(&1,id) and String.contains?(&1,original_hash)))
            assert out =~ hash(File.read!(Path.join(archive,"manifest.json")))
            cleaned=custody(c)
            only=cleaned.head==original.head and cleaned.index==original.index and cleaned.approval==original.approval and cleaned.tree==b.start_tree
            history_ok=Enum.all?(history,fn {p,bytes}->File.read(Path.join(run_dir,p))=={:ok,bytes} end)
            no_inference=count(c)==n
            {repeat,rk}=invoke(c,["intent","recover",id,"--output",archive])
            repeat_ok=rk==1 and repeat =~ "recovery_refused" and custody(c)==cleaned
            Map.merge(journey(c,archive,original_hash,original.head),%{"recovery exit"=>k,"exact private archive"=>archive_ok,"only production cleared"=>only,"original run unchanged"=>history_ok,"no recovery inference"=>no_inference,"repeat refused"=>repeat_ok,"stopped tree"=>stopped.tree})
          end
        end
      end
    after
      if sleeper do
        case Port.info(sleeper,:os_pid) do
          {:os_pid,pid}->System.cmd("/bin/kill",["-TERM",Integer.to_string(pid)],stderr_to_stdout: true)
          _->:ok
        end
        if Port.info(sleeper), do: Port.close(sleeper)
      end
    end
  end
  # Qualify later observers without inventing a recovery implementation: start
  # with a clean production tree and explicitly constructed diagnostic artifacts.
  def fixture_lifecycle(c) do
    configure(c,"recover")
    original_hash=contract(c)
    start_head=git(c,["rev-parse","HEAD"])
    archive=Path.join(c.root,"manual production evidence")
    put(archive,"candidate/app.txt","A\n")
    put(archive,"context.md","Lower-authority diagnostic production archive at #{archive}; no automatic import.\n")
    put(archive,"correction.md","Correct only the protected step to expect A newline as the approved prose requires. app.txt is production-clean baseline; inspect the observer control.\n")
    journey(c,archive,original_hash,start_head)
  end
  def journey(c,archive,original_hash,start_head) do
    context=File.read!(Path.join(archive,"context.md"))
    ds=[declaration("features/steps/integration_steps.js")]
    proposed=[%{"path"=>Intent.intent_md("fixture"),"content"=>md(ds)},%{"path"=>"features/steps/integration_steps.js","content"=>step(true)}]
    feature=File.read!(Path.join(c.repo,Intent.feature("fixture")))
    script(c,[call("submit_refinement",%{"files"=>proposed}),call("submit_refinement",%{"files"=>[%{"path"=>Intent.feature("fixture"),"content"=>feature}]})])
    {refine_out,refine_code}=invoke(c,["intent","refine","fixture",original_hash,Path.join(archive,"correction.md")])
    before_approval=count(c)
    {refusal,not_approved}=invoke(c,["intent","build","fixture"])
    needs=refine_code==0 and not_approved==5 and refusal =~ "intent/not_approved" and count(c)==before_approval and not File.exists?(approval(c))
    new_hash=contract(c)
    {approve_out,approved}=invoke(c,["intent","approve","fixture",new_hash]); assert approved==0, approve_out<>refine_out
    sign(c)
    script(c,[call("read_file",%{"path"=>Path.join(archive,"candidate/app.txt")}),call("write_file",%{"path"=>"app.txt","content"=>"A\n"}),call("finish",%{"summary"=>"fresh implementation"}),call("write_file",%{"path"=>"review.txt","content"=>"independent scoped repair\n"}),call("submit_review",%{"verdict"=>"approve","findings"=>[]})])
    nfresh=count(c)
    clean_start=File.read!(Path.join(c.repo,"app.txt"))=="baseline\n" and not File.exists?(Path.join(c.repo,"valuable new.txt"))
    {landed,landed_code}=invoke(c,["intent","build","fixture","--context",Path.join(archive,"context.md")])
    final_results=Path.wildcard(Path.join(c.repo,".kogen/local/runs/*/result.json")) |> Enum.map(&(JSON.decode!(File.read!(&1))))
    landed_result=Enum.find(final_results,&(&1["outcome"]=="landed")) || %{}
    {signature,signed}=Helpers.git!(c,["verify-commit","HEAD"])
    fresh=Enum.drop(FakeProvider.provider_requests(c.server),nfresh)
    first_input=case fresh do [r|_]->FakeProvider.input_text(r); _->"" end
    %{"refinement exit"=>refine_code,"fresh approval required"=>needs,"fresh build exit"=>landed_code,"one signed commit"=>git(c,["rev-list","--count",start_head<>"..HEAD"])=="1" and signed==0 and signature =~ "Good","independent changed-tree verification"=>is_integer(landed_result["passes"]) and landed_result["passes"]>=2 and landed_result["reviews"]==1 and File.read!(Path.join(c.repo,"review.txt"))=="independent scoped repair\n","landed approval consumed"=>not File.exists?(approval(c)),"handoff used not imported"=>clean_start and String.contains?(first_input,context) and not File.exists?(Path.join(c.repo,"valuable new.txt")),"output"=>refine_out<>landed}
  end
  def sign(c) do
    key=Path.join(c.root,"signing")
    {_,0}=System.cmd("/usr/bin/ssh-keygen",["-q","-t","ed25519","-N","","-f",key])
    allowed=Path.join(c.root,"allowed-signers")
    File.write!(allowed,"kogen-integration@example.invalid "<>File.read!(key<>".pub"))
    for pair <- [["gpg.format","ssh"],["user.signingkey",key],["commit.gpgsign","true"],["gpg.ssh.allowedSignersFile",allowed]],do: git(c,["config"|pair])
  end
end

mode=System.fetch_env!("BUR_MODE")
if String.starts_with?(mode,"control-") do
  System.halt(UnblockingExercise.control(String.replace_prefix(mode,"control-","")))
else
  receipt=UnblockingExercise.run(mode)
  File.write!(System.fetch_env!("BUR_RECEIPT"),JSON.encode!(receipt))
end
