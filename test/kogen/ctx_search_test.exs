Code.require_file("../support/ctx_fixture.ex", __DIR__)

defmodule Kogen.CtxSearchTest do
  use ExUnit.Case, async: true
  alias Kogen.Test.CtxFixture

  setup do
    {root, home} = CtxFixture.create!()
    binary = CtxFixture.binary()
    {_, "", 0} = CtxFixture.run(binary, root, home, ["index"])
    %{root: root, home: home, binary: binary}
  end

  defp search(binary, root, home, args) do
    {out, err, status} = CtxFixture.run(binary, root, home, ["search" | args])
    assert err == ""
    assert status == 0
    String.split(out, "\n", trim: true)
  end

  test "C1 search uses the probed bm25 order", %{root: root, home: home, binary: binary} do
    assert search(binary, root, home, ["the"]) == [
             ".kogen/intents/complete/stray-rework/INTENT.md:9-9 [intent] The Developer deletes each stray path and the guard passes.",
             ".kogen/intents/complete/stray-rework/scenarios.yaml:1-3 [intent] - id: stray-file-reworked given: A fixture with a stray file. then: The guard reworks the stray file.",
             ".kogen/intents/complete/stray-rework/INTENT.md:5-5 [intent] A stray Mix lock directory stopped the Build."
           ]
  end

  test "C2 search covers intents and memory only", %{root: root, home: home, binary: binary} do
    results = search(binary, root, home, ["stray"])
    assert length(results) == 5
    prefixes = results |> Enum.map(&(String.split(&1, " ") |> hd())) |> MapSet.new()

    assert prefixes ==
             MapSet.new([
               ".kogen/intents/complete/stray-rework/INTENT.md:1-1",
               ".kogen/intents/complete/stray-rework/INTENT.md:5-5",
               ".kogen/intents/complete/stray-rework/INTENT.md:9-9",
               ".kogen/intents/complete/stray-rework/scenarios.yaml:1-3",
               ".kogen/memory/lesson/lesson-stray-rework.md:1-5"
             ])

    assert Enum.count(results, &String.contains?(&1, " [memory] ")) == 1
    assert Enum.count(results, &String.contains?(&1, " [intent] ")) == 4
    refute Enum.any?(results, &String.contains?(&1, "codex-raw"))
    refute Enum.any?(results, &String.contains?(&1, "lib/shop"))
  end

  test "C3 limit reports every omitted hit", %{root: root, home: home, binary: binary} do
    assert search(binary, root, home, ["stray", "--limit", "2"]) == [
             ".kogen/intents/complete/stray-rework/INTENT.md:1-1 [intent] # Rework stray paths",
             ".kogen/intents/complete/stray-rework/scenarios.yaml:1-3 [intent] - id: stray-file-reworked given: A fixture with a stray file. then: The guard reworks the stray file.",
             "... 3 more"
           ]

    assert search(binary, root, home, ["stray", "--limit", "1"]) == [
             ".kogen/intents/complete/stray-rework/INTENT.md:1-1 [intent] # Rework stray paths",
             "... 4 more"
           ]
  end

  test "C4 joins query arguments and returns the expected memory snippet", %{
    root: root,
    home: home,
    binary: binary
  } do
    expected = [
      ".kogen/intents/complete/stray-rework/INTENT.md:5-5 [intent] A stray Mix lock directory stopped the Build.",
      ".kogen/memory/lesson/lesson-stray-rework.md:1-5 [memory] --- id: \"lesson-stray-rework\" kind: \"lesson\" claim: \"stray-rework published after 2 stopped Builds: stray Mix lock directories\" ---"
    ]

    assert search(binary, root, home, ["Mix lock"]) == expected
    assert search(binary, root, home, ["Mix", "lock"]) == expected
  end

  test "C5 does not stem terms", %{root: root, home: home, binary: binary} do
    assert search(binary, root, home, ["rework"]) == [
             ".kogen/intents/complete/stray-rework/INTENT.md:1-1 [intent] # Rework stray paths",
             ".kogen/memory/lesson/lesson-stray-rework.md:1-5 [memory] --- id: \"lesson-stray-rework\" kind: \"lesson\" claim: \"stray-rework published after 2 stopped Builds: stray Mix lock directories\" ---"
           ]
  end

  test "C6 searches drafts but not code", %{root: root, home: home, binary: binary} do
    assert search(binary, root, home, ["discounts"]) == [
             ".kogen/intents/drafts/cart-discounts/INTENT.md:1-1 [intent] # Add cart discounts",
             ".kogen/intents/drafts/cart-discounts/INTENT.md:3-3 [intent] Discounts apply before tax in Shop.Pricing."
           ]

    assert search(binary, root, home, ["Pricing"]) == [
             ".kogen/intents/drafts/cart-discounts/INTENT.md:3-3 [intent] Discounts apply before tax in Shop.Pricing."
           ]
  end

  test "C7 doubles quotes inside terms", %{root: root, home: home, binary: binary} do
    assert search(binary, root, home, [~s(guard"passes)]) == [
             ".kogen/intents/complete/stray-rework/INTENT.md:9-9 [intent] The Developer deletes each stray path and the guard passes."
           ]
  end

  test "C8 punctuation-only terms are empty and missing query is usage", %{
    root: root,
    home: home,
    binary: binary
  } do
    assert search(binary, root, home, ["-", ":"]) == []
    {out, err, 2} = CtxFixture.run(binary, root, home, ["search"])
    assert out == ""
    assert String.starts_with?(err, "usage: kogen-ctx")
  end

  test "C9 chunks runs over sixty lines", %{root: root, home: home, binary: binary} do
    path = Path.join(root, ".kogen/memory/lesson/long-run.md")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Enum.map_join(1..130, "\n", &"row #{&1} marker") <> "\n")
    results = search(binary, root, home, ["marker"])

    assert Enum.map(results, &hd(String.split(&1, " "))) == [
             ".kogen/memory/lesson/long-run.md:1-60",
             ".kogen/memory/lesson/long-run.md:61-120",
             ".kogen/memory/lesson/long-run.md:121-130"
           ]

    assert List.last(results) ==
             ".kogen/memory/lesson/long-run.md:121-130 [memory] " <>
               Enum.map_join(121..130, " ", &"row #{&1} marker")
  end
end
