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

      refute dispatches_with_environment?(dir, "make check", [
               {"KOGEN_ROLE", "developer"},
               {"KOGEN_VERIFICATION_TARGETS", "[\"fixture_gate\"]"},
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
             ["check", "live", "fixture_gate"]

    in_policy_fixture!(fn dir ->
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
    {_out, 0} = System.cmd("git", ["init", "-q", "-b", "main"], cd: dir)
    fun.(dir)
  end

  defp root_for_test, do: Path.expand("../..", __DIR__)
end
