Code.require_file(Path.expand("../support/integration_helpers.ex", __DIR__))

defmodule Kogen.Integration.RefinementTest do
  use ExUnit.Case, async: true
  alias Kogen.{Config, Intent, Integration.FakeProvider, Integration.Helpers}
  @moduletag :integration

  setup_all do
    suite = Helpers.setup_suite!()
    on_exit(fn -> Helpers.cleanup_suite(suite) end)
    {:ok, suite: suite}
  end

  test "SHP-11 a delta changes one draft file, preserves other bytes and still needs approval", %{
    suite: suite
  } do
    context = fixture!(suite)
    path = Intent.intent_md("fixture")
    before = package(context)
    updated = String.replace(before[path], "# Preserve the fixture", "# Clarify the fixture")
    script!(context, [submission([%{"path" => path, "content" => updated}])])
    {output, status} = refine(context)
    assert status == 0, output
    assert output =~ "refined fixture"
    assert package(context) == Map.put(before, path, updated)
    refute File.exists?(Intent.approval_path(context.repo, "fixture"))
    {output, 5} = Helpers.run_kogen(context, ["intent", "build", "fixture"])
    assert output =~ "intent/not_approved"
    [_, request] = FakeProvider.provider_requests(context.server)
    assert request.json["model"] == "gpt-6.1-sol"
    assert request.json["reasoning"]["effort"] == "high"
    assert request.json["input"] |> hd() |> Map.fetch!("content") =~ before[path]
    assert [_] = Path.wildcard(Path.join(context.repo, ".kogen/local/refinements/*/result.json"))
  end

  test "SHP-11 invalid, unsupported, provider and not-ready results preserve the ready draft", %{
    suite: suite
  } do
    for kind <- [:invalid, :unsupported, :provider, :not_ready, :topology] do
      context = fixture!(suite)
      before = package(context)

      actions =
        case kind do
          :invalid ->
            List.duplicate(submission([%{"path" => "new.txt", "content" => "no"}]), 3)

          :unsupported ->
            [
              {:function, "submit_refinement",
               %{
                 "constraint" =>
                   "This needs a new step file; refinement changes existing files only."
               }}
            ]

          :provider ->
            [
              submission([
                %{
                  "path" => Intent.feature("fixture"),
                  "content" =>
                    "Feature: Fixture\n  Scenario: Undefined\n    Then a new undefined sentence\n"
                }
              ]),
              {:http, 400,
               %{"error" => %{"code" => "invalid_request_error", "message" => "fixture refusal"}}}
            ]

          :topology ->
            [
              submission([
                %{
                  "path" => Intent.intent_md("fixture"),
                  "content" =>
                    String.replace(
                      before[Intent.intent_md("fixture")],
                      "- features/steps/integration_steps.js\n",
                      ""
                    )
                }
              ])
            ]

          :not_ready ->
            List.duplicate(
              submission([
                %{
                  "path" => Intent.feature("fixture"),
                  "content" =>
                    "Feature: Fixture\n  Scenario: Undefined\n    Then a new undefined sentence\n"
                }
              ]),
              3
            )
        end

      script!(context, actions)
      {output, status} = refine(context)
      assert status != 0, output

      expected =
        case kind do
          kind when kind in [:unsupported, :topology] -> "shape/refinement_constraint"
          :provider -> "provider/"
          _ -> "shape/refinement_invalid"
        end

      assert output =~ expected

      assert package(context) == before
      refute File.exists?(Intent.approval_path(context.repo, "fixture"))

      [evidence] =
        Path.wildcard(Path.join(context.repo, ".kogen/local/refinements/*/result.json"))

      assert File.read!(evidence) =~ "outcome"
    end
  end

  test "SHP-11 rejects protected and shared step edits without changing the original package", %{
    suite: suite
  } do
    for target <- [Config.path(), "features/steps/integration_steps.js"] do
      context = fixture!(suite)

      if target != Config.path() do
        other = Path.join(context.repo, Intent.intent_md("other"))
        File.mkdir_p!(Path.dirname(other))

        File.write!(
          other,
          "# Other\nAcceptance:\n- .kogen/intents/other/acceptance.feature\n- #{target}\n"
        )
      end

      before = package(context)
      original = File.read!(Path.join(context.repo, target))

      script!(
        context,
        List.duplicate(submission([%{"path" => target, "content" => "changed"}]), 3)
      )

      {output, status} = refine(context)
      assert status == 1, output
      assert output =~ "not an exclusively owned editable draft file"
      assert package(context) == before
      assert File.read!(Path.join(context.repo, target)) == original
    end
  end

  test "SHP-11 approved drafts and stale exact hashes refuse before model requests", %{
    suite: suite
  } do
    context = Helpers.project!(suite, [], staged_intent: false)
    on_exit(fn -> Helpers.cleanup_case(context) end)
    before = package(context)
    requests = FakeProvider.provider_requests(context.server)
    {output, 5} = refine(context)
    assert output =~ "intent/refinement_approved"
    File.rm!(Intent.approval_path(context.repo, "fixture"))
    {output, 1} = refine(context, String.duplicate("0", 64))
    assert output =~ "intent/refinement_stale"
    assert package(context) == before
    assert FakeProvider.provider_requests(context.server) == requests
  end

  test "SHP-11 an external edit while refining is preserved and prevents publication", %{
    suite: suite
  } do
    context = fixture!(suite)
    before = package(context)
    path = Intent.intent_md("fixture")
    marker = Path.join(context.root, "probe-started")
    updated = String.replace(before[path], "# Preserve", "# Clarify")

    script!(context, [
      {:function, "probe", %{"command" => "touch '#{marker}' && sleep 1"}},
      submission([%{"path" => path, "content" => updated}])
    ])

    hash = hash(context)
    port = Helpers.start_kogen(context, ["intent", "refine", "fixture", hash, request!(context)])
    Helpers.wait_for_file!(marker)
    {approval_output, 3} = Helpers.run_kogen(context, ["intent", "approve", "fixture"])
    assert approval_output =~ "environment/build_running"
    refute File.exists?(Intent.approval_path(context.repo, "fixture"))
    feature = Intent.feature("fixture")
    external = before[feature] <> "\n# external edit\n"
    File.write!(Path.join(context.repo, feature), external)
    {output, status} = Helpers.await_exit(port, "", 20_000)
    assert status == 1, output
    assert output =~ "intent/refinement_stale"
    assert package(context) == Map.put(before, feature, external)
  end

  test "SHP-11 interruption during a probe preserves the ready package and retained evidence", %{
    suite: suite
  } do
    context = fixture!(suite)
    before = package(context)
    marker = Path.join(context.root, "probe-started")
    script!(context, [{:function, "probe", %{"command" => "touch '#{marker}' && sleep 10"}}])

    port =
      Helpers.start_kogen(context, [
        "intent",
        "refine",
        "fixture",
        hash(context),
        request!(context)
      ])

    Helpers.wait_for_file!(marker)
    Helpers.signal!(context, port, "INT")
    {_output, status} = Helpers.await_exit(port, "", 20_000)
    assert status == 130
    assert package(context) == before
    [evidence] = Path.wildcard(Path.join(context.repo, ".kogen/local/refinements/*/result.json"))
    assert File.read!(evidence) =~ "interrupted"
  end

  defp fixture!(suite) do
    context = Helpers.project!(suite, [], staged_intent: false)
    on_exit(fn -> Helpers.cleanup_case(context) end)
    File.rm!(Intent.approval_path(context.repo, "fixture"))
    context
  end

  defp package(context),
    do:
      Map.new(Intent.baseline(context.repo, "fixture", Config.load!(context.repo)), fn path ->
        {path, File.read!(Path.join(context.repo, path))}
      end)

  defp hash(context),
    do:
      Intent.hash(
        context.repo,
        Intent.baseline(context.repo, "fixture", Config.load!(context.repo))
      )

  defp submission(files), do: {:function, "submit_refinement", %{"files" => files}}

  defp script!(context, actions),
    do:
      Agent.update(context.server.state, fn state ->
        %{state | script: Enum.take(state.script, state.next) ++ actions}
      end)

  defp request!(context) do
    path = Path.join(context.root, "correction.txt")
    File.write!(path, "Clarify only the existing draft; preserve its executable contract.")
    path
  end

  defp refine(context, hash \\ nil),
    do:
      Helpers.run_kogen(context, [
        "intent",
        "refine",
        "fixture",
        hash || hash(context),
        request!(context)
      ])
end
