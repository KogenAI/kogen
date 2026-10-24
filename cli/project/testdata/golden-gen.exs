# Generates cli/project/testdata/golden.json from the Elixir Kogen (main at the migration start):
#   mise exec -- mix run --no-start cli/project/testdata/golden-gen.exs
# The Go tests in cli/project compare their results with these pinned Elixir results.
alias Kogen.{Config, Gherkin, Intent, Yaml}

hdr = "version: 1\n"

config_texts = [
  Config.template(),
  hdr,
  "",
  "\n\n# only a comment\n",
  "- a\n- b\n",
  "just text\n",
  "version: 2\n",
  "version: \"1\"\n",
  "version: '1'\n",
  "version: true\n",
  "commands: {}\n",
  "limits: 3\n",
  hdr <> "limits: 3\n",
  hdr <> "commands: 3\n",
  hdr <> "commands:\n  setup: [a, b]\n",
  hdr <> "commands:\n  setup: [a, ]\n",
  hdr <> "commands:\n  setup: [a,, b]\n",
  hdr <> "commands:\n  setup: [a, b\n",
  hdr <> "commands:\n  setup: []\n  fix: []\n  checks: []\n",
  hdr <> "commands:\n  setup:\n    - mix deps.get\n    - 'npm ci'\n    - \"echo \\\"hi\\\"\"\n",
  hdr <> "commands:\n  setup:\n    - true\n    - 3\n    - 'ok'\n    -\n",
  hdr <> "commands:\n  setup:\n  - a\n  - b\nprotect:\n- x\n- y\n",
  hdr <> "commands:\n  setup:\n    -a\n",
  hdr <> "commands:\n  setup:\n    - a\n      b\n",
  hdr <> "commands:\n  setup: [a]\n    extra\n",
  hdr <> "commands:\n  setup: a\n",
  hdr <> "commands:\n  fix: [mix format] # comment\n  # full comment\n  checks: [{name: t, run: 'a # b'}]\n",
  hdr <> "commands:\n  checks: [{name: t, run: \"a # b\"}, {name: lint, run: x}]\n",
  hdr <> "commands:\n  checks: [{name: t, name: u, run: x}]\n",
  hdr <> "commands:\n  checks: [{name: t, run: x]\n",
  hdr <> "commands:\n  checks: [{name t}]\n",
  hdr <> "commands:\n  checks: [{name: t, run: x, extra: 1}]\n",
  hdr <> "commands:\n  checks:\n    - name: a-b-c\n      run: x\n    - name: a--b\n      run: y\n",
  hdr <> "commands:\n  checks:\n    - name: a\n      run: x\n      extra: 1\n    - name: b\n",
  hdr <> "commands:\n  checks:\n    - just text\n    - [a]\n    -\n",
  hdr <> "commands:\n  checks:\n    -\n      name: z\n      run: q\n",
  hdr <> "commands:\n  checks:\n    - name: 1\n      run: x\n",
  hdr <> "commands:\n  checks:\n    - name: 'x'\n      run: ''\n",
  hdr <> "commands:\n  checks:\n    - name: x\n      run: ~\n",
  hdr <> "commands:\n  acceptance:\n    run: 'a'\n    steps_dir: features/steps///\n",
  hdr <> "commands:\n  acceptance:\n    run: a\n",
  hdr <> "commands:\n  acceptance:\n    steps_dir: s\n",
  hdr <> "commands:\n  acceptance: {run: x, steps_dir: y/}\n",
  hdr <> "commands:\n  acceptance: {run: x, steps_dir: y, extra: 1}\n",
  hdr <> "commands:\n  acceptance: [a]\n",
  hdr <> "commands:\n  acceptance:\n    run: [a]\n",
  hdr <> "commands:\n  acceptance:\n    run: ''\n    steps_dir: ''\n",
  hdr <> "commands:\n  acceptance:\n    run: 1.5\n",
  hdr <> "commands:\n  acceptance:\n    run: 1e5\n    steps_dir: v1.2\n",
  hdr <> "commands:\n  acceptance:\n    run: null\n    steps_dir: ~\n",
  hdr <> "commands:\n  acceptance:\n    run: |\n      text\n",
  hdr <> "commands:\n  acceptance:\n    run: &a x\n",
  hdr <> "commands:\n  acceptance:\n    run: !tag x\n",
  hdr <> "commands:\n  acceptance:\n    run: \"bad \\q escape\"\n",
  hdr <> "commands:\n  acceptance:\n    run: \"unclosed\n",
  hdr <> "commands:\n  acceptance:\n    run: 'it''s'\n",
  hdr <> "commands:\n  acceptance:\n    run: \"a\" trailing\n",
  hdr <> "commands:\n  acceptance:\n    run: \"tab\\there\\nnl \\\\ \\\"q\\\"\"\n",
  hdr <> "commands:\n\tsetup: []\n",
  hdr <> "commands:\n   setup: []\n  fix: []\n",
  hdr <> "commands:\n  setup: []\n    fix: []\n",
  hdr <> "protect: [a, 'b/c', \"d\"]\n",
  hdr <> "protect:\n  - '.credo.exs'\n  - config/**/*.yaml\n",
  hdr <> "protect: x\n",
  hdr <> "protect: [1, true]\n",
  hdr <> "protect:\n",
  hdr <> "models:\n  build: {model: gpt-6-luna, effort: high}\n",
  hdr <> "models:\n  plan: {model: old, effort: high}\n  build: {model: m, effort: e}\n",
  hdr <> "models:\n  plan: garbage\n",
  hdr <> "models:\n  other: {model: m, effort: e}\n",
  hdr <> "models:\n  build: {model: m}\n",
  hdr <> "models:\n  build: {model: m, effort: e, extra: 1}\n",
  hdr <> "models:\n  build: [m, e]\n",
  hdr <> "models:\n  build: {model: 1, effort: high}\n",
  hdr <> "models:\n  build: {model: '', effort: ''}\n",
  hdr <> "models: x\n",
  hdr <> "models:\n  build:\n    model: m\n    effort: e\n    provider: chatgpt\n",
  hdr <> "models:\n  build:\n    model: grok-4.7\n    effort: xhigh\n    provider: supergrok\n  shape: {model: grok-4, effort: low, provider: supergrok}\n",
  hdr <> "models:\n  review: {model: m, effort: e, provider: }\n",
  hdr <> "models:\n  review: {model: m, effort: e, provider: 'chatgpt'}\n",
  hdr <> "models:\n  shape: {model: claude-opus-5-5, effort: max, provider: anthropic}\n  build: {model: kimi-k3, effort: default, provider: opencode-go}\n  review: {model: claude-sonnet-5-5, effort: low, provider: anthropic}\n",
  hdr <> "models:\n  shape: {model: claude-opus-5-5, effort: xhigh, provider: anthropic}\n",
  hdr <> "models:\n  build: {model: claude-haiku-5-5, effort: high, provider: anthropic}\n",
  hdr <> "models:\n  build: {model: kimi-k3, effort: low, provider: opencode-go}\n",
  hdr <> "models:\n  build: {model: grok-4.7, effort: high, provider: opencode-go}\n",
  hdr <> "models:\n  review: {model: m, effort: e, provider: claude}\n",
  hdr <> "shape_workers:\n  enabled: true\n  read: {model: kimi-k3, effort: high, provider: opencode-go}\n  probe: {model: claude-sonnet-5-5, effort: medium, provider: anthropic}\n  draft: {model: grok-4.7, effort: low, provider: supergrok}\n",
  hdr <> "shape_workers:\n  enabled: true\n  read: {model: kimi-k3, effort: max, provider: opencode-go}\n  probe: {model: claude-sonnet-5-5, effort: default, provider: anthropic}\n  draft: {model: m, effort: e}\n",
  hdr <> "shape_workers:\n  enabled: false\n",
  hdr <> "shape_workers:\n  enabled: true\n",
  hdr <> "shape_workers:\n  enabled: 'true'\n",
  hdr <> "shape_workers:\n  enabled: yes\n",
  hdr <> "shape_workers:\n  enabled: true\n  read: {model: a, effort: b}\n  probe: {model: a, effort: b, provider: chatgpt}\n  draft: {model: grok-4.7, effort: low, provider: supergrok}\n",
  hdr <> "shape_workers:\n  enabled: true\n  read: {model: a, effort: b}\n",
  hdr <> "shape_workers:\n  enabled: false\n  read: {model: ' ', effort: b}\n  draft: [x]\n  probe: {model: a, effort: b, extra: 1}\n",
  hdr <> "shape_workers:\n  extra: 1\n",
  hdr <> "shape_workers: x\n",
  hdr <> "shape_workers: {enabled: true, read: {model: a, effort: b}}\n",
  hdr <> "shape_workers:\n  read:\n    model: a\n    effort: b\n",
  hdr <> "a: 1\nb: 2\nc: 3\n",
  "commands:\n  setup: []\n",
  "models:\n  build: {model: a, effort: b}\nprotect: x\n",
  hdr <> "commands:\n  setup: [a]\ncommands:\n  fix: [b]\n",
  hdr <> "commands:\n  setup: {a: 1, a: 2}\n",
  hdr <> "commands:\n  setup: {a: [1, 2], b: {c: d}, e}\n",
  hdr <> "commands:\n  setup: [[a, b], {c: d}]\n",
  hdr <> "key with space: 1\n",
  hdr <> "commands:\n  setup:\n    - a: b\n    - c\n",
  hdr <> "commands:\n  setup:\n    - 'a'  \n    -    b   \n",
  hdr <> "commands:\n  setup: ['a' , \"b\"  ,c]\n",
  hdr <> "commands:\n  setup: [a b, c d]\n",
  hdr <> "commands:\n  setup: ['unclosed]\n",
  hdr <> "commands:\n  setup: [a] [b]\n",
  hdr <> "commands:\n  setup: [a]x\n",
  hdr <> "commands:\n  setup: [{a: 1}]\n",
  hdr <> "commands:\n  setup: [{a: }]\n",
  hdr <> "commands:\n  setup: [{a: 1,}]\n",
  hdr <> "commands:\n  setup:\n    - 'é ü' \n    - \"ñ\"\n",
  hdr <> "commands:\r\n  setup: [a]\r\n",
  hdr <> "# lead\nversion: 1 # trailing\ncommands: # c\n  setup: [a] # c2\n",
  hdr <> "commands:\n  checks:\n    - name: a\n      run: x # not a comment? yes it is\n",
  hdr <> "commands:\n  checks:\n    - name: a\n      run: \"x # kept\" # dropped\n",
  hdr <> "commands:\n  checks:\n    - {name: a, run: 'x'}\n    - name: b\n      run: y\n",
  hdr <> "commands:\n  checks:\n  - name: a\n    run: x\n"
]

