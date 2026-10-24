# Generates cli/project/testdata/facts-golden.json from the Elixir Kogen (main at the migration start):
#   mise exec -- mix run --no-start cli/project/testdata/facts-gen.exs
# The Go tests of facts.go and provenance.go compare their results with these pinned Elixir results:
# the configuration digest of Kogen.SourceProvenance.origin/2, JSON.encode! bytes, the Source
# comparison reader, and the exact files that capture, publish, refine and LocalFacts.package write
# for one fixed repository (fixed identities and dates, so the commit and tree ids are stable).
alias Kogen.{Config, Intent, LocalFacts, SourceProvenance, WorkingContext}

hdr = "version: 1\n"

config_texts = [
  Config.template(),
  hdr,
  File.read!("cli/project/testdata/parity.json") |> JSON.decode!() |> get_in(["files", ".kogen/project.yaml"]),
  hdr <> "commands:\n  setup: [a, b]\n  fix: ['x y']\n  checks: [{name: t, run: 'mix test'}, {name: lint, run: x}]\nprotect: [a, 'b/']\n",
  hdr <> "commands:\n  acceptance:\n    run: 'a b'\n    steps_dir: features/steps///\n",
  hdr <> "commands:\n  acceptance:\n    run: 'only run'\n",
  hdr <> "commands:\n  acceptance:\n    steps_dir: only/steps\n",
  hdr <> "models:\n  shape:\n    model: m1\n    effort: low\n  plan:\n    model: ignored\n    effort: x\n",
  hdr <> "models:\n  build:\n    provider: chatgpt\n    model: gpt-6.1-sol\n    effort: medium\n  review:\n    provider: supergrok\n    model: grok-4.7\n    effort: xhigh\n",
  hdr <> "shape_workers:\n  enabled: true\n  read:\n    model: a\n    effort: low\n  probe:\n    model: b\n    effort: medium\n  draft:\n    provider: supergrok\n    model: grok-4.7\n    effort: high\n",
  hdr <> "shape_workers:\n  enabled: false\n  read:\n    provider: chatgpt\n    model: a\n    effort: low\n",
  hdr <> "shape_workers:\n  enabled: false\n  draft:\n    model: z\n    effort: low\n  read:\n    model: a\n    effort: low\n",
  hdr <> "commands:\n  setup:\n    - 'Δ 🙂'\n    - \"tab\\there\"\n"
]

config_digests =
  for text <- config_texts do
    config = Config.parse!(text, "x")
    %{"text" => text, "digest" => WorkingContext.hash(:erlang.term_to_binary(config))}
  end

# JSON.encode! over decoded JSON text.
nbsp = <<0xC2, 0xA0>>
ls = <<0xE2, 0x80, 0xA8>>

