defmodule Kogen.TargetedReadinessTest do
  use ExUnit.Case, async: true

  alias Kogen.Build.VerificationPlan
  alias Kogen.Intent

  @root Path.expand("../..", __DIR__)
  @fixture_slug "readiness-rework-fixture"

  test "development selectors intersect the changed path and omit unrelated proof commands" do
    root =
      Path.join(
        System.tmp_dir!(),
        "kogen-targeted-readiness-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(root, "test/kogen"))

    File.write!(
      Path.join(root, "test/kogen/reconcile_test.exs"),
      "defmodule ReconcileTest do end\n"
    )

    on_exit(fn -> File.rm_rf(root) end)

    plan = %{
      offline_commands: [
        "mix test 'test/kogen/reconcile_scenario_test.exs'",
        "mix test 'test/kogen/unrelated_scenario_test.exs'",
        "mix test 'test/kogen/full_proof_inventory_test.exs'"
      ],
      rehearsals: ["python3 -B scripts/check/rehearsals.exs"],
      scenarios: [
        %{
          "id" => "reconcile-slice",
          "affected_paths" => ["lib/kogen/reconcile.ex"],
          "selector_commands" => ["mix test 'test/kogen/reconcile_scenario_test.exs'"]
        },
        %{
          "id" => "unrelated-slice",
          "affected_paths" => ["lib/kogen/unrelated.ex"],
          "selector_commands" => ["mix test 'test/kogen/unrelated_scenario_test.exs'"]
        },
        %{
          "id" => "proof-inventory",
          "affected_paths" => ["lib/kogen/all.ex"],
          "selector_commands" => ["mix test 'test/kogen/full_proof_inventory_test.exs'"]
        }
      ]
    }

    commands = VerificationPlan.readiness_commands(plan, ["lib/kogen/reconcile.ex"], root)

    assert "mix format" in commands
    assert "python3 -B scripts/check/changed_credo.py" in commands
    assert "mix test 'test/kogen/reconcile_scenario_test.exs'" in commands
    assert "mix test 'test/kogen/reconcile_test.exs'" in commands
    refute "mix test 'test/kogen/unrelated_scenario_test.exs'" in commands
    refute "mix test 'test/kogen/full_proof_inventory_test.exs'" in commands
    refute "python3 -B scripts/check/rehearsals.exs" in commands
  end

  test "the Developer prompt scopes local observations and hands coherent work to full controller verification" do
    template = File.read!(Path.expand("../../priv/kogen/prompts/developer.md", __DIR__))

    assert template =~ "{{readiness_scope}}"
    assert template =~ "{{readiness_commands}}"
    assert template =~ "hand off as soon as the Candidate is coherent"
    assert template =~ "Build still runs the full\nrequired verification targets"
    assert template =~ "controller receipts for that Candidate revision count;"
    assert template =~ "Do not rerun the entire proof\nselector list"
    assert template =~ "An editing helper may run an\nexact supplied focused non-gate command"
    assert template =~ ~r/The root Developer waits for\s+the helper/
    refute template =~ "Immediately before implementation, run the first command"
    refute template =~ "The controller may issue the same command list at both points"
  end

  test "rework prompt binds focused instructions to the current Candidate tree revision" do
    control = temporary_control_root!()
    candidate = temporary_git_root!()
    on_exit(fn -> File.rm_rf(candidate) end)

    approved_root = Path.join(control, ".kogen/intents/approved")
    {:ok, intent} = Intent.read(@fixture_slug, approved_root)
    {:ok, config} = Intent.read_config(Path.join(@root, ".kogen/config.yaml"))
    {:ok, candidate_revision} = Kogen.Git.candidate_id(candidate)

    # Rendering names control explicitly. It must never move this shared VM's
    # working directory: a concurrently loading test file then resolved its
    # `__DIR__`-relative Code.require_file under control and failed :enoent.
    test_pid = self()

    tracer =
      spawn_link(fn ->
        receive do
          :report ->
            {:messages, messages} = Process.info(self(), :messages)
            send(test_pid, {:cwd_changes, for({:trace, _, :call, call} <- messages, do: call)})
        end
      end)

    :erlang.trace(self(), true, [:call, :set_on_spawn, {:tracer, tracer}])
    :erlang.trace_pattern({:file, :set_cwd, 1}, true, [:global])

    prompt =
      try do
        Kogen.Build.render_developer_prompt(intent, "", ["check"], config, %{
          control: control,
          candidate: candidate,
          changed_paths: [],
          readiness_focus: "following rework feedback"
        })
      after
        :erlang.trace_pattern({:file, :set_cwd, 1}, false, [:global])
        :erlang.trace(self(), false, [:call, :set_on_spawn])
      end

    delivered = :erlang.trace_delivered(:all)
    assert_receive {:trace_delivered, :all, ^delivered}, 5_000
    send(tracer, :report)
    assert_receive {:cwd_changes, []}, 5_000

    assert prompt =~
             "revision #{candidate_revision}; changed paths: none; focus: following rework feedback"

    assert prompt =~ "Kogen's Build controller owns verification gates."
    assert prompt =~ "through delegated helpers. Focused non-gate tests remain allowed."
    assert prompt =~ ~r/An editing helper may run an\s+exact supplied focused non-gate command/

    [_, readiness_block] =
      Regex.run(~r/## Targeted development checks.*?```text\n(.*?)\n```/s, prompt)

    refute readiness_block =~ "mix test"
    refute readiness_block =~ "rehearsals"
  end

  defp temporary_control_root! do
    root =
      Path.join(
        System.tmp_dir!(),
        "kogen-readiness-control-#{System.unique_integer([:positive])}"
      )

    package = Path.join([root, ".kogen/intents/approved", @fixture_slug])
    File.mkdir_p!(package)
    on_exit(fn -> File.rm_rf(root) end)

    for path <- ["Makefile", "priv/kogen"] do
      target = Path.join(root, path)
      File.mkdir_p!(Path.dirname(target))
      File.ln_s!(Path.join(@root, path), target)
    end

    File.write!(
      Path.join(package, "intent.yaml"),
      Jason.encode!(%{
        "id" => "01960000-0000-7000-8000-000000000101",
        "slug" => @fixture_slug,
        "title" => "Readiness rework fixture",
        "may_change_guarded_paths" => ["test/kogen/**"]
      })
    )

    File.write!(
      Path.join(package, "scenarios.yaml"),
      Jason.encode!([
        %{
          "id" => "rework-readiness",
          "given" => "the Developer has a coherent Candidate",
          "when" => "the prompt is rendered for rework",
          "then" => "local observations stay distinct from controller verification",
          "wrong_result" => "focused observations are presented as gate receipts",
          "verified_by" => ["check"],
          "evidence" => "this fixture's rendered prompt",
          "proof" => %{
            "offline" => ["test/kogen/targeted_readiness_test.exs"],
            "paid_target" => "none",
            "paid_reason" => "offline-sufficient: prompt rendering fixture",
            "affected_paths" => ["test/kogen/targeted_readiness_test.exs"]
          }
        }
      ])
    )

    root
  end

  defp temporary_git_root! do
    root =
      Path.join(
        System.tmp_dir!(),
        "kogen-targeted-revision-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    assert {_, 0} = System.cmd("git", ["init", "--quiet"], cd: root)
    File.write!(Path.join(root, "base.txt"), "base\n")
    assert {_, 0} = System.cmd("git", ["add", "base.txt"], cd: root)

    assert {_, 0} =
             System.cmd(
               "git",
               [
                 "-c",
                 "user.name=Kogen Test",
                 "-c",
                 "user.email=kogen@example.test",
                 "commit",
                 "--quiet",
                 "-m",
                 "base"
               ],
               cd: root
             )

    root
  end
end