normalize = fn config ->
  %{
    "setup" => config.setup,
    "fix" => config.fix,
    "checks" => Enum.map(config.checks, fn {n, r} -> [n, r] end),
    "acceptance_run" => config.acceptance_run,
    "steps_dir" => config.steps_dir,
    "protect" => config.protect,
    "models" =>
      Map.new(config.models, fn {k, v} ->
        {k, %{"model" => v.model, "effort" => v.effort, "provider" => Map.get(v, :provider)}}
      end),
    "shape_workers" =>
      Map.new(config.shape_workers, fn
        {:enabled, b} -> {"enabled", b}
        {k, v} -> {k, %{"model" => v.model, "effort" => v.effort, "provider" => Map.get(v, :provider)}}
      end)
  }
end

config_cases =
  for text <- config_texts do
    result =
      try do
        %{"config" => normalize.(Config.parse!(text, "/p/.kogen/project.yaml"))}
      rescue
        e in Kogen.Error ->
          %{"error" => %{"class" => e.class, "reason" => e.reason, "detail" => e.detail, "exit" => e.exit, "lines" => e.lines}}
      end

    %{"text" => text, "result" => result}
  end

render_inputs = [
  %{setup: [], fix: [], checks: [], protect: [], acceptance: nil},
  %{setup: ["mix deps.get"], fix: [], checks: [], protect: [], acceptance: nil},
  %{setup: [], fix: ["mix format"], checks: [%{name: "test", run: "mix test"}], protect: [], acceptance: nil},
  %{setup: ["it's", "a b"], fix: ["x"], checks: [%{name: "a", run: "echo 'q'"}, %{name: "b", run: "y"}], protect: [".formatter.exs", "a'b"], acceptance: %{run: "run it's", steps_dir: "features/steps"}},
  %{setup: [], fix: [], checks: [], protect: ["x/**"], acceptance: %{run: "c", steps_dir: "s"}},
  %{setup: [], fix: [], checks: [%{name: "only", run: "go test ./..."}], protect: [], acceptance: %{run: "", steps_dir: ""}}
]

