defmodule Kogen.ColdOfflineContractTest do
  use ExUnit.Case, async: true

  test "cold environment consumer rejects warm, credentialed, and provider-touched inputs" do
    root = Path.expand("../..", __DIR__)
    warm = Path.join(System.tmp_dir!(), "warm-#{System.unique_integer([:positive])}")
    receipt = Path.join(System.tmp_dir!(), "provider-#{System.unique_integer([:positive])}")
    File.mkdir!(warm)
    File.write!(receipt, "attempted")

    on_exit(fn ->
      File.rm_rf(warm)
      File.rm(receipt)
    end)

    program = ~S'''
    import importlib.util, json, sys
    spec = importlib.util.spec_from_file_location("offline", sys.argv[1])
    offline = importlib.util.module_from_spec(spec); spec.loader.exec_module(offline)
    valid = offline.validate_cold_environment(sys.argv[2], {"HEX_OFFLINE":"1"}, sys.argv[3] + ".absent")
    wrong = offline.validate_cold_environment(sys.argv[3], {"HEX_OFFLINE":"0", "KOGEN_HARNESS":"foreign"}, sys.argv[4])
    print(json.dumps({"valid":valid,"wrong":wrong}))
    '''

    absent = Path.join(System.tmp_dir!(), "absent-#{System.unique_integer([:positive])}")

    {output, 0} =
      System.cmd(
        "python3",
        ["-c", program, Path.join(root, "scripts/check/offline.py"), absent, warm, receipt],
        stderr_to_stdout: true
      )

    result = Jason.decode!(String.trim(output))

    assert result["valid"] == []
    assert "cold build path already exists" in result["wrong"]
    assert "HEX_OFFLINE must be 1" in result["wrong"]
    assert "KOGEN_HARNESS must be absent" in result["wrong"]
    assert "provider denial receipt already exists" in result["wrong"]
  end

  test "provider denial remains enforced after offline stages settle" do
    root = Path.expand("../..", __DIR__)
    receipt = Path.join(System.tmp_dir!(), "provider-post-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm(receipt) end)

    program = ~S'''
    import importlib.util, json, pathlib, sys
    spec = importlib.util.spec_from_file_location("offline", sys.argv[1])
    offline = importlib.util.module_from_spec(spec); spec.loader.exec_module(offline)
    receipt = pathlib.Path(sys.argv[2])
    before = offline.validate_provider_denial(receipt)
    receipt.write_text("attempted")
    after = offline.validate_provider_denial(receipt)
    print(json.dumps({"before":before,"after":after}))
    '''

    {output, 0} =
      System.cmd("python3", ["-c", program, Path.join(root, "scripts/check/offline.py"), receipt],
        stderr_to_stdout: true
      )

    result = Jason.decode!(String.trim(output))
    assert result["before"] == []
    assert result["after"] == ["provider denial was bypassed during offline execution"]
  end

  test "Gitless binding requires and verifies outer-owned copied-input provenance" do
    root = Path.expand("../..", __DIR__)

    fixture =
      Path.join(System.tmp_dir!(), "gitless-binding-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(fixture, "priv/kogen"))
    File.write!(Path.join(fixture, "input.txt"), "candidate bytes\n")
    File.write!(Path.join(fixture, "mix.lock"), "lock\n")
    File.write!(Path.join(fixture, "priv/kogen/test-reliability.yaml"), "catalog\n")
    File.write!(Path.join(fixture, "priv/kogen/verification_targets.yaml"), "targets\n")
    on_exit(fn -> File.rm_rf(fixture) end)

    program = ~S'''
    import importlib.util, json, os, pathlib, sys
    spec = importlib.util.spec_from_file_location("offline", sys.argv[1])
    offline = importlib.util.module_from_spec(spec); spec.loader.exec_module(offline)
    root = pathlib.Path(sys.argv[2]); digest = offline.source_manifest_sha256(root)
    base = {"HEX_OFFLINE":"1", "KOGEN_CHECK_GIT":"definitely-must-not-run-git"}
    def outcome(env):
      try: return {"ok": offline.receipt_bindings(root, env, "attempt")}
      except Exception as error: return {"error": str(error)}
    missing = outcome(base)
    valid_env = dict(base, KOGEN_OFFLINE_SOURCE_REVISION="outer-revision",
      KOGEN_OFFLINE_CANDIDATE_SHA256=digest,
      KOGEN_OFFLINE_SOURCE_MANIFEST_SHA256=digest)
    valid = outcome(valid_env)
    (root / "untracked.txt").write_text("new consumed bytes")
    invalidated = outcome(valid_env)
    print(json.dumps({"digest":digest,"missing":missing,"valid":valid,
                      "invalidated":invalidated}))
    '''

    {output, 0} =
      System.cmd("python3", ["-c", program, Path.join(root, "scripts/check/offline.py"), fixture],
        stderr_to_stdout: true
      )

    result = Jason.decode!(String.trim(output))
    assert result["missing"]["error"] =~ "Gitless receipt provenance missing"
    assert result["valid"]["ok"]["provenance"] == "outer-owner"
    assert result["valid"]["ok"]["candidate_sha256"] == result["digest"]
    assert result["invalidated"]["error"] =~ "copied-input manifest does not match"
  end
end
