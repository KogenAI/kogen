Code.require_file(Path.expand("../support/integration_helpers.ex", __DIR__))

defmodule Kogen.Integration.StagesTest do
  use ExUnit.Case, async: true, group: :installed_release
  alias Kogen.{Config, Intent, Run}
  alias Kogen.Integration.{FakeProvider, Helpers}
  @moduletag :integration
  @moduletag timeout: 300_000

  setup_all do
    suite = Helpers.setup_suite!()
    on_exit(fn -> Helpers.cleanup_suite(suite) end)
    {:ok, suite: suite}
  end

  defp call(name, args), do: {:function, name, args}
  defp write(text), do: call("write_file", %{"path" => "app.txt", "content" => text <> "\n"})
  defp finish, do: call("finish", %{"summary" => "Verify"})
  defp stop, do: {:http, 400, %{"error" => %{"message" => "local fixture stop"}}}
  defp review, do: call("submit_review", %{"verdict" => "approve", "findings" => []})

  defp fixture(suite, checks, script, opts \\ []) do
    c = Helpers.project!(suite, [], staged_intent: false)
    on_exit(fn -> Helpers.cleanup_case(c) end)
    config = Config.load!(c.repo)
    trace = Path.join(c.root, "setup-trace")

    setup =
      "test ! -f .kogen/local/warm || exit 26; touch .kogen/local/warm; printf '%s\\n' \"$PWD\" >> #{Kogen.Init.shell_quote(trace)}"

    File.write!(
      Path.join(c.repo, Config.path()),
      Config.render(%{
        setup: [setup],
        fix: [],
        checks: Keyword.get(opts, :whole_checks, []),
        protect: [],
        acceptance: %{run: config.acceptance_run, steps_dir: config.steps_dir}
      })
    )

    {_, 0} = Helpers.git!(c, ["commit", "-qm", "Configure fresh setup", "--", Config.path()])

    plan = %{
      "version" => 1,
      "stages" => [
        %{
          "id" => "foundation",
          "title" => "Foundation",
          "goal" => "First runnable section",
          "checks" => checks
        },
        %{
          "id" => "surface",
          "title" => "Surface",
          "goal" => "Integrated section",
          "checks" => ["true"]
        }
      ]
    }

    md = Path.join(c.repo, Intent.intent_md("fixture"))
    File.write!(md, File.read!(md) <> "\n## Stages\n```json\n#{JSON.encode!(plan)}\n```\n")
    {card, 5} = Helpers.run_kogen(c, ["intent", "approve", "fixture"])
    [_, hash] = Regex.run(~r/SHA-256: ([a-f0-9]{64})/, card)
    {_, 0} = Helpers.run_kogen(c, ["intent", "approve", "fixture", hash])
    FakeProvider.append(c.server, script)
    {c, trace}
  end

  defp checkpoint(c) do
    {out, 0} = Helpers.run_kogen(c, ["context"])
    id = JSON.decode!(out)["data"]["last_built"]["run_id"]
    path = Path.join([c.repo, ".kogen/local/runs", id, "checkpoint.json"])
    {:ok, doc, b} = Run.decode_checkpoint(File.read!(path))
    {path, doc, b}
  end

  test "stage scratch mutations are red, ordered red stops commands, fresh setup and milestone custody survive Resume",
       %{suite: suite} do
    checks = [
      "if grep -qx mutate app.txt; then printf 'scratch mutation\\n' > app.txt; fi; if grep -qx red app.txt; then echo scoped-red; exit 23; fi",
      "echo later-command"
    ]

    {c, trace} =
      fixture(suite, checks, [
        write("mutate"),
        finish(),
        write("red"),
        finish(),
        write("ready"),
        finish(),
        stop()
      ])

    {out, 4} = Helpers.run_kogen(c, ["intent", "build", "fixture"])
    assert out =~ "stage foundation gate failed"
    {cp, doc, b} = checkpoint(c)
    assert Enum.map(b.stage_evidence, & &1.green) == [false, false, true]
    [mutated, red, green] = b.stage_evidence
    assert mutated.moved == ["app.txt"]
    assert mutated.failing == []
    assert red.not_run == ["stage-foundation-2"]
    assert red.failing == ["stage-foundation-1"]
    assert hd(red.checks).output =~ "scoped-red"
    assert green.clean and green.green

    assert b.stage_progress == %{
             "total" => 2,
             "completed" => ["foundation"],
             "active" => "surface",
             "phase" => "stage"
           }

    assert File.read!(Path.join(c.repo, "app.txt")) == "ready\n"
    assert length(String.split(File.read!(trace), "\n", trim: true)) == 5
    {inspect_out, 0} = Helpers.run_kogen(c, ["intent", "inspect", b.run.id, "--json"])
    assert JSON.decode!(inspect_out)["data"]["stage_progress"] == b.stage_progress
    original_result = File.read!(Path.join(Path.dirname(cp), "result.json"))
    original_cp = File.read!(cp)
    n = length(FakeProvider.provider_requests(c.server))
    # Corrupt navigation or its bound proof, never reinterpret it as unstaged.
    for changed <- [
          %{b | stage_progress: nil},
          put_in(b.stage_progress["completed"], []),
          put_in(b.stage_progress["active"], "foundation"),
          Map.update!(b, :stage_evidence, fn [e | rest] ->
            [%{e | tree: String.duplicate("0", 40)} | rest]
          end)
        ] do
      File.write!(
        cp,
        JSON.encode!(Map.put(doc, "state", Base.encode64(:erlang.term_to_binary(changed))))
      )

      before = File.read!(cp)
      {refusal, 1} = Helpers.run_kogen(c, ["intent", "resume", b.run.id])
      assert refusal =~ "resume_refused"
      assert File.read!(cp) == before
      assert length(FakeProvider.provider_requests(c.server)) == n
      assert File.read!(Path.join(Path.dirname(cp), "result.json")) == original_result
    end

    File.write!(cp, original_cp)
    FakeProvider.append(c.server, [finish(), review()])
    {out, 0} = Helpers.run_kogen(c, ["intent", "resume", b.run.id])
    assert out =~ "stage surface gate passed"
    refute out =~ "stage foundation gate passed"
    assert File.read!(Path.join(Path.dirname(cp), "result.json")) == original_result
    assert length(String.split(File.read!(trace), "\n", trim: true)) == 7
    assert File.exists?(Path.join(c.repo, ".kogen/local/warm"))
  end

  defp assert_phase_refused(c, trace, phases) do
    {cp, doc, b} = checkpoint(c)
    original_cp = File.read!(cp)
    result = Path.join(Path.dirname(cp), "result.json")
    approval = Intent.approval_path(c.repo, "fixture")

    before =
      {File.read!(result), File.read(approval), File.read!(b.git_index),
       File.read!(Path.join(c.repo, "app.txt")), Helpers.git!(c, ["rev-parse", "HEAD"]),
       File.read!(trace)}

    requests = length(FakeProvider.provider_requests(c.server))

    for phase <- phases do
      changed = put_in(b.stage_progress["phase"], phase)

      damaged =
        doc
        |> Map.put("stage_progress", changed.stage_progress)
        |> Map.put("state", Base.encode64(:erlang.term_to_binary(changed)))

      File.write!(cp, JSON.encode!(damaged))
      damaged_bytes = File.read!(cp)
      {out, 1} = Helpers.run_kogen(c, ["intent", "resume", b.run.id])
      assert out =~ "resume_refused"
      assert File.read!(cp) == damaged_bytes

      assert {File.read!(result), File.read(approval), File.read!(b.git_index),
              File.read!(Path.join(c.repo, "app.txt")), Helpers.git!(c, ["rev-parse", "HEAD"]),
              File.read!(trace)} == before

      assert length(FakeProvider.provider_requests(c.server)) == requests
    end

    File.write!(cp, original_cp)
    b
  end

  test "Resume refuses phase claims inconsistent with final work, reviewer ownership or landing",
       %{suite: suite} do
    {c, trace} =
      fixture(suite, ["true"], [write("broken"), finish(), finish(), stop()],
        whole_checks: [%{name: "whole", run: "! grep -qx broken app.txt"}]
      )

    {_, 4} = Helpers.run_kogen(c, ["intent", "build", "fixture"])
    final = assert_phase_refused(c, trace, ["review", "landed"])
    assert final.stage_progress["phase"] == "final"
    assert final.continuation.stage == :builder

    FakeProvider.append(c.server, [write("ready"), finish(), stop()])
    {_, 4} = Helpers.run_kogen(c, ["intent", "resume", final.run.id])
    reviewer = assert_phase_refused(c, trace, ["final", "landed"])
    assert reviewer.stage_progress["phase"] == "review"
    assert reviewer.continuation.stage == :review

    FakeProvider.append(c.server, [review()])
    {_, 0} = Helpers.run_kogen(c, ["intent", "resume", reviewer.run.id])
    landed = assert_phase_refused(c, trace, ["final", "review"])
    assert landed.stage_progress["phase"] == "landed"
    {out, 0} = Helpers.run_kogen(c, ["intent", "resume", landed.run.id])
    assert out =~ "already landed"
  end

  test "interrupting a stage gate retains no completed evidence and Resume reruns fresh setup and commands",
       %{suite: suite} do
    marker = Kogen.tmp_path("stage-interrupted-marker")
    on_exit(fn -> File.rm(marker) end)
    quoted = Kogen.Init.shell_quote(marker)

    {c, trace} =
      fixture(
        suite,
        ["if ! test -f #{quoted}; then touch #{quoted}; sleep 600; fi", "echo complete"],
        [write("candidate"), finish(), stop()]
      )

    port = Helpers.start_kogen(c, ["intent", "build", "fixture"])
    Helpers.wait_for_file!(marker)
    Helpers.signal!(c, port, "INT")
    {out, 130} = Helpers.await_exit(port, "", 60_000)
    assert out =~ "interrupted"
    {cp, _, b} = checkpoint(c)
    assert b.continuation.stage == :builder_verify
    assert b.stage_evidence == []
    assert b.stage_progress["completed"] == []
    old = File.read!(Path.join(Path.dirname(cp), "result.json"))
    {out, 4} = Helpers.run_kogen(c, ["intent", "resume", b.run.id])
    assert out =~ "stage foundation gate passed"
    {_, _, resumed} = checkpoint(c)
    assert resumed.stage_progress["completed"] == ["foundation"]
    assert length(resumed.stage_evidence) == 1
    assert length(String.split(File.read!(trace), "\n", trim: true)) == 4
    assert File.read!(Path.join(Path.dirname(cp), "result.json")) == old
  end
end