render_cases =
  for input <- render_inputs do
    text = Config.render(input)
    # The rendered text must parse back; record that too.
    parsed = normalize.(Config.parse!(text, "r"))
    %{"input" => %{
        "setup" => input.setup, "fix" => input.fix,
        "checks" => Enum.map(input.checks, &[&1.name, &1.run]),
        "protect" => input.protect,
        "acceptance" => input.acceptance && [input.acceptance.run, input.acceptance.steps_dir]
      }, "text" => text, "parsed" => parsed}
  end

conv = fn conv, node ->
  case node do
    {:map, l, pairs} -> ["map", l, Enum.map(pairs, fn {k, kl, n} -> [k, kl, conv.(conv, n)] end)]
    {:seq, l, items} -> ["seq", l, Enum.map(items, &conv.(conv, &1))]
    {:scalar, l, t, kind} -> ["scalar", l, t, Atom.to_string(kind)]
  end
end

yaml_cases =
  for text <- config_texts ++ ["a: [1\n", "a:\n  - b\n  c: d\n", "- a\n  b: c\n", "a: b\n c: d\n", "  a: 1\n  b: 2\n", "a: 1\n  b: 2\n", "-\n- a\n", "- - a\n", "a: 'x\n"] do
    result =
      case Yaml.parse(text) do
        {:ok, node} -> %{"ok" => conv.(conv, node)}
        {:error, [{n, m}]} -> %{"error" => [n, m]}
      end

    %{"text" => text, "result" => result}
  end

