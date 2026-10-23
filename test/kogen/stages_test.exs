defmodule Kogen.StagesTest do
  use ExUnit.Case, async: true
  alias Kogen.Stages

  defp plan do
    %{
      "version" => 1,
      "stages" => [
        %{
          "id" => "foundation",
          "title" => "Foundation",
          "goal" => "First runnable section",
          "checks" => ["first", "second"]
        },
        %{"id" => "surface", "title" => "Surface", "goal" => "Integrate", "checks" => ["third"]}
      ]
    }
  end

  defp section(p), do: "## Stages\n```json\n#{JSON.encode!(p)}\n```\n"

  test "absent plan is unchanged; explicit plan retains ordered literals" do
    assert Stages.parse("## Foundation\nSome stages in prose.\n") == {:ok, nil}
    assert Stages.parse("````markdown\n" <> section(plan()) <> "````\n") == {:ok, nil}
    assert Stages.parse("~~~markdown\n" <> section(plan()) <> "~~~\n") == {:ok, nil}
    assert Stages.parse(section(plan())) == {:ok, plan()["stages"]}
    assert Stages.initial(nil) == nil

    assert Stages.initial(plan()["stages"]) == %{
             "total" => 2,
             "completed" => [],
             "active" => "foundation",
             "phase" => "stage"
           }
  end

  test "stage navigation cannot claim builder work under another saved owner" do
    stages = plan()["stages"]

    b = %{
      intent: %{text: section(plan())},
      stage_plan: stages,
      stage_progress: Stages.initial(stages),
      stage_evidence: []
    }

    for continuation <- [
          %{stage: :startup},
          %{stage: :builder},
          %{stage: :builder_verify},
          %{stage: :tool, owner: :builder}
        ] do
      assert Stages.valid?(Map.put(b, :continuation, continuation))
    end

    for continuation <- [
          %{stage: :review},
          %{stage: :review_verify},
          %{stage: :review_retry_verify},
          %{stage: :commit},
          %{stage: :landed},
          %{stage: :tool, owner: :reviewer}
        ] do
      refute Stages.valid?(Map.put(b, :continuation, continuation))
    end
  end

  test "all specified schema errors name stages rather than silently ignoring metadata" do
    p = plan()
    [first, last] = p["stages"]

    invalid =
      [
        nil,
        [],
        %{},
        Map.delete(p, "version"),
        Map.put(p, "extra", true),
        %{p | "version" => 2},
        %{p | "version" => 1.0},
        %{p | "version" => "1"},
        %{p | "stages" => []},
        %{p | "stages" => [first]},
        %{p | "stages" => "stages"},
        %{p | "stages" => [first, first]}
      ] ++
        for entry <-
              [nil, "stage", Map.put(first, "extra", true)] ++
                Enum.map(Map.keys(first), &Map.delete(first, &1)) ++
                for(
                  id <- ["", "Foundation", "bad_id", "-bad", "bad-", 1],
                  do: %{first | "id" => id}
                ) ++
                for(
                  key <- ["title", "goal"],
                  value <- ["", " \n", 2, [], nil],
                  do: Map.put(first, key, value)
                ) ++
                for(
                  checks <- [[], "true", [""], [" \n"], [1], ["true", nil]],
                  do: %{first | "checks" => checks}
                ),
            do: %{p | "stages" => [entry, last]}

    for value <- invalid do
      assert {:error, "stages:" <> _} = Stages.parse(section(value)), inspect(value)
    end

    for text <- [
          "## Stages\nnot json\n",
          "## Stages\n```json\n{\n```\n",
          section(p) <> section(p),
          section(p) <> "```json\n{}\n```\n",
          "## Stages\n```json\n#{JSON.encode!(p)}\n```\nextra\n"
        ] do
      assert {:error, "stages:" <> _} = Stages.parse(text)
    end
  end
end
