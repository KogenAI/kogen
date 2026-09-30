Code.require_file("../support/dependency_fixture.ex", __DIR__)

defmodule Kogen.ColdOfflineTest do
  use ExUnit.Case, async: true

  # Subprocesses run from this checkout, never the shared VM's mutable cwd.
  @project_root Path.expand("../..", __DIR__)

  @offline Path.expand("../../scripts/check/offline.py", __DIR__)

  # Focused cold setup/dependency regression, part of the ordinary check: a
  # cold copy builds only under its MIX_BUILD_PATH, and the base export must
  # reuse those builds with materialized sources and headers rather than
  # recompiling yamerl without its include tree.
  test "base enumeration reuses cold build-path dependencies with complete headers" do
    program = ~S'''
    import importlib.util, json, os, pathlib, shutil, sys, tempfile
    spec = importlib.util.spec_from_file_location("offline", sys.argv[1])
    offline = importlib.util.module_from_spec(spec); spec.loader.exec_module(offline)
    calls = []
    def no_prepare(command, cwd, env, timeout):
        calls.append({"command": command, "cwd": str(cwd), "mix_env": env.get("MIX_ENV")})
        return 0, "", {"status": "not-required"}
    offline.run_bounded_capture = no_prepare

    def fixture(temporary):
        root = pathlib.Path(temporary) / "root"
        (root / "deps/yamerl/include/internal").mkdir(parents=True)
        (root / "deps/yamerl/src").mkdir(parents=True)
        (root / "deps/yamerl/include/yamerl_nodes.hrl").write_text("-record(n, {}).\n")
        (root / "deps/yamerl/include/internal/yamerl_constr.hrl").write_text("-record(c, {}).\n")
        (root / "deps/yamerl/src/yamerl.erl").write_text("-module(yamerl).\n")
        lib = root / "_build/cold/lib"
        (lib / "yamerl/ebin").mkdir(parents=True)
        (lib / "yamerl/ebin/yamerl.app").write_text("{application, yamerl, []}.\n")
        (lib / "yamerl/include").symlink_to("../../../../deps/yamerl/include")
        (lib / "yamerl/src").symlink_to("../../../../deps/yamerl/src")
        (lib / "kogen/ebin").mkdir(parents=True)
        (lib / "kogen/ebin/Elixir.Kogen.Build.beam").write_bytes(b"candidate")
        return root, lib

    def attempt(root, env):
        base = root.parent / ("base-" + str(len(list(root.parent.iterdir()))))
        base.mkdir()
        try:
            return {"names": offline.copy_installed_dependencies(root, env, base), "base": base}
        except RuntimeError as error:
            return {"error": str(error)}

    result = {}
    with tempfile.TemporaryDirectory(prefix="kogen-cold-deps-") as temporary:
        root, lib = fixture(temporary)
        cold = attempt(root, {"MIX_BUILD_PATH": "_build/cold"})
        copied = cold["base"] / "_build/lib/yamerl"
        result["cold"] = {
            "names": cold["names"],
            "header_regular": (copied / "include/yamerl_nodes.hrl").is_file()
                and not (copied / "include").is_symlink(),
            "internal_header": (copied / "include/internal/yamerl_constr.hrl").is_file(),
            "source": (copied / "src/yamerl.erl").is_file(),
            "candidate_app_copied": (cold["base"] / "_build/lib/kogen").exists(),
            "prepared": list(calls),
        }
        absolute = attempt(root, {"MIX_BUILD_PATH": str(root / "_build/cold")})
        result["absolute"] = absolute.get("names")
        default = attempt(root, {})
        result["default"] = {"error": default.get("error"), "prepared": calls[-1] if calls else None}
        (lib / "yamerl/include").unlink()
        (lib / "yamerl/include").symlink_to("../../../../deps/yamerl/missing-include")
        result["dangling"] = attempt(root, {"MIX_BUILD_PATH": "_build/cold"}).get("error")
        (lib / "yamerl/include").unlink()
        (lib / "yamerl/include").mkdir()
        (lib / "yamerl/include/yamerl_nodes.hrl").write_text("-record(n, {}).\n")
        result["partial_headers"] = attempt(root, {"MIX_BUILD_PATH": "_build/cold"}).get("error")
        shutil.rmtree(lib / "yamerl/include")
        (lib / "yamerl/include").symlink_to("../../../../deps/yamerl/include")
        (lib / "yamerl/ebin/yamerl.app").unlink()
        result["missing_app"] = attempt(root, {"MIX_BUILD_PATH": "_build/cold"}).get("error")
    print(json.dumps(result))
    '''

    {output, 0} =
      System.cmd("python3", ["-B", "-c", program, @offline],
        stderr_to_stdout: true,
        cd: @project_root
      )

    result = output |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()

    assert result["cold"] == %{
             "names" => ["yamerl"],
             "header_regular" => true,
             "internal_header" => true,
             "source" => true,
             "candidate_app_copied" => false,
             "prepared" => []
           }

    assert result["absolute"] == ["yamerl"]

    # Without MIX_BUILD_PATH the default _build/test is empty: dependencies
    # are prepared once in the Candidate root, and a preparation that builds
    # nothing fails explicitly instead of recompiling inside the export.
    assert result["default"]["error"] =~ "installed dependency builds are missing under"
    assert result["default"]["error"] =~ "_build/test/lib"

    assert result["default"]["prepared"] == %{
             "command" => ["mix", "deps.compile"],
             "cwd" => result["default"]["prepared"]["cwd"],
             "mix_env" => "test"
           }

    assert String.ends_with?(result["default"]["prepared"]["cwd"], "/root")
    assert result["dangling"] =~ "yamerl: dangling installed links ['include']"
    assert result["partial_headers"] =~ "yamerl: include differs from deps/yamerl/include"
    assert result["partial_headers"] =~ "internal/yamerl_constr.hrl"
    assert result["missing_app"] =~ "yamerl: ebin/yamerl.app is missing"
  end

  test "immutable base enumeration compiles nothing from a relocated dependency build path" do
    root = Path.expand("../..", __DIR__)

    program = ~S'''
    import importlib.util, json, os, pathlib, shutil, sys, tempfile
    root = pathlib.Path(sys.argv[1])
    spec = importlib.util.spec_from_file_location("offline", sys.argv[2])
    offline = importlib.util.module_from_spec(spec); spec.loader.exec_module(offline)
    capture = offline.run_bounded_capture
    outputs = []
    def recording(command, cwd, env, timeout):
        returncode, output, cleanup = capture(command, cwd, env, timeout)
        outputs.append({"command": command, "output": output})
        return returncode, output, cleanup
    offline.run_bounded_capture = recording
    installed = offline.installed_dependency_libs(root, dict(os.environ))
    with tempfile.TemporaryDirectory(prefix="kogen-cold-relocated-") as temporary:
        cold_lib = pathlib.Path(temporary) / "cold/lib"
        for dependency in installed.iterdir():
            if dependency.is_dir() and dependency.name != "kogen":
                shutil.copytree(dependency, cold_lib / dependency.name, symlinks=False)
        (cold_lib / "yamerl/ebin/.relocated").write_text("cold\n")
        env = dict(os.environ, MIX_BUILD_PATH=str(cold_lib.parent))
        workspace = pathlib.Path(temporary) / "support"
        manifest = offline.make_base_manifest(root, shutil.which("git"), env, workspace)
        base = workspace / "base"
        print(json.dumps({
            "tests": len(manifest["tests"]),
            "relocated": (base / "_build/lib/yamerl/ebin/.relocated").is_file(),
            "header": (base / "_build/lib/yamerl/include/yamerl_nodes.hrl").is_file(),
            "commands": [entry["command"] for entry in outputs],
            "recompiled": [entry["command"] for entry in outputs
                           if "Compiling yamerl" in entry["output"]],
        }))
    '''

    {output, status} =
      System.cmd("python3", ["-B", "-c", program, root, @offline],
        stderr_to_stdout: true,
        cd: @project_root
      )

    assert status == 0, output
    result = output |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()
    assert result["tests"] > 0
    assert result["relocated"]
    assert result["header"]

    assert result["commands"] == [
             ["mix", "test", "--dry-run", "--exclude", "live", "--seed", "1"]
           ]

    assert result["recompiled"] == []
  end

  # Only the outer verification owner runs this empty-cache acceptance step,
  # an explicit diagnostic outside routine Builds. The nested complete
  # offline recipe excludes :live, including this driver itself.
  @tag :live
  @tag timeout: 1_200_000
  test "the complete offline gate passes with an empty private build cache" do
    root = Path.expand("../..", __DIR__)
    identity = "cold-offline-#{System.pid()}-#{System.unique_integer([:positive])}"
    fixture = Path.join(System.tmp_dir!(), identity)
    File.mkdir!(fixture)

    log_base =
      System.get_env("KOGEN_LIVE_LOG_DIR") || Path.join(root, ".kogen/runtime/live-evidence")

    log_dir = Path.join(log_base, identity)
    File.mkdir_p!(log_dir)

    on_exit(fn ->
      result = File.rm_rf(fixture)
      File.write!(Path.join(log_dir, "cold-cleanup.txt"), inspect(result) <> "\n")
      assert match?({:ok, _}, result), "cold fixture cleanup failed: #{inspect(result)}"
    end)

    {copy_output, copy_status} =
      System.cmd(
        "rsync",
        [
          "-a",
          "--exclude=_build",
          "--exclude=deps",
          "--exclude=.git",
          "--exclude=.kogen/runtime",
          "--exclude=.kogen/build.lock",
          root <> "/",
          fixture <> "/"
        ],
        stderr_to_stdout: true,
        cd: @project_root
      )

    assert copy_status == 0, copy_output
    Kogen.DependencyFixture.copy!(Path.join(root, "deps"), Path.join(fixture, "deps"))

    {source_revision, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: root)
    source_revision = String.trim(source_revision)
    attach_source_history!(root, fixture, source_revision)

    {source_manifest, 0} =
      System.cmd("python3", ["-B", "scripts/check/offline.py", "--source-manifest-sha256"],
        cd: root
      )

    source_manifest = String.trim(source_manifest)

    {fixture_manifest, 0} =
      System.cmd("python3", ["-B", "scripts/check/offline.py", "--source-manifest-sha256"],
        cd: fixture
      )

    assert String.trim(fixture_manifest) == source_manifest
    build_path = Path.join(fixture, "_build/cold")
    refute File.exists?(build_path)

    File.write!(Path.join(log_dir, "conditions.txt"), """
    Source: #{root}
    Fixture: #{fixture}
    MIX_BUILD_PATH: _build/cold (fixture-local, #{build_path})
    Cache initially absent: true
    Dependencies: installed sources copied privately without build caches; no downloads
    Git: private repository sharing source objects read-only, HEAD #{source_revision}, index at HEAD
    Owner: outer cold-offline verification; nested recipe excludes all live cases
    """)

    # The fixture's mise.toml is a byte copy of the Candidate's own config, but
    # mise trusts config files by path; name exactly that copy as trusted,
    # keeping any caller trust list, so the cold copy resolves project Python.
    trusted_mise =
      [System.get_env("MISE_TRUSTED_CONFIG_PATHS"), Path.join(fixture, "mise.toml")]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(":")

    {output, status} =
      System.cmd("make", ["check"],
        cd: fixture,
        env: [
          {"MISE_TRUSTED_CONFIG_PATHS", trusted_mise},
          # Resolve from the child's physical cwd: macOS TMPDIR may use /var
          # while Rebar sees /private/var, breaking its relative header links.
          {"MIX_BUILD_PATH", "_build/cold"},
          {"HEX_OFFLINE", "1"},
          {"KOGEN_COLD_OFFLINE", "1"},
          {"KOGEN_OFFLINE_SOURCE_REVISION", source_revision},
          {"KOGEN_OFFLINE_CANDIDATE_SHA256", source_manifest},
          {"KOGEN_OFFLINE_SOURCE_MANIFEST_SHA256", source_manifest},
          {"KOGEN_HARNESS", nil},
          {"KOGEN_RAW_LOG_DIR", nil},
          {"KOGEN_TEST_PROCESS_GUARD", nil}
        ],
        stderr_to_stdout: true
      )

    File.write!(Path.join(log_dir, "cold-check.log"), output)
    shim_path = Path.join(fixture, ".kogen/runtime/path-shim-invoked")
    shim_receipt = if File.exists?(shim_path), do: File.read!(shim_path), else: nil

    # Keep the postflight inputs before cleanup: the outer Build's bounded
    # failure tail may omit this test's original assertion diagnostic.
    File.write!(
      Path.join(log_dir, "cold-outcome.json"),
      Jason.encode!(%{
        exit_code: status,
        fixture: fixture,
        shim_receipt: shim_receipt,
        output_sha256: :crypto.hash(:sha256, output) |> Base.encode16(case: :lower)
      }) <> "\n"
    )

    assert status == 0, "cold offline gate failed; #{log_dir}/cold-check.log\n#{output}"
    assert output =~ "warm=False"
    assert output =~ "mix format --check-formatted"
    assert output =~ "mix compile --warnings-as-errors --force"
    assert output =~ "mix credo --strict"
    assert output =~ "mix test --exclude live"
    assert output =~ "Complete offline gate:"
    assert output =~ "exit=0"
    assert is_nil(shim_receipt), "unexpected offline provider dispatch: #{inspect(shim_receipt)}"
  end

  # The ordinary check runs in a Git work tree whose HEAD is the admission
  # base and whose files are the Candidate. Give the copy that same context:
  # a private repository borrowing the source objects read-only, HEAD at the
  # source revision, and an index reset to HEAD so the copied files show the
  # same Candidate changes. No build cache is copied.
  defp attach_source_history!(root, fixture, source_revision) do
    clone = fixture <> ".git-clone"
    on_exit(fn -> File.rm_rf(clone) end)

    for {args, cd} <- [
          {["clone", "-q", "--no-checkout", "--shared", root, clone], root},
          {["reset", "-q", source_revision], clone}
        ] do
      {output, status} = System.cmd("git", args, cd: cd, stderr_to_stdout: true)
      assert status == 0, "cold fixture git #{hd(args)} failed: #{output}"
    end

    File.rename!(Path.join(clone, ".git"), Path.join(fixture, ".git"))
    File.rm_rf!(clone)
    {output, status} = System.cmd("git", ["reset", "-q"], cd: fixture, stderr_to_stdout: true)
    assert status == 0, "cold fixture index reset failed: #{output}"
    {head, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: fixture)
    assert String.trim(head) == source_revision
  end
end