# ---- Gherkin ----
features = [
  "Feature: A\n  Scenario: one\n    Given a\n    Then b\n",
  "@ft\nFeature: A\n  @a @b\n  Scenario: one\n    Given a\n    Then b\n  Scenario: two\n    When c\n    Then d\n",
  "Feature: A\n  Background:\n    Given bg\n  Scenario: one\n    Then x\n  Scenario: two\n    Then y\n",
  "Feature: A\n  Scenario: one\n    Then x\n  Background:\n    Given late\n  Scenario: two\n    Then y\n",
  "Feature: A\n  Background:\n    Given bg\n  Rule: r1\n    Background:\n      Given rbg\n    Scenario: in\n      Then x\n  Rule: r2\n    Scenario: in2\n      Then y\n",
  "@t1\nFeature: A\n  @rt\n  Rule: r\n    @st\n    Scenario: s\n      Then x\n  Scenario: after rule\n    Then y\n",
  "Feature: A\n  Scenario Outline: o <x> <y>\n    Given <x> and <y>\n    Then ok <x>\n    Examples:\n      | x | y |\n      | 1 | 2 |\n      | 3 | 4 |\n    @ex\n    Examples: more\n      | x | y |\n      | 5 | 6 |\n",
  "Feature: A\n  Scenario Template: t <a>\n    Then <a>\n    Scenarios:\n      | a |\n      | <b> |\n      | z |\n",
  "Feature: A\n  Scenario Outline: o\n    Then x\n    Examples:\n      | a |\n",
  "Feature: A\n  Scenario Outline: o\n    Then x\n",
  "Feature: A\n  Scenario Outline: o\n    Then x\n    Examples:\n      | a | b |\n      | 1 |\n",
  "Feature: A\n  Scenario: s\n    Then x\n    Examples:\n      | a |\n",
  "Feature: A\n  Scenario: s\n    Then x\n      | a |\n      | b |\n      | no end\n",
  "Feature: A\n  Scenario: s\n    Then x\n      | a | b\\|c |\n      | 1 | 2 |\n",
  "Feature: A\n  Scenario: s\n    Then x\n      \"\"\"\n      Given not a step\n      | a |\n      \"\"\"\n    And y\n",
  "Feature: A\n  Scenario: s\n    Then x\n      ```json\n      {}\n      ```\n",
  "Feature: A\n  Scenario: s\n    Then x\n      \"\"\"\n      open\n",
  "Feature: A\n  Scenario: s\n    \"\"\"\n    doc\n    \"\"\"\n",
  "Feature: A\n  Scenario: s\n    Then x\n  random text here\n",
  "Feature: A\n  description line\n  Scenario: s\n    description\n    Then x\n",
  "Feature: A\n  Scenario: s\n    Then x\n  @bad tag\n  Scenario: t\n    Then y\n",
  "Feature: A\n  @a #comment\n  Scenario: s\n    Then x\n",
  "Feature: A\n  @a # comment @b\n  Scenario: s\n    Then x\n",
  "Scenario: s\n  Then x\n",
  "",
  "# comment only\n",
  "@tag\n",
  "Feature: A\n",
  "Feature: A\n  Scenario: s\n",
  "Feature: A\n  Scenario: s\n    * star\n    But not\n    And more\n",
  "Feature: A\n  Scenario: s\n    Given\n",
  "Feature: A\n  Scenario: s\n    Thenx\n",
  "Feature: A\n  Example: e\n    Then x\n",
  "Feature: A\n  Background:\n    Given b\n      | a |\n  Scenario: s\n    Then x\n",
  "Feature: A\n  Scenario: s\n    Then x\n  Background:\n    Then y\n  Rule: r\n    Scenario: t\n      Then z\n",
  "Feature: A\n  Scenario: s\n    Then x @a\n",
  "Feature: A\n  Scenario: s\n    Then x\n  Rule: r\n    Background:\n      Given a\n  Rule: q\n    Scenario: t\n      Then z\n",
  "Feature: A\n\n  Scenario: with colon: in name\n    Then x\n",
  "Feature: A\r\n  Scenario: crlf\r\n    Given a\r\n    Then b\r\n",
  "Feature: A\n  Scenario Outline: o <a>\n    Then <a><a>\n    Examples:\n      | a |\n      | <a>x |\n",
  "Feature: A\n  Scenario Outline: o\n    Examples:\n      | a |\n      | 1 |\n    Then late\n",
  "Feature: A\n  Scenario Outline: o\n    Then x\n    Examples:\n      | a |\n      | 1 |\n    Examples:\n",
  "Feature: A\n  Scenario Outline: o <n>\n    Then x\n    Examples:\n      | n |\n      | 1 |\n  Scenario: plain\n    Then y\n",
  "@x\nFeature: A\n  @y\n  Rule: r\n    @z\n    Scenario Outline: o\n      Then q\n      @e\n      Examples:\n        | a |\n        | 1 |\n",
  "Feature: A\n  Scenario: s\n    Then x\n  |\n",
  "Feature: A\n  Scenario: s\n    Then x\n      ||\n      |\n"
]

