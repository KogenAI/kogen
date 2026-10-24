defmodule Kogen.Integration.ShapeWorkingContextTest do
  use ExUnit.Case, async: true
  alias Kogen.{ShapeWorkingContext, WorkingContext}

  setup do
    root = Kogen.tmp_path("shape-window")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    authority = [%{"role" => "user", "content" => "exact request Δ\r\n"}]

    sh = %{
      root: root,
      started_at: System.monotonic_time(:millisecond),
      role: %{model: "fixture", effort: "high"},
      tools: [],
      declared_steps: ["features/steps/new.js"],
      inspected: true,
      docs: [%{result: "unsupported"}],
      ready: nil,
      working_context: ShapeWorkingContext.new(root, "fixture", authority)
    }

    {:ok, sh: sh, authority: authority}
  end

  defp exchange(n) do
    [
      %{"type" => "reasoning", "encrypted_content" => "opaque#{n}"},
      %{
        "type" => "message",
        "role" => "assistant",
        "phase" => "commentary",
        "content" => [%{"type" => "output_text", "text" => "observation #{n}"}]
      },
      %{
        "type" => "function_call",
        "call_id" => "a#{n}",
        "name" => "read_file",
        "arguments" => "{}"
      },
      %{
        "type" => "function_call",
        "call_id" => "b#{n}",
        "name" => "read_file",
        "arguments" => "{}"
      },
      %{
        "type" => "function_call_output",
        "call_id" => "a#{n}",
        "output" => String.duplicate("x", 190_000)
      },
      %{"type" => "function_call_output", "call_id" => "b#{n}", "output" => "second result"}
    ]
  end

  test "repeated windows archive exact input and previous handoff, keeping full newest batch", %{
    sh: sh,
    authority: authority
  } do
    input = authority ++ exchange(1) ++ exchange(2) ++ exchange(3)
    {sh, reduced} = ShapeWorkingContext.prepare(sh, input, 2, %{proposed: []}, "policy")
    assert hd(reduced) == hd(authority)
    assert Enum.take(reduced, -6) == exchange(3)
    assert WorkingContext.measure(Kogen.ChatGPT.request_body(sh.role, "policy", reduced, [])).fits
    [ref] = sh.working_context.history
    archive = JSON.decode!(File.read!(ref["path"]))

    assert Map.delete(archive, "documentation") == %{
             "version" => 1,
             "owner" => "shape",
             "input" => input,
             "previous" => nil
           }

    snapshot = archive["documentation"]
    assert File.read!(snapshot["path"]) == JSON.encode!(hd(sh.docs)) <> "\n"
    assert snapshot["sha256"] == WorkingContext.hash(File.read!(snapshot["path"]))
    assert WorkingContext.hash(File.read!(ref["path"])) == ref["sha256"]
    handoff = Enum.at(reduced, 1)["content"]
    assert handoff =~ "Local working-window reset"
    assert handoff =~ "observation 1"
    assert not (handoff =~ "unsupported")
    state = handoff |> String.split("manifest/state: ") |> List.last() |> JSON.decode!()
    assert state["history"] == %{"head" => ref, "count" => 1}
    assert state["documentation"] == snapshot
    assert handoff =~ "invalid_submissions\":2"

    sh = %{
      sh
      | ready: %{
          intent: %Kogen.Intent{slug: "fixture", text: "exact checked proposal"},
          sha256: "candidate identity",
          candidate_tree: "tree identity",
          scenarios: [%{name: "missing behavior", status: "failed"}]
        }
    }

    second = reduced ++ exchange(4) ++ exchange(5)
    {sh, second_reduced} = ShapeWorkingContext.prepare(sh, second, 2, %{}, "policy")
    assert Enum.at(second_reduced, 1)["content"] =~ "candidate identity"
    assert Enum.at(second_reduced, 1)["content"] =~ "missing behavior"
    assert sh.ready.intent.text == "exact checked proposal"
    next = List.last(sh.working_context.history)
    assert JSON.decode!(File.read!(next["path"]))["previous"] == ref
    assert JSON.decode!(File.read!(next["path"]))["input"] == second
  end

  test "reset event measures the actual new-window cache envelope", %{
    sh: sh,
    authority: authority
  } do
    sh = %{sh | role: %{model: "gpt-6.1-sol", effort: "high"}}
    input = authority ++ exchange(1) ++ exchange(2) ++ exchange(3)
    Kogen.ShapeEvidence.start(sh.root)

    try do
      Process.put(:provider_working_window, 0)
      Kogen.ChatGPT.request_body(sh.role, "policy", input, [])
      Kogen.PromptCache.unsupported()
      {sh, reduced} = ShapeWorkingContext.prepare(sh, input, 0, %{}, "policy")
      actual = Kogen.ChatGPT.request_body(sh.role, "policy", reduced, [])
      assert Map.has_key?(actual, "prompt_cache_key")

      event =
        File.read!(Path.join(sh.root, "events.ndjson"))
        |> String.split("\n", trim: true)
        |> Enum.map(&JSON.decode!/1)
        |> Enum.find(&(&1["event"] == "working_context_reset"))

      assert event["after_bytes"] == WorkingContext.measure(actual).rendered_bytes
    after
      Kogen.ShapeEvidence.finish()
    end
  end

  test "unsafe ancestor custody refuses before writing an unsent archive", %{sh: sh} do
    outside = Kogen.tmp_path("shape-window-outside")
    File.mkdir_p!(outside)
    on_exit(fn -> File.rm_rf!(outside) end)
    File.mkdir_p!(Path.join(sh.root, ".kogen/local"))
    File.ln_s!(outside, Path.join(sh.root, ".kogen/local/shaping"))
    # The immediate slug directory already exists, hiding the ancestor symlink
    # from a mkdir-only walk.
    File.mkdir!(Path.join(outside, "fixture"))
    input = [%{"role" => "user", "content" => String.duplicate("x", 600_000)}]
    sh = %{sh | working_context: ShapeWorkingContext.new(sh.root, "fixture", input)}

    error =
      assert_raise Kogen.Error, fn -> ShapeWorkingContext.prepare(sh, input, 0, %{}, "policy") end

    assert error.reason == "context_custody_invalid"
    assert Path.wildcard(Path.join(outside, "**/*.json")) == []
  end

  for damage <- [:changed, :missing, :symlink, :mode] do
    test "#{damage} custody refuses even an otherwise fitting next request", %{
      sh: sh,
      authority: authority
    } do
      input = authority ++ exchange(1) ++ exchange(2) ++ exchange(3)
      {sh, reduced} = ShapeWorkingContext.prepare(sh, input, 0, %{}, "policy")
      [ref] = sh.working_context.history
      path = ref["path"]

      case unquote(damage) do
        :changed ->
          File.write!(path, "changed")

        :missing ->
          File.rm!(path)

        :symlink ->
          File.rename!(path, path <> ".original")
          File.ln_s!(path <> ".original", path)

        :mode ->
          File.chmod!(path, 0o644)
      end

      error =
        assert_raise Kogen.Error, fn ->
          ShapeWorkingContext.prepare(sh, reduced, 0, %{}, "policy")
        end

      assert error.reason == "context_custody_invalid"
    end
  end

  test "irreducible authority is retained exactly unsent", %{sh: sh} do
    input = [%{"role" => "user", "content" => String.duplicate("x", 600_000)}]
    sh = %{sh | working_context: ShapeWorkingContext.new(sh.root, "huge", input)}

    error =
      assert_raise Kogen.Error, fn -> ShapeWorkingContext.prepare(sh, input, 0, %{}, "policy") end

    assert error.reason == "context_budget_exceeded"
    assert error.detail =~ "fresh identical retry is not recovery"
    [path] = Path.wildcard(sh.working_context.dir <> "/*.json")
    assert JSON.decode!(File.read!(path))["input"] == input
  end
end
