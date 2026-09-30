Code.require_file("../support/verification_cycle_fixture.ex", __DIR__)

defmodule Kogen.ParallelSettlementFanoutTest do
  @moduledoc """
  `Kogen.Build.Fanout` against fake provider processes (small shell scripts;
  no real provider): a finite ceiling, settle-everything, cancellation that
  reaps owned process groups only, and durable per-job settlement.
  """

  use ExUnit.Case, async: true

  alias Kogen.Build.Fanout
  alias Kogen.ProcessCustody

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "kogen-fanout-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  # A job whose child is one supervised shell script (its own process group).
  defp shell_job(id, script, env \\ []) do
    %{
      id: id,
      run: fn ctx ->
        {:ok, facts} =
          ProcessCustody.run(["sh", "-c", script], ctx.dir,
            log_path: Path.join(ctx.dir, "out.log"),
            env: env,
            on_start: ctx.on_start
          )

        %{
          "exit_code" => facts["exit_code"],
          "pid" => facts["pid"],
          "output" => facts["log_bytes"]
        }
      end
    }
  end

  defp wait_until(fun, timeout \\ 15_000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn ->
      cond do
        fun.() -> :ok
        System.monotonic_time(:millisecond) > deadline -> :timeout
        true -> Process.sleep(10) && :retry
      end
    end)
    |> Enum.find(&(&1 != :retry))
  end

  defp alive?(pid) do
    case System.cmd("kill", ["-0", to_string(pid)], stderr_to_stdout: true) do
      {_out, 0} -> true
      _ -> false
    end
  end

  defp running_count(dir) do
    case File.ls(Path.join(dir, "running")) do
      {:ok, names} -> length(names)
      _ -> 0
    end
  end

  defp read_pid(path) do
    case File.read(path) do
      {:ok, text} -> text |> String.trim() |> Integer.parse() |> then(fn {n, _} -> n end)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  describe "ceiling" do
    # Each job records how many peers are running when it starts, then holds
    # until the test releases it.
    defp gated(id, dir) do
      shell_job(
        id,
        """
        mkdir -p "$D/running"; : > "$D/running/#{id}"
        ls "$D/running" | wc -l | tr -d ' ' > "$D/snap-#{id}"
        while [ ! -e "$D/release" ]; do sleep 0.02; done
        rm -f "$D/running/#{id}"
        """,
        [{"D", dir}]
      )
    end

    defp snapshots(dir) do
      dir
      |> Path.join("snap-*")
      |> Path.wildcard()
      |> Enum.map(&(&1 |> File.read!() |> String.trim() |> String.to_integer()))
    end

    test "never exceeds the ceiling and does exceed one when the ceiling is two", %{dir: dir} do
      jobs = for n <- 1..5, do: gated("job-#{n}", dir)

      {:ok, handle} =
        Fanout.start(jobs, max_concurrency: 2, settle_root: Path.join(dir, "settle"))

      assert :ok = wait_until(fn -> running_count(dir) == 2 end)
      # Both slots are held while the rest queue: nothing else can start.
      assert running_count(dir) == 2
      File.write!(Path.join(dir, "release"), "go")

      summary = Fanout.await(handle)

      assert Enum.all?(summary.results, &(&1["status"] == "settled"))
      assert length(summary.results) == 5
      assert Enum.max(snapshots(dir)) == 2
      assert length(snapshots(dir)) == 5
      assert summary.max_observed == 2
    end

    test "a ceiling of one runs strictly one at a time", %{dir: dir} do
      File.write!(Path.join(dir, "release"), "go")
      jobs = for n <- 1..3, do: gated("job-#{n}", dir)
      summary = Fanout.run(jobs, max_concurrency: 1, settle_root: Path.join(dir, "settle"))

      assert Enum.all?(summary.results, &(&1["status"] == "settled"))
      assert snapshots(dir) == [1, 1, 1]
      assert summary.max_observed == 1
    end

    test "a non-positive ceiling is refused" do
      assert_raise ArgumentError, fn -> Fanout.start([], max_concurrency: 0) end
    end
  end

  test "one failing job never cancels another: every job settles", %{dir: dir} do
    jobs = [
      shell_job("bad-1", "echo one; exit 3"),
      shell_job("good", "echo fine"),
      shell_job("bad-2", "exit 4")
    ]

    summary = Fanout.run(jobs, max_concurrency: 2, settle_root: Path.join(dir, "settle"))

    assert Enum.map(summary.results, & &1["status"]) == ["settled", "settled", "settled"]
    assert Enum.map(summary.results, & &1["result"]["exit_code"]) == [3, 0, 4]
    assert summary.cancelled == nil
  end

  test "a raised job is recorded as crashed and the others still settle", %{dir: dir} do
    jobs = [
      %{id: "boom", run: fn _ctx -> raise "kaput" end},
      %{id: "fine", run: fn _ctx -> %{"ok" => true} end}
    ]

    summary = Fanout.run(jobs, max_concurrency: 1, settle_root: Path.join(dir, "settle"))
    assert Enum.map(summary.results, & &1["status"]) == ["crashed", "settled"]
  end

  describe "cancellation" do
    test "reaps the running group, queues nothing else, leaves unrelated processes alone", %{
      dir: dir
    } do
      # An unrelated process spawned outside the fan-out.
      port =
        Port.open({:spawn_executable, System.find_executable("sleep")}, [
          :binary,
          :exit_status,
          args: ["120"]
        ])

      {:os_pid, unrelated} = Port.info(port, :os_pid)

      on_exit(fn ->
        System.cmd("kill", ["-KILL", to_string(unrelated)], stderr_to_stdout: true)
      end)

      running =
        shell_job(
          "running",
          """
          sleep 120 & echo $! > "$D/grandchild"
          echo $$ > "$D/leader"
          wait
          """,
          [{"D", dir}]
        )

      queued =
        for n <- 1..2,
            do: shell_job("queued-#{n}", ~s(echo never > "$D/queued-ran"), [{"D", dir}])

      {:ok, handle} =
        Fanout.start([running | queued],
          max_concurrency: 1,
          settle_root: Path.join(dir, "settle")
        )

      assert :ok =
               wait_until(fn ->
                 read_pid(Path.join(dir, "leader")) && read_pid(Path.join(dir, "grandchild"))
               end)

      leader = read_pid(Path.join(dir, "leader"))
      grandchild = read_pid(Path.join(dir, "grandchild"))
      assert alive?(leader) and alive?(grandchild)

      :ok = Fanout.cancel(handle, "operator stop")
      summary = Fanout.await(handle)

      by_id = Map.new(summary.results, &{&1["id"], &1})
      assert by_id["running"]["status"] == "cancelled"
      assert by_id["queued-1"]["status"] == "not_started"
      assert by_id["queued-2"]["status"] == "not_started"
      # Neither pass nor fail.
      assert Enum.all?(summary.results, &(&1["status"] not in ["settled", "failed", "passed"]))
      assert summary.cancelled == "operator stop"

      assert :ok = wait_until(fn -> not alive?(leader) and not alive?(grandchild) end)
      refute File.exists?(Path.join(dir, "queued-ran"))
      assert alive?(unrelated)
      assert Port.info(port) != nil
    end

    test "a job active at cancellation is cancelled even when it returns ok afterwards", %{
      dir: dir
    } do
      # No process group to reap, and the job outlives the stop by returning a
      # result: it must still be cancelled work, never settled.
      stubborn = %{
        id: "stubborn",
        run: fn ctx ->
          File.write!(Path.join(ctx.dir, "started"), "1")

          wait = fn wait ->
            if ctx.cancelled?.(), do: :ok, else: Process.sleep(5) && wait.(wait)
          end

          wait.(wait)
          %{"finished" => true}
        end
      }

      {:ok, handle} = Fanout.start([stubborn], settle_root: Path.join(dir, "settle"))

      assert :ok =
               wait_until(fn ->
                 File.exists?(Path.join([dir, "settle", "stubborn", "started"]))
               end)

      :ok = Fanout.cancel(handle, "operator stop")
      summary = Fanout.await(handle)

      assert [%{"id" => "stubborn", "status" => "cancelled", "reason" => "operator stop"} = entry] =
               summary.results

      assert entry["result"] == %{"finished" => true}
      assert summary.cancelled == "operator stop"
    end

    test "a stop predicate on a settled job cancels the rest (a classified stop)", %{dir: dir} do
      slow = shell_job("slow", ~s(echo $$ > "$D/slow-pid"; sleep 120), [{"D", dir}])

      stopper =
        shell_job("stopper", ~s(while [ ! -e "$D/slow-pid" ]; do sleep 0.02; done; exit 9), [
          {"D", dir}
        ])

      after_stop = shell_job("after", "echo late")

      summary =
        Fanout.run([slow, stopper, after_stop],
          max_concurrency: 2,
          settle_root: Path.join(dir, "settle"),
          stop_when: fn entry -> entry["id"] == "stopper" && "classified provider stop" end
        )

      by_id = Map.new(summary.results, &{&1["id"], &1})
      assert by_id["stopper"]["status"] == "settled"
      assert by_id["slow"]["status"] == "cancelled"
      assert by_id["after"]["status"] == "not_started"
      assert summary.cancelled == "classified provider stop"
      refute alive?(read_pid(Path.join(dir, "slow-pid")))
    end

    test "reap_identity refuses this controller and its ancestors" do
      me = ProcessCustody.self_identity()

      assert {:error, _} =
               ProcessCustody.reap_identity(%{
                 "pid" => me["pid"],
                 "pgid" => me["pid"],
                 "started_at" => me["started_at"]
               })

      assert {:error, _} = ProcessCustody.reap_identity(%{"pid" => 0, "pgid" => 0})
    end

    test "a pid whose start time changed is left alone", %{dir: dir} do
      job = shell_job("holder", ~s(echo $$ > "$D/pid"; sleep 120), [{"D", dir}])

      {:ok, handle} =
        Fanout.start([job], max_concurrency: 1, settle_root: Path.join(dir, "settle"))

      assert :ok = wait_until(fn -> read_pid(Path.join(dir, "pid")) end)
      pid = read_pid(Path.join(dir, "pid"))

      # A recorded identity with a different start time is a reused pid.
      assert {:ok, []} =
               ProcessCustody.reap_identity(%{
                 "pid" => pid,
                 "pgid" => pid,
                 "started_at" => "Mon Jan  1 00:00:00 2001"
               })

      assert alive?(pid)
      Fanout.cancel(handle, "cleanup")
      Fanout.await(handle)
      assert :ok = wait_until(fn -> not alive?(pid) end)
    end
  end

  describe "durable settlement" do
    test "every settled job leaves its own file with a matching digest", %{dir: dir} do
      root = Path.join(dir, "settle")

      jobs = [
        shell_job("one", "echo 1"),
        %{id: "two", run: fn _ctx -> %{"value" => 2, term: {:in_memory, self()}} end}
      ]

      summary = Fanout.run(jobs, max_concurrency: 2, settle_root: root)

      for entry <- summary.results do
        %{"path" => path, "sha256" => sha} = entry["settlement"]
        assert path == Path.join([root, entry["id"], "settlement.json"]) |> Path.expand()
        bytes = File.read!(path)
        assert sha == Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

        assert File.read!(Path.join([root, entry["id"], "settlement.sha256"])) |> String.trim() ==
                 sha

        assert Fanout.verify_settlement(entry) == :ok
      end

      # The in-memory term is returned, never persisted.
      two = Enum.find(summary.results, &(&1["id"] == "two"))
      assert {:in_memory, _} = two["result"][:term]
      refute File.read!(two["settlement"]["path"]) =~ "in_memory"

      assert [%{"id" => "one", "verified" => true}, %{"id" => "two", "verified" => true}] =
               Fanout.read_settled(root) |> Enum.map(&Map.take(&1, ["id", "verified"]))
    end

    test "tampering with a settlement file is detected", %{dir: dir} do
      root = Path.join(dir, "settle")
      summary = Fanout.run([shell_job("one", "echo 1")], settle_root: root)
      [entry] = summary.results
      path = entry["settlement"]["path"]

      File.write!(path, File.read!(path) <> " ")
      assert {:error, _} = Fanout.verify_settlement(entry)

      assert [%{"id" => "one", "verified" => false}] =
               Fanout.read_settled(root) |> Enum.map(&Map.take(&1, ["id", "verified"]))
    end

    test "a restart sees which jobs settled and which did not start", %{dir: dir} do
      root = Path.join(dir, "settle")
      hold = shell_job("hold", ~s(echo $$ > "$D/pid"; sleep 120), [{"D", dir}])
      later = shell_job("later", "echo later")
      {:ok, handle} = Fanout.start([hold, later], max_concurrency: 1, settle_root: root)
      assert :ok = wait_until(fn -> read_pid(Path.join(dir, "pid")) end)
      # Nothing has settled while the first job runs.
      assert Fanout.read_settled(root) == []
      Fanout.cancel(handle, "stop")
      Fanout.await(handle)

      assert [
               %{"id" => "hold", "status" => "cancelled"},
               %{"id" => "later", "status" => "not_started"}
             ] =
               Fanout.read_settled(root) |> Enum.map(&Map.take(&1, ["id", "status"]))
    end
  end