json_inputs = [
  ~s({"b":1,"a":[1,2,{"z":null,"y":true}],"A":"x"}),
  ~s({"k":"tab\\t nl\\n cr\\r bs\\b ff\\f q\\" bsl\\\\ slash\\/ ctl\\u0001\\u001f del\\u007f"}),
  ~s({"k":"<>& é 🙂 診断 ) <> ls <> nbsp <> ~s("}),
  ~s({"é":1,"e":2,"z":3,"Z":4,"10":5,"9":6,"":7}),
  ~s({"i":123456789012345678901234567890,"neg":-5,"f":false}),
  ~s([]),
  ~s({"m":{},"l":[[],[[]]]})
]

json_cases =
  for text <- json_inputs do
    %{"input" => text, "output" => JSON.encode!(JSON.decode!(text))}
  end

# Source comparison reader.
cmp_prefix = "# Example\n\n"

cmp_texts = [
  cmp_prefix <> "## Source comparison\nreport\n\n## Tests\n",
  "## Source comparison\nreport",
  "## Source comparison   \nreport\n",
  "## Source comparison\t\nrep\n## next\nmore",
  "## Source comparison\r\nreport\r\n",
  "## Source comparison\n\n## Tests\n",
  "## Source comparison\n## Tests\nbody\n",
  "## Source comparison\n\n   \n## Tests\n",
  "## Source comparison\n" <> nbsp <> "x" <> nbsp <> "\n## T\n",
  "## Source comparison\n" <> ls <> "x " <> ls <> "\n",
  "## Source comparison",
  "## Source comparison\n",
  "x ## Source comparison\nreport\n",
  "## Source comparison heading\nreport\n",
  "## Source comparison\nfirst\n### sub\nstill\n## Other\n",
  "# T\n## Source comparison\nA\n## Source comparison\nB\n",
  "## Source comparison",
  "## Source comparison\n" <> String.duplicate("x", 8192),
  "## Source comparison\n" <> String.duplicate("x", 8193),
  "## Source comparison\n  " <> String.duplicate("y", 8192) <> "  \n## T",
  "## Source comparison\n" <> String.duplicate("Δ", 4096) <> "\n",
  "## Source comparison\n" <> String.duplicate("Δ", 4097) <> "\n",
  "# Missing\n",
  ""
]

comparison_root = Kogen.tmp_path("prov-gen-cmp")
File.mkdir_p!(Path.join(comparison_root, ".kogen/intents/ex"))

comparison_cases =
  for text <- cmp_texts do
    File.write!(Path.join(comparison_root, Intent.intent_md("ex")), text)

    result =
      try do
        %{"ok" => SourceProvenance.comparison(comparison_root, "ex")}
      rescue
        e in Kogen.Error ->
          %{"error" => %{"class" => e.class, "reason" => e.reason, "detail" => e.detail, "exit" => e.exit}}
      end

    %{"text" => text, "result" => result}
  end

File.rm_rf!(comparison_root)

# One fixed repository.
parity = File.read!("cli/project/testdata/parity.json") |> JSON.decode!()

repo_files =
  parity["files"]
  |> Map.take([
    ".kogen/project.yaml",
    ".formatter.exs",
    "mix.exs",
    ".kogen/intents/build-continuity/acceptance.feature",
    ".kogen/intents/build-continuity/model.qnt",
    "features/steps/build_continuity_steps.js"
  ])
  |> Map.put(
    ".kogen/intents/build-continuity/intent.md",
    parity["files"][".kogen/intents/build-continuity/intent.md"] <>
      "\n## Source comparison\naddressed: request 1 -> Intent; omitted: literal 'Δ 🙂'\n\n## Tail\nmore\n"
  )
  |> Map.put(".kogen/intents/broken/intent.md", "# Broken\n\n## Source comparison\nonly this\n")
  |> Map.put(".gitignore", "ignored.txt\n")
  |> Map.put("src/main.txt", "main\n")

untracked = %{"notes.txt" => "untracked\n", "ignored.txt" => "ignored\n"}

git_env = [
  {"GIT_CONFIG_GLOBAL", "/dev/null"},
  {"GIT_CONFIG_NOSYSTEM", "1"},
  {"GIT_AUTHOR_NAME", "Kogen Test"},
  {"GIT_AUTHOR_EMAIL", "kogen-test@example.test"},
  {"GIT_COMMITTER_NAME", "Kogen Test"},
  {"GIT_COMMITTER_EMAIL", "kogen-test@example.test"},
  {"GIT_AUTHOR_DATE", "2026-01-01T00:00:00Z"},
  {"GIT_COMMITTER_DATE", "2026-01-01T00:00:00Z"}
]

for {k, v} <- git_env, do: System.put_env(k, v)

root = Kogen.tmp_path("prov-gen-repo")
File.mkdir_p!(root)
git = fn args -> {_, 0} = System.cmd("git", args, cd: root, stderr_to_stdout: true) end
git.(["init", "-q"])
git.(["config", "commit.gpgsign", "false"])

for {p, c} <- repo_files do
  File.mkdir_p!(Path.dirname(Path.join(root, p)))
  File.write!(Path.join(root, p), c)
end

git.(["add", "-A"])
git.(["commit", "-q", "-m", "fixture"])
for {p, c} <- untracked, do: File.write!(Path.join(root, p), c)

config = Config.load!(root)
slug = "build-continuity"
head = Kogen.Git.head(root)

request_text = "  Δ🙂\r\n/private path/診断.txt\n  "

rounds = [
  %{
    "questions" => [
      %{"text" => "Which?", "options" => [%{"label" => "Alpha"}, %{"label" => "Beta", "note" => "n"}]},
      %{"text" => "Free text?"},
      %{"text" => "Letter without options", "options" => nil}
    ],
    "answers" => %{"1" => "b", "2" => "a", "3" => "c", "4" => "z", "10" => "free text"}
  },
  %{
    "questions" => [%{"text" => "One", "options" => [%{"label" => "Only"}, %{"x" => 1}]}],
    "answers" => %{"0" => "a", "1" => "b", "2" => "c", "-1" => "a", "+1" => "a", "3" => "ab", "4" => "a\n", "5" => "", "6" => "Δ"}
  }
]

state = %{
  "request" => request_text,
  "source_path" => "-",
  "rounds" => rounds,
  "origin" => SourceProvenance.origin(root, config)
}

SourceProvenance.capture(root, slug, config, state)
path = SourceProvenance.path(root, slug)
captured = File.read!(path)
contract = Intent.hash(root, Intent.baseline(root, slug, config))

LocalFacts.package(root, slug, config)
LocalFacts.package(root, "broken", config)
checkout = LocalFacts.checkout(root)
package_valid = File.read!(Path.join(root, ".kogen/local/packages/#{slug}.json"))
package_invalid = File.read!(Path.join(root, ".kogen/local/packages/broken.json"))

# Refine: new comparison and contract, one correction appended, the old receipt archived.
ref = SourceProvenance.binding(root, slug)
intent_md = Path.join(root, Intent.intent_md(slug))
File.write!(intent_md, File.read!(intent_md) |> String.replace("addressed: request 1", "addressed: requests 1 and 2"))
correction = SourceProvenance.request("make it faster\n", "corr.txt")
SourceProvenance.refine(root, slug, correction, contract, ref)
refined = File.read!(path)
contract2 = Intent.hash(root, Intent.baseline(root, slug, config))
dir = Path.dirname(path)

files =
  for f <- Enum.sort(File.ls!(dir)), into: %{} do
    {f, File.read!(Path.join(dir, f))}
  end

modes =
  for f <- Enum.sort(File.ls!(dir)), into: %{} do
    {f, Bitwise.band(File.stat!(Path.join(dir, f)).mode, 0o777)}
  end

# A second refine on the new binding (two corrections, two archives).
ref2 = SourceProvenance.binding(root, slug)
File.write!(intent_md, File.read!(intent_md) <> "\n")
SourceProvenance.refine(root, slug, SourceProvenance.request("again", nil), contract2, ref2)
refined2 = File.read!(path)

card = SourceProvenance.card(SourceProvenance.binding(root, slug))

out = %{
  "config_digests" => config_digests,
  "json" => json_cases,
  "comparison" => comparison_cases,
  "repo" => %{
    "files" => repo_files,
    "untracked" => untracked,
    "slug" => slug,
    "head" => head,
    "state" => state,
    "contract_sha256" => contract,
    "captured" => captured,
    "package_valid" => package_valid,
    "package_invalid" => package_invalid,
    "git_dir_hash" => checkout["id"],
    "refine" => %{
      "correction" => correction,
      "ref" => ref,
      "refined" => refined,
      "contract_sha256" => contract2,
      "dir_files" => files,
      "dir_modes" => modes,
      "refined_twice" => refined2,
      "card" => card
    }
  }
}

File.rm_rf!(root)
File.write!("cli/project/testdata/facts-golden.json", JSON.encode!(out) <> "\n")
IO.puts("facts golden written")
