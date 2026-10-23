ExUnit.start(autorun: false)
Code.require_file("test/support/integration_helpers.ex")

defmodule BoundedToolResultsFixture do
  alias Kogen.Integration.{Helpers, FakeProvider}
  alias Kogen.{Tools, Shape, Intent, Config, WorkingContext}

  def put(root, path, bytes) do
    p = Path.join(root, path)
    File.mkdir_p!(Path.dirname(p))
    File.write!(p, bytes)
  end

  def git(c, args) do
    {text, 0} = Helpers.git!(c, args)
    String.trim(text)
  end

  def approval(c) do
    case File.read(Intent.approval_path(c.repo, "fixture")) do
      {:ok, bytes} -> bytes
      _ -> nil
    end
  end

  def body(input) do
    json = Kogen.ChatGPT.request_body(%{model: "fixture", effort: "high"}, "fixture policy", input, [])
    %{json: json, body: JSON.encode!(json)}
  end

  def group(id, entries) do
    prefix = [
      %{"type" => "reasoning", "id" => "rs-#{id}", "encrypted_content" => "opaque+/==\nΔ #{id}", "summary" => []},
      %{"type" => "message", "id" => "msg-#{id}", "role" => "assistant", "phase" => "commentary", "content" => [%{"type" => "output_text", "text" => "Unfinished bounded inspection #{id}"}]}
    ]
    calls = entries |> Enum.with_index() |> Enum.map(fn {{name, args, _source}, n} ->
      %{"type" => "function_call", "id" => "fc-#{id}-#{n}", "call_id" => "call-#{id}-#{n}", "name" => name, "arguments" => JSON.encode!(args)}
    end)
    %{prefix: Enum.map(prefix, &Shape.replay_item/1), calls: calls, sources: Enum.map(entries, &elem(&1, 2)), items: prefix ++ calls}
  end

  def display(g) do
    Enum.map(g.items, &Shape.replay_item/1) ++ Enum.zip_with(g.calls, g.sources, fn c, s -> Shape.output(c, Tools.cut(s.text)) end)
  end

  def boundary(s, control) do
    sources = Enum.map(s["sizes"], &String.duplicate("x", &1)) ++ [
      String.duplicate("\"\\\t\r\n\u0001", 20_000),
      String.duplicate("Δ🙂", 20_000),
      "Readiness observations\n" <> String.duplicate("feedback", 90_000)
    ]
    results = sources |> Enum.with_index() |> Enum.map(fn {source, n} ->
      call = %{"call_id" => "boundary-#{n}"}
      out = Shape.output(call, if(control, do: Tools.cut(source), else: source))
      %{source: source, actual: out["output"], again: Shape.output(call, out["output"])["output"], call_id: out["call_id"], expected_call_id: call["call_id"]}
    end)
    image = [%{"type" => "input_text", "text" => "{\"fixture\":true}"}, %{"type" => "input_image", "image_url" => "data:image/png;base64,fixture"}]
    image_call = %{"call_id" => "typed-fixture"}
    out = Shape.output(image_call, image)
    base = body([]).json
    measures = Enum.map([s["ceiling"] - 1, s["ceiling"], s["ceiling"] + 1], fn size ->
      empty = Map.put(base, "padding", "")
      rendered = Map.put(empty, "padding", String.duplicate("x", size - byte_size(JSON.encode!(empty))))
      WorkingContext.measure(rendered)
    end)
    %{mode: "boundary", results: results, typed: %{source: image, actual: out["output"], call_id: out["call_id"], expected_call_id: image_call["call_id"]}, measure: %{bytes: Enum.map(measures, & &1.rendered_bytes), fits: Enum.map(measures, & &1.fits), reserves: Enum.map(measures, & &1.output_reserve_tokens)}}
  end

  def fixture_text(s), do: JSON.encode!(%{"input" => String.duplicate("x", s["fixtureBytes"] - 12)})
  def read_entry(path, source), do: {"read_file", %{"path" => path, "start_line" => 1, "end_line" => 35}, %{text: source}}
  def ordinary_entry, do: {"read_file", %{"path" => "ordinary.txt", "start_line" => 2, "end_line" => 3}, %{text: "2\t  Δ🙂\r\n3\tlast"}}

  def seed(c, s, mode) do
    huge = fixture_text(s)
    put(c.repo, "large.json", huge)
    put(c.repo, "ordinary.txt", "first\n  Δ🙂\r\nlast\n")
    put(c.repo, "pad.txt", String.duplicate("p", s["limit"] - 3) <> "\n")
    put(c.repo, "search.txt", "MATCH" <> String.duplicate("q", s["fixtureBytes"]) <> "\n")
    if mode == "shape" do
      for n <- 1..1100, do: put(c.repo, "corpus/#{n}-" <> String.duplicate("name", 12), "")
    end
    p = Intent.intent_md("fixture")
    put(c.repo, p, File.read!(Path.join(c.repo, p)) <> "\nOriginal bounded-results source packet:\n" <> s["packet"] <> "\n")
    git(c, ["add", "."])
    git(c, ["commit", "-qm", "Seed bounded result fixtures"])
    {_, 0} = Helpers.run_kogen(c, ["intent", "approve", "fixture", Intent.hash(c.repo, Intent.baseline(c.repo, "fixture", Config.load!(c.repo)))])
  end

  def files(c), do: Map.new(~w(large.json ordinary.txt pad.txt search.txt), fn p -> {p, WorkingContext.hash(File.read!(Path.join(c.repo, p)))} end)
  def context(c), do: %{root: c.repo, protected: [], tools: ~w(read_file list_files search_text probe)}
  def script(c, actions), do: FakeProvider.append(c.server, actions)
  def function(name, args), do: {:function, name, args}
  def action(g), do: {:items, g.items}

  def history(c) do
    Path.wildcard(Path.join(c.repo, ".kogen/local/shaping/bounded-case/working-context/*/*.json"))
    |> Enum.sort()
    |> Enum.map(fn p ->
      bytes = File.read!(p)
      %{path: p, bytes: Base.encode64(bytes), sha256: WorkingContext.hash(bytes), mode: Bitwise.band(File.stat!(p).mode, 0o777), dir_mode: Bitwise.band(File.stat!(Path.dirname(p)).mode, 0o777)}
    end)
  end

  def requests(c, mode) do
    FakeProvider.provider_requests(c.server)
    |> Enum.reject(fn r -> Enum.any?(r.json["tools"] || [], &(&1["name"] == "submit_configuration")) end)
    |> Enum.map(fn r ->
      names = Enum.map(r.json["tools"] || [], & &1["name"])
      phase = cond do
        "submit_review" in names -> "review"
        "finish" in names -> "build"
        "submit_refinement" in names -> "refine"
        true -> mode
      end
      %{body: r.body, json: r.json, phase: phase}
    end)
  end

  def exercise(c, s, mode) do
    seed(c, s, mode)
    before_files = files(c)
    before_head = git(c, ["rev-parse", "HEAD"])
    before_approval = approval(c)
    g = group("#{mode}-read", [read_entry("large.json", "1\t" <> fixture_text(s)), ordinary_entry()])
    correction = Path.join(c.root, "request.txt")
    File.write!(correction, s["packet"])

    {out, status, groups, proposed} = case mode do
      "shape" ->
        growth = for n <- 1..s["growthTurns"], do: group("growth-#{n}", [read_entry("pad.txt", "1\t" <> String.duplicate("p", s["limit"] - 3))])
        script(c, Enum.map(growth, &action/1) ++ [{:pause, self(), function("read_file", %{"path" => "ordinary.txt"})}])
        port = Helpers.start_kogen(c, ["intent", "shape", "bounded-case", correction])
        paused = receive do
          {:provider_paused, pid} -> pid
        after
          60_000 -> raise("Shape never reached the completed-reset observation boundary")
        end
        [archive | _] = history(c)
        custody = group("custody", [read_entry(archive.path, "1\t" <> String.trim_trailing(File.read!(archive.path), "\n"))])
        put(c.repo, ".kogen/local/bounded-reproducer/1.json", fixture_text(s))
        synthetic = group("ignored-single-line", [read_entry(".kogen/local/bounded-reproducer/1.json", "1\t" <> fixture_text(s))])
        list = Tools.run("list_files", %{"path" => "corpus"}, context(c))
        search = Tools.run("search_text", %{"path" => "search.txt", "pattern" => "MATCH"}, context(c))
        tools = group("discovery", [
          {"list_files", %{"path" => "corpus"}, %{text: list}},
          {"search_text", %{"path" => "search.txt", "pattern" => "MATCH"}, %{text: search}},
          {"probe", %{"command" => "cat search.txt"}, %{text: File.read!(Path.join(c.repo, "search.txt")), probe: true}}
        ])
        script(c, [action(custody), action(synthetic), action(g), action(tools), function("submit", %{"questions" => [%{"question" => s["question"], "options" => [%{"label" => "Continue", "recommended" => true}]}]})])
        send(paused, :continue)
        {out, status} = Helpers.await_exit(port, "", 90_000)
        {out, status, growth ++ [custody, synthetic, g, tools], nil}
      "refine" ->
        p = Intent.intent_md("fixture")
        changed = File.read!(Path.join(c.repo, p)) <> "\nBounded result fixture correction.\n"
        script(c, [action(g), function("submit_refinement", %{"files" => [%{"path" => p, "content" => changed}]})])
        hash = Intent.hash(c.repo, Intent.baseline(c.repo, "fixture", Config.load!(c.repo)))
        {out, status} = Helpers.run_kogen(c, ["intent", "refine", "fixture", hash, correction])
        {out, status, [g], changed}
      "build-review" ->
        reviewer = group("independent-review-read", [read_entry("large.json", "1\t" <> fixture_text(s)), ordinary_entry()])
        script(c, [action(g), function("write_file", %{"path" => "app.txt", "content" => "bounded implementation\n"}), function("finish", %{"summary" => "Implement fixture"}), action(reviewer), function("submit_review", %{"verdict" => "approve", "findings" => []})])
        {out, status} = Helpers.run_kogen(c, ["intent", "build", "fixture"])
        {out, status, [g, reviewer], nil}
    end
    reqs = requests(c, mode)
    authorities = Map.new(reqs, fn r -> {r.phase, Enum.find(r.json["input"], &(&1["role"] == "user"))} end)
    %{mode: mode, exit: status, output: out, requests: reqs, authorities: authorities, history: history(c), groups: Enum.map(groups, &Map.delete(&1, :items)), files_before: before_files, files_after: files(c), ordinary: Tools.run("read_file", %{"path" => "ordinary.txt", "start_line" => 2, "end_line" => 3}, context(c)), head_before: before_head, head_after: git(c, ["rev-parse", "HEAD"]), approval_before: before_approval, approval_after: approval(c), proposed: proposed, published: File.read!(Path.join(c.repo, Intent.intent_md("fixture"))), app_after: File.read!(Path.join(c.repo, "app.txt"))}
  end

  # Observer controls are local serialized fixtures, not claims that the unimplemented
  # native flow passed. Sources are actual file bytes; outputs use the existing cutter.
  def controls(s) do
    root = Kogen.tmp_path("bounded-observer")
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    try do
      put(root, "large.json", fixture_text(s))
      put(root, "ordinary.txt", "first\n  Δ🙂\r\nlast\n")
      source = Tools.run("read_file", %{"path" => "large.json", "start_line" => 1, "end_line" => 35}, %{root: root, protected: [], tools: ["read_file"]})
      old = group("old", [read_entry("large.json", source), ordinary_entry()])
      archive = Path.join(root, "archive.json")
      bytes = JSON.encode!(%{input: display(old)}) <> "\n"
      File.write!(archive, bytes); File.chmod!(archive, 0o600)
      g = group("control", [read_entry(archive, "1\t" <> String.trim_trailing(bytes, "\n")), ordinary_entry()])
      authority = %{"role" => "user", "content" => s["packet"]}
      ref = %{path: archive, bytes: Base.encode64(File.read!(archive)), sha256: WorkingContext.hash(bytes), mode: Bitwise.band(File.stat!(archive).mode, 0o777), dir_mode: Bitwise.band(File.stat!(root).mode, 0o777)}
      records = for mode <- ["shape", "refine", "build-review"] do
        phases = if mode == "build-review", do: ["build", "review"], else: [mode]
        reqs = Enum.flat_map(phases, fn phase -> [Map.put(body([authority]), :phase, phase), Map.put(body([authority] ++ display(g)), :phase, phase)] end)
        %{mode: mode, exit: s["statuses"][mode], output: s["question"] <> " refined fixture", requests: reqs, authorities: Map.new(phases, &{&1, authority}), history: [ref], groups: [Map.delete(g, :items)], files_before: %{large: WorkingContext.hash(File.read!(Path.join(root, "large.json")))}, files_after: %{large: WorkingContext.hash(File.read!(Path.join(root, "large.json")))}, ordinary: Tools.run("read_file", %{"path" => "ordinary.txt", "start_line" => 2, "end_line" => 3}, %{root: root, protected: [], tools: ["read_file"]}), head_before: "fixture-head", head_after: if(mode == "build-review", do: "landed-head", else: "fixture-head"), approval_before: "fixture-approval", approval_after: if(mode == "shape", do: "fixture-approval", else: nil), proposed: "owned correction", published: "owned correction", app_after: "bounded implementation\n"}
      end
      [boundary(s, true) | records]
    after
      File.rm_rf!(root)
    end
  end

  def main([mode, input, receipt]) do
    s = JSON.decode!(File.read!(input))
    result = case mode do
      "boundary" -> boundary(s, false)
      "control" -> controls(s)
      _ ->
        suite = Helpers.setup_suite!()
        try do
          c = Helpers.project!(suite, [], staged_intent: false)
          try do
            exercise(c, s, mode)
          after
            Helpers.cleanup_case(c)
          end
        after
          Helpers.cleanup_suite(suite)
        end
    end
    File.write!(receipt, JSON.encode!(result))
  end
end

BoundedToolResultsFixture.main(System.argv())
