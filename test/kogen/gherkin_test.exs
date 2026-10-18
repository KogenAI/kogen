defmodule Kogen.GherkinTest do
  use ExUnit.Case, async: true

  alias Kogen.Gherkin

  test "VER-3 / VER-4 / SHP-5: scenarios expose their report lines, inherited steps, tags, and Then steps" do
    feature = """
    @feature-tag
    Feature: Accounting
      Background:
        Given the project is ready

      @rule-tag
      Rule: an example rule
        Background:
          And the rule is active

        @scenario-tag
        Scenario: ordinary scenario
          When the action runs
          Then the result is visible

        Scenario Outline: value <value>
          When the value is <value>
          Then it is accepted
          @example-tag
          Examples:
            | value |
            | first |
            | second |
    """

    assert {:ok, scenarios} = Gherkin.parse(feature)

    assert Enum.map(scenarios, &{&1.name, &1.line}) == [
             {"ordinary scenario", 12},
             {"value first", 22},
             {"value second", 23}
           ]

    [ordinary, first, second] = scenarios
    assert ordinary.tags == ["@feature-tag", "@rule-tag", "@scenario-tag"]

    assert ordinary.steps |> Enum.map(& &1.text) == [
             "the project is ready",
             "the rule is active",
             "the action runs",
             "the result is visible"
           ]

    assert first.tags == ["@feature-tag", "@rule-tag", "@example-tag"]
    assert Enum.any?(first.steps, &(&1.keyword == "Then "))
    assert Enum.any?(second.steps, &(&1.keyword == "Then "))

    assert Enum.map(first.steps, & &1.text) == [
             "the project is ready",
             "the rule is active",
             "the value is first",
             "it is accepted"
           ]
  end

  test "SHP-5: malformed outline structure returns a source-line problem" do
    assert {:error, 3, "Examples: belongs to a Scenario Outline"} =
             Gherkin.parse("""
             Feature: Invalid
               Scenario: ordinary
               Examples:
             """)
  end
end
