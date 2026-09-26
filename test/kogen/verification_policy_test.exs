defmodule Kogen.VerificationPolicyTest do
  use ExUnit.Case, async: true

  alias Kogen.VerificationPolicy

  @targets ["check", "live", "fixture_gate"]

  test "the production PreToolUse policy blocks every covered explicit gate before fake dispatch" do
    in_policy_fixture!(fn dir ->
      for command <- [
            "make check",
            "make 'fixture_gate'",
            "make -j check",
            "make --jobs check",
            "KOGEN_ROLE=reviewer /usr/bin/make -C . -j 2 live fixture_gate",
            "make harmless; make check",
            "echo safe && make -f Makefile fixture_gate",
            "make harmless | make check",
            "make harmless\nmake check",
            ".codex/hooks/check.sh",
            "./.codex/hooks/check.sh",
            "sh .codex/hooks/check.sh",
            "bash -e ./.codex/hooks/check.sh",
            "zsh #{Path.join(dir, ".codex/hooks/check.sh")}"
          ] do
        refute dispatches?(dir, command), "unexpected dispatch for #{inspect(command)}"
        refute File.exists?(Path.join(dir, "dispatched")), "a blocked command reached dispatch"
      end
    end)
  end

  test "focused tests and lookalikes reach the same fake dispatcher" do
    in_policy_fixture!(fn dir ->
      for command <- [
            "mix test test/kogen/intent_test.exs",
            "echo 'make check'",
            "cat README.md",
            "make harmless",
            "make -I check harmless",
            "make --include-dir check harmless"
          ] do
        assert dispatches?(dir, command), "expected dispatch for #{inspect(command)}"
      end
    end)
  end

  test "missing policy data and invalid Bash input deny before fake dispatch" do
    in_policy_fixture!(fn dir ->
      refute dispatches?(dir, "make check", [])
      refute dispatches?(dir, nil)

      # No target name is special any more (`policy_targets/0` no longer
      # requires the hardcoded check/live pair), so an unset or invalid
      # targets list is still what makes this deny, not the target names.
      refute dispatches_with_environment?(dir, "make check", [
               {"KOGEN_ROLE", "developer"},
               {"KOGEN_PROJECT_ROOT", dir}
             ])

      refute dispatches_with_environment?(dir, ".codex/hooks/check.sh", [
               {"KOGEN_ROLE", "developer"},
               {"KOGEN_VERIFICATION_TARGETS", Jason.encode!(@targets)},
               {"KOGEN_PROJECT_ROOT", Path.join(dir, "not-the-project")}
             ])

      refute File.exists?(Path.join(dir, "dispatched"))
    end)
  end

  test "Build-side policy has fixed check/live ownership and validates hook registration" do
    assert VerificationPolicy.normalized_targets(["fixture_gate", "check", "fixture_gate"]) ==
             ["fixture_gate", "check"]

    assert VerificationPolicy.normalized_targets(["test"]) == ["test"]

    in_policy_fixture!(fn dir ->
      assert VerificationPolicy.preflight(["check", "fixture_gate"], dir) ==
               :ok

      # Preflight no longer needs the bootstrap Stop script at all: the guard
      # (verification_policy.py) and its PreToolUse registration are enough,
      # so a follow-up Intent can delete `.codex/hooks/check.sh`.
      File.rm!(Path.join(dir, ".codex/hooks/check.sh"))

      assert VerificationPolicy.preflight(["check", "fixture_gate"], dir) ==
               :ok

      File.rm!(Path.join(dir, ".codex/hooks/verification_policy.py"))

      assert {:error, reason} =
               VerificationPolicy.preflight(["check"], dir)

      assert reason =~ "required verification policy file"

      File.cp!(
        Path.join(root_for_test(), ".codex/hooks/verification_policy.py"),
        Path.join(dir, ".codex/hooks/verification_policy.py")
      )

      File.write!(
        Path.join(dir, ".codex/hooks.json"),
        ~s({"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"echo verification_policy.py"}]}]}})
      )

      assert {:error, registration_reason} =
               VerificationPolicy.preflight(["check"], dir)

      assert registration_reason =~ "verification-policy hook is not registered"
    end)
  end

  test "the guard blocks a renamed catalog gate with no hardcoded check/live pair" do
    in_policy_fixture!(fn dir ->
      refute dispatches_with_environment?(dir, "make test", [
               {"KOGEN_ROLE", "developer"},
               {"KOGEN_VERIFICATION_TARGETS", Jason.encode!(["test"])},
               {"KOGEN_PROJECT_ROOT", dir}
             ])

      assert dispatches_with_environment?(dir, "make check", [
               {"KOGEN_ROLE", "developer"},
               {"KOGEN_VERIFICATION_TARGETS", Jason.encode!(["test"])},
               {"KOGEN_PROJECT_ROOT", dir}
             ])
    end)
  end

  test "VerificationPolicy.environment names the Candidate in KOGEN_PROJECT_ROOT" do
    candidate = "/tmp/kogen candidate root"
    env = VerificationPolicy.environment(@targets, candidate)
    assert {"KOGEN_PROJECT_ROOT", ^candidate} = List.keyfind(env, "KOGEN_PROJECT_ROOT", 0)
  end

  test "preflight(targets, candidate_root) reads the Candidate's own hook files, independent of control" do
    control = fixture_pair_dir("control")
    candidate = fixture_pair_dir("candidate")
    populate_policy_fixture!(control)
    populate_policy_fixture!(candidate)

    assert VerificationPolicy.preflight(["check"], control) == :ok
    assert VerificationPolicy.preflight(["check"], candidate) == :ok

    # The Candidate's registration is broken; control's stays intact. Passing
    # the Candidate root explicitly must fail even though control passes.
    File.write!(
      Path.join(candidate, ".codex/hooks.json"),
      ~s({"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"echo not-registered"}]}]}})
    )

    assert VerificationPolicy.preflight(["check"], control) == :ok
    assert {:error, reason} = VerificationPolicy.preflight(["check"], candidate)
    assert reason =~ "verification-policy hook is not registered"

    # And the reverse: break control's registration, the Candidate's own
    # copy (read explicitly from the Candidate root) still passes.
    File.write!(
      Path.join(control, ".codex/hooks.json"),
      ~s({"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"echo not-registered"}]}]}})
    )

    File.write!(
      Path.join(candidate, ".codex/hooks.json"),
      File.read!(Path.join(root_for_test(), ".codex/hooks.json"))
    )

    assert {:error, _reason} = VerificationPolicy.preflight(["check"], control)
    assert VerificationPolicy.preflight(["check"], candidate) == :ok
  end

  # Behavior, not bytes: a hook edit is free to change so long as (1) every
  # registered PreToolUse Bash command still resolves to a real script on
  # disk, (2) the command Kogen.VerificationPolicy requires is the one
  # registered for PreToolUse Bash in both the Codex and Claude Code harness
  # configs, and (3) every Python hook still compiles. The behavior tests
  # above stay the real protection: a hook edit that lets a gate through
  # fails them regardless of what this test asserts.
  test "every registered PreToolUse Bash command resolves to an existing script, matches VerificationPolicy's required command in both harness configs, and every Python hook compiles" do
    root = root_for_test()

    # `preflight/2` on the tracked Candidate proves the command registered in
    # `.codex/hooks.json` is exactly the one `Kogen.VerificationPolicy`'s own
    # registration check requires (`registered_hook/1`, unchanged by this
    # Intent) — without this test pinning that literal itself.
    assert VerificationPolicy.preflight(["check"], root) == :ok

    codex_hooks = root |> Path.join(".codex/hooks.json") |> File.read!() |> Jason.decode!()
    codex_command = pretooluse_bash_command(codex_hooks)
    assert is_binary(codex_command), ".codex/hooks.json: no PreToolUse Bash command is registered"

    claude_settings =
      root |> Path.join("priv/kogen/claude_code/settings.json") |> File.read!() |> Jason.decode!()

    claude_command = pretooluse_bash_command(claude_settings)

    assert is_binary(claude_command),
           "priv/kogen/claude_code/settings.json: no PreToolUse Bash command is registered"

    assert claude_command == codex_command,
           "the two harness configs register different PreToolUse Bash commands"

    for {label, command} <- [{"codex", codex_command}, {"claude", claude_command}] do
      resolved = resolve_command_script(root, command)

      assert resolved && File.regular?(resolved),
             "#{label} config: #{inspect(command)} does not resolve to an existing script"
    end

    for path <- hook_scripts(root), String.ends_with?(path, ".py") do
      absolute = Path.join(root, path)

      # A syntax check that writes no bytecode (`py_compile` writes a
      # `__pycache__` even under `-B`).
      check = "import sys; compile(open(sys.argv[1]).read(), sys.argv[1], 'exec')"

      assert {_output, 0} =
               System.cmd("python3", ["-B", "-c", check, absolute], stderr_to_stdout: true)
    end
  end

  test "a fixture copy of the hooks stays valid with a comment added to a hook script" do
    in_full_hook_fixture!(fn dir ->
      script = Path.join(dir, ".codex/hooks/verification_policy.py")
      File.write!(script, "# a harmless comment\n" <> File.read!(script))

      assert VerificationPolicy.preflight(["check"], dir) == :ok
      assert dispatches?(dir, "cat README.md")
      refute dispatches?(dir, "make check")
    end)
  end

  test "a fixture copy fails when the hook stops blocking make check" do
    in_full_hook_fixture!(fn dir ->
      script = Path.join(dir, ".codex/hooks/verification_policy.py")

      weakened =
        String.replace(
          File.read!(script),
          "def prohibited(argv, targets, root):",
          "def prohibited(argv, targets, root):\n    return False  # weakened\n"
        )

      assert weakened != File.read!(script)
      File.write!(script, weakened)

      assert dispatches?(dir, "make check"),
             "a weakened hook must let make check reach fake dispatch"
    end)
  end

  test "a fixture copy fails when the hook's PreToolUse registration is removed" do
    in_full_hook_fixture!(fn dir ->
      File.write!(
        Path.join(dir, ".codex/hooks.json"),
        Jason.encode!(%{"hooks" => %{}})
      )

      assert {:error, reason} = VerificationPolicy.preflight(["check"], dir)
      assert reason =~ "verification-policy hook is not registered"
    end)
  end

  test "a fixture copy fails when the registered script is missing" do
    in_full_hook_fixture!(fn dir ->
      File.rm!(Path.join(dir, ".codex/hooks/verification_policy.py"))

      assert {:error, reason} = VerificationPolicy.preflight(["check"], dir)
      assert reason =~ "required verification policy file"
    end)
  end

  defp in_full_hook_fixture!(fun) do
    in_policy_fixture!(fn dir ->
      root = root_for_test()

      File.mkdir_p!(Path.join(dir, "priv/kogen/claude_code"))

      File.cp!(
        Path.join(root, "priv/kogen/claude_code/settings.json"),
        Path.join(dir, "priv/kogen/claude_code/settings.json")
      )

      fun.(dir)
    end)
  end

  defp pretooluse_bash_command(hooks) do
    hooks
    |> get_in(["hooks", "PreToolUse"])
    |> Enum.find_value(fn
      %{"matcher" => "Bash", "hooks" => entries} ->
        Enum.find_value(entries, fn
          %{"type" => "command", "command" => command} -> command
          _ -> nil
        end)

      _ ->
        nil
    end)
  end

  # The registered command runs its script through an interpreter with a
  # `$(git rev-parse --show-toplevel)`-relative path, never a bare literal
  # path, so resolving it means expanding that shell expression from the
  # Candidate root, the same way the harness would when it dispatches the
  # hook.
  defp resolve_command_script(root, command) do
    case Regex.run(~r/"([^"]+)"\s*\z/, command) do
      [_, quoted] ->
        {resolved, 0} = System.cmd("sh", ["-c", "echo \"#{quoted}\""], cd: root)
        String.trim(resolved)

      _ ->
        nil
    end
  end

  defp hook_scripts(root) do
    root
    |> Path.join(".codex/hooks/**")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.reject(&String.contains?(&1, "__pycache__"))
    |> Enum.map(&Path.relative_to(&1, root))
  end

  defp fixture_pair_dir(label) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "kogen-policy-pair-#{label}-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(dir, ".codex/hooks"))
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp populate_policy_fixture!(dir) do
    root = root_for_test()

    File.cp!(Path.join(root, ".codex/hooks.json"), Path.join(dir, ".codex/hooks.json"))

    File.cp!(
      Path.join(root, ".codex/hooks/verification_policy.py"),
      Path.join(dir, ".codex/hooks/verification_policy.py")
    )

    File.chmod!(Path.join(dir, ".codex/hooks/verification_policy.py"), 0o755)
    File.mkdir_p!(Path.join(dir, "deps"))
  end

  defp dispatches?(dir, command, targets \\ @targets) do
    dispatches_with_environment?(
      dir,
      command,
      [{"KOGEN_ROLE", "developer"} | VerificationPolicy.environment(targets, dir)]
    )
  end

  defp dispatches_with_environment?(dir, command, environment) do
    marker = Path.join(dir, "dispatched")
    File.rm(marker)

    input =
      if is_binary(command),
        do: Jason.encode!(%{"tool_name" => "Bash", "tool_input" => %{"command" => command}}),
        else: Jason.encode!(%{"tool_name" => "Bash", "tool_input" => %{}})

    input_path = Path.join(dir, "policy-input.json")
    File.write!(input_path, input)

    {output, 0} =
      System.cmd(
        "sh",
        [
          "-c",
          "python3 \"$1\" < \"$2\"",
          "--",
          Path.join(dir, ".codex/hooks/verification_policy.py"),
          input_path
        ],
        cd: dir,
        env: environment
      )

    if output == "" do
      File.write!(marker, "fake dispatcher ran\n")
      true
    else
      assert output =~ "permissionDecision"
      false
    end
  end

  defp in_policy_fixture!(fun) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "kogen-policy-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(dir, ".codex/hooks"))
    on_exit(fn -> File.rm_rf(dir) end)
    root = root_for_test()

    File.cp!(Path.join(root, ".codex/hooks.json"), Path.join(dir, ".codex/hooks.json"))

    File.cp!(
      Path.join(root, ".codex/hooks/verification_policy.py"),
      Path.join(dir, ".codex/hooks/verification_policy.py")
    )

    File.write!(Path.join(dir, ".codex/hooks/check.sh"), "#!/bin/sh\n")
    File.chmod!(Path.join(dir, ".codex/hooks/verification_policy.py"), 0o755)
    # Build admission copies control deps/ into each Candidate.
    File.mkdir_p!(Path.join(dir, "deps"))
    {_out, 0} = System.cmd("git", ["init", "-q", "-b", "main"], cd: dir)
    fun.(dir)
  end

  defp root_for_test, do: Path.expand("../..", __DIR__)
end
