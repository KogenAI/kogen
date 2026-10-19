const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { When, Then, AfterAll } = require('@cucumber/cucumber');
const REPO = path.resolve(__dirname, '../..');
let archivePromise, work;
function run(file, args, opts = {}) {
  return new Promise((resolve, reject) => {
    const p = spawn(file, args, { ...opts, detached: true, stdio: ['ignore', 'pipe', 'pipe'] });
    let out = '';
    p.stdout.on('data', b => { out += b; }); p.stderr.on('data', b => { out += b; });
    const timer = setTimeout(() => { try { process.kill(-p.pid, 'SIGKILL'); } catch {} }, 240000);
    p.on('error', e => { clearTimeout(timer); reject(e); });
    p.on('close', code => { clearTimeout(timer); resolve({ code, out }); });
  });
}
async function archive() {
  if (!archivePromise) archivePromise = (async () => {
    work = fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-clean-candidate-harness-'));
    const r = await run('/bin/sh', ['packaging/package.sh'], { cwd: REPO });
    assert.equal(r.code, 0, r.out);
    // Packaging writes diagnostics on stderr; find the absolute archive line.
    const a = r.out.split('\n').find(s => s.startsWith('/') && s.endsWith('.tar.gz'));
    assert.ok(a && fs.existsSync(a), r.out); return a;
  })();
  return archivePromise;
}
AfterAll(function () { if (work) fs.rmSync(work, { recursive: true, force: true }); });
// Independent harness: source under test stays editable; no generated implementation test is required.
const driver = String.raw`
Code.require_file(Path.expand("test/support/integration_helpers.ex", File.cwd!()))
defmodule CleanCandidateExercise do
  use ExUnit.Case
  alias Kogen.{Config, Intent}
  alias Kogen.Integration.{Helpers, FakeProvider}
  @tag timeout: 180_000
  test "observe the native Build" do
    suite = Helpers.setup_suite!()
    on_exit(fn -> Helpers.cleanup_suite(suite) end)
    c = Helpers.project!(suite, [], staged_intent: false)
    on_exit(fn -> Helpers.cleanup_case(c) end)
    # Capture physical paths while directories exist; verification scratch may be removed before receipt inspection.
    {repo_cwd, 0} = System.cmd("/bin/sh", ["-c", "pwd -P"], cd: c.repo)
    mode = System.fetch_env!("CC_MODE")
    put = fn p, text -> file = Path.join(c.repo, p); File.mkdir_p!(Path.dirname(file)); File.write!(file, text) end
    git = fn args -> {out, 0} = Helpers.git!(c, args); String.trim(out) end
    put.(".gitignore", ".kogen/local/\nbuild/\n")
    put.("src/app.sh", "printf 'baseline\\n'\n")
    put.("launcher.sh", "exec sh src/app.sh\n")
    put.("generate.sh", "set -eu\nif [ -f build/app.sh ]; then prior=present; else prior=absent; fi\nmkdir -p build\nif [ -f candidate-input.sh ]; then cp candidate-input.sh build/app.sh; else cp src/app.sh build/app.sh; fi\nprintf '%s|%s|%s\\n' \"$(pwd -P)\" \"$prior\" \"$(sh build/app.sh)\" >> \"$CC_TRACE_FILE\"\n")
    put.("check.sh", "set -eu\n" <> (if mode == "check-output", do: "sh generate.sh\n", else: "") <> "actual=$(sh launcher.sh)\nif [ -f candidate-input.sh ]; then expected=$(sh candidate-input.sh); else expected=$(sh src/app.sh); fi\n[ \"$actual\" = \"$expected\" ]\n")
    original = Config.load!(c.repo)
    config = Config.render(%{setup: if(mode == "setup-output", do: ["sh generate.sh"], else: []), fix: [], checks: [%{name: "shell-output", run: "sh check.sh"}], protect: ["check.sh"], acceptance: %{run: original.acceptance_run, steps_dir: original.steps_dir}})
    put.(".kogen/project.yaml", config)
    git.(["add", "-A"]); git.(["commit", "-qm", "Configure shell output fixture"])
    dir = ".kogen/intents/fixture"
    put.(dir <> "/intent.md", "# Verify shell output\n\nSlug: fixture\nModel: " <> dir <> "/model.qnt invariants=Nonnegative seed=31 samples=2 steps=2\nAcceptance:\n- " <> dir <> "/acceptance.feature\n- features/steps/integration_steps.js\n\nChange the launcher output.\n\n## Decisions\n- Use candidate-output. (source: request)\n\n## Tests\n- Output: shell fixture (scenario)\n\n## Feasibility\n- none\n")
    put.(dir <> "/model.qnt", "module fixture {\n var n: int\n action init = n' = 0\n action step = n' = n + 1\n val Nonnegative = n >= 0\n}\n")
    put.(dir <> "/acceptance.feature", "Feature: Shell output\n  Scenario: Candidate output\n    Then shell output is \"candidate-output\"\n")
    target = if mode == "check-output", do: "candidate-input.sh", else: "launcher.sh"
    put.("features/steps/integration_steps.js", "const {Then}=require('@cucumber/cucumber'); const {spawnSync}=require('node:child_process'); const assert=require('node:assert/strict'); Then('shell output is {string}', expected=>{const r=spawnSync('/bin/sh',[" <> JSON.encode!(target) <> "],{encoding:'utf8'}); assert.equal(r.status,0,r.stderr); assert.equal(r.stdout.trim(),expected);});\n")
    trace = Path.join(c.root, "generation.trace")
    File.write!(trace, "")
    opts = [env: [{"CC_TRACE_FILE", trace}]]
    {card, 5} = Helpers.run_kogen(c, ["intent", "approve", "fixture"], opts)
    [_, hash] = Regex.run(~r/SHA-256: ([0-9a-f]{64})/, card)
    {_, 0} = Helpers.run_kogen(c, ["intent", "approve", "fixture", hash], opts)
    git.(["add", dir, "features/steps/integration_steps.js"])
    index = File.read!(Path.join(c.repo, ".git/index"))
    approval = File.read!(Intent.approval_path(c.repo, "fixture"))
    start = git.(["rev-parse", "HEAD"])
    hook = Path.join(c.repo, ".git/hooks/pre-commit")
    File.write!(hook, "#!/bin/sh\nprintf hook > .kogen/local/hook-ran\n"); File.chmod!(hook, 0o755)
    direct = "exec sh candidate-input.sh\n"
    ignored = "exec sh build/app.sh\n"
    poison = "printf 'candidate-output\\n'\n"
    shell = "printf 'printf '\\''candidate-output\\\\n'\\''\\n' > candidate-input.sh\n"
    # Use write_file for exact fixture bytes; shell only creates the ignored artifact.
    build = [f("write_file", %{"path" => "candidate-input.sh", "content" => poison}), f("write_file", %{"path" => "launcher.sh", "content" => if(mode == "reviewer-repair", do: direct, else: ignored)}), f("shell", %{"command" => "mkdir -p build; cp candidate-input.sh build/app.sh"}), f("finish", %{"summary" => "candidate ready"})]
    approve = f("submit_review", %{"verdict" => "approve", "findings" => []})
    tail = cond do
      mode == "ignored-shell" -> [{:http, 400, %{"error" => %{"message" => "bounded red stop", "code" => "invalid_request_error"}}}]
      mode == "reviewer-repair" -> [f("write_file", %{"path" => "launcher.sh", "content" => ignored}), approve, f("write_file", %{"path" => "launcher.sh", "content" => direct <> "# reviewer repaired\n"}), approve]
      true -> [approve]
    end
    Agent.update(c.server.state, fn s -> %{s | script: Enum.take(s.script, s.next) ++ build ++ tail} end)
    t = System.monotonic_time(:millisecond)
    {output, status} = Helpers.run_kogen(c, ["intent", "build", "fixture"], opts)
    wall = System.monotonic_time(:millisecond) - t
    requests = FakeProvider.provider_requests(c.server)
    reviews = FakeProvider.review_requests(c.server)
    feedback = Enum.map_join(requests, "\n", &JSON.encode!(&1.json["input"]))
    [result_file] = Path.wildcard(Path.join(c.repo, ".kogen/local/runs/*/result.json"))
    result = JSON.decode!(File.read!(result_file))
    count = String.to_integer(git.(["rev-list", "--count", start <> "..HEAD"]))
    generated = File.read!(trace) |> String.split("\n", trim: true) |> Enum.any?(fn line ->
      case String.split(line, "|") do
        [cwd, "absent", "candidate-output"] -> cwd != String.trim(repo_cwd)
        _ -> false
      end
    end)
    fresh = if count == 1 do
      clone = Path.join(c.root, "fresh-result")
      {_, 0} = System.cmd("git", ["clone", "--no-local", "-q", c.repo, clone], env: Helpers.env_for(c), stderr_to_stdout: true)
      commands = (if mode == "setup-output", do: ["sh generate.sh"], else: []) ++ ["sh check.sh", "sh launcher.sh"]
      Enum.all?(commands, fn cmd -> {_, code} = System.cmd("/bin/sh", ["-c", cmd], cd: clone, env: Helpers.env_for(c, %{"CC_TRACE_FILE" => trace}), stderr_to_stdout: true); code == 0 end)
    else false end
    [review_file] = if count == 1, do: Path.wildcard(Path.join(c.repo, ".kogen/local/runs/*/review-1.json")), else: [nil]
    bound = if review_file, do: JSON.decode!(File.read!(review_file))["tree"] == git.(["rev-parse", "HEAD^{tree}"]), else: false
    model = output =~ "model passed"
    receipt = %{
      landed: status == 0 and result["outcome"] == "landed", commitCount: count,
      cleanFailureFeedback: String.contains?(feedback, "Verification pass") and String.contains?(feedback, "build/app.sh") and String.contains?(feedback, "failed"),
      indexPreserved: File.read!(Path.join(c.repo, ".git/index")) == index,
      approvalPreserved: File.read(Intent.approval_path(c.repo, "fixture")) == {:ok, approval},
      workspaceArtifactPreserved: File.read(Path.join(c.repo, "build/app.sh")) == {:ok, poison},
      reviewStages: result["reviews"], cleanGenerationObserved: generated, freshCloneRuns: fresh,
      generatedOutputCommitted: count == 1 and String.contains?(git.(["ls-tree", "-r", "--name-only", "HEAD"]), "build/app.sh"),
      candidateInputCommitted: count == 1 and git.(["show", "HEAD:candidate-input.sh"]) == String.trim(poison),
      modelPassed: model, hookRan: File.exists?(Path.join(c.repo, ".kogen/local/hook-ran")),
      sameReviewerRepair: length(reviews) == 4 and Enum.any?(reviews, &String.contains?(JSON.encode!(&1.json["input"]), "Final verification")) and result["reviews"] == 1,
      finalTreeBound: bound, wall_ms: wall, result: result, output: output,
      runtime: suite.release, sourceHead: System.get_env("CC_SOURCE_HEAD"), mode: mode
    }
    File.write!(System.fetch_env!("CC_RECEIPT"), JSON.encode!(receipt))
  end
  defp f(name, args), do: {:function, name, args}
end
`;
When('I exercise clean candidate verification in mode {string}', { timeout: 300000 }, async function (mode) {
  assert.ok(['ignored-shell', 'setup-output', 'check-output', 'reviewer-repair'].includes(mode));
  const a = await archive();
  const temp = fs.mkdtempSync(path.join(work, 'case-'));
  const script = path.join(temp, 'clean_candidate_test.exs'), receipt = path.join(temp, 'receipt.json');
  fs.writeFileSync(script, driver);
  const r = await run('mix', ['test', script], { cwd: REPO, env: { ...process.env, KOGEN_ARCHIVE: a, CC_MODE: mode, CC_RECEIPT: receipt, CC_SOURCE_HEAD: 'b2c9876b27a99d19a82564821879dc42e83b03c1' } });
  assert.equal(r.code, 0, r.out);
  assert.ok(fs.existsSync(receipt), r.out);
  this.cleanCandidateReceipt = JSON.parse(fs.readFileSync(receipt, 'utf8'));
  await this.attach(JSON.stringify(this.cleanCandidateReceipt), 'application/json');
});
Then('the clean candidate observations are:', function (table) {
  assert.ok(this.cleanCandidateReceipt, 'no native observations');
  for (const [key, value] of table.raw()) assert.deepEqual(this.cleanCandidateReceipt[key], JSON.parse(value), `${key}: ${JSON.stringify(this.cleanCandidateReceipt)}`);
});