gherkin_cases =
  for text <- features do
    result =
      case Gherkin.parse(text) do
        {:ok, scenarios} ->
          %{
            "scenarios" =>
              Enum.map(scenarios, fn s ->
                %{
                  "name" => s.name,
                  "line" => s.line,
                  "tags" => s.tags,
                  "steps" => Enum.map(s.steps, &[&1.keyword, &1.text, &1.line]),
                  "outline" => if(Map.has_key?(s, :outline_line), do: [s.outline_name, s.outline_line, s.outline_examples])
                }
              end)
          }

        {:error, n, msg} ->
          %{"error" => [n, msg]}
      end

    %{"text" => text, "result" => result}
  end

# ---- Intent check ----
model_json = fn
  :none -> "none"
  nil -> nil
  m -> m
end

slug = "demo-intent"
feature_p = Intent.feature(slug)
md_p = Intent.intent_md(slug)
model_p = Intent.model_path(slug)
good_feature = "Feature: F\n  Scenario: s\n    Then it works\n"
good_model = "module m {\n  val Inv = true\n  def Other = 1\n}\n"

intent_md = fn opts ->
  title = Keyword.get(opts, :title, "# Demo title")
  slug_line = Keyword.get(opts, :slug, "Slug: #{slug}")
  model = Keyword.get(opts, :model, "Model: not applicable — display only")
  acc = Keyword.get(opts, :acc, "Acceptance:\n- #{feature_p}")
  dec = Keyword.get(opts, :dec, "## Decisions\n\n- Do it (source: request)\n")
  feas = Keyword.get(opts, :feas, "## Feasibility\n\n- none\n")
  tests = Keyword.get(opts, :tests, "## Tests\n\n- rule: add a test (unit)\n")
  Enum.join([title, slug_line, model, acc, "", "prose", "", dec, feas, tests], "\n")
