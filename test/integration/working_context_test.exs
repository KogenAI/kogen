defmodule Kogen.Integration.WorkingContextTest do
  use ExUnit.Case, async: true
  alias Kogen.{Git, Run, Snapshot, WorkingContext}

  setup do
    root = Kogen.tmp_path("window-custody")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    Git.ok!(root, ["init", "-q"])
    File.write!(Path.join(root, ".gitignore"), ".kogen/local/\n")
    File.write!(Path.join(root, "app.txt"), "original\n")
    Git.ok!(root, ["add", "."])

    Git.ok!(root, [
      "-c",
      "user.name=Fixture",
      "-c",
      "user.email=fixture@example.invalid",
      "-c",
      "commit.gpgsign=false",
      "-c",
      "core.hooksPath=/dev/null",
      "commit",
      "-qm",
      "baseline"
    ])

    start = Git.head(root)
    tree = Snapshot.tree(root, start, [])

    b = %{
      root: root,
      start: start,
      excluded: [],
      run: Run.start(root),
      phase: :building,
      continuation: %{stage: :review},
      repairs: 1,
      working_context: %{},
      last_pass: %{green: true, tree: tree},
      last_review: %{findings: ["unresolved blocker"]},
      approval_bytes:
        Base.encode64(JSON.encode!(%{"sha256" => WorkingContext.hash("exact approval")}))
    }

    {:ok, b: b, tree: tree}
  end

  for provider <- ["chatgpt", "opencode-go"] do
    test "#{provider} resets retain observations, complete latest exchange and private exact history, not stale green",
         %{b: b, tree: tree} do
      role =
        if unquote(provider) == "opencode-go",
          do: %{provider: "opencode-go", model: "kimi-k3", effort: "high"},
          else: %{model: "fixture", effort: "high"}

      authority = %{"role" => "user", "content" => "exact approved authority Δ🙂\r\n"}
      diagnostic = %{"role" => "user", "content" => "private frozen diagnostic, not authority"}

      groups =
        for i <- 1..3 do
          [
            %{"type" => "reasoning", "encrypted_content" => "opaque+/==\nΔ#{i}", "summary" => []},
            %{
              "type" => "message",
              "role" => "assistant",
              "phase" => "commentary",
              "content" => [%{"type" => "output_text", "text" => "UNFINISHED #{i}\nΔ🙂"}]
            },
            %{
              "type" => "function_call",
              "call_id" => "call#{i}",
              "name" => "write_file",
              "arguments" =>
                JSON.encode!(%{"path" => "app.txt", "content" => String.duplicate("x", 190_000)})
            },
            %{"type" => "function_call_output", "call_id" => "call#{i}", "output" => "ok"}
          ]
        end

      groups =
        if unquote(provider) == "opencode-go" do
          Enum.map(groups, fn [_, message, call, output] ->
            raw = %{
              "role" => "assistant",
              "content" => "UNFINISHED",
              "reasoning" => "opaque Δ",
              "reasoning_details" => [
                %{"type" => "reasoning.text", "index" => 0, "vendor" => [2, 1]}
              ],
              "tool_calls" => [
                %{
                  "id" => call["call_id"],
                  "type" => "function",
                  "function" => %{"name" => call["name"], "arguments" => call["arguments"]}
                }
              ]
            }

            [Map.put(message, "opencode_go_message", raw), call, output]
          end)
        else
          groups
        end

      input = [authority, diagnostic] ++ List.flatten(groups)
      File.write!(Path.join(b.root, "app.txt"), "edited after green\n")

      {saved, active} =
        WorkingContext.prepare(
          b,
          "review",
          role,
          "policy",
          input,
          []
        )

      assert Enum.take(active, 2) == [authority, diagnostic]
      assert Enum.take(active, -length(List.last(groups))) == List.last(groups)

      reset =
        Enum.at(active, 2)["content"]
        |> String.replace_prefix("Local working-window reset\n", "")
        |> JSON.decode!()

      assert reset["phase"] == "review"

      assert reset["checks"] == %{
               "status" => "stale",
               "candidate_tree" => tree,
               "failing" => [],
               "not_run" => []
             }

      assert reset["findings"] == ["unresolved blocker"]
      assert length(reset["unfinished"]) == 3
      assert reset["approval_sha256"] == WorkingContext.hash("exact approval")
      [ref] = reset["history"]
      bytes = File.read!(ref["path"])
      assert WorkingContext.hash(bytes) == ref["sha256"]
      assert JSON.decode!(bytes)["input"] == input
      assert WorkingContext.validate!(saved) == saved

      assert WorkingContext.measure(Kogen.ChatGPT.request_body(role, "policy", active, [])).fits

      runs = Path.join(b.root, ".kogen/local/runs")
      File.rename!(runs, runs <> "-moved")
      File.ln_s!(runs <> "-moved", runs)

      try do
        assert_raise Kogen.Error, ~r/history custody.*unsafe/, fn ->
          WorkingContext.validate!(saved)
        end
      after
        File.rm!(runs)
        File.rename!(runs <> "-moved", runs)
      end

      File.write!(ref["path"], "changed")

      assert_raise Kogen.Error, ~r/history custody.*inspect checkpoint/, fn ->
        WorkingContext.validate!(saved)
      end
    end
  end

  test "irreducible authority refuses without archive or checkout changes", %{b: b} do
    input = [%{"role" => "user", "content" => String.duplicate("x", 600_000)}]
    before = File.read!(Path.join(b.root, ".git/index"))

    assert_raise Kogen.Error, ~r/mandatory.*524288.*131072.*checkpoint.*approval/, fn ->
      WorkingContext.prepare(b, "build", %{model: "fixture", effort: "high"}, "policy", input, [])
    end

    refute File.exists?(Path.join(b.run.dir, "working-context"))
    assert File.read!(Path.join(b.root, ".git/index")) == before
    assert Git.head(b.root) == b.start
  end
end
