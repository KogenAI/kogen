const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { When, Then } = require('@cucumber/cucumber');
const REPO = path.resolve(__dirname, '../..');
let exercise;

// Reuse the installed-release fixture and fake provider, but do not depend on
// implementation tests or their assertions. Only these steps are frozen.
const driver = String.raw`
ExUnit.start(autorun: false)
Code.require_file("test/support/integration_helpers.ex")
alias Kogen.{Config, Intent, Readiness, Integration.Helpers, Integration.FakeProvider}
suite = Helpers.setup_suite!()
try do
 results = for mode <- ["shape", "refine"], into: %{} do
  c = Helpers.project!(suite, [], staged_intent: false)
  try do
   slug = if mode == "shape", do: "compact-observed", else: "fixture"
   intent = Intent.intent_md(slug)
   feature = Intent.feature(slug)
   helper = if mode == "shape", do: "features/steps/compact_observed.js", else: "features/steps/integration_steps.js"
   trace = Path.join(c.root, "compact-readiness-runs")
   config = Config.load!(c.repo)
   run = "if grep -q 'Scenario:' \"$KOGEN_ACCEPTANCE_FEATURES\"; then printf 'run\\n' >> '#{trace}'; fi; " <> config.acceptance_run
   File.write!(Path.join(c.repo, Config.path()), Config.render(%{setup: [], fix: [], checks: [], protect: config.protect, acceptance: %{run: run, steps_dir: config.steps_dir}}))
   {_, 0} = Helpers.git!(c, ["add", Config.path()])
   {_, 0} = Helpers.git!(c, ["commit", "-qm", "Count compact readiness executions"])
   hash = fn -> Intent.hash(c.repo, Intent.baseline(c.repo, slug, Config.load!(c.repo))) end
   # Refresh approval for the changed configuration, before freezing Refine.
   if mode == "refine" do
    {_, 0} = Helpers.run_kogen(c, ["intent", "approve", slug, hash.()])
   end
   count = fn ->
    case File.read(trace) do
     {:ok, text} -> length(String.split(text, "\n", trim: true))
     _ -> 0
    end
   end
   before_count = count.()
   original_baseline = if mode == "refine", do: Map.new(Intent.baseline(c.repo, slug, Config.load!(c.repo)), &{&1, File.read!(Path.join(c.repo, &1))}), else: %{Config.path() => File.read!(Path.join(c.repo, Config.path()))}
   md = if mode == "shape" do
    "# Observe compact acknowledgements\n\nSlug: #{slug}\nModel: not applicable — no state changes\nAcceptance:\n- #{feature}\n- #{helper}\n\n## Tests\n- compact fixture: actual scenario (regression)\n\n## Feasibility\n- none\n"
   else
    File.read!(Path.join(c.repo, intent))
   end
   ft = "Feature: Compact acknowledgement\n  Scenario: Legitimate product red\n    Then compact product behavior exists\n"
   body = fn message ->
    "const { Then } = require('@cucumber/cucumber');\nThen('compact product behavior exists', function () { throw new Error('#{message}'); });\n" <> "// large helper body\n" <> String.duplicate("// retained fixture padding\n", 100)
   end
   initial_helper = body.("incorrect fixture input")
   corrected_helper = body.("legitimate missing product behavior")
   initial = [%{"path" => intent, "content" => md}, %{"path" => feature, "content" => ft}, %{"path" => helper, "content" => initial_helper}]
   tool = if mode == "shape", do: "submit", else: "submit_refinement"
   submit = fn files -> {:function, tool, %{"files" => files}} end
   unsafe = [%{"path" => helper, "content" => "throw new Error('POISON MUST NOT SURVIVE');\n"}, %{"path" => "../outside", "content" => "unsafe"}]
   ack = [%{"path" => feature, "content" => ft}]
   actions = [submit.([]), submit.(initial), submit.(unsafe), submit.([%{"path" => helper, "content" => corrected_helper}]), submit.(ack)]
   Agent.update(c.server.state, &%{&1 | script: Enum.take(&1.script, &1.next) ++ actions})
   request = Path.join(c.root, "compact-request.txt")
   File.write!(request, "Inspect readiness; correct fixture inputs and acknowledge legitimate missing-feature red with the smallest eligible current-candidate artifact.")
   args = if mode == "shape", do: ["intent", "shape", slug, request], else: ["intent", "refine", slug, hash.(), request]
   {output, status} = Helpers.run_kogen(c, args)
   if status != 0, do: raise("#{mode} failed: #{output}")
   requests = FakeProvider.provider_requests(c.server) |> Enum.map(& &1.json) |> Enum.filter(fn req -> Enum.any?(req["tools"] || [], &(&1["name"] == tool)) end)
   first = hd(requests)
   definition = Enum.find(first["tools"], &(&1["name"] == tool))
   prompt = (first["instructions"] || "") <> "\n" <> (definition["description"] || "")
   feedback = FakeProvider.tool_outputs(c.server)
   observations = Enum.filter(feedback, &String.contains?(&1, "Readiness observations")) |> Enum.join("\n")
   expected = Map.merge(original_baseline, %{intent => md, feature => ft, helper => corrected_helper})
   baseline = Intent.baseline(c.repo, slug, Config.load!(c.repo))
   actual = Map.new(baseline, &{&1, File.read!(Path.join(c.repo, &1))})
   record = Path.join(c.repo, ".kogen/local/readiness/#{slug}.json") |> File.read!() |> JSON.decode!()
   ready = Readiness.cached(c.repo, slug, Config.load!(c.repo))
   submitted_smallest = byte_size(ft) == Enum.min(Enum.map([md, ft, corrected_helper], &byte_size/1)) and length(ack) == 1
   {mode, %{
    "files minItems" => get_in(definition, ["parameters", "properties", "files", "minItems"]) || 0,
    "empty submission rejected" => Enum.any?(feedback, &((String.starts_with?(&1, "invalid:") or String.starts_with?(&1, "invalid submission:")) and not String.contains?(&1, "Readiness observations"))),
    "unsafe submission rejected" => Enum.any?(feedback, &(String.contains?(&1, "No proposals from this submission were retained") or String.contains?(&1, "no proposals from this submission were retained"))),
    "candidate readiness executions" => count.() - before_count,
    "smallest artifact submitted" => submitted_smallest,
    "exact complete package retained" => actual == expected and not File.exists?(Path.join(c.root, "outside")),
    "evidence matches complete inputs" => ready != nil and record["sha256"] == hash.() and record["head"] == Kogen.Git.head(c.repo) and record["baseline"] == baseline,
    "no approval" => not File.exists?(Intent.approval_path(c.repo, slug)),
    "prompt" => String.downcase(prompt),
    "feedback" => String.downcase(observations)
   }}
  after
   Helpers.cleanup_case(c)
  end
 end
 IO.puts("COMPACT_ACK_RESULT=" <> JSON.encode!(results))
after
 Helpers.cleanup_suite(suite)
end
ExUnit.run()
`;