end

base_overlay = %{feature_p => good_feature}

intent_cases_in = [
  {"good", %{md_p => intent_md.([])}},
  {"missing intent", %{}},
  {"missing feature", %{md_p => intent_md.([])} |> Map.delete(feature_p), :nofeature},
  {"bad gherkin", %{md_p => intent_md.([]), feature_p => "Feature: F\n  Scenario: s\n    Then a\n  stray words\n"}},
  {"no title", %{md_p => intent_md.(title: "no title line")}},
  {"empty title", %{md_p => intent_md.(title: "# ")}},
  {"long title", %{md_p => intent_md.(title: "# " <> String.duplicate("a", 51))}},
  {"title 50", %{md_p => intent_md.(title: "# " <> String.duplicate("a", 50))}},
  {"title combining", %{md_p => intent_md.(title: "# " <> String.duplicate("e\u0301", 50))}},
  {"title emoji", %{md_p => intent_md.(title: "# " <> String.duplicate("👩‍👩‍👧", 40) <> String.duplicate("🇧🇦", 10))}},
  {"title long cjk", %{md_p => intent_md.(title: "# " <> String.duplicate("日", 51))}},
  {"title period", %{md_p => intent_md.(title: "# Ends with period.")}},
  {"wrong slug", %{md_p => intent_md.(slug: "Slug: other")}},
  {"no slug", %{md_p => intent_md.(slug: "")}},
  {"slug spaces", %{md_p => intent_md.(slug: "Slug:   #{slug}  ")}},
  {"no model", %{md_p => intent_md.(model: "")}},
  {"model hyphen", %{md_p => intent_md.(model: "Model: not applicable - because")}},
  {"model no reason", %{md_p => intent_md.(model: "Model: not applicable — ")}},
  {"model nbsp reason", %{md_p => intent_md.(model: "Model: not applicable —\u00a0x")}},
  {"model garbage", %{md_p => intent_md.(model: "Model: whatever")}},
  {"model ok", %{md_p => intent_md.(model: "Model: #{model_p} invariants=Inv,Other seed=1 samples=2 steps=3"), model_p => good_model}},
  {"model missing file", %{md_p => intent_md.(model: "Model: #{model_p} invariants=Inv seed=1 samples=2 steps=3")}},
  {"model wrong path", %{md_p => intent_md.(model: "Model: other.qnt invariants=Inv seed=1 samples=2 steps=3")}},
  {"model missing invariant", %{md_p => intent_md.(model: "Model: #{model_p} invariants=Inv,Nope,Gone seed=1 samples=2 steps=3"), model_p => good_model}},
  {"model word boundary", %{md_p => intent_md.(model: "Model: #{model_p} invariants=In seed=1 samples=2 steps=3"), model_p => good_model}},
  {"model bad numbers", %{md_p => intent_md.(model: "Model: #{model_p} invariants=Inv seed=x samples=2 steps=3"), model_p => good_model}},
  {"acc not feature first", %{md_p => intent_md.(acc: "Acceptance:\n- other.js\n- #{feature_p}")}},
  {"acc none", %{md_p => intent_md.(acc: "")}},
  {"acc missing file", %{md_p => intent_md.(acc: "Acceptance:\n- #{feature_p}\n- features/steps/x.js")}},
  {"acc overlay file", %{md_p => intent_md.(acc: "Acceptance:\n- #{feature_p}\n- features/steps/x.js"), "features/steps/x.js" => "//"}},
  {"acc ignored", %{md_p => intent_md.(acc: "Acceptance:\n- #{feature_p}\n- ignored.js"), "ignored.js" => "//"}},
  {"acc ignored dir", %{md_p => intent_md.(acc: "Acceptance:\n- #{feature_p}\n- build/out.js"), "build/out.js" => "//"}},
  {"acc blank lines", %{md_p => intent_md.(acc: "Acceptance:\n\n \t\n- #{feature_p}\n\n- later")}},
  {"acc crlf", %{md_p => String.replace(intent_md.([]), "\n", "\r\n")}},
  {"decision no source", %{md_p => intent_md.(dec: "## Decisions\n\n- Do it\n- Other (source: answer 2)\n")}},
  {"decision answer", %{md_p => intent_md.(dec: "## Decisions\n- Do it (source: answer 12)  \n")}},
  {"decision bad answer", %{md_p => intent_md.(dec: "## Decisions\n- Do it (source: answer x)\n")}},
  {"no decisions", %{md_p => intent_md.(dec: "")}},
  {"no feasibility", %{md_p => intent_md.(feas: "")}},
  {"empty feasibility", %{md_p => intent_md.(feas: "## Feasibility\n\nprose only\n\n")}},
  {"no tests", %{md_p => intent_md.(tests: "")}},
  {"empty tests", %{md_p => intent_md.(tests: "## Tests\n\nprose\n")}},
  {"bad tests", %{md_p => intent_md.(tests: "## Tests\n- no layer here\n- none: \n- none: reason\n- rule: thing (bogus)\n- rule: thing (existing)\n- a: b (integration)\n")}},
  {"tests none ok", %{md_p => intent_md.(tests: "## Tests\n- none: copy change\n")}},
  {"no scenario", %{md_p => intent_md.([]), feature_p => "Feature: F\n"}},
  {"no then", %{md_p => intent_md.([]), feature_p => "Feature: F\n  Scenario: s\n    Given a\n    And b\n"}},
  {"star then", %{md_p => intent_md.([]), feature_p => "Feature: F\n  Scenario: s\n    * a\n"}},
  {"tagged", %{md_p => intent_md.([]), feature_p => "@wip\nFeature: F\n  @skip @manual\n  Scenario: s\n    Then a\n  @ignore\n  Scenario: t\n    Given b\n"}},
  {"tagged outline", %{md_p => intent_md.([]), feature_p => "Feature: F\n  @pending\n  Scenario Outline: o <x>\n    Given a\n    Examples:\n      | x |\n      | 1 |\n      | 2 |\n"}},
  {"many problems", %{md_p => "no title\nno slug\n", feature_p => "Feature: F\n"}}
]

