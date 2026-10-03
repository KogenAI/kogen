defmodule Kogen.E2e.BuildTest do
  use Kogen.Testkit.Case

  alias Kogen.E2e.Build
  alias Kogen.E2e.Build.Options
  alias Kogen.E2e.Build.Result
  alias Kogen.E2e.ScriptedProvider
  alias Kogen.Testkit.Git

  @moduletag :e2e
  @intent_slug "build-engine"

  setup_all do
    shared_root = Kogen.Testkit.Temp.create!()
    seed_project = Build.prepare_seed!(shared_root)
    on_exit(fn -> File.rm_rf!(shared_root) end)
    {:ok, seed_project: seed_project}
  end

  test "happy path lands a single-parent commit with the Kogen trailers", context do
    result = Build.run!(context.tmp_dir, landing_script(), options(context.seed_project))
    assert %Result{build: %{status: :landed, landed_sha: sha}, run_status: :landed} = result
    assert result.claim_released

    message = Git.git!(result.fixture.origin, ["show", "-s", "--format=%B", sha])
    assert message =~ "Kogen-Intent: #{@intent_slug}"
    assert message =~ "Kogen-Run: #{result.build.run_id}"
    assert message =~ "Kogen-Approval: #{result.fixture.approval_commit}"
    assert message =~ ~r/Kogen-Receipt: [0-9a-f]{40}/

    parents = Git.git!(result.fixture.origin, ["rev-list", "--parents", "-n", "1", sha])
    assert String.split(String.trim(parents)) == [sha, result.fixture.approved_base]
    assert Enum.any?(result.events, &(&1.event == "finished" and &1.status == "landed"))
  end

  test "a review revision runs repair and then lands", context do
    script = landing_script("revise once")
    result = Build.run!(context.tmp_dir, script, options(context.seed_project))

    assert result.build.status == :landed
    assert result.run_status == :landed
    assert result.claim_released
    assert Enum.any?(result.events, &(&1.event == "repair" and &1.reason == "review_revise"))

    reviews = Enum.count(result.events, &(&1.event == "model_stage" and &1.stage == "review"))
    assert reviews == 2
  end

  test "a persistently red acceptance fails as a candidate and releases its claim", context do
    result = Build.run!(context.tmp_dir, red_acceptance_script(), options(context.seed_project))
    fixture = result.fixture

    assert result.build.status == :failed
    assert result.build.failure.class == :candidate
    assert result.run_status == :failed
    assert result.claim_released
    approved_base = fixture.approved_base

    current_base = fixture.origin |> Git.git!(["rev-parse", "refs/heads/main"]) |> String.trim()
    assert current_base == approved_base

    assert Enum.any?(result.events, fn event ->
             event.event == "acceptance_result" and match?(%{"status" => "fail"}, event.result)
           end)
  end

  test "an origin base move during Build parks the candidate", context do
    options = %Options{seed_project: context.seed_project, move_base_on: :context}
    result = Build.run!(context.tmp_dir, landing_script(), options)
    fixture = result.fixture

    assert result.build.status == :parked
    assert result.build.landed_sha == nil
    assert result.run_status == :parked
    assert result.claim_released

    moved_base = fixture.origin |> Git.git!(["rev-parse", "refs/heads/main"]) |> String.trim()
    assert moved_base != fixture.approved_base

    parked =
      Git.git!(fixture.origin, [
        "show-ref",
        "--verify",
        "refs/kogen/parked/#{result.build.run_id}"
      ])

    assert parked =~ result.build.run_id
  end

  defp options(seed_project), do: %Options{seed_project: seed_project}

  defp landing_script do
    [
      ScriptedProvider.answer(:context, "TinyApp.value/0 is the implementation target."),
      ScriptedProvider.answer(:plan, "Update TinyApp.value/0."),
      ScriptedProvider.write(:develop, "lib/tiny_app.ex", ready_source("candidate", :ready)),
      ScriptedProvider.answer(:develop, "Done."),
      ScriptedProvider.answer(:review, review_text("accept", :accept))
    ]
  end

  defp landing_script("revise once") do
    [
      ScriptedProvider.answer(:context, "TinyApp.value/0 is the implementation target."),
      ScriptedProvider.answer(:plan, "Update TinyApp.value/0."),
      ScriptedProvider.write(:develop, "lib/tiny_app.ex", ready_source("candidate", :ready)),
      ScriptedProvider.answer(:develop, "Done."),
      ScriptedProvider.answer(:review, review_text("revise once", :revise)),
      ScriptedProvider.edit(
        :develop,
        "lib/tiny_app.ex",
        "# revision: candidate",
        "# revision: reviewed"
      ),
      ScriptedProvider.answer(:develop, "Done after repair."),
      ScriptedProvider.answer(:review, review_text("accept", :accept))
    ]
  end

  defp red_acceptance_script do
    [
      ScriptedProvider.answer(:context, "TinyApp.value/0 is the implementation target."),
      ScriptedProvider.answer(:plan, "Update TinyApp.value/0."),
      ScriptedProvider.write(:develop, "lib/tiny_app.ex", ready_source("zero", :wrong)),
      ScriptedProvider.answer(:develop, "Done."),
      ScriptedProvider.edit(:develop, "lib/tiny_app.ex", "revision: zero", "revision: one"),
      ScriptedProvider.answer(:develop, "Done after repair one."),
      ScriptedProvider.edit(:develop, "lib/tiny_app.ex", "revision: one", "revision: two"),
      ScriptedProvider.answer(:develop, "Done after repair two.")
    ]
  end

  defp ready_source(marker, value) do
    """
    defmodule TinyApp do
      # revision: #{marker}
      def value, do: :#{value}
    end
    """
  end

  defp review_text("revise once", :revise),
    do: ~s({"verdict":"revise","findings":["A1: keep a clear implementation revision marker"]})

  defp review_text(_label, :accept), do: ~s({"verdict":"accept","findings":[]})
end
