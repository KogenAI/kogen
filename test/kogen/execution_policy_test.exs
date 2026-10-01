defmodule Kogen.ExecutionPolicyTest do
  use ExUnit.Case, async: true

  # Resolved from this file, never the shared VM's mutable working directory.
  @root Path.expand("../..", __DIR__)
  @config_path Path.join(@root, ".kogen/config.yaml")

  # The controller renders the policy from its control checkout. Changing the
  # VM-wide working directory for that raced concurrently loading test files
  # (a `__DIR__`-relative `Code.require_file` failed with :enoent).
  test "a named policy root is read without changing the working directory" do
    {:ok, config} = Kogen.Intent.read_config(@config_path)
    root = Path.join(System.tmp_dir!(), "kogen-policy-root-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    source = File.read!(Path.join(@root, "priv/kogen/prompts/execution-policy.md"))
    File.mkdir_p!(Path.join(root, "priv/kogen/prompts"))

    File.write!(
      Path.join(root, "priv/kogen/prompts/execution-policy.md"),
      "Named control policy marker.\n" <> source
    )

    cwd = File.cwd!()
    policy = Kogen.ExecutionPolicy.render(config, "developer", root)
    assert File.cwd!() == cwd
    assert policy =~ "Named control policy marker."

    refute Kogen.ExecutionPolicy.render(config, "developer", @root) =~
             "Named control policy marker."
  end

  test "all roles receive the complete shared policy without expanding role authority" do
    {:ok, config} = Kogen.Intent.read_config(@config_path)

    for role <- ["shaping", "developer", "reviewer"] do
      policy = Kogen.ExecutionPolicy.render(config, role, @root)
      assert length(Regex.scan(~r/## Shared execution and delegation policy/, policy)) == 1
      refute policy =~ "{{"

      for obligation <- [
            "preparation, startup, cache/context transfer, coordination",
            "verification and repair all count",
            "Batch independent tools",
            "Reuse relevant helpers",
            "stopping\nconditions",
            "exclusive write ownership",
            "useful independent root work",
            "no mandatory fanout, spawn quota or automatic escalation",
            "concise advisory conclusions, source locators",
            "against actual source bytes",
            "Never reconstruct prose as an exact quote",
            "Reviewer and every child are read-only",
            "human product/UX decisions and explicit same-conversation",
            "Developer\nowns implementation and handoff within approved paths",
            "missing usage is not\nzero",
            "Unit prices or raw tokens do not establish complete-task savings",
            "same-Developer rework, fresh independent Review"
          ] do
        assert policy =~ obligation
      end
    end
  end

  test "rendered role policies keep gate ownership and retry accounting with the Build controller" do
    {:ok, config} = Kogen.Intent.read_config(@config_path)

    for role <- ["shaping", "developer", "reviewer"] do
      policy = Kogen.ExecutionPolicy.render(config, role, @root)
      compact_policy = Regex.replace(~r/\s+/, policy, " ")

      assert policy =~
               ~r/For a Build, its\s+controller alone runs exactly the approved `verified_by` targets and writes\s+their receipts/is

      assert policy =~
               ~r/No role or helper may manually run or delegate a declared\s+target, including\s+`make check`/is

      assert policy =~ "wrapper, aggregate alias"
      assert policy =~ "or substitute another gate"
      assert policy =~ "Focused non-gate checks remain"
      assert policy =~ "cannot stand in for receipts"

      assert compact_policy =~
               "Offline target, catalog and Candidate-caused `prepare` failures use `offline_retries` when present"

      assert compact_policy =~
               "legacy attempt contexts without that field fall back to `verification_retries`"

      assert compact_policy =~ "Paid provider-backed target failures use `verification_retries`"

      assert compact_policy =~
               "Terminal environment or provider failures spend neither retry budget"

      assert compact_policy =~
               "A permitted declared-target retry resumes the same Developer session"

      assert compact_policy =~
               "This class-specific retry accounting remains separate from the outer allowance, which remains reserved for settled verification"

      refute compact_policy =~ "unified Stop verification ownership"
      refute compact_policy =~ "Stop owns verification retries"
    end
  end

  test "each role template has one insertion and retains its authoritative completion contract" do
    for role <- ["shaping", "developer", "reviewer"] do
      template = File.read!(Path.join(@root, "priv/kogen/prompts/#{role}.md"))
      assert length(Regex.scan(~r/\{\{execution_policy\}\}/, template)) == 1
      refute template =~ "{{scout_model}}"
      refute template =~ "## Proactive native delegation"
    end

    assert File.read!(Path.join(@root, "priv/kogen/prompts/developer.md")) =~
             "{{verification_ownership}}"

    assert File.read!(Path.join(@root, "priv/kogen/prompts/developer.md")) =~
             "## Final Developer notes"

    assert File.read!(Path.join(@root, "priv/kogen/prompts/reviewer.md")) =~
             "You must not modify the Candidate"

    assert File.read!(Path.join(@root, "priv/kogen/prompts/reviewer.md")) =~
             "schema-valid final verdict yourself"

    assert File.read!(Path.join(@root, "priv/kogen/prompts/shaping.md")) =~
             "in this same conversation"
  end

  test "Claude Code roles name the configured Claude Code agents instead of Codex native kinds" do
    config = %{
      harness: "claude",
      shaping: %{model: "claude-opus-5-5", effort: "medium"},
      developer: %{model: "claude-opus-5-5", effort: "medium"},
      reviewer: %{model: "claude-opus-5-5", effort: "medium"},
      helpers: %{
        scout: %{model: "claude-sonnet-5", effort: "low"},
        worker: %{model: "claude-sonnet-5", effort: "medium"},
        expert: %{model: "claude-opus-5-5", effort: "high"}
      }
    }

    for role <- ["shaping", "developer", "reviewer"] do
      policy = Kogen.ExecutionPolicy.render(config, role, @root)
      assert policy =~ "- **scout:** `claude-sonnet-5` at `low`; Claude Code agent `kogen-scout`."

      assert policy =~
               "- **worker:** `claude-sonnet-5` at `medium`; Claude Code agent `kogen-worker`."

      assert policy =~
               "- **expert:** `claude-opus-5-5` at `high`; Claude Code agent `kogen-expert`."

      assert policy =~ "never to built-in agents"
      refute policy =~ "native kind"
      refute policy =~ "native agent-kind enums"
    end

    codex = Kogen.ExecutionPolicy.render(%{config | harness: "codex"}, "developer", @root)
    assert codex =~ "native kind `explorer`"
    assert codex =~ "not native agent-kind enums: use the supported kinds above."
  end

  test "each tracked route renders its own helper profiles and harness-specific delegation" do
    {:ok, claude} = Kogen.Intent.read_config(@config_path, "claude")
    {:ok, codex} = Kogen.Intent.read_config(@config_path, "codex")

    for role <- ["shaping", "developer", "reviewer"] do
      claude_policy = Kogen.ExecutionPolicy.render(claude, role, @root)
      codex_policy = Kogen.ExecutionPolicy.render(codex, role, @root)

      assert claude_policy =~
               "- **scout:** `claude-sonnet-5` at `low`; Claude Code agent `kogen-scout`."

      assert codex_policy =~ "- **scout:** `gpt-6-luna` at `low`; native kind `explorer`."
      assert codex_policy =~ "- **worker:** `gpt-6-luna` at `high`; native kind `worker`."
      assert codex_policy =~ "- **expert:** `gpt-6.1-sol` at `high`; native kind `default`."
      refute codex_policy =~ "claude-"
      refute codex_policy =~ "Claude Code agent"
      refute claude_policy =~ "gpt-"
    end

    assert Kogen.ExecutionPolicy.render(codex, "reviewer", @root) =~
             "Configured root (reviewer): `gpt-6.1-sol` at `high`."
  end

  test "rendering dispatches only on an explicit claude or codex harness" do
    {:ok, codex} = Kogen.Intent.read_config(@config_path, "codex")

    for invalid <- ["pi", "", nil] do
      assert_raise ArgumentError, ~r/unsupported harness/, fn ->
        Kogen.ExecutionPolicy.render(
          %{Map.drop(codex, [:roles, :native_helpers]) | harness: invalid},
          "developer",
          @root
        )
      end
    end

    assert_raise KeyError, fn ->
      Kogen.ExecutionPolicy.render(
        Map.drop(codex, [String.to_existing_atom("harness"), :roles, :native_helpers]),
        "developer",
        @root
      )
    end
  end

  test "hybrid roles render their own harness's native helpers and never a substituted expert" do
    {:ok, config} =
      Kogen.Intent.read_config(@config_path, "claude-dominant-adversarial-codex")

    for role <- ["shaping", "developer"] do
      policy = Kogen.ExecutionPolicy.render(config, role, @root)
      assert policy =~ "- **scout:** `claude-sonnet-5` at `low`; Claude Code agent `kogen-scout`."

      assert policy =~
               "- **worker:** `claude-sonnet-5` at `medium`; Claude Code agent `kogen-worker`."

      assert policy =~ "- **expert:** `gpt-6.1-sol` at `high` on the Codex harness"
      assert policy =~ "`mix kogen.expert`"
      refute policy =~ "kogen-expert"
      refute policy =~ "gpt-6-luna"
    end

    reviewer = Kogen.ExecutionPolicy.render(config, "reviewer", @root)
    assert reviewer =~ "Configured root (reviewer): `gpt-6.1-sol` at `high`."
    assert reviewer =~ "- **scout:** `gpt-6-luna` at `low`; native kind `explorer`."
    assert reviewer =~ "- **expert:** `gpt-6.1-sol` at `high`; native kind `default`."
    refute reviewer =~ "claude-"
    refute reviewer =~ "mix kogen.expert"

    {:ok, codex_dominant} =
      Kogen.Intent.read_config(@config_path, "codex-dominant-adversarial-claude")

    developer = Kogen.ExecutionPolicy.render(codex_dominant, "developer", @root)
    assert developer =~ "- **scout:** `gpt-6-luna` at `low`; native kind `explorer`."
    assert developer =~ "- **expert:** `claude-opus-5-5` at `high` on the Claude Code harness"
    refute developer =~ "native kind `default`"

    reviewer = Kogen.ExecutionPolicy.render(codex_dominant, "reviewer", @root)

    assert reviewer =~
             "- **expert:** `claude-opus-5-5` at `high`; Claude Code agent `kogen-expert`."
  end
end
