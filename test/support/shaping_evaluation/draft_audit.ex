defmodule Kogen.ShapingDraftAudit do
  @moduledoc false
  alias Kogen.Build.VerificationPlan
  import ExUnit.Assertions

  @cases ~w(csv-flawed csv-complete booking-flawed booking-complete csv-continuation)

  def audit!(root) do
    VerificationPlan.trace("Kogen.ShapingDraftAudit.audit!")
    intents = Map.new(@cases, &{&1, read_intent!(root, &1)})
    seed = Path.join(root, "continuation-seed")
    first = read_intent_dir!(seed, "frozen continuation seed")

    partial =
      read_intent_dir!(
        Path.join([root, "runs", "csv-continuation", "drafts-by-turn", "0"]),
        "partial continuation"
      )

    continued = intents["csv-continuation"]

    for key <- ~w(id slug shaping shaped_against) do
      assert first[key] == continued[key], "continuation changed original #{key}"
      assert first[key] == partial[key], "partial continuation changed original #{key}"
    end

    prior = Map.get(first, "shaping_continuations", [])
    visits = Map.get(continued, "shaping_continuations", [])

    assert partial["shaping_continuations"] == visits,
           "same-session clarification changed the continuation visit"

    assert length(visits) == length(prior) + 1
    assert Enum.take(visits, length(prior)) == prior
    visit = List.last(visits)
    assert visit["started"] != first["shaping"]["started"]
    assert visit["checkout"] == first["shaped_against"]
    assert visit["harness"] == first["shaping"]["harness"]

    for case_name <- @cases do
      assert_state!(root, case_name, intents[case_name])
      assert_scenarios!(root, case_name)
    end

    :ok
  end

  defp read_intent!(root, case_name) do
    dir = Path.join([root, "runs", case_name, "draft"])
    read_intent_dir!(dir, case_name)
  end

  defp read_intent_dir!(dir, case_name) do
    assert {:ok, intent} = YamlElixir.read_from_file(Path.join(dir, "intent.yaml"))
    assert is_map(intent)
    assert intent["status"] in ["draft", "unapproved"]
    refute File.exists?(Path.join(dir, "approval.md"))

    for key <- ~w(id slug title) do
      assert nonblank?(intent[key]), "#{case_name}: missing #{key}"
    end

    for key <- ~w(harness model effort started) do
      assert nonblank?(get_in(intent, ["shaping", key])), "#{case_name}: missing shaping #{key}"
    end

    for key <- ~w(branch head) do
      assert nonblank?(get_in(intent, ["shaped_against", key]))
    end

    assert is_list(intent["may_change_guarded_paths"]) and
             intent["may_change_guarded_paths"] != []

    intent
  end

  defp assert_state!(root, case_name, intent) do
    path = Path.join([root, "runs", case_name, "draft-state.json"])
    state = Jason.decode!(File.read!(path))
    visits = Map.get(intent, "shaping_continuations", [])
    assert is_list(visits)
    latest = List.last(visits) || intent["shaping"]

    assert state == %{
             "intent_id" => intent["id"],
             "baseline" => Map.take(intent["shaped_against"], ~w(branch head)),
             "visit_id" => latest["started"],
             "unapproved" => true
           },
           "#{case_name}: captured state differs from original YAML"
  end

  defp assert_scenarios!(root, case_name) do
    path = Path.join([root, "runs", case_name, "draft", "scenarios.yaml"])
    assert {:ok, scenarios} = YamlElixir.read_from_file(path)
    assert is_list(scenarios) and scenarios != []
    ids = Enum.map(scenarios, & &1["id"])
    assert ids == Enum.uniq(ids)

    Enum.each(scenarios, fn scenario ->
      for key <- ~w(id given when then wrong_result evidence) do
        assert nonblank?(scenario[key]), "#{case_name}: missing scenario #{key}"
      end

      assert is_list(scenario["verified_by"]) and scenario["verified_by"] != []
      assert Enum.all?(scenario["verified_by"], &nonblank?/1)
    end)
  end

  defp nonblank?(text) when is_binary(text), do: String.trim(text) != ""
  defp nonblank?(_value), do: false
end