end

defmodule Kogen.ParallelSettlementClassificationTest do
  @moduledoc "Dispatch ledger and typed-evidence classification."

  use ExUnit.Case, async: true

  alias Kogen.Build.DispatchLedger
  alias Kogen.Harness.ProviderMarker

  defp dispatched(target \\ "live", cycle \\ 1),
    do: [%{"cycle" => cycle, "target" => target, "attempt" => "initial"}]

  defp evidence(overrides) do
    Map.merge(
      %{
        "kind" => "target",
        "provider_backed" => true,
        "marker" => nil,
        "exit_code" => 1,
        "timed_out" => false,
        "cleanup" => "clean",
        "target" => "live",
        "cycle" => 1
      },
      Map.new(overrides)
    )
  end

  test "an ordinary dispatched failure with no marker is paid, never provider" do
    assert %{"class" => "paid", "pending_evidence" => false} =
             DispatchLedger.classify(dispatched(), evidence(%{}))

    for code <- [1, 2, 124, 137] do
      assert %{"class" => "paid"} =
               DispatchLedger.classify(dispatched(), evidence(%{"exit_code" => code}))
    end
  end

  test "only an explicit provider marker is provider" do
    marker = %{"class" => "provider", "kind" => "overload", "retry" => true}

    assert %{"class" => "provider", "pending_evidence" => false} =
             DispatchLedger.classify(dispatched(), evidence(%{"marker" => marker}))
  end

  test "a login rejection is environment without pending evidence" do
    marker = %{"class" => "environment", "kind" => "login_rejected", "harness" => "codex"}

    assert %{"class" => "environment", "pending_evidence" => false} =
             DispatchLedger.classify(dispatched(), evidence(%{"marker" => marker}))
  end

  test "a Kogen credential-scope refusal is environment, never paid or a retry" do
    text = "** (RuntimeError) unexpected discovery settings in Kogen credential store: /x/plugins"
    assert ProviderMarker.scope_refusal?(text)
    refute ProviderMarker.scope_refusal?("assertion failed")
    refute ProviderMarker.scope_refusal?(nil)

    assert %{"class" => "environment", "pending_evidence" => false} =
             DispatchLedger.classify(
               dispatched(),
               evidence(%{"credential_scope_refusal" => true})
             )
  end

  test "custody, supervisor, missing-exit and unmarked-timeout failures are environment pending" do
    for overrides <- [
          %{"kind" => "runner"},
          %{"cleanup" => "failed"},
          %{"exit_code" => nil},
          %{"timed_out" => true}
        ] do
      assert %{"class" => "environment", "pending_evidence" => true} =
               DispatchLedger.classify(dispatched(), evidence(overrides))
    end
  end

  test "a failure with no recorded dispatch is offline" do
    assert %{"class" => "offline", "pending_evidence" => false} =
             DispatchLedger.classify([], evidence(%{}))

    # A dispatch of another target or cycle does not count.
    assert %{"class" => "offline"} =
             DispatchLedger.classify(dispatched("other"), evidence(%{}))

    assert %{"class" => "offline"} =
             DispatchLedger.classify(dispatched("live", 2), evidence(%{}))

    assert %{"class" => "offline"} =
             DispatchLedger.classify(dispatched(), evidence(%{"provider_backed" => false}))
  end

  test "each dispatch is recorded once and validated against its cycles" do
    cycles = [%{"sequence" => 1, "candidate_id" => "tree-1"}]

    entry = fn attempt ->
      DispatchLedger.begin(
        %{target: "live", candidate_id: "tree-1", cycle: 1, attempt: attempt},
        %{"pid" => 10, "pgid" => 10, "started_at" => "Mon Jan  1 00:00:00 2001"}
      )
      |> DispatchLedger.finish(
        {:ok, %{"exit_code" => 0, "finished_at" => "2026-01-01T00:00:00Z"}}
      )
    end

    ledger = DispatchLedger.append([], [entry.("initial"), entry.("initial")])
    assert DispatchLedger.count(ledger) == 1
    assert DispatchLedger.validate(ledger, cycles) == :ok

    ledger = DispatchLedger.append(ledger, [entry.("provider-retry")])
    assert DispatchLedger.count(ledger) == 2
    assert DispatchLedger.validate(ledger, cycles) == :ok

    forged = List.update_at(ledger, 0, &Map.put(&1, "candidate_id", "tree-2"))
    assert {:error, _} = DispatchLedger.validate(forged, cycles)

    assert {:error, _} = DispatchLedger.validate(tl(ledger), cycles)
  end
