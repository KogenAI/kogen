defmodule Kogen.RunTest do
  use ExUnit.Case, async: true
  alias Kogen.Run

  test "checkpoint decoder refuses damaged, incomplete and incompatible state" do
    for bytes <- [
          "{broken",
          "{}",
          ~s({"version":999}),
          ~s({"version":1,"state":"bad"}),
          JSON.encode!(%{"version" => 1, "state" => Base.encode64(:erlang.term_to_binary(%{}))})
        ] do
      assert {:error, _} = Run.decode_checkpoint(bytes)
    end
  end

  test "green reuse requires complete required clean evidence, not a stored Boolean" do
    root = Kogen.tmp_path("complete-pass")
    on_exit(fn -> File.rm_rf!(root) end)
    File.mkdir_p!(Path.join(root, ".kogen/intents/example"))

    File.write!(
      Path.join(root, ".kogen/intents/example/acceptance.feature"),
      "Feature: Example\n  Scenario: Complete\n    Given a gate\n"
    )

    intent = %Kogen.Intent{root: root, slug: "example"}
    config = %Kogen.Config{setup: ["true"], checks: [{"z-first", "true"}, {"a-last", "true"}]}

    pass = %{
      green: true,
      clean: true,
      moved: [],
      failing: [],
      acceptance: %{
        status: 0,
        problems: [],
        passed: 1,
        scenarios: [%{line: 2, name: "Complete", status: "passed"}]
      },
      model: :none,
      checks: Enum.map(config.checks, fn {n, c} -> %{name: n, command: c, status: 0} end)
    }

    assert Run.complete_pass?(pass, config, intent, :none)

    current =
      Map.merge(pass, %{not_run: [], setup: [%{name: "setup-1", command: "true", status: 0}]})

    assert Run.complete_pass?(current, config, intent, :none)
    refute Run.complete_pass?(Map.delete(current, :setup), config, intent, :none)

    for broken <- [
          %{pass | clean: false},
          %{pass | green: false},
          %{pass | acceptance: :not_run},
          %{pass | acceptance: %{pass.acceptance | status: 1}},
          %{pass | acceptance: %{pass.acceptance | problems: ["report_invalid"]}},
          %{
            pass
            | acceptance: %{
                pass.acceptance
                | scenarios: pass.acceptance.scenarios ++ pass.acceptance.scenarios
              }
          },
          %{pass | checks: []},
          %{pass | checks: Enum.reverse(pass.checks)},
          %{pass | acceptance: %{pass.acceptance | scenarios: []}},
          %{
            pass
            | acceptance: %{
                pass.acceptance
                | scenarios: [%{line: 2, name: "Complete", status: "skipped"}]
              }
          },
          Map.put(pass, :not_run, ["a-last"]),
          Map.put(pass, :setup, [])
        ] do
      refute Run.complete_pass?(broken, config, intent, :none)
    end

    refute Run.complete_pass?(pass, config, intent, %{path: "model.qnt"})
    assert Run.complete_pass?(%{pass | model: {:ok, []}}, config, intent, %{path: "model.qnt"})

    # Exercise the persisted checkpoint boundary too: neither green location may bypass
    # required-gate validation, while old complete clean evidence remains compatible.
    intent = %{intent | title: "Example", text: "Example", model: "not applicable — fixture"}
    run = Run.start(root)

    b = %{
      root: root,
      slug: intent.slug,
      start: "head",
      git_index: "index",
      start_tree: "tree",
      approval_bytes: Base.encode64("approval"),
      run: run,
      config: config,
      intent: intent,
      model: :none,
      phase: :building,
      t0: 0,
      last_pass: nil,
      last_review: nil,
      blocker: nil,
      parent: nil,
      root_run: nil,
      baseline_digests: %{Kogen.Config.path() => "digest"},
      baseline: [Kogen.Config.path()],
      excluded: [],
      round: 1,
      pass: 1,
      review: 1,
      repairs: 0,
      model_active_ms: 0,
      unknown_requests: 0,
      usage: Kogen.Usage.zero(),
      attempt_usage: Kogen.Usage.zero(),
      continuation: %{stage: :builder, input: []}
    }

    encode = fn state ->
      JSON.encode!(%{
        "version" => 2,
        "state" => Base.encode64(:erlang.term_to_binary(state)),
        "identity" => "identity",
        "candidate" => "tree",
        "index" => Base.encode64("index"),
        "approval" => b.approval_bytes
      })
    end

    session = %{
      input: [],
      attempts: [],
      role: %{model: "fixture", effort: "high"},
      tools: [],
      usage: %{}
    }

    for evidence <- [pass, current] do
      evidence =
        Map.merge(evidence, %{
          n: 1,
          tree: "tree",
          checks: Enum.map(evidence.checks, &Map.put(&1, :output, ""))
        })

      state = %{
        b
        | last_pass: evidence,
          continuation: %{stage: :review, pass: evidence, session: session}
      }

      assert {:ok, _, _} = Run.decode_checkpoint(encode.(state))

      cache = %{
        "conversation" => %{id: "conversation-id", unsupported: true, response: "resp_last"}
      }

      assert {:ok, _, saved} =
               Run.decode_checkpoint(encode.(Map.put(state, :prompt_cache_states, cache)))

      assert saved.prompt_cache_states == cache

      for damaged <- [
            nil,
            [],
            %{"key" => %{}},
            %{"key" => %{id: "id", unsupported: "false", response: nil}}
          ] do
        assert {:error, _} =
                 Run.decode_checkpoint(encode.(Map.put(state, :prompt_cache_states, damaged)))
      end

      for incomplete <- [
            Map.put(evidence, :not_run, ["a-last"]),
            %{evidence | checks: []},
            %{evidence | acceptance: :not_run},
            Map.put(evidence, :setup, []),
            evidence |> Map.put(:not_run, []) |> Map.delete(:setup)
          ] do
        assert {:error, _} = Run.decode_checkpoint(encode.(%{state | last_pass: incomplete}))

        assert {:error, _} =
                 Run.decode_checkpoint(
                   encode.(%{state | continuation: %{state.continuation | pass: incomplete}})
                 )
      end
    end
  end

  test "atomic checkpoint publication leaves prior valid document through interrupted publication" do
    root = Kogen.tmp_path("checkpoint-publication")
    on_exit(fn -> File.rm_rf!(root) end)
    run = Run.start(root)
    Run.checkpoint(run, %{"version" => 1, "marker" => "complete"})
    path = Path.join(run.dir, "checkpoint.json")
    File.write!(path <> ".tmp", "{interrupted")
    assert JSON.decode!(File.read!(path)) == %{"version" => 1, "marker" => "complete"}
    Run.checkpoint(run, %{"version" => 1, "marker" => "next"})
    assert JSON.decode!(File.read!(path))["marker"] == "next"
    refute File.exists?(path <> ".tmp")
  end

  test "the run log cap preserves UTF-8 and fits in 1 MiB including its marker" do
    for size <- [1_048_575, 1_048_576] do
      text = String.duplicate("x", size)
      assert Run.cap(text) == text
    end

    for text <- [
          String.duplicate("x", 1_048_577),
          String.duplicate("€", 400_000),
          String.duplicate("🌍", 300_000)
        ] do
      capped = Run.cap(text)
      assert byte_size(capped) <= 1_048_576
      assert String.valid?(capped)
      assert %{"output" => ^capped} = JSON.decode!(JSON.encode!(%{"output" => capped}))
      [head, tail] = String.split(capped, "\n[... cut in the run log ...]\n")
      assert String.starts_with?(text, head)
      assert String.ends_with?(text, tail)
    end
  end
end
