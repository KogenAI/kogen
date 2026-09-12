Code.require_file("../support/dependency_fixture.ex", __DIR__)

defmodule Kogen.ColdOfflineTest do
  use ExUnit.Case, async: true

  # Only the outer verification owner runs this acceptance step. The nested
  # complete offline recipe excludes :live, including this driver itself.
  @moduletag :live
  @moduletag timeout: 300_000

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
          "--exclude=.kogen/intents",
          "--exclude=.kogen/build.lock",
          root <> "/",
          fixture <> "/"
        ],
        stderr_to_stdout: true
      )

    assert copy_status == 0, copy_output
    Kogen.DependencyFixture.copy!(Path.join(root, "deps"), Path.join(fixture, "deps"))
    build_path = Path.join(fixture, "_build/cold")
    refute File.exists?(build_path)

    File.write!(Path.join(log_dir, "conditions.txt"), """
    Source: #{root}
    Fixture: #{fixture}
    MIX_BUILD_PATH: _build/cold (fixture-local, #{build_path})
    Cache initially absent: true
    Dependencies: installed sources copied privately without build caches; no downloads
    Owner: outer live verification; nested recipe excludes all live cases
    """)

    {output, status} =
      System.cmd("make", ["check"],
        cd: fixture,
        env: [
          # Resolve from the child's physical cwd: macOS TMPDIR may use /var
          # while Rebar sees /private/var, breaking its relative header links.
          {"MIX_BUILD_PATH", "_build/cold"},
          {"HEX_OFFLINE", "1"},
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
end