function runExercise() {
  return new Promise((resolve, reject) => {
    const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'compact-ack-driver-'));
    const file = path.join(scratch, 'driver.exs');
    fs.writeFileSync(file, driver);
    const child = spawn('mix', ['run', file], {
      cwd: REPO, detached: true,
      env: { ...process.env, ERL_FLAGS: process.env.ERL_FLAGS || '+S 2:2 +SDcpu 1 +SDio 1' },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let output = '';
    child.stdout.on('data', b => { output += b; });
    child.stderr.on('data', b => { output += b; });
    const timer = setTimeout(() => { try { process.kill(-child.pid, 'SIGKILL'); } catch {} }, 240000);
    child.on('error', e => { clearTimeout(timer); fs.rmSync(scratch, { recursive: true, force: true }); reject(e); });
    child.on('close', code => {
      clearTimeout(timer);
      fs.rmSync(scratch, { recursive: true, force: true });
      try {
        assert.equal(code, 0, output);
        const line = output.split('\n').find(s => s.startsWith('COMPACT_ACK_RESULT='));
        assert.ok(line, output);
        resolve(JSON.parse(line.slice('COMPACT_ACK_RESULT='.length)));
      } catch (e) { reject(e); }
    });
  });
}
When('I exercise compact acknowledgement through installed {string}', { timeout: 250000 }, async function (operation) {
  if (!exercise) exercise = runExercise();
  const results = await exercise;
  assert.ok(Object.hasOwn(results, operation), operation);
  this.compactAck = results[operation];
});
Then('the compact acknowledgement observations are:', function (table) {
  const failures = [];
  for (const row of table.hashes()) {
    const name = row.observation, expected = row.expected;
    let actual;
    if (name === 'prompt contains' || name === 'feedback contains') {
      actual = this.compactAck[name.split(' ')[0]].includes(expected.toLowerCase());
      if (!actual) failures.push(`${name}: missing ${JSON.stringify(expected)}`);
    } else if (name === 'obsolete feedback absent') {
      if (this.compactAck.feedback.includes(expected.toLowerCase())) failures.push(`${name}: ${expected}`);
    } else {
      actual = String(this.compactAck[name]);
      if (actual !== expected) failures.push(`${name}: expected ${expected}, got ${actual}`);
    }
  }
  assert.deepEqual(failures, []);
});
