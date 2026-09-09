defmodule Kogen.LiveTest do
  @moduledoc """
  Real-provider `make live` only (never part of `make check`): direct
  `Kogen.Harness` probes against the real `codex` CLI (session identity,
  exact `Codex resume`, a schema-valid Reviewer Verdict), using the configured
  real models from the tracked `.kogen/config.yaml`. Cheap, fast,
  infrastructure-level evidence for the primitives the full real
  Shape-to-Commit lifecycle in `test/kogen/live_shape_to_build_test.exs`
  builds on.
  """
  use ExUnit.Case, async: false

  @moduletag :live
  @moduletag timeout: 600_000

  test "developer session identity, exact resume, and a schema-valid reviewer verdict" do
    {:ok, config} = Kogen.Intent.read_config()
    project_root = File.cwd!()
    log_dir = primitive_log_dir(project_root)
    fixture = primitive_fixture(project_root)

    setup_fixture(project_root, fixture)
    File.write!(Path.join(log_dir, "fixture-path.txt"), fixture <> "\n")

    previous_raw_log_dir = System.get_env("KOGEN_RAW_LOG_DIR")
    System.put_env("KOGEN_RAW_LOG_DIR", log_dir)

    on_exit(fn ->
      restore_env("KOGEN_RAW_LOG_DIR", previous_raw_log_dir)
      File.rm_rf!(fixture)
    end)

    File.cd!(fixture, fn ->
      assert {:ok, %{session_id: session_id, result: result}} =
               Kogen.Harness.launch_developer(
                 "Reply with exactly the word PROBEOK and nothing else. Do not use any tools.",
                 config.developer.model,
                 config.developer.effort
               )

      # `codex exec --json` settles a turn with `turn.completed`; it does not
      # emit the legacy Claude-style `result` event. Keep this primitive probe
      # tied to the event that the Harness actually uses to establish settlement.
      assert result["type"] == "turn.completed"
      assert is_map(result["usage"])

      assert {:ok, %{session_id: ^session_id}} =
               Kogen.Harness.resume_developer(
                 session_id,
                 "Reply with exactly the word RESUMEOK and nothing else. Do not use any tools.",
                 config.developer.model,
                 config.developer.effort
               )

      assert {:ok, %{verdict: verdict, findings: findings, session_id: reviewer_session_id}} =
               Kogen.Harness.launch_reviewer(
                 "This is a schema probe, not a real review. Answer with verdict=accept and " <>
                   "findings=[\"ok\"]. Do not use any tools.",
                 config.reviewer.model,
                 config.reviewer.effort
               )

      assert verdict in ["accept", "rework"]
      assert is_list(findings)
      assert is_binary(reviewer_session_id)
      assert reviewer_session_id != session_id
    end)
  end

  defp primitive_log_dir(project_root) do
    dir =
      Path.join(
        project_root,
        ".kogen/runtime/live-evidence/primitives-#{System.system_time(:nanosecond)}"
      )

    File.mkdir_p!(dir)
    dir
  end

  defp primitive_fixture(project_root) do
    runtime_root = Path.join(project_root, ".kogen/runtime/live-primitives")
    File.mkdir_p!(runtime_root)
    Path.join(runtime_root, "fixture-#{System.system_time(:nanosecond)}")
  end

  defp setup_fixture(project_root, fixture) do
    hooks_dir = Path.join(fixture, ".codex/hooks")
    File.mkdir_p!(hooks_dir)

    File.cp!(
      Path.join(project_root, ".codex/hooks.json"),
      Path.join(fixture, ".codex/hooks.json")
    )

    File.cp!(Path.join(project_root, ".codex/hooks/check.sh"), Path.join(hooks_dir, "check.sh"))

    File.cp!(
      Path.join(project_root, ".codex/hooks/verification_policy.py"),
      Path.join(hooks_dir, "verification_policy.py")
    )

    File.chmod!(Path.join(hooks_dir, "check.sh"), 0o755)
    File.write!(Path.join(fixture, "Makefile"), ".PHONY: check\ncheck:\n\t@true\n")
    File.write!(Path.join(fixture, "README.md"), "Live primitive fixture\n")

    env = [
      {"GIT_AUTHOR_NAME", "Kogen Fixture"},
      {"GIT_AUTHOR_EMAIL", "kogen-fixture@example.invalid"},
      {"GIT_COMMITTER_NAME", "Kogen Fixture"},
      {"GIT_COMMITTER_EMAIL", "kogen-fixture@example.invalid"}
    ]

    {_out, 0} = System.cmd("git", ["init", "-q", "-b", "main"], cd: fixture)
    {_out, 0} = System.cmd("git", ["add", "-A"], cd: fixture)

    {_out, 0} =
      System.cmd("git", ["commit", "-q", "-m", "fixture baseline"], cd: fixture, env: env)
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