end

defmodule Kogen.ParallelSettlementVerificationTest do
  @moduledoc """
  `Kogen.Build.Verification.run_cycle/4` fanning provider-backed targets out
  through `Kogen.Build.Fanout` against a git fixture whose targets are fake
  provider processes (Make recipes that print markers and exit).
  """

  use Kogen.IsolatedCase, async: true

  alias Kogen.Build.{FailureHandoff, Fanout, Verification}
  alias Kogen.VerificationCycleFixture, as: Fixture

  @retries 2
  @overload ~s({"type":"result","is_error":true,"api_error_status":429})

  setup do
    root = Fixture.new!()
    # Scratch files live outside the Candidate so they never change its tree.
    scratch = root <> "-scratch"
    File.mkdir_p!(scratch)

    on_exit(fn ->
      File.rm_rf(root)
      File.rm_rf(scratch)
    end)

    {:ok, root: root, scratch: scratch}
  end

  # A fixture whose catalog is an offline `check` plus the given paid targets,
  # each recipe a shell fragment.
  defp install!(root, recipes, check_recipe \\ "@true") do
    names = ["check" | Enum.map(recipes, &elem(&1, 0))]

    entries =
      [Fixture.offline_entry("check")] ++
        (recipes
         |> Enum.with_index()
         |> Enum.map(fn {{name, _}, index} -> Fixture.provider_entry(name, 100 + index * 100) end))

    Fixture.write_catalog!(root, entries)

    makefile =
      ".PHONY: #{Enum.join(names, " ")}\n\ncheck:\n\t#{check_recipe}\n" <>
        Enum.map_join(recipes, fn {name, recipe} -> "\n#{name}:\n\t#{recipe}\n" end)

    File.write!(Path.join(root, "Makefile"), makefile)
    plan = Fixture.plan(root, names)
    {plan, Fixture.env(root, plan)}
  end

  defp start!(root, plan, token \\ "token-1", roots \\ nil) do
    {:ok, execution} =
      Verification.initialize(
        Fixture.tracking_path(root),
        token,
        0,
        plan.targets,
        %{verification: @retries, offline: 1},
        plan,
        roots
      )

    execution
  end

  defp cycle!(root, execution, env) do
    candidate = Fixture.candidate_id!(root)
    {:ok, execution, state} = Fixture.run_cycle(execution, "session-1", candidate, env)
    {execution, state, List.last(state["cycles"])}
  end

  defp handoff(root, execution, state, cycle, extra \\ %{}) do
    FailureHandoff.render(
      Map.merge(
        %{
          cycle: cycle,
          state: state,
          context: execution.context,
          control: root,
          candidate_root: root,
          receipt_path: &Verification.receipt_path(execution, &1, &2)
        },
        extra
      )
    )
  end

  test "two failing paid targets and one passing target all settle, and one handoff names both",
       %{root: root} do
    {plan, env} =
      install!(root, [
        {"p1", "@echo 'assert boom-p1'; exit 1"},
        {"p2", "@echo 'assert boom-p2'; exit 1"},
        {"p3", "@echo fine-p3"}
      ])

    execution = start!(root, plan)
    {execution, state, cycle} = cycle!(root, execution, Map.put(env, :max_concurrency, 2))

    assert Enum.map(cycle["receipts"], &{&1["target"], &1["status"]}) ==
             [{"check", "passed"}, {"p1", "failed"}, {"p2", "failed"}, {"p3", "passed"}]

    assert Enum.map(cycle["failures"], &{&1["target"], &1["class"]}) ==
             [{"p1", "paid"}, {"p2", "paid"}]

    assert cycle["failure"]["target"] == "p1"
    assert cycle["class"] == "paid"
    assert cycle["dispatch_count"] == 3
    assert state["dispatch_count"] == 3
    assert Enum.map(state["dispatch_ledger"], & &1["target"]) |> Enum.sort() == ["p1", "p2", "p3"]
    assert Enum.all?(state["dispatch_ledger"], &(&1["attempt"] == "initial"))

    # Every job settled durably, in its own directory.
    settled = cycle["fanout"]["settlements"]
    assert Enum.sort(Enum.map(settled, & &1["id"])) == ["target-p1", "target-p2", "target-p3"]
    assert Enum.all?(settled, &(&1["status"] == "settled"))
    assert Verification.validate_state(state, execution) == :ok
    # The persisted state is plain JSON: string keys and values at every level.
    assert Jason.decode!(Jason.encode!(state)) == state

    prompt = handoff(root, execution, state, cycle)
    assert prompt =~ "All failures of this cycle (2)"
    assert prompt =~ "boom-p1"
    assert prompt =~ "boom-p2"
    assert prompt =~ "### `p1`"
    assert prompt =~ "### `p2`"
    refute prompt =~ "fine-p3"
    assert byte_size(prompt) <= 24_000
  end

  test "each paid target gets its own evidence root", %{root: root} do
    recipe =
      ~S(@mkdir -p "$$KOGEN_LIVE_LOG_DIR" && echo "$$KOGEN_LIVE_LOG_DIR" > "$$KOGEN_LIVE_LOG_DIR/root.txt")

    {plan, env} = install!(root, [{"p1", recipe}, {"p2", recipe}])
    execution = start!(root, plan)
    {_execution, _state, _cycle} = cycle!(root, execution, env)

    base = Path.join(root, ".kogen/runtime/live-evidence/cycle-1")

    assert File.read!(Path.join([base, "p1", "root.txt"])) |> String.trim() ==
             Path.join(base, "p1")

    assert File.read!(Path.join([base, "p2", "root.txt"])) |> String.trim() ==
             Path.join(base, "p2")
  end

  test "observed concurrency never exceeds the ceiling and exceeds one at ceiling two", %{
    root: root,
    scratch: scratch
  } do
    dir = Path.join(scratch, "conc")
    File.mkdir_p!(dir)

    recipe = fn name ->
      ~s(@mkdir -p #{dir}/running; : > #{dir}/running/#{name}; ) <>
        ~s(ls #{dir}/running | wc -l | tr -d " " > #{dir}/snap-#{name}; ) <>
        ~s(while [ ! -e #{dir}/release ]; do sleep 0.02; done; rm -f #{dir}/running/#{name})
    end

    recipes = for n <- ~w(p1 p2 p3), do: {n, recipe.(n)}
    {plan, env} = install!(root, recipes)
    execution = start!(root, plan)
    parent = self()

    releaser =
      Task.async(fn ->
        wait = fn wait ->
          if File.exists?(Path.join(dir, "running")) and
               length(File.ls!(Path.join(dir, "running"))) >= 2,
             do: :ok,
             else: Process.sleep(10) && wait.(wait)
        end

        wait.(wait)
        # Two are running and the third is queued behind the ceiling.
        send(parent, {:running, length(File.ls!(Path.join(dir, "running")))})
        File.write!(Path.join(dir, "release"), "go")
      end)

    {_execution, _state, cycle} = cycle!(root, execution, Map.put(env, :max_concurrency, 2))
    Task.await(releaser, 30_000)

    assert_received {:running, 2}

    snaps =
      for f <- Path.wildcard(Path.join(dir, "snap-*")),
          do: f |> File.read!() |> String.trim() |> String.to_integer()

    assert length(snaps) == 3
    assert Enum.max(snaps) == 2
    assert cycle["fanout"]["max_concurrency"] == 2
    assert cycle["fanout"]["max_observed"] == 2
    assert cycle["status"] == "passed", inspect(cycle["failures"])
    assert cycle["dispatch_count"] == 3
  end

  test "with no configured cap all four jobs start concurrently", %{root: root, scratch: scratch} do
    dir = Path.join(scratch, "all-at-once")
    File.mkdir_p!(dir)

    # Each job waits (bounded) until all four are running, so a cap below
    # four fails the target instead of passing.
    recipe = fn name ->
      ~s{@mkdir -p #{dir}/running; : > #{dir}/running/#{name}; i=0; } <>
        ~s{while [ $$(ls #{dir}/running | wc -l) -lt 4 ]; do i=$$((i+1)); } <>
        ~s{[ $$i -gt 500 ] && exit 1; sleep 0.02; done}
    end

    {plan, env} = install!(root, for(n <- ~w(p1 p2 p3 p4), do: {n, recipe.(n)}))
    refute Map.has_key?(env, :max_concurrency)
    execution = start!(root, plan)
    {_execution, _state, cycle} = cycle!(root, execution, env)

    assert cycle["status"] == "passed", inspect(cycle["failures"])
    assert cycle["fanout"]["max_concurrency"] == 4
    assert cycle["fanout"]["max_observed"] == 4
  end

  test "an offline failure dispatches nothing and companions are not started", %{
    root: root,
    scratch: scratch
  } do
    marker = Path.join(scratch, "companion-ran")
    dispatched = Path.join(scratch, "dispatched")

    {plan, env} =
      install!(root, [{"p1", "@touch #{dispatched}"}], "@echo offline-broke; exit 1")

    companion = %{
      id: "review",
      run: fn _ctx ->
        File.write!(marker, "ran")
        %{"ok" => true}
      end
    }

    execution = start!(root, plan)
    {execution, state, cycle} = cycle!(root, execution, Map.put(env, :companions, [companion]))

    assert cycle["failure"]["class"] == "offline"
    assert cycle["class"] == "offline"
    assert Enum.map(cycle["receipts"], & &1["target"]) == ["check"]
    assert cycle["dispatch_count"] == 0
    assert state["dispatch_count"] == 0
    assert state["dispatch_ledger"] == []
    refute Map.has_key?(cycle, "fanout")
    refute File.exists?(dispatched)
    refute File.exists?(marker)
    assert [%{"id" => "review", "status" => "not_started"}] = cycle["companions"]
    assert Jason.decode!(Jason.encode!(state)) == state
    assert %{"review" => %{"status" => "not_started"}} = execution.companions

    # A companion given as a function is not even called.
    Fixture.reset_calls!(root)
    test_pid = self()
    fun = fn _partial -> send(test_pid, :called) && [] end

    {_execution2, _state2, cycle2} =
      cycle!(root, start!(root, plan, "token-2"), Map.put(env, :companions, fun))

    assert [%{"id" => "companions", "status" => "not_started"}] = cycle2["companions"]
    refute_received :called
  end

  test "ordinary exit 1 is paid, an explicit marker is provider", %{root: root} do
    {plan, env} =
      install!(root, [
        {"plain", "@echo compile error; touch plain-done; exit 1"},
        # The provider stop cancels work still running, so `limited` fails
        # only after `plain` has failed and left its marker.
        {"limited",
         "@while [ ! -f plain-done ]; do sleep 0.05; done; sleep 0.3; echo '#{@overload}'; exit 1"}
      ])

    execution = start!(root, plan)
    {execution, state, cycle} = cycle!(root, execution, env)

    classes = Map.new(cycle["failures"], &{&1["target"], &1["class"]})
    assert classes == %{"plain" => "paid", "limited" => "provider"}
    # An environment or provider stop outranks a plain paid failure.
    assert cycle["failure"]["target"] == "limited"
    assert cycle["class"] == "provider"
    assert state["terminal_state"] == "provider"
    assert Verification.validate_state(state, execution) == :ok
  end

  test "a companion's result is returned while a target fails and is never cancelled by it",
       %{root: root, scratch: scratch} do
    failed = Path.join(scratch, "target-failed")
    {plan, env} = install!(root, [{"p1", "@touch #{failed}; echo bad; exit 1"}])

    companion = %{
      id: "review",
      run: fn ctx ->
        wait = fn wait ->
          if File.exists?(failed), do: :ok, else: Process.sleep(10) && wait.(wait)
        end

        wait.(wait)
        # The target has failed; the fan-out must still leave us running.
        Process.sleep(200)

        %{
          "verdict" => "approve",
          "cancelled_seen" => ctx.cancelled?.(),
          term: {:provisional_review, [1, 2, 3]}
        }
      end
    }

    execution = start!(root, plan)
    {execution, state, cycle} = cycle!(root, execution, Map.put(env, :companions, [companion]))

    assert cycle["failure"]["target"] == "p1"
    assert [%{"id" => "review", "status" => "settled"} = summary] = cycle["companions"]
    assert is_binary(summary["settlement_sha256"])

    entry = execution.companions["review"]
    assert entry["status"] == "settled"
    assert entry["result"]["cancelled_seen"] == false
    assert entry["result"]["verdict"] == "approve"
    assert entry["result"][:term] == {:provisional_review, [1, 2, 3]}
    refute File.read!(entry["settlement"]["path"]) =~ "provisional_review"

    # The companion never changes the target's pass/fail class.
    assert Jason.decode!(Jason.encode!(state)) == state
    assert cycle["class"] == "paid"
    assert Verification.validate_state(state, execution) == :ok
  end

  test "a companion given as a function sees the offline receipts and may fail without stopping targets",
       %{root: root} do
    {plan, env} = install!(root, [{"p1", "@echo ok"}])
    test = self()

    fun = fn partial ->
      send(
        test,
        {:partial, Enum.map(partial["receipts"], & &1["target"]), partial["candidate_id"]}
      )

      raise "reviewer could not start"
    end

    execution = start!(root, plan)
    {execution, _state, cycle} = cycle!(root, execution, Map.put(env, :companions, fun))

    assert_received {:partial, ["check"], candidate}
    assert is_binary(candidate)
    assert cycle["status"] == "passed"

    assert [%{"id" => "companions", "status" => "error", "reason" => reason}] =
             cycle["companions"]

    assert reason =~ "reviewer could not start"
    assert execution.companions["companions"]["status"] == "error"
  end

  test "the frozen dispatch ceiling is reserved before fan-out: too few left starts nothing",
       %{root: root, scratch: scratch} do
    {plan, env} =
      install!(root, [
        {"p1", "@touch #{scratch}/p1"},
        {"p2", "@touch #{scratch}/p2"},
        {"p3", "@touch #{scratch}/p3"}
      ])

    execution = start!(root, plan)
    {execution, state, cycle} = cycle!(root, execution, Map.put(env, :dispatches_left, 1))

    assert cycle["status"] == "failed"
    assert cycle["failure"]["kind"] == "budget"
    assert cycle["failure"]["budget"] == "dispatches"
    assert cycle["failure"]["class"] == "environment"
    assert cycle["dispatch_count"] == 0
    assert state["dispatch_ledger"] == []
    assert Enum.all?(~w(p1 p2 p3), &(not File.exists?(Path.join(scratch, &1))))
    assert Verification.validate_state(state, execution) == :ok
  end

  test "a Reviewer that fails is recorded in the dispatch ledger from its launch",
       %{root: root} do
    {plan, env} = install!(root, [{"p1", "@echo ok"}])

    companion = %{
      id: "provisional-review",
      run: fn _ctx -> %{"status" => "error", "reason" => "boom", term: nil} end
    }

    execution = start!(root, plan)
    {execution, state, cycle} = cycle!(root, execution, Map.put(env, :companions, [companion]))

    assert [%{"status" => "settled"}] = cycle["companions"]

    assert %{"role" => "reviewer", "outcome" => "transport_error", "process" => process} =
             Enum.find(state["dispatch_ledger"], &(&1["target"] == "provisional-review"))

    assert is_binary(process)
    assert Verification.validate_state(state, execution) == :ok
  end

  test "an operator cancel reaps the running target and the cycle is neither passed nor failed by it",
       %{root: root, scratch: scratch} do
    pidfile = Path.join(scratch, "p1.pid")

    # Longest first: the higher-ranked p1 takes the only slot, p2 queues.
    {plan, env} =
      install!(root, [{"p2", "@echo late"}, {"p1", "@echo $$ > #{pidfile}; sleep 60"}])

    execution = start!(root, plan)
    parent = self()

    env =
      env
      |> Map.put(:max_concurrency, 1)
      |> Map.put(:on_fanout, fn handle ->
        spawn(fn ->
          wait = fn wait ->
            if File.exists?(pidfile), do: :ok, else: Process.sleep(10) && wait.(wait)
          end

          wait.(wait)
          Fanout.cancel(handle, "operator stop")
          send(parent, :cancelled)
        end)
      end)

    {_execution, state, cycle} = cycle!(root, execution, env)
    assert_received :cancelled

    assert Enum.map(cycle["cancelled"], &{&1["target"], &1["status"]}) ==
             [{"p2", "not_started"}, {"p1", "cancelled"}]

    assert Enum.map(cycle["receipts"], & &1["target"]) == ["check"]
    assert Jason.decode!(Jason.encode!(state)) == state
    assert cycle["failure"]["kind"] == "cancelled"
    assert cycle["class"] == "environment"
    assert state["terminal_state"] == "environment"
    # The cancelled target was dispatched (its spend counts once); the queued one was not.
    assert Enum.map(state["dispatch_ledger"], &{&1["target"], &1["outcome"]}) == [
             {"p1", "cancelled"}
           ]
  end

  test "the durable settlements, the ledger and the failure lists are tamper-evident", %{
    root: root
  } do
    {plan, env} = install!(root, [{"p1", "@echo bad; exit 1"}, {"p2", "@echo ok"}])
    execution = start!(root, plan)
    {execution, state, cycle} = cycle!(root, execution, env)
    assert Verification.validate_state(state, execution) == :ok

    [settlement | _] = cycle["fanout"]["settlements"]
    path = Path.expand(settlement["path"], root)
    original = File.read!(path)
    File.write!(path, original <> " ")
    assert {:error, _} = Verification.validate_state(state, execution)
    File.write!(path, original)
    assert Verification.validate_state(state, execution) == :ok

    forged_ledger =
      put_in(state, ["dispatch_ledger", Access.at(0), "target"], "p9")

    assert {:error, _} = Verification.validate_state(forged_ledger, execution)

    dropped =
      state
      |> update_in(["dispatch_ledger"], &tl/1)
      |> update_in(["dispatch_count"], &(&1 - 1))

    assert {:error, _} = Verification.validate_state(dropped, execution)

    forged_class =
      update_in(state, ["cycles", Access.at(0), "failures", Access.at(0), "class"], fn _ ->
        "wat"
      end)

    assert {:error, _} = Verification.validate_state(forged_class, execution)
  end

  describe "resume across attempts (prior receipts)" do
    setup %{root: root} do
      # `b-fail-marker` is gitignored, so toggling it never changes the tree.
      {plan, env} = install!(root, [{"a", "@echo a-ok"}, {"b", "@test ! -f b-fail-marker"}])
      File.write!(Path.join(root, "b-fail-marker"), "x")
      roots = %{control_root: root, candidate_root: root, frozen: %{"route" => "r1"}}
      execution = start!(root, plan, "token-1", roots)
      {execution, _state, cycle} = cycle!(root, execution, env)
      assert Enum.map(cycle["receipts"], & &1["status"]) == ["passed", "passed", "failed"]
      File.rm!(Path.join(root, "b-fail-marker"))

      digest =
        Base.encode16(:crypto.hash(:sha256, File.read!(execution.state_path)), case: :lower)

      {:ok, prior} = Verification.reusable_prior(execution.state_path, digest)

      {:ok,
       plan: plan,
       env: env,
       roots: roots,
       prior: prior,
       prior_execution: execution,
       digest: digest}
    end

    defp calls_of(cycle),
      do: cycle["receipts"] |> Enum.reject(& &1["reused_from"]) |> Enum.map(& &1["target"])

    test "only passed receipts are offered, bound to their origin", %{prior: prior} do
      assert prior |> Enum.map(& &1["receipt"]["target"]) |> Enum.sort() == ["a", "check"]
      assert Enum.all?(prior, &(&1["receipt"]["status"] == "passed"))
      assert Enum.all?(prior, &is_binary(&1["origin"]["frozen_context_sha256"]))
    end

    test "an exact binding is reused and only the failed target reruns",
         %{root: root, plan: plan, env: env, roots: roots, prior: prior} do
      execution = start!(root, plan, "token-2", roots)
      {execution, state, cycle} = cycle!(root, execution, Map.put(env, :prior_receipts, prior))

      assert cycle["status"] == "passed"
      assert calls_of(cycle) == ["b"]
      reused = Enum.filter(cycle["receipts"], & &1["reused_from"])
      assert Enum.sort(Enum.map(reused, & &1["target"])) == ["a", "check"]
      assert Enum.all?(reused, &(&1["reused_from"]["prior"] == true))
      assert cycle["dispatch_count"] == 1
      assert Verification.validate_state(state, execution) == :ok
    end

    test "a changed tree reruns everything",
         %{root: root, plan: plan, env: env, roots: roots, prior: prior} do
      Fixture.edit_tracked_file!(root)
      execution = start!(root, plan, "token-2", roots)
      {_execution, _state, cycle} = cycle!(root, execution, Map.put(env, :prior_receipts, prior))
      assert calls_of(cycle) == ["check", "a", "b"]
    end

    test "a changed catalog digest reruns", %{
      root: root,
      plan: plan,
      env: env,
      roots: roots,
      prior: prior
    } do
      stale =
        for entry <- prior,
            do: put_in(entry, ["receipt", "catalog_sha256"], String.duplicate("0", 64))

      execution = start!(root, plan, "token-2", roots)
      {_execution, _state, cycle} = cycle!(root, execution, Map.put(env, :prior_receipts, stale))
      assert calls_of(cycle) == ["check", "a", "b"]
    end

    test "a changed frozen context reruns", %{root: root, plan: plan, env: env, prior: prior} do
      other = %{control_root: root, candidate_root: root, frozen: %{"route" => "r2"}}
      execution = start!(root, plan, "token-2", other)
      {_execution, _state, cycle} = cycle!(root, execution, Map.put(env, :prior_receipts, prior))
      assert calls_of(cycle) == ["check", "a", "b"]
    end

    test "a tampered prior state is refused and reruns everything",
         %{
           root: root,
           plan: plan,
           env: env,
           roots: roots,
           prior_execution: prior_execution,
           digest: digest
         } do
      File.write!(prior_execution.state_path, File.read!(prior_execution.state_path) <> " ")
      assert {:error, _} = Verification.reusable_prior(prior_execution.state_path, digest)

      execution = start!(root, plan, "token-2", roots)
      {_execution, _state, cycle} = cycle!(root, execution, Map.put(env, :prior_receipts, []))
      assert calls_of(cycle) == ["check", "a", "b"]
    end

    test "a tampered prior log is refused, and one tampered after loading reruns that target",
         %{
           root: root,
           plan: plan,
           env: env,
           roots: roots,
           prior: prior,
           prior_execution: prior_execution,
           digest: digest
         } do
      a = Enum.find(prior, &(&1["receipt"]["target"] == "a"))
      log = Path.expand(a["receipt"]["log_path"], root)
      File.write!(log, File.read!(log) <> "tampered\n")

      execution = start!(root, plan, "token-2", roots)
      {_execution, _state, cycle} = cycle!(root, execution, Map.put(env, :prior_receipts, prior))
      assert "a" in calls_of(cycle)
      assert "b" in calls_of(cycle)
      refute "check" in calls_of(cycle)

      assert {:error, _} = Verification.reusable_prior(prior_execution.state_path, digest)
    end
  end
end
