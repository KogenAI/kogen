const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { Given, When, Then } = require('@cucumber/cucumber');
const REPO = path.resolve(__dirname, '../..');

// Independent installed-CLI observer. Reuse only installation/project/server
// facilities, never implementation-test assertions or a future product helper.
const driver = String.raw`
ExUnit.start(autorun: false)
Code.require_file("test/support/integration_helpers.ex")
defmodule ShapeIndexExercise do
 alias Kogen.{Config, Intent, Git, ShapeContext, SourceProvenance, Integration.Helpers, Integration.FakeProvider}
 def put(c, p, bytes) do
  target = Path.join(c.repo, p)
  File.mkdir_p!(Path.dirname(target))
  File.write!(target, bytes)
 end
 def script(c, actions), do: Agent.update(c.server.state, &%{&1 | script: Enum.take(&1.script, &1.next) ++ actions})
 def f(name, args), do: {:function, name, args}
 def requests(c), do: FakeProvider.provider_requests(c.server) |> Enum.filter(fn r -> Enum.any?(r.json["tools"] || [], &(&1["name"] == "submit")) end)
 def contract(input) do
  case Enum.find(input || [], &(&1["role"] == "user")) do
   %{"content" => blocks} when is_list(blocks) -> Enum.map(blocks, & &1["text"])
   %{"content" => text} when is_binary(text) -> [text]
   _ -> []
  end
 end
 def lines(p) do
  case File.read(p) do
   {:ok, bytes} -> String.split(bytes, "\n", trim: true) |> Enum.map(&JSON.decode!/1)
   _ -> []
  end
 end
 def json(p) do
  case File.read(p) do
   {:ok, bytes} -> JSON.decode!(bytes)
   _ -> nil
  end
 end
 def run do
  cfg = JSON.decode!(File.read!(System.fetch_env!("SHAPE_INDEX_INPUT")))
  mode = cfg["mode"]
  suite = Helpers.setup_suite!()
  try do
   c = Helpers.project!(suite, [], staged_intent: false)
   try do
    slug = "index-observed"
    state = Path.join(c.repo, ".kogen/local/shaping/#{slug}")
    trace = Path.join(c.root, "readiness-executions")
    testing_rules = File.read!(Path.join(suite.prefix, "lib/kogen/docs/testing-rules.md"))
    config = Config.load!(c.repo)
    command = "if grep -q 'Scenario:' \"$KOGEN_ACCEPTANCE_FEATURES\"; then printf 'ran\\n' >> '#{trace}'; fi; " <> config.acceptance_run
    put(c, Config.path(), Config.render(%{setup: [], fix: [], checks: [], protect: ["protected.txt"], acceptance: %{run: command, steps_dir: config.steps_dir}}))
    readme = "# Fixture authority Δ\r\nKeep exact authority and investigate relevant files.\r\n"
    put(c, "README.md", readme)
    put(c, "protected.txt", "protected literal\n")
    selected = "selected/source.txt"
    selected_body = "NAVIGATION_SOURCE_SENTINEL Δ\nsecond exact line\n"
    put(c, selected, selected_body)
    put(c, "padding.txt", String.duplicate("discovery padding line\n", 1800))
    if cfg["files"] > 0 do
     for n <- 1..cfg["files"] do
      id = String.pad_leading(to_string(n), 5, "0")
      put(c, "inventory/branch-#{id}/source-#{id}.ex", "defmodule Inventory#{id} do\n  def navigation_declaration_#{id}(value), do: value\n  def another_navigation_declaration_#{id}(value), do: value\nend\n")
     end
    end
    {_, 0} = Helpers.git!(c, ["add", "."])
    {_, 0} = Helpers.git!(c, ["commit", "-qm", "Seed native navigation fixture"])
    revision = ShapeContext.revision(c.repo)
    head = Git.head(c.repo)
    index = File.read!(Path.join(c.repo, ".git/index"))
    approval_path = Intent.approval_path(c.repo, "fixture")
    original_approval = File.read!(approval_path)
    source = cfg["source"] <> if(mode == "irreducible", do: "\n" <> String.duplicate("M", 600000), else: "")
    request_path = Path.join(c.root, "request.txt")
    File.write!(request_path, source)
    mdpath = Intent.intent_md(slug)
    ftpath = Intent.feature(slug)
    helper = "features/steps/index_observed.js"
    md = "# Preserve the navigation fixture\n\nSlug: #{slug}\nModel: not applicable — a stateless fixture\nAcceptance:\n- #{ftpath}\n- #{helper}\n\nKeep the full supplied source packet as diagnostic provenance; this fixture implements no migration or operator monitoring.\n\n## Source comparison\n- addressed: complete source packet is the native request; this local contract tests Shape plumbing and preserves the source receipt.\n\n## Tests\n- Baseline source stays readable: actual filesystem scenario (regression)\n\n## Feasibility\n- none\n"
    ft = "Feature: Navigation fixture\n  Scenario: Read the actual baseline\n    Then the navigation fixture baseline is readable\n"
    js = "const assert = require('node:assert/strict');\nconst fs = require('node:fs');\nconst { Then } = require('@cucumber/cucumber');\nThen('the navigation fixture baseline is readable', function () { assert.equal(fs.readFileSync('app.txt', 'utf8'), 'baseline\\n'); });\n"
    files = [%{path: mdpath, content: md}, %{path: ftpath, content: ft}, %{path: helper, content: js}]
    question = %{question: "Which fixture label should be retained?", options: [%{label: "Keep the full fixture scope", recommended: true}, %{label: "Use the alternate fixture label"}]}
    answered = mode == "answers"
    input = if answered do
     script(c, [f("submit", %{questions: [question]})])
     {output, 5} = Helpers.run_kogen(c, ["intent", "shape", slug, request_path])
     unless output =~ question.question, do: raise("product-question precondition was not reached")
     answers = Path.join(c.root, "answers.txt")
     File.write!(answers, "1: b\n")
     answers
    else
     request_path
    end
    before_requests = length(requests(c))
    actions = [f("submit", %{files: files}), f("list_files", %{path: "selected"}), f("search_text", %{path: "selected", pattern: "NAVIGATION_SOURCE_SENTINEL"}), f("read_file", %{path: selected, start_line: 1, end_line: 2}), f("submit", %{files: [%{path: mdpath, content: md <> "- documentation-lookup: retrieved https://example.invalid/never-looked-up\n"}, Enum.at(files, 1), Enum.at(files, 2)]})]
    growth = if cfg["reads"] > 0, do: List.duplicate(f("read_file", %{path: "padding.txt"}), cfg["reads"]), else: []
    script(c, actions ++ growth ++ [f("submit", %{files: files})])
    {output, status} = Helpers.run_kogen(c, ["intent", "shape", slug, input])
    reqs = Enum.drop(requests(c), before_requests)
    events = lines(Path.join(state, "events.ndjson"))
    resets = Enum.filter(events, &(&1["event"] == "working_context_reset"))
    stops = Enum.filter(events, &(&1["event"] == "working_context_stop"))
    refs = Enum.map(resets ++ stops, & &1["archive"])
    archives = Enum.map(refs, fn ref ->
     bytes = File.read!(ref["path"])
     %{ref: ref, bytes: bytes, doc: JSON.decode!(bytes), mode: Bitwise.band(File.stat!(ref["path"]).mode, 0o777), dir_mode: Bitwise.band(File.stat!(Path.dirname(ref["path"])).mode, 0o777)}
    end)
    all_contracts = Enum.map(reqs, &contract(&1.json["input"])) ++ Enum.map(archives, &contract(&1.doc["input"]))
    first_contract = List.first(all_contracts) || []
    stable = List.first(first_contract) || ""
    dynamic = Enum.at(first_contract, 1) || ""
    expected_navigation = %{"root" => c.repo, "revision" => %{"head" => revision.head, "tree" => revision.tree}, "retrieval" => "read_file exact bytes and line ranges; list_files directories; search_text exact signatures"}
    navigation = case String.split(dynamic, "Context navigation: ", parts: 2) do
     ["", text] -> case JSON.decode(String.trim_trailing(text, "\n")) do
      {:ok, nav} -> nav == expected_navigation and String.ends_with?(text, "\n") and not String.contains?(String.trim_trailing(text, "\n"), "\n")
      _ -> false
     end
     _ -> false
    end
    outputs = FakeProvider.tool_outputs(c.server)
    provenance = json(SourceProvenance.path(c.repo, slug))
    ready = json(Path.join(c.repo, ".kogen/local/readiness/#{slug}.json"))
    hash = if File.regular?(Path.join(c.repo, mdpath)), do: Intent.hash(c.repo, Intent.baseline(c.repo, slug, Config.load!(c.repo))), else: nil
    baseline = if hash, do: Intent.baseline(c.repo, slug, Config.load!(c.repo)), else: []
    exact_qa = not answered or (stable =~ question.question and stable =~ "answer: 1: b" and stable =~ "Use the alternate fixture label" and provenance != nil and get_in(provenance, ["rounds", Access.at(0), "inputs"]) == ["1: b\n"] and get_in(provenance, ["rounds", Access.at(0), "answers", "1"]) == "b" and get_in(provenance, ["rounds", Access.at(0), "resolved_answers", "1"]) == "Use the alternate fixture label")
    archive_integrity = archives != [] and Enum.all?(archives, fn a -> ShapeContext.hash(a.bytes) == a.ref["sha256"] and a.mode == 0o600 and a.dir_mode == 0o700 and a.doc["owner"] == "shape" and contract(a.doc["input"]) == first_contract end)
    reset_measurement = resets != [] and Enum.all?(resets, fn e ->
     Enum.any?(reqs, &(byte_size(&1.body) == e["after_bytes"])) and e["before_bytes"] > e["after_bytes"] and e["after_bytes"] <= 524288 and e["input_budget_bytes"] == 524288 and e["output_reserve_tokens"] == 131072
    end)
    authority = all_contracts != [] and Enum.all?(all_contracts, fn blocks ->
     text = List.first(blocks) || ""
     length(blocks) == 2 and text == stable and text =~ ("# Request\n\n" <> source <> "\n") and text =~ readme and text =~ testing_rules and text =~ "configured protect patterns: [\"protected.txt\"]" and text =~ "paths currently matched by those patterns: [\"protected.txt\"]" and text =~ "automatic baseline: every file in" and text =~ ".kogen/intents/index-observed/" and text =~ "automatic paths currently present or listed: [\".kogen/project.yaml\"]" and text =~ "Full contract inclusions: exact request, Q&A, README, testing rules and protection/automatic baseline are authoritative and are not clipped."
    end)
    unchanged = Git.head(c.repo) == head and File.read!(Path.join(c.repo, ".git/index")) == index and File.read!(Path.join(c.repo, "protected.txt")) == "protected literal\n" and File.read!(approval_path) == original_approval and not File.exists?(Intent.approval_path(c.repo, slug))
    source_ok = provenance != nil and get_in(provenance, ["request", "text"]) == source and get_in(provenance, ["request", "sha256"]) == ShapeContext.hash(source) and provenance["contract_sha256"] == hash
    ready_ok = ready != nil and ready["version"] == 3 and ready["sha256"] == hash and ready["head"] == head and ready["baseline"] == baseline and is_binary(ready["candidate_tree"]) and ready["candidate_tree"] == Kogen.Snapshot.tree(c.repo, head, []) and ready["scenarios"] != [] and Enum.all?(ready["scenarios"], &(&1["status"] == "passed"))
    observed = %{
     "status" => status,
     "Shape provider request count" => length(reqs),
     "navigation shape and identity" => navigation and Enum.all?(all_contracts, &(Enum.at(&1, 1) == dynamic)),
     "descriptor maximum bytes" => byte_size(dynamic),
     "exact authority" => authority,
     "exact question and answer" => exact_qa,
     "inspection refused before reads" => Enum.any?(outputs, &String.contains?(&1, "shape/uninspected")),
     "fabricated documentation refused" => Enum.any?(outputs, &String.contains?(&1, "shape/undocumented")),
     "list search and read reached source" => selected in outputs and "#{selected}:1:NAVIGATION_SOURCE_SENTINEL Δ" in outputs and "1\tNAVIGATION_SOURCE_SENTINEL Δ\n2\tsecond exact line" in outputs,
     "inventory absent from mandatory" => not String.contains?(stable <> dynamic, "inventory/branch-") and not String.contains?(stable <> dynamic, "navigation_declaration_"),
     "actual readiness ran" => File.read(trace) == {:ok, "ran\n"},
     "exact provenance and readiness" => source_ok and ready_ok,
     "no approval or Git mutation" => unchanged,
     "all sent requests within ceiling" => reqs != [] and Enum.all?(reqs, &(byte_size(&1.body) <= 524288)),
     "a real working window reset" => resets != [],
     "archives bind exact mandatory" => archive_integrity,
     "reset measures actual rendered body" => reset_measurement,
     "honest budget stop" => status == 1 and output =~ "candidate/context_budget_exceeded" and output =~ "ceiling 524288; reserve 131072 tokens" and output =~ "fresh identical retry is not recovery" and stops != [] and Enum.all?(stops, &(&1["input_budget_bytes"] == 524288 and &1["output_reserve_tokens"] == 131072 and &1["measured_bytes"] > 524288)),
     "exact unsent input custody" => reqs == [] and archive_integrity and Enum.all?(archives, &(&1.doc["input"] |> contract() |> List.first() |> String.contains?(source))),
     "no publication" => provenance == nil and ready == nil and not File.exists?(Path.join(c.repo, mdpath)) and not File.exists?(Path.join(c.repo, helper))
    }
    IO.puts("SHAPE_INDEX_RESULT=" <> JSON.encode!(%{observed: observed, output: output}))
   after
    Helpers.cleanup_case(c)
   end
  after
   Helpers.cleanup_suite(suite)
  end
 end
end
ShapeIndexExercise.run()
ExUnit.run()
`;