tmp = Path.join(System.tmp_dir!(), "kogen-golden-#{System.unique_integer([:positive])}")
File.mkdir_p!(tmp)
{_, 0} = System.cmd("git", ["init", "--quiet"], cd: tmp)
File.write!(Path.join(tmp, ".gitignore"), "ignored.js\nbuild/\n")

intent_cases =
  for c <- intent_cases_in do
    label = elem(c, 0)
    overlay = if tuple_size(c) == 3, do: elem(c, 1), else: Map.merge(base_overlay, elem(c, 1))

    result =
      case Intent.check(tmp, slug, overlay) do
        {:ok, intent, scenarios} ->
          %{"ok" => %{
              "title" => intent.title,
              "acceptance" => intent.acceptance,
              "model" => model_json.(Intent.model(intent)),
              "decisions" => intent.decisions,
              "tests" => intent.tests,
              "feasibility" => intent.feasibility,
              "scenarios" => length(scenarios)
            }}

        {kind, problems} ->
          %{"problems" => [Atom.to_string(kind) | problems]}
      end

    %{"label" => label, "overlay" => overlay, "result" => result}
  end

File.rm_rf!(tmp)

# Intent.read of odd texts (acceptance/section edges)
read_texts = [
  "",
  "# T\nSlug: s\nModel: not applicable — x\nAcceptance:\n\n- a\n- b\nnot bullet\n- c\n",
  "Acceptance:\n\n## Decisions\n- unrelated\n",
  "Acceptance:\n- a\nordinary text\n- unrelated\n",
  "Acceptance:\n\n- a\n\n- unrelated\n",
  "  Acceptance:  \n  - a\n- b  \n-  c\n-d\n",
  "# T\n#not title\n# Second\n## Decisions\n- d1\nprose\n- d2\n## Tests\n- t1\n# H1\n- t2\n## Feasibility\n- f\n",
  "## Tests\n- t1\n## Tests\n- t2\n",
  "Model:  x  \nModel: y\nSlug:  s \nSlug: t\n"
]

