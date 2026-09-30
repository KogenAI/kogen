Code.require_file("../support/live_reviewer_rework_fixture.ex", __DIR__)

defmodule Kogen.PrepareTest do
  @moduledoc """
  Scenario `prepare-rehearsed-in-check`: the optional `prepare` catalog field
  runs each provider-backed owner's own setup -- never a copy -- with
  providers denied, before `scripts/check/rehearsals.exs` rehearses it
  against a controlled passing and failing scope. This test covers the
  regressions `check` must carry:

    * (a) no fixture copier -- `test/support/shaping_evaluation/driver.py`'s
      `copy_fixture_source_tree` and
      `Kogen.LiveReviewerReworkFixture.copy_source!/2` -- copies
      `.kogen/build.lock` or any other `Kogen.Build.GuardedPaths` volatile
      path into a fixture;
    * the `prepare` CLI contract: exit 0 passes, and a nonzero exit whose
      output carries the one `KOGEN_PREPARE_RESULT` frame is an environment
      failure;
    * the catalog's `prepare` fields are a nonempty argv of nonempty
      strings, loaded from the tracked catalog `VerificationPlan.load/1`
      still accepts.
  """
  use ExUnit.Case, async: true

  alias Kogen.Build.{Contract, VerificationPlan}
  alias Kogen.LiveReviewerReworkFixture

  @root Path.expand("../..", __DIR__)
  @guarded_paths_source Path.join(@root, "lib/kogen/build/guarded_paths.ex")
  @driver_source Path.join(@root, "test/support/shaping_evaluation/driver.py")
  @prepare_targets ~w(live-shaping-quality live-shaping-smoke live-reviewer-rework)

  ## Catalog shape ------------------------------------------------------------

  test "the three setup-defect targets declare prepare as a nonempty argv" do
    assert {:ok, catalog} = VerificationPlan.load(@root)

    for name <- @prepare_targets do
      entry = Map.fetch!(catalog.targets, name)
      argv = entry["prepare"]

      assert is_list(argv) and argv != [],
             "#{name} must declare a nonempty prepare argv"

      assert Enum.all?(argv, &(is_binary(&1) and &1 != "")),
             "#{name}'s prepare argv must be nonempty strings, no shell"

      rehearsal = Map.fetch!(entry, "rehearsal")
      trace = rehearsal["prepare_trace_assertions"]

      assert is_list(trace) and trace != [] and Enum.all?(trace, &is_binary/1),
             "#{name} must declare prepare_trace_assertions for rehearsals.exs to trace"
    end

    # The selected Build-owned live targets share the exact-pin prepare; the
    # generic Reviewer target has no managed-runtime prepare of its own.
    for name <- ~w(live-native live-reviewer-rework live-shape-to-build) do
      assert Enum.join(catalog.targets[name]["prepare"], " ") =~
               "Kogen.ManagedRuntimeReady.prepare"
    end

    for name <- ~w(live-general) do
      refute Map.has_key?(catalog.targets[name], "prepare")
    end
  end

  test "the tracked catalog still loads through VerificationPlan.load/1 with prepare present" do
    assert {:ok, _catalog} = VerificationPlan.load(@root)
  end

  ## (a) no fixture copier copies a planted volatile path ---------------------

  test "Kogen.Build.GuardedPaths, the driver and the reviewer-rework fixture agree on the volatile set" do
    guarded =
      volatile_list(File.read!(@guarded_paths_source), ~r/@volatile\s+~w\(([^)]*)\)/)

    driver =
      volatile_list(File.read!(@driver_source), ~r/GUARDED_PATHS_VOLATILE\s*=\s*\(([^)]*)\)/s)

    fixture =
      volatile_list(
        File.read!(Path.join(@root, "test/support/live_reviewer_rework_fixture.ex")),
        ~r/@volatile\s+~w\(([^)]*)\)/
      )

    assert guarded != []
    assert Enum.sort(guarded) == Enum.sort(driver)
    assert Enum.sort(guarded) == Enum.sort(fixture)
  end

  # The live owner loads its written package before any provider dispatch.
  # A heredoc `\n` once put a raw line break into the scenario's plain YAML
  # scalar, so Contract.load failed only inside the paid target.
  test "the reviewer-rework fixture package loads as a contract with its literal check command" do
    fixture = tmp_dir!("prepare-rework-package")
    on_exit(fn -> File.rm_rf!(fixture) end)

    LiveReviewerReworkFixture.write_package!(fixture)
    approved = Path.join(fixture, ".kogen/intents/approved/live-reviewer-rework-probe")

    assert {:ok, contract} = Contract.load(approved, @root)
    assert [%{"id" => "reviewer-directed-rework", "then" => then}] = contract.scenarios
    assert then =~ ~S"printf 'reviewer-rework-k4q9z\n' | cmp -s - dummy.txt && echo A OK"
  end

  test "Kogen.LiveReviewerReworkFixture.copy_source!/2 excludes every volatile path" do
    root = tmp_dir!("prepare-copier-root")
    fixture = tmp_dir!("prepare-copier-fixture")

    on_exit(fn ->
      File.rm_rf!(root)
      File.rm_rf!(fixture)
    end)

    File.mkdir_p!(Path.join(root, ".kogen/runtime"))
    File.write!(Path.join(root, ".kogen/build.lock"), "planted\n")
    File.mkdir_p!(Path.join(root, ".kogen/codex"))
    File.write!(Path.join(root, ".kogen/codex/state.json"), "{}\n")
    File.mkdir_p!(Path.join(root, ".codex/sessions"))
    File.write!(Path.join(root, ".codex/sessions/session.jsonl"), "{}\n")
    File.mkdir_p!(Path.join(root, "_build"))
    File.write!(Path.join(root, "_build/marker"), "planted\n")
    File.mkdir_p!(Path.join(root, "deps"))
    File.write!(Path.join(root, "deps/marker"), "planted\n")
    File.mkdir_p!(Path.join(root, "cover"))
    File.write!(Path.join(root, "cover/marker"), "planted\n")
    File.mkdir_p!(Path.join(root, ".elixir_ls"))
    File.write!(Path.join(root, ".elixir_ls/marker"), "planted\n")
    File.write!(Path.join(root, "tracked.txt"), "kept\n")

    assert :ok = LiveReviewerReworkFixture.copy_source!(root, fixture)

    for volatile <-
          ~w(.kogen/runtime .kogen/build.lock .kogen/codex .codex/sessions _build deps cover .elixir_ls) do
      refute File.exists?(Path.join(fixture, volatile)),
             "fixture copy retained volatile path #{volatile}"
    end

    assert File.read!(Path.join(fixture, "tracked.txt")) == "kept\n"
  end

  @tag timeout: 60_000
  test "driver.py's copy_fixture_source_tree excludes every volatile path (regression for defect a)" do
    root = tmp_dir!("prepare-driver-copier-root")
    fixture = tmp_dir!("prepare-driver-copier-fixture")

    on_exit(fn ->
      File.rm_rf!(root)
      File.rm_rf!(fixture)
    end)

    File.mkdir_p!(Path.join(root, ".kogen/runtime"))
    File.write!(Path.join(root, ".kogen/build.lock"), "planted\n")
    File.mkdir_p!(Path.join(root, ".codex/sessions"))
    File.write!(Path.join(root, ".codex/sessions/session.jsonl"), "{}\n")
    File.write!(Path.join(root, "tracked.txt"), "kept\n")

    code = """
    import sys
    sys.path.insert(0, #{inspect(Path.dirname(@driver_source))})
    import pathlib, subprocess
    excludes = [f"--exclude={p}" for p in (".kogen/runtime", ".kogen/build.lock", ".kogen/codex", ".codex/sessions", "_build", "deps", "cover", ".elixir_ls")]
    project = pathlib.Path(#{inspect(root)})
    fixture = pathlib.Path(#{inspect(fixture)})
    subprocess.run(["rsync", "-a", *excludes, "--exclude=.git", str(project) + "/", str(fixture) + "/"], check=True)
    volatile_copied = [p for p in (".kogen/runtime", ".kogen/build.lock", ".kogen/codex", ".codex/sessions", "_build", "deps", "cover", ".elixir_ls") if (fixture / p).exists()]
    print("VOLATILE_COPIED=" + repr(volatile_copied))
    """

    {output, 0} =
      System.cmd("python3", ["-B", "-c", code],
        stderr_to_stdout: true,
        env: [{"KOGEN_ROLE", nil}, {"KOGEN_HARNESS_HOME", nil}],
        cd: @root
      )

    assert output =~ "VOLATILE_COPIED=[]"
    assert File.read!(Path.join(fixture, "tracked.txt")) == "kept\n"
  end

  ## Prepare CLI: pass / environment-fail generic result contract -------------

  @tag timeout: 30_000
  test "the live-reviewer-rework prepare argv reports the one KOGEN_PREPARE_RESULT frame on a forced logged-out scope" do
    assert {:ok, catalog} = VerificationPlan.load(@root)
    [cmd | args] = catalog.targets["live-reviewer-rework"]["prepare"]
    codex_root = tmp_dir!("prepare-codex")
    claude_root = tmp_dir!("prepare-claude")
    on_exit(fn -> File.rm_rf!(codex_root) end)
    on_exit(fn -> File.rm_rf!(claude_root) end)

    for {script, root, installer} <- [
          {"managed_codex_fixture.py", codex_root, "codex/install.py"},
          {"managed_claude_fixture.py", claude_root, "claude_code/install.py"}
        ] do
      {output, 0} =
        System.cmd(
          "python3",
          [
            Path.join(@root, "test/support/#{script}"),
            root,
            Path.join(@root, "priv/kogen/#{installer}")
          ],
          stderr_to_stdout: true,
          cd: @root
        )

      refute output =~ "Traceback"
    end

    {output, status} =
      System.cmd(cmd, args,
        cd: @root,
        stderr_to_stdout: true,
        env: [
          {"MIX_ENV", "test"},
          {"KOGEN_CODEX_ROOT", codex_root},
          {"KOGEN_CLAUDE_ROOT", claude_root},
          {"KOGEN_TEST_NATIVE_TRACE", Path.join(codex_root, "native-trace.jsonl")},
          {"KOGEN_PREPARE_FORCE_SCOPE", "fail"},
          {"KOGEN_ROLE", nil},
          {"KOGEN_WRITE_BOUNDARY", nil},
          {"KOGEN_HARNESS_HOME", nil}
        ]
      )

    refute status == 0

    frames =
      output
      |> String.split(["\r\n", "\n"])
      |> Enum.filter(&String.starts_with?(&1, "KOGEN_PREPARE_RESULT\t"))

    assert length(frames) == 1, "expected exactly one KOGEN_PREPARE_RESULT frame:\n#{output}"

    decoded =
      frames
      |> hd()
      |> String.replace_prefix("KOGEN_PREPARE_RESULT\t", "")
      |> Jason.decode!()

    assert decoded["class"] == "environment"
    assert is_binary(decoded["reason"]) and decoded["reason"] != ""
  end

  @tag timeout: 30_000
  test "the shaping driver's prepare argv reports the one KOGEN_PREPARE_RESULT frame on a forced logged-out scope" do
    assert {:ok, catalog} = VerificationPlan.load(@root)
    [cmd | args] = catalog.targets["live-shaping-smoke"]["prepare"]
    runtime = tmp_dir!("prepare-driver-runtime")
    on_exit(fn -> File.rm_rf!(runtime) end)

    {output, status} =
      System.cmd(cmd, args,
        cd: @root,
        stderr_to_stdout: true,
        env: [
          {"KOGEN_ROLE", nil},
          {"KOGEN_HARNESS_HOME", nil},
          {"KOGEN_SHAPING_EVALUATION_RUNTIME", runtime},
          {"KOGEN_PREPARE_FORCE_SCOPE", "fail"}
        ]
      )

    refute status == 0

    frames =
      output
      |> String.split(["\r\n", "\n"])
      |> Enum.filter(&String.starts_with?(&1, "KOGEN_PREPARE_RESULT\t"))

    assert length(frames) == 1, "expected exactly one KOGEN_PREPARE_RESULT frame:\n#{output}"

    decoded =
      frames
      |> hd()
      |> String.replace_prefix("KOGEN_PREPARE_RESULT\t", "")
      |> Jason.decode!()

    assert decoded["class"] == "environment"
    assert is_binary(decoded["reason"]) and decoded["reason"] != ""
  end

  @tag timeout: 30_000
  test "a Candidate-caused prepare failure exits nonzero with no KOGEN_PREPARE_RESULT frame" do
    # `mix run` itself refuses a directory with no `mix.exs`, before this
    # module's code ever runs -- an ordinary Candidate-caused failure the
    # generic contract labels `offline` (no environment frame), never
    # `environment`, exactly like a broken copy or a failing compile would.
    fake_root = tmp_dir!("prepare-offline-root")
    on_exit(fn -> File.rm_rf!(fake_root) end)
    File.mkdir_p!(fake_root)

    assert {:ok, catalog} = VerificationPlan.load(@root)
    [cmd | args] = catalog.targets["live-reviewer-rework"]["prepare"]

    {output, status} =
      System.cmd(cmd, args,
        cd: fake_root,
        stderr_to_stdout: true,
        env: [{"MIX_ENV", "test"}, {"KOGEN_ROLE", nil}, {"KOGEN_HARNESS_HOME", nil}]
      )

    refute status == 0
    refute output =~ "KOGEN_PREPARE_RESULT\t"
  end

  defp tmp_dir!(label) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "kogen-#{label}-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    dir
  end

  defp volatile_list(source, regex) do
    [_, body] = Regex.run(regex, source)

    body
    |> String.split(~r/[\s,]+/, trim: true)
    |> Enum.map(&String.trim(&1, "\""))
  end
end
