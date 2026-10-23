Code.require_file(Path.expand("../support/integration_helpers.ex", __DIR__))

defmodule Kogen.Integration.ShapeContextPublicationTest do
  use ExUnit.Case, async: true
  alias Kogen.{Config, Intent, Integration.Helpers}
  @moduletag :integration

  setup_all do
    suite = Helpers.setup_suite!()
    on_exit(fn -> Helpers.cleanup_suite(suite) end)
    %{suite: suite}
  end

  test "custody damaged during final readiness cannot publish successful evidence", %{
    suite: suite
  } do
    c = Helpers.project!(suite, [], staged_intent: false)
    on_exit(fn -> Helpers.cleanup_case(c) end)
    slug = "custody-ready"
    config = Config.load!(c.repo)
    custody = Path.join(c.repo, ".kogen/local/shaping/#{slug}/working-context")

    # Readiness runs in clean scratch, but an external change to the linked
    # invocation custody must still prevent final publication in the source repo.
    damage =
      "if grep -q 'Scenario:' \"$KOGEN_ACCEPTANCE_FEATURES\"; then " <>
        "for archive in '#{custody}/'*/*.json; do printf damage >> \"$archive\"; done; fi; "

    File.write!(
      Path.join(c.repo, Config.path()),
      Config.render(%{
        setup: [],
        fix: [],
        checks: [],
        protect: config.protect,
        acceptance: %{run: damage <> config.acceptance_run, steps_dir: config.steps_dir}
      })
    )

    File.write!(Path.join(c.repo, "padding.txt"), String.duplicate("discovery line\n", 2000))
    Helpers.git!(c, ["add", Config.path(), "padding.txt"])
    Helpers.git!(c, ["commit", "-qm", "Seed custody regression"])
    approval = File.read!(Intent.approval_path(c.repo, "fixture"))
    head = Kogen.Git.head(c.repo)
    index = File.read!(Path.join(c.repo, ".git/index"))
    md = Intent.intent_md(slug)
    ft = Intent.feature(slug)
    js = "features/steps/custody_ready.js"

    files = [
      %{
        path: md,
        content: """
        # Preserve final custody

        Slug: #{slug}
        Model: not applicable — fixture is stateless
        Acceptance:
        - #{ft}
        - #{js}

        ## Source comparison
        - addressed: fixture request; final custody remains intact.

        ## Tests
        - Final custody: the fixture scenario (regression)

        ## Feasibility
        - none
        """
      },
      %{
        path: ft,
        content: "Feature: Custody\n  Scenario: Ready\n    Then custody fixture passes\n"
      },
      %{
        path: js,
        content:
          "const { Then } = require('@cucumber/cucumber');\nThen('custody fixture passes', function () {});\n"
      }
    ]

    actions =
      List.duplicate({:function, "read_file", %{path: "padding.txt"}}, 40) ++
        [{:function, "submit", %{files: files}}]

    Agent.update(c.server.state, &%{&1 | script: Enum.take(&1.script, &1.next) ++ actions})
    request = Path.join(c.root, "request.txt")
    File.write!(request, "Preserve the fixture with intact local custody.")
    {output, status} = Helpers.run_kogen(c, ["intent", "shape", slug, request])
    archives = Path.wildcard(custody <> "/*/*.json")
    assert archives != []
    assert Enum.all?(archives, &(File.read!(&1) |> String.ends_with?("damage")))
    assert status != 0, output
    assert output =~ "candidate/context_custody_invalid"
    assert output =~ ~r/Shape local working-window reset .*custody .* \(\d+ s\)/
    refute File.exists?(Path.join(c.repo, ".kogen/local/provenance/#{slug}/current.json"))
    refute File.exists?(Path.join(c.repo, ".kogen/local/readiness/#{slug}.json"))
    assert File.read!(Intent.approval_path(c.repo, "fixture")) == approval
    assert Kogen.Git.head(c.repo) == head
    assert File.read!(Path.join(c.repo, ".git/index")) == index
  end
end
