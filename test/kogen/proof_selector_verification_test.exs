Code.require_file("../support/integrity_fixture.ex", __DIR__)

defmodule Kogen.ProofSelectorVerificationTest do
  @moduledoc """
  The controller-run scenario proof selectors
  (`controller-runs-proof-selectors`): a real `base: fail` selector red on
  base and green on the Candidate, rejected non-proofs (empty selector,
  `assert true`, `:live`-tagged), the base workspace's own runner and
  `priv/` bytes, a tampered/rebuilt workspace, a weakened `base: pass`
  selector, legacy and unconfigured contracts, timeouts, and workspace
  cleanup.
  """
  use Kogen.IsolatedCase, async: true

  alias Kogen.Build.{BaseWorkspace, VerificationPlan}
  alias Kogen.IntegrityFixture, as: Fixture

  test "a real base: fail selector is red on the admission base and green on the Candidate" do
    %{dir: dir, base_commit: base_commit} = Fixture.create()

    # The Candidate both changes behaviour and adds a test for it. Base's
    # implementation (a + b) never changes: only the test file is overlaid.
    Fixture.write!(dir, "lib/calc.ex", """
    defmodule Calc do
      def add(a, b), do: a + b + 1
      def value, do: Path.join(Path.dirname(__DIR__), "priv/value.txt") |> File.read!() |> String.trim()
    end
    """)

    Fixture.write!(dir, "test/red_test.exs", """
    defmodule RedTest do
      use ExUnit.Case

      test "adds" do
        assert Calc.add(1, 2) == 4
      end
    end
    """)

    scenario =
      Fixture.scenario("s-change", "test/red_test.exs", base: "fail", affected_paths: ["lib/**"])

    env = Fixture.env(dir, [scenario], base_commit: base_commit)
    execution = Fixture.execution!(dir, "tok-1", 1, ["check"], env.plan)

    {_candidate_id, {:ok, execution, state}} = Fixture.run_cycle!(dir, execution, "dev-1", env)
    cycle = List.last(state["cycles"])
    assert cycle["status"] == "passed"
    red = Enum.find(cycle["proofs"], &(&1["kind"] == "base_red"))
    assert red["red"] == true
    assert red["red_kind"] == "assertion"
    assert red["base_commit"] == base_commit
    assert is_binary(red["workspace_sha256"])
    refute red["workspace_rebuilt"]

    # An unrelated Candidate change (the overlay digest is unchanged) reuses
    # the earlier red result instead of running it again.
    Fixture.write!(dir, "dummy.txt", "unrelated change\n")

    {_candidate_id_2, {:ok, _execution, state}} = Fixture.run_cycle!(dir, execution, "dev-1", env)

    cycle2 = List.last(state["cycles"])
    assert cycle2["status"] == "passed"
    red2 = Enum.find(cycle2["proofs"], &(&1["kind"] == "base_red"))
    assert red2["red"] == true
    assert red2["reused_from"]["cycle_sequence"] == 1
  end

  test "an empty selector and an assert true selector cannot detect the change" do
    %{dir: dir, base_commit: base_commit} = Fixture.create()

    Fixture.write!(dir, "test/empty_test.exs", """
    defmodule EmptyTest do
      use ExUnit.Case
    end
    """)

    Fixture.write!(dir, "test/true_test.exs", """
    defmodule TrueTest do
      use ExUnit.Case

      test "always" do
        assert true
      end
    end
    """)

    for file <- ["test/empty_test.exs", "test/true_test.exs"] do
      scenario = Fixture.scenario("s-#{Path.basename(file, ".exs")}", file, base: "fail")
      env = Fixture.env(dir, [scenario], base_commit: base_commit)
      execution = Fixture.execution!(dir, "tok-#{Path.basename(file)}", 1, ["check"], env.plan)

      {_candidate_id, {:ok, _execution, state}} = Fixture.run_cycle!(dir, execution, "dev-1", env)

      cycle = List.last(state["cycles"])
      assert cycle["status"] == "failed"
      assert cycle["failure"]["reason"] =~ "proof cannot detect the change"
    end
  end

  test "a :live-tagged selector cannot detect the change" do
    %{dir: dir, base_commit: base_commit} = Fixture.create()

    # Built by concatenation so this fixture source never spells out the
    # literal attribute a repository-wide scan
    # (selective_verification_targets_test.exs) counts across
    # test/kogen/*_test.exs; this file is not itself a live-owner test.
    live_tag = "@" <> "tag :live"

    Fixture.write!(dir, "test/live_tagged_test.exs", """
    defmodule LiveTaggedTest do
      use ExUnit.Case

      #{live_tag}
      test "only runs live" do
        assert Calc.add(1, 2) == 4
      end
    end
    """)

    scenario = Fixture.scenario("s-live", "test/live_tagged_test.exs", base: "fail")
    env = Fixture.env(dir, [scenario], base_commit: base_commit)
    execution = Fixture.execution!(dir, "tok-live", 1, ["check"], env.plan)

    {_candidate_id, {:ok, _execution, state}} = Fixture.run_cycle!(dir, execution, "dev-1", env)
    cycle = List.last(state["cycles"])
    assert cycle["status"] == "failed"
    assert cycle["failure"]["reason"] =~ "proof cannot detect the change"
  end

  test "the red run uses base's runner even when it was edited in the Candidate" do
    %{dir: dir, base_commit: base_commit} = Fixture.create()

    Fixture.write!(dir, "test/red_test.exs", """
    defmodule RedTest do
      use ExUnit.Case

      test "adds" do
        assert Calc.add(1, 2) == 4
      end
    end
    """)

    # Edit the runner (test_helper.exs) in the Candidate. If the red run used
    # it instead of base's own runner, ExUnit would never start there, which
    # would surface as an infrastructure error (never a red result).
    Fixture.write!(
      dir,
      "test/test_helper.exs",
      "ExUnit.start(exclude: [:live])\nraise \"the Candidate's runner must never run in the red workspace\"\n"
    )

    scenario = Fixture.scenario("s-change", "test/red_test.exs", base: "fail")
    env = Fixture.env(dir, [scenario], base_commit: base_commit)
    execution = Fixture.execution!(dir, "tok-runner", 1, ["check"], env.plan)

    {_candidate_id, {:ok, _execution, state}} = Fixture.run_cycle!(dir, execution, "dev-1", env)
    cycle = List.last(state["cycles"])
    # The Candidate's own proof run also uses the Candidate's runner, so it
    # fails there for the same (unrelated) reason: this is not a red result.
    assert cycle["status"] == "failed"
    assert cycle["failure"]["kind"] == "proof"
    assert Enum.find(cycle["proofs"], &(&1["kind"] == "base_red")) == nil
  end

  test "a tampered base workspace digest is detected and rebuilt, never reused" do
    %{dir: dir, base_commit: base_commit} = Fixture.create()

    Fixture.write!(dir, "lib/calc.ex", """
    defmodule Calc do
      def add(a, b), do: a + b + 1
      def value, do: Path.join(Path.dirname(__DIR__), "priv/value.txt") |> File.read!() |> String.trim()
    end
    """)

    Fixture.write!(dir, "test/red_test.exs", """
    defmodule RedTest do
      use ExUnit.Case

      test "adds" do
        assert Calc.add(1, 2) == 4
      end
    end
    """)

    scenario =
      Fixture.scenario("s-change", "test/red_test.exs", base: "fail", affected_paths: ["lib/**"])

    {:ok, catalog} = VerificationPlan.load(dir)
    {:ok, workspace} = BaseWorkspace.create(dir, base_commit, catalog.integrity["base_cache"])

    # Tamper with the workspace directly.
    File.write!(Path.join(workspace.path, "priv/value.txt"), "tampered\n")

    env = Fixture.env(dir, [scenario], base_commit: base_commit, workspace: workspace)
    execution = Fixture.execution!(dir, "tok-tamper", 1, ["check"], env.plan)

    tampered_path = workspace.path
    {_candidate_id, {:ok, execution, state}} = Fixture.run_cycle!(dir, execution, "dev-1", env)
    on_exit(fn -> BaseWorkspace.remove(execution.workspace) end)
    cycle = List.last(state["cycles"])
    red = Enum.find(cycle["proofs"], &(&1["kind"] == "base_red"))
    assert red["workspace_rebuilt"] == true
    # The tampered workspace is torn down, not reused, once its digest no
    # longer matches; the rebuilt one is a fresh, untampered copy of the same
    # admission tree, so its digest matches the original (untampered) one.
    refute File.exists?(tampered_path)
    assert red["workspace_sha256"] == workspace.digest
  end

  test "a base: pass selector weakened in the Candidate must still pass with base's bytes" do
    %{dir: dir} = Fixture.create()

    Fixture.write!(dir, "test/preserve_test.exs", """
    defmodule PreserveTest do
      use ExUnit.Case

      test "adds" do
        assert Calc.add(1, 2) == 3
      end
    end
    """)

    base_commit = Fixture.commit!(dir, "add preservation selector")

    # Regress the implementation and weaken the preservation selector to hide
    # it (the weakened test still passes against the regressed behaviour).
    Fixture.write!(dir, "lib/calc.ex", """
    defmodule Calc do
      def add(a, b), do: a + b + 1
      def value, do: Path.join(Path.dirname(__DIR__), "priv/value.txt") |> File.read!() |> String.trim()
    end
    """)

    Fixture.write!(dir, "test/preserve_test.exs", """
    defmodule PreserveTest do
      use ExUnit.Case

      test "adds" do
        assert Calc.add(1, 2) == 4
      end
    end
    """)

    scenario = Fixture.scenario("s-preserve", "test/preserve_test.exs", base: "pass")
    env = Fixture.env(dir, [scenario], base_commit: base_commit)
    execution = Fixture.execution!(dir, "tok-weaken", 1, ["check"], env.plan)

    {_candidate_id, {:ok, _execution, state}} = Fixture.run_cycle!(dir, execution, "dev-1", env)
    cycle = List.last(state["cycles"])
    assert cycle["status"] == "failed"
    assert cycle["failure"]["reason"] =~ "base's bytes of its edited preservation selectors fail"
  end

  test "a legacy contract without proof.base is labelled unproven-on-base and runs only on the Candidate" do
    %{dir: dir, base_commit: base_commit} = Fixture.create()

    Fixture.write!(dir, "test/legacy_test.exs", """
    defmodule LegacyTest do
      use ExUnit.Case

      test "adds" do
        assert Calc.add(1, 2) == 3
      end
    end
    """)

    scenario = Fixture.scenario("s-legacy", "test/legacy_test.exs")
    assert scenario["proof"]["base"] == nil
    env = Fixture.env(dir, [scenario], base_commit: base_commit)
    assert Enum.find(env.plan.scenarios, &(&1["id"] == "s-legacy"))["label"] == "unproven-on-base"
    execution = Fixture.execution!(dir, "tok-legacy", 1, ["check"], env.plan)

    {_candidate_id, {:ok, _execution, state}} = Fixture.run_cycle!(dir, execution, "dev-1", env)
    cycle = List.last(state["cycles"])
    assert cycle["status"] == "passed"
    assert [proof] = cycle["proofs"]
    assert proof["kind"] == "candidate"
  end

  test "a catalog without integrity fields labels every scenario integrity-not-configured" do
    %{dir: dir} = Fixture.create()

    Fixture.write!(dir, "priv/kogen/verification_targets.yaml", """
    targets:
      - name: check
        cost_class: offline-complete
        rank: 0
        dependencies: []
        provider_backed: false
        owner: fixture
    """)

    Fixture.write!(dir, "test/legacy_test.exs", """
    defmodule LegacyTest do
      use ExUnit.Case

      test "x" do
        assert true
      end
    end
    """)

    base_commit = Fixture.commit!(dir, "drop integrity fields")

    scenario = Fixture.scenario("s-plain", "test/legacy_test.exs", base: "fail")

    env = Fixture.env(dir, [scenario], base_commit: base_commit)
    assert env.catalog.integrity == nil

    assert Enum.find(env.plan.scenarios, &(&1["id"] == "s-plain"))["label"] ==
             "integrity-not-configured"

    execution = Fixture.execution!(dir, "tok-plain", 1, ["check"], env.plan)

    {_candidate_id, {:ok, _execution, state}} = Fixture.run_cycle!(dir, execution, "dev-1", env)
    cycle = List.last(state["cycles"])
    assert cycle["status"] == "passed"
    assert cycle["proofs"] == []
  end

  test "a timeout is an error, never a red result" do
    %{dir: dir, base_commit: base_commit} = Fixture.create()

    # Base workspace runs always carry their own MIX_BUILD_PATH
    # (`Kogen.Build.BaseWorkspace.run_environment/1`); the real Candidate run
    # never sets it. Sleeping only there makes the red-on-base run the one
    # that times out, without the Candidate's own proof run flaking on a
    # slow first compile.
    Fixture.write!(dir, "test/slow_test.exs", """
    defmodule SlowTest do
      use ExUnit.Case

      test "sleeps only in a base workspace run" do
        if System.get_env("MIX_BUILD_PATH"), do: Process.sleep(15_000)
        assert Calc.add(1, 2) == 3
      end
    end
    """)

    scenario = Fixture.scenario("s-slow", "test/slow_test.exs", base: "fail")
    env = Fixture.env(dir, [scenario], base_commit: base_commit)
    execution = Fixture.execution!(dir, "tok-slow", 1, ["check"], env.plan)

    previous = Application.get_env(:kogen, :focused_runner_timeout_ms)
    Application.put_env(:kogen, :focused_runner_timeout_ms, 3_000)

    try do
      {_candidate_id, {:ok, _execution, state}} = Fixture.run_cycle!(dir, execution, "dev-1", env)

      cycle = List.last(state["cycles"])
      assert cycle["status"] == "failed"
      assert cycle["failure"]["kind"] == "proof"
      error = Enum.find(cycle["proofs"], &(&1["status"] == "error"))
      assert error["red"] == false
    after
      if previous,
        do: Application.put_env(:kogen, :focused_runner_timeout_ms, previous),
        else: Application.delete_env(:kogen, :focused_runner_timeout_ms)
    end
  end

  test "the temporary base workspace is removed" do
    %{dir: dir, base_commit: base_commit} = Fixture.create()
    {:ok, catalog} = VerificationPlan.load(dir)
    {:ok, workspace} = BaseWorkspace.create(dir, base_commit, catalog.integrity["base_cache"])
    assert File.dir?(workspace.path)
    assert BaseWorkspace.remove(workspace) == :ok
    refute File.exists?(workspace.path)
  end

  test "a base_cache entry naming .kogen/build.lock is rejected" do
    %{dir: dir} = Fixture.create(base_cache: [".kogen/build.lock"])

    assert {:error, reason} = VerificationPlan.load(dir)
    assert reason =~ "base_cache must not copy controller volatile state"
  end

  test "a base run reads the workspace's own priv/ bytes, never the parent checkout's" do
    %{dir: dir, base_commit: base_commit} = Fixture.create()
    {:ok, catalog} = VerificationPlan.load(dir)
    {:ok, workspace} = BaseWorkspace.create(dir, base_commit, catalog.integrity["base_cache"])

    # Change the Candidate's implementation (priv/value.txt is not part of
    # the verification surface, so it is never overlaid) and its selector to
    # match the new behaviour.
    Fixture.write!(dir, "priv/value.txt", "999\n")

    Fixture.write!(dir, "test/priv_test.exs", """
    defmodule PrivTest do
      use ExUnit.Case

      test "reads the new value" do
        assert Calc.value() == "999"
      end
    end
    """)

    scenario = Fixture.scenario("s-priv", "test/priv_test.exs", base: "fail")
    env = Fixture.env(dir, [scenario], base_commit: base_commit, workspace: workspace)
    execution = Fixture.execution!(dir, "tok-priv", 1, ["check"], env.plan)

    {_candidate_id, {:ok, _execution, state}} = Fixture.run_cycle!(dir, execution, "dev-1", env)
    cycle = List.last(state["cycles"])
    # The Candidate run passes (its own priv/value.txt now holds "999"). The
    # base run overlays only the selector file (never priv/value.txt), so it
    # must run against the base workspace's own frozen "base" bytes and go
    # red there; if it instead read the live parent checkout's priv/value.txt
    # (also "999" by now), the base run would wrongly pass and the whole
    # cycle would fail as "proof cannot detect the change" instead.
    assert cycle["status"] == "passed"
    red = Enum.find(cycle["proofs"], &(&1["kind"] == "base_red"))
    assert red["red"] == true
    assert red["red_kind"] == "assertion"
  end
end