function runExercise(inputs) {
  return new Promise((resolve, reject) => {
    const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'shape-context-index-'));
    const file = path.join(scratch, 'driver.exs');
    const input = path.join(scratch, 'input.json');
    fs.writeFileSync(file, driver);
    fs.writeFileSync(input, JSON.stringify(inputs));
    const child = spawn('mix', ['run', file], {
      cwd: REPO, detached: true,
      env: { ...process.env, SHAPE_INDEX_INPUT: input, ERL_FLAGS: process.env.ERL_FLAGS || '+S 2:2 +SDcpu 1 +SDio 1' },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let output = '';
    let timedOut = false;
    child.stdout.on('data', b => { output += b; });
    child.stderr.on('data', b => { output += b; });
    const timer = setTimeout(() => { timedOut = true; try { process.kill(-child.pid, 'SIGKILL'); } catch {} }, 240000);
    child.on('error', e => { clearTimeout(timer); fs.rmSync(scratch, { recursive: true, force: true }); reject(e); });
    child.on('close', code => {
      clearTimeout(timer);
      fs.rmSync(scratch, { recursive: true, force: true });
      try {
        assert.equal(timedOut, false, 'installed Shape fixture timed out');
        assert.equal(code, 0, output);
        const marker = output.split('\n').find(s => s.startsWith('SHAPE_INDEX_RESULT='));
        assert.ok(marker, output);
        resolve(JSON.parse(marker.slice('SHAPE_INDEX_RESULT='.length)));
      } catch (e) { reject(e); }
    });
  });
}
Given('the exact Shape index source packet:', function (source) { this.shapeIndexSource = source; });
When('I exercise native Shape index mode {string} with {int} inventory files and {int} extra reads', { timeout: 250000 }, async function (mode, files, reads) {
  assert.ok(['answers', 'large', 'windows', 'irreducible'].includes(mode));
  assert.equal(typeof this.shapeIndexSource, 'string');
  this.shapeIndexResult = await runExercise({ mode, files, reads, source: this.shapeIndexSource });
});
Then('the Shape index contract observations are:', function (table) {
  assert.ok(this.shapeIndexResult);
  const { observed, output } = this.shapeIndexResult;
  const failures = [];
  for (const row of table.hashes()) {
    assert.ok(Object.hasOwn(observed, row.observation), `unknown observation ${row.observation}`);
    const actual = observed[row.observation];
    const expected = JSON.parse(row.expected);
    const pass = row.observation === 'descriptor maximum bytes' ? actual > 0 && actual <= expected : actual === expected;
    if (!pass) failures.push(`${row.observation}: expected ${row.observation === 'descriptor maximum bytes' ? 'at most ' : ''}${expected}, got ${JSON.stringify(actual)}`);
  }
  assert.deepEqual(failures, [], `${failures.join('\n')}\nInstalled CLI output:\n${output.slice(-12000)}`);
});
