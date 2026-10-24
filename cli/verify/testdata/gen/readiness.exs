# Writes cli/verify/testdata/golden/readiness.json: the version 3 readiness record
# Kogen.Readiness.record_pass!/4 (the Elixir reference) writes for the two fixture projects in
# testdata/readiness-simple and testdata/readiness-full, committed with a fixed identity and
# date so that HEAD and tree are the same in the Go test.
#
#   cd <repo> && mise exec -- mix run --no-start cli/verify/testdata/gen/readiness.exs

alias Kogen.{Config, Gherkin, Intent, Readiness, Snapshot}

git = fn root, args, env ->
  {out, 0} = System.cmd("git", args, cd: root, env: env, stderr_to_stdout: true)
  out
end

date_env = [
  {"GIT_AUTHOR_DATE", "2026-01-01T00:00:00Z"},
  {"GIT_COMMITTER_DATE", "2026-01-01T00:00:00Z"},
  {"GIT_AUTHOR_NAME", "Fixture"},
  {"GIT_AUTHOR_EMAIL", "fixture@example.invalid"},
  {"GIT_COMMITTER_NAME", "Fixture"},
  {"GIT_COMMITTER_EMAIL", "fixture@example.invalid"},
  {"GIT_CONFIG_GLOBAL", "/dev/null"},
  {"GIT_CONFIG_NOSYSTEM", "1"}
]

scenario_json = fn s, status, detail -> Map.merge(s, %{status: status, detail: detail}) end

records =
  for name <- ["readiness-simple", "readiness-full"] do
    root = Path.join(System.tmp_dir!(), "kogen-golden-#{name}-#{System.unique_integer([:positive])}")
    File.cp_r!(Path.join("cli/verify/testdata", name), root)
    git.(root, ["init", "-q"], date_env)
    git.(root, ["config", "commit.gpgsign", "false"], date_env)
    git.(root, ["add", "-A"], date_env)
    git.(root, ["commit", "-qm", "baseline", "--no-verify"], date_env)

    config = Config.load!(root)
    {:ok, intent, _} = Intent.check(root, "fixture")
    {:ok, expected} = Gherkin.parse(File.read!(Path.join(root, Intent.feature("fixture"))))
    baseline = Intent.baseline(root, "fixture", config)
    head = Kogen.Git.head(root)
    tree = Snapshot.tree(root, head, [])

    [a, b] = expected

    ready = %{
      intent: intent,
      feasibility: if(name == "readiness-full", do: nil, else: []),
      model: Intent.model(intent),
      scenarios: [scenario_json.(a, "failed", "acceptance.feature line 3: Then the candidate succeeds\nboom"), scenario_json.(b, "passed", nil)],
      acceptance_exit: 1,
      baseline: baseline,
      sha256: Intent.hash(root, baseline),
      head: head,
      candidate_tree: tree
    }

    ready =
      if name == "readiness-full" do
        # The declared evidence, as readiness executes it.
        proof = Kogen.Feasibility.declarations(intent) |> Enum.map(fn d ->
          %{
            "id" => d["id"],
            "kind" => d["kind"],
            "inputs" => Map.new(d["inputs"], fn p -> {p, Kogen.ShapeContext.hash(File.read!(Path.join(root, p)))} end),
            "observers" => %{},
            "checks" => Enum.map(d["checks"], &Map.put(&1, "timed_out", false))
          }
        end)

        %{ready | feasibility: proof}
      else
        ready
      end

    Readiness.record_pass!(root, "fixture", config, ready)
    record_path = Path.join(root, ".kogen/local/readiness/fixture.json")
    record = File.read!(record_path)
    cached = Readiness.cached(root, "fixture", config)
    true = cached != nil
    packages = File.read!(Path.join(root, ".kogen/local/packages/fixture.json"))

    # What a changed HEAD does to the same record.
    git.(root, ["commit", "--allow-empty", "-qm", "later", "--no-verify"], date_env)
    nil = Readiness.cached(root, "fixture", config)
    false = Readiness.current?(root, "fixture", config, ready)

    File.rm_rf!(root)

    %{
      "project" => name,
      "head" => head,
      "tree" => tree,
      "sha256" => ready.sha256,
      "baseline" => baseline,
      "record" => JSON.decode!(record),
      "record_text" => record,
      "scenarios" => Enum.map(ready.scenarios, &Map.new(&1, fn {k, v} -> {Atom.to_string(k), v} end)),
      "package_facts_keys" => packages |> JSON.decode!() |> Map.keys() |> Enum.sort()
    }
  end

File.write!(
  Path.join(File.cwd!(), "cli/verify/testdata/golden/readiness.json"),
  JSON.encode!(records) <> "\n"
)

IO.puts("wrote #{length(records)} records")