read_cases =
  for t <- read_texts do
    i = Intent.read("/nonexistent", "demo-intent", %{md_p => t})
    %{"text" => t, "result" => %{
        "title" => i.title, "slug_line" => i.slug_line, "model" => i.model,
        "model_spec" => model_json.(Intent.model(i)),
        "acceptance" => i.acceptance, "decisions" => i.decisions,
        "feasibility" => i.feasibility, "tests" => i.tests
      }}
  end

# ---- Detect ----
json = &JSON.encode!/1
detect_inputs = [
  {%{}, []},
  {%{"mix.exs" => ""}, ["mix.exs"]},
  {%{"mix.exs" => "deps: [:credo]"}, ["mix.exs", ".credo.exs"]},
  {%{"mix.exs" => "deps: [:credo]"}, ["mix.exs", ".formatter.exs"]},
  {%{"mix.exs" => "x"}, ["mix.exs", ".formatter.exs", ".credo.exs"]},
  {%{"package.json" => json.(%{"scripts" => %{"test" => "jest", "lint" => "eslint", "typecheck" => "tsc", "check" => "x", "build" => "b"}})}, ["package.json", "package-lock.json"]},
  {%{"package.json" => json.(%{"scripts" => %{"test" => "  echo \"Error: no test specified\" && exit 1  "}})}, ["package.json"]},
  {%{"package.json" => json.(%{"scripts" => "nope"})}, ["package.json"]},
  {%{"package.json" => json.(%{"scripts" => %{"test" => 1, "lint" => nil}})}, ["package.json"]},
  {%{"package.json" => "not json"}, ["package.json"]},
  {%{"package.json" => "[1,2]"}, ["package.json"]},
  {%{"package.json" => ""}, ["package.json"]},
  {%{"package.json" => json.(%{"dependencies" => %{"@cucumber/cucumber" => "1"}})}, ["package.json", "features/step_definitions/x.js", "features/steps/y.js"]},
  {%{"package.json" => json.(%{"devDependencies" => %{"@cucumber/cucumber" => "1"}})}, ["package.json", "features/step_definitions/x.js"]},
  {%{"package.json" => json.(%{"devDependencies" => %{"@cucumber/cucumber" => "1"}})}, ["package.json", "features/steps.js"]},
  {%{"package.json" => json.(%{"dependencies" => "x", "devDependencies" => []})}, ["package.json"]},
  {%{"mix.exs" => "", "package.json" => json.(%{"scripts" => %{"test" => "jest", "check" => "c"}})}, ["mix.exs", "package.json", "package-lock.json"]},
  {%{"mix.exs" => "", "package.json" => json.(%{"scripts" => %{"test" => "jest"}}), "go.mod" => "module x"}, ["mix.exs", "package.json", "go.mod"]},
  {%{"go.mod" => "module x"}, ["go.mod"]},
  {%{"go.mod" => "module x"}, []},
  {%{"cli/go.mod" => "module x"}, ["cli/go.mod"]},
  {%{"cli/go.mod" => "module x", "go.mod" => "module y"}, ["cli/go.mod", "go.mod"]},
  {%{"cli/go.mod" => "module x", "go.mod" => "module y"}, ["go.mod"]}
]

detect_cases =
  for {files, tracked} <- detect_inputs do
    d = Kogen.Detect.detect(files, tracked)
    %{"files" => files, "tracked" => tracked, "result" => %{
        "setup" => d.setup, "fix" => d.fix,
        "checks" => Enum.map(d.checks, &[&1.name, &1.run]),
        "protect" => d.protect, "runner" => d.runner
      }}
  end

acceptance = %{
  "project" => Kogen.Detect.acceptance_command("features/steps", :project),
  "kogen" => Kogen.Detect.acceptance_command("features/step_definitions", :kogen)
}

out = %{
  "config" => config_cases,
  "render" => render_cases,
  "yaml" => yaml_cases,
  "gherkin" => gherkin_cases,
  "intent" => intent_cases,
  "intent_read" => read_cases,
  "detect" => detect_cases,
  "acceptance" => acceptance
}

File.write!(System.get_env("GOLDEN_OUT", "cli/project/testdata/golden.json"), JSON.encode!(out) <> "\n")
IO.puts("golden written")
