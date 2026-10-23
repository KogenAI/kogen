defmodule Kogen.Integration.ReviewMaterialTest do
  use ExUnit.Case, async: true
  alias Kogen.{ChatGPT, Git, ReviewMaterial, Run, Snapshot, Tools, WorkingContext}

  setup do
    root = Kogen.tmp_path("review-material")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    Git.ok!(root, ["init", "-q"])
    File.write!(Path.join(root, ".gitignore"), ".kogen/local/\n")
    File.write!(Path.join(root, "app.txt"), "baseline\n")
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
      review: 1,
      continuation: %{stage: :review},
      repairs: 0,
      working_context: %{},
      last_pass: %{tree: tree, green: true},
      last_review: nil,
      approval_bytes: Base.encode64(JSON.encode!(%{"sha256" => "exact approval"}))
    }

    {:ok, b: b, tree: tree}
  end

  test "small source remains inline without new custody", %{b: b, tree: tree} do
    m = material("small source\n")
    diagnostic = [%{"role" => "user", "content" => "frozen diagnostic\r\nΔ🙂"}]
    {same, input} = ReviewMaterial.prepare(b, tree, m, role(), "policy", [], diagnostic)
    assert same.working_context["review"].mandatory == input
    assert same.working_context["review"].inline_material == m

    assert input == [
             %{
               "role" => "user",
               "content" => Kogen.PromptCache.contract_blocks(m.authority, m.source)
             }
             | diagnostic
           ]

    refute File.exists?(Path.join(b.run.dir, "review-source"))
  end

  for historical <- [false, true] do
    test "fitted inline source relocates on pressure (historical=#{historical})", %{
      b: b,
      tree: tree
    } do
      source =
        "# Check results of the final pass\nacceptance: passed (1 scenarios)\n# Diff of existing/deleted paths\n" <>
          String.duplicate("candidate source Δ🙂\r\n", 15_000)

      files = [
        %{
          "path" => "app.txt",
          "status" => "changed",
          "mode" => "100644",
          "git_object" => Git.ok!(b.root, ["rev-parse", "HEAD:app.txt"]),
          "bytes" => 9,
          "sha256" => WorkingContext.hash("baseline\n")
        }
      ]

      m = %{material(source) | files: files}
      diagnostic = [%{"role" => "user", "content" => "frozen diagnostic Δ\r\n"}]
      {saved, input} = ReviewMaterial.prepare(b, tree, m, role(), "policy", [], diagnostic)
      refute File.exists?(Path.join(b.run.dir, "review-source"))
      {same, ^input} = WorkingContext.prepare(saved, "review", role(), "policy", input, [])
      assert same == saved

      exchange = [
        %{
          "type" => "function_call",
          "name" => "read_file",
          "call_id" => "large",
          "arguments" => "{}"
        },
        %{
          "type" => "function_call_output",
          "call_id" => "large",
          "output" => String.duplicate("x", 220_000)
        }
      ]

      initial =
        if unquote(historical),
          do:
            put_in(
              saved.working_context["review"],
              Map.drop(saved.working_context["review"], [:inline_material, :source_tree])
            ),
          else: saved

      {reset, active} =
        WorkingContext.prepare(initial, "review", role(), "policy", input ++ exchange, [])

      refs =
        Enum.filter(reset.working_context["review"].history, fn ref ->
          JSON.decode!(File.read!(ref["path"]))["review_source"] != nil
        end)

      assert Enum.map_join(refs, fn ref ->
               JSON.decode!(File.read!(ref["path"]))["review_source"]["text"]
             end) == source

      assert hd(active)["content"] |> hd() |> Map.fetch!("text") == m.authority
      assert JSON.encode!(active) =~ m.checks
      assert WorkingContext.measure(ChatGPT.request_body(role(), "policy", active, [])).fits
      assert length(ReviewMaterial.unread(reset, active)) == length(refs)
      assert Enum.at(active, 1) == hd(diagnostic)
      text = hd(active)["content"] |> Enum.at(1) |> Map.fetch!("text")
      [catalog_line] = Enum.filter(String.split(text, "\n"), &String.starts_with?(&1, "{\""))
      catalog = JSON.decode!(catalog_line)
      assert catalog["source_bytes"] == byte_size(source)
      assert catalog["source_sha256"] == WorkingContext.hash(source)
      assert catalog["start_head"] == b.start

      if unquote(historical) do
        assert catalog["candidate_tree"] == nil
        assert catalog["binding"] =~ "historical"
      else
        assert catalog["candidate_tree"] == tree
        assert catalog["files"] == files
      end

      # Relocation is a one-time representation transition, not repeated pinning.
      again = ReviewMaterial.relocate(reset, role(), "policy", [])
      assert again == reset
    end
  end

  for provider <- ["chatgpt", "opencode-go"] do
    test "#{provider} exact UTF8 source delivery survives reset and damaged custody refuses", %{
      b: b,
      tree: tree
    } do
      role =
        if unquote(provider) == "opencode-go",
          do: %{provider: "opencode-go", model: "kimi-k3", effort: "high"},
          else: role()

      source =
        String.duplicate("literal Δ🙂\r\n\t\"\\\u0001", 30_000) <> String.duplicate(<<1>>, 12_000)

      m = material(source)
      {saved, input} = ReviewMaterial.prepare(b, tree, m, role, "policy", [], [])

      assert ChatGPT.request_body(role, "policy", input, [])
             |> WorkingContext.measure()
             |> Map.fetch!(:fits)

      assert hd(input)["content"] |> hd() |> Map.fetch!("text") == m.authority
      refs = saved.working_context["review"].history
      assert length(refs) > 1
      ctx = %{root: b.root, protected: [], tools: ["read_file"]}

      exchanges =
        for {ref, n} <- Enum.with_index(refs) do
          bytes = File.read!(ref["path"])
          assert WorkingContext.hash(bytes) == ref["sha256"]
          assert Bitwise.band(File.stat!(ref["path"]).mode, 0o777) == 0o600
          assert Bitwise.band(File.stat!(Path.dirname(ref["path"])).mode, 0o777) == 0o700
          output = Tools.run("read_file", %{"path" => ref["path"]}, ctx)
          assert Tools.cut(output) == output

          [
            %{
              "type" => "function_call",
              "call_id" => "read-#{n}",
              "name" => "read_file",
              "arguments" => JSON.encode!(%{"path" => ref["path"]})
            },
            %{"type" => "function_call_output", "call_id" => "read-#{n}", "output" => output}
          ]
        end

      assert Enum.map_join(refs, fn ref ->
               JSON.decode!(File.read!(ref["path"]))["review_source"]["text"]
             end) == source

      assert length(ReviewMaterial.unread(saved, input)) == length(refs)
      [first | _] = exchanges
      [call, result] = first

      for bad <- [
            [call],
            [call, %{result | "output" => "truncated"}],
            [call, %{result | "call_id" => "wrong"}]
          ] do
        assert length(ReviewMaterial.unread(saved, input ++ bad)) == length(refs)
      end

      complete = input ++ List.flatten(exchanges)
      assert ReviewMaterial.unread(saved, complete) == []
      {reset, active} = WorkingContext.prepare(saved, "review", role, "policy", complete, [])
      assert length(active) < length(complete)
      assert ReviewMaterial.unread(reset, active) == []
      assert WorkingContext.validate!(reset) == reset
      File.write!(hd(refs)["path"], "changed")

      assert_raise Kogen.Error, ~r/history custody.*changed/, fn ->
        WorkingContext.validate!(reset)
      end
    end
  end

  test "irreducible authority refuses without files or index changes", %{b: b, tree: tree} do
    m = %{
      material(String.duplicate("source", 120_000))
      | authority: String.duplicate("authority", 70_000)
    }

    index = File.read!(Path.join(b.root, ".git/index"))

    assert_raise Kogen.Error, ~r/mandatory authority.*524288.*131072.*checkpoint.*approval/, fn ->
      ReviewMaterial.prepare(b, tree, m, role(), "policy", [], [])
    end

    assert File.read!(Path.join(b.root, ".git/index")) == index
    refute File.exists?(Path.join(b.run.dir, "review-source"))
  end

  defp role, do: %{model: "fixture", effort: "high"}

  defp material(source),
    do: %{
      authority: "exact approved literal Δ🙂\r\n\t  ",
      source: source,
      checks: "acceptance: passed (1 scenarios)",
      files: []
    }
end
