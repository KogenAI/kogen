const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { When, Then, AfterAll } = require('@cucumber/cucumber');
const root = path.resolve(__dirname, '../..');
let work, archivePromise;
function run(file, args, opts = {}) {
  return new Promise((resolve, reject) => {
    const p = spawn(file, args, { ...opts, detached: true, stdio: ['ignore', 'pipe', 'pipe'] });
    let output = '';
    p.stdout.on('data', b => { output += b; }); p.stderr.on('data', b => { output += b; });
    const timer = setTimeout(() => { try { process.kill(-p.pid, 'SIGKILL'); } catch {} }, 300000);
    p.on('error', e => { clearTimeout(timer); reject(e); });
    p.on('close', code => { clearTimeout(timer); resolve({ code, output }); });
  });
}
async function archive() {
  if (!archivePromise) archivePromise = (async () => {
    work = fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-fail-fast-'));
    const r = await run('/bin/sh', ['packaging/package.sh'], { cwd: root });
    assert.equal(r.code, 0, r.output);
    const a = r.output.split('\n').find(s => s.startsWith('/') && s.endsWith('.tar.gz'));
    assert.ok(a && fs.existsSync(a), r.output); return a;
  })();
  return archivePromise;
}
AfterAll(() => { if (work) fs.rmSync(work, { recursive: true, force: true }); });
// Independent installed-CLI harness. No production file or builder-owned implementation test is frozen here.
const driver = String.raw`
Code.require_file(Path.expand("test/support/integration_helpers.ex", File.cwd!()))
defmodule FailFastExercise do
  use ExUnit.Case
  alias Kogen.{Config, Intent, Run}
  alias Kogen.Integration.{Helpers, FakeProvider}
  @tag timeout: 240_000
  test "observe installed verification boundaries" do
    suite = Helpers.setup_suite!()
    on_exit(fn -> Helpers.cleanup_suite(suite) end)
    c = Helpers.project!(suite, [], staged_intent: false)
    on_exit(fn -> Helpers.cleanup_case(c) end)
    mode = System.fetch_env!("FF_MODE")
    put = fn p, text -> f = Path.join(c.repo, p); File.mkdir_p!(Path.dirname(f)); File.write!(f, text) end
    git = fn args -> {out, 0} = Helpers.git!(c, args); String.trim(out) end
    put.(".gitignore", ".kogen/local/\n")
    put.("app.txt", "baseline\n")
    put.("policy.qnt", "module policy { val Allowed = true }\n")
    # External trace is evidence only. It supplies no candidate inputs.
    trace = Path.join(c.root, "trace")
    File.write!(trace, "")
    put.("gate.sh", "set -eu\nprintf '%s|%s|%s\\n' \"$(pwd -P)\" \"$(cat app.txt)\" \"$1\" >> \"$FF_TRACE\"\ncase \"$1:$(cat app.txt)\" in setup-1:setup-red|z-cheap:project-red) echo definitive-fixture-red; exit 19;; esac\n")
    original = Config.load!(c.repo)
    runner = original.acceptance_run <> if(mode == "custom", do: "", else: " --fail-fast")
    # A wrapper containing shell syntax must remain verbatim, not be parsed or rewritten.
    runner = "printf 'wrapper\\n' >> \"$FF_WRAPPER\"; " <> runner
    config = Config.render(%{setup: ["sh gate.sh setup-1"], fix: [], checks: [%{name: "z-cheap", run: "sh gate.sh z-cheap"}, %{name: "a-later", run: "sh gate.sh a-later"}], protect: ["gate.sh"], acceptance: %{run: runner, steps_dir: original.steps_dir}})
    put.(".kogen/project.yaml", config)
    git.(["add", "-A"]); git.(["commit", "-qm", "Configure fail-fast fixture"])
    dir = ".kogen/intents/fixture"
    put.(dir <> "/intent.md", "# Verify candidate gates\n\nSlug: fixture\nModel: " <> dir <> "/model.qnt invariants=Valid seed=31 samples=2 steps=2\nAcceptance:\n- " <> dir <> "/acceptance.feature\n- features/steps/integration_steps.js\n\nExercise candidate gates.\n\n## Decisions\n- Keep every gate. (source: request)\n\n## Tests\n- Candidate: installed fixture (scenario)\n\n## Feasibility\n- none\n")
    put.(dir <> "/model.qnt", "module fixture {\n import policy.* from \"../../../policy\"\n var n: int\n action init = n' = 0\n action step = n' = n + 1\n val Valid = Allowed\n}\n")
    put.(dir <> "/acceptance.feature", "Feature: Gates\n  Scenario: First case\n    Then candidate gate 1 succeeds\n  Scenario: Later case\n    Then candidate gate 2 succeeds\n")
    put.("features/steps/integration_steps.js", "const {Then}=require('@cucumber/cucumber'); const fs=require('node:fs'); const assert=require('node:assert/strict'); Then('candidate gate {int} succeeds', n=>{const app=fs.readFileSync('app.txt','utf8').trim(); fs.appendFileSync(process.env.FF_TRACE, fs.realpathSync('.')+'|'+app+'|acceptance-'+n+'\\n'); if(n===1) assert.notEqual(app,'acceptance-red','definitive acceptance red');});\n")
    wrapper = Path.join(c.root, "wrapper")
    opts = [env: [{"FF_TRACE", trace}, {"FF_WRAPPER", wrapper}]]
    {card, 5} = Helpers.run_kogen(c, ["intent", "approve", "fixture"], opts)
    [_, hash] = Regex.run(~r/SHA-256: ([0-9a-f]{64})/, card)
    {_, 0} = Helpers.run_kogen(c, ["intent", "approve", "fixture", hash], opts)
    git.(["add", dir, "features/steps/integration_steps.js"])
    index = File.read!(Path.join(c.repo, ".git/index"))
    approval = File.read!(Intent.approval_path(c.repo, "fixture"))
    start = git.(["rev-parse", "HEAD"])
    # Sign only the actual Build result, not setup commits.
    key = Path.join(c.root, "signing-key")
    {_, 0} = System.cmd("ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", key])
    signers = Path.join(c.root, "allowed-signers")
    File.write!(signers, "kogen-integration@example.invalid " <> File.read!(key <> ".pub"))
    git.(["config", "gpg.format", "ssh"]); git.(["config", "user.signingkey", key]); git.(["config", "commit.gpgsign", "true"])
    red = case mode do
      "acceptance" -> "acceptance-red"
      "custom" -> "acceptance-red"
      "project" -> "project-red"
      "setup" -> "setup-red"
      "model" -> "model-red"
      "reviewer" -> "builder-green"
    end
    edit = fn value -> f("write_file", %{"path" => "app.txt", "content" => value <> "\n"}) end
    policy = fn ok -> f("write_file", %{"path" => "policy.qnt", "content" => "module policy { val Allowed = #{ok} }\n"}) end
    finish = f("finish", %{"summary" => "Verify the candidate"})
    approve = f("submit_review", %{"verdict" => "approve", "findings" => []})
    stop = {:http, 400, %{"error" => %{"message" => "bounded fixture stop", "code" => "invalid_request_error"}}}
    script = [edit.(red)] ++ (if mode == "model", do: [policy.(false)], else: []) ++ [finish] ++
      (if mode == "reviewer", do: [edit.("acceptance-red"), approve, edit.("reviewer-green"), approve], else: [stop])
    install = fn actions -> Agent.update(c.server.state, fn s -> %{s | script: Enum.take(s.script, s.next) ++ actions} end) end
    install.(script)
    File.write!(trace, "")
    {output, status} = Helpers.run_kogen(c, ["intent", "build", "fixture"], opts)
    [result_path] = Path.wildcard(Path.join(c.repo, ".kogen/local/runs/*/result.json"))
    run_dir = Path.dirname(result_path)
    result = JSON.decode!(File.read!(result_path))
    logs = read_logs(run_dir)
    passes = Enum.filter(logs, &(&1["event"] == "pass"))
    first = hd(passes)
    cp = File.read!(Path.join(run_dir, "checkpoint.json"))
    {:ok, _, saved} = Run.decode_checkpoint(cp)
    required = ["model", "z-cheap", "a-later"]
    expected = case mode do
      "setup" -> ["acceptance" | required]
      "model" -> ["z-cheap", "a-later"]
      "project" -> ["a-later"]
      "reviewer" -> []
      _ -> required
    end
    requests = FakeProvider.provider_requests(c.server)
    feedback = Enum.map_join(requests, "\n", &JSON.encode!(&1.json["input"]))
    names = fn text, list -> Regex.match?(~r/not[ _-]run|unrun|skipped/i, text) and Enum.all?(list, &String.contains?(text, &1)) end
    trace_rows = fn -> File.read!(trace) |> String.split("\n", trim: true) |> Enum.map(&String.split(&1, "|")) end
    native_trace = fn value -> trace_rows.() |> Enum.filter(fn [cwd, app, _] -> cwd != c.repo and app == value end) |> Enum.map(&List.last/1) end
    initial_trace = native_trace.(red)
    red_custody = git.(["rev-parse", "HEAD"]) == start and File.read!(Path.join(c.repo, ".git/index")) == index and File.read(Intent.approval_path(c.repo, "fixture")) == {:ok, approval}
    first_history = File.read!(result_path)
    first_trace_count = length(initial_trace)
    {resume_output, resume_status} = if mode != "reviewer" do
      # The first finish on resume is unchanged red: it cannot reuse an incomplete pass.
      install.([finish, edit.("repaired-green"), policy.(true), finish, approve])
      Helpers.run_kogen(c, ["intent", "resume", Path.basename(run_dir)], opts)
    else {output, status} end
    results = Path.wildcard(Path.join(c.repo, ".kogen/local/runs/*/result.json")) |> Enum.map(&(JSON.decode!(File.read!(&1))))
    landed = Enum.find(results, &(&1["outcome"] == "landed"))
    final_value = if mode == "reviewer", do: "reviewer-green", else: "repaired-green"
    final_trace = native_trace.(final_value)
    expected_trace = ["setup-1", "acceptance-1", "acceptance-2", "z-cheap", "a-later"]
    count = String.to_integer(git.(["rev-list", "--count", start <> "..HEAD"]))
    {_, signed_status} = Helpers.git!(c, ["-c", "gpg.ssh.allowedSignersFile=" <> signers, "verify-commit", "HEAD"])
    all_logs = Path.wildcard(Path.join(c.repo, ".kogen/local/runs/*/log.jsonl")) |> Enum.flat_map(fn p -> read_logs(Path.dirname(p)) end)
    all_passes = Enum.filter(all_logs, &(&1["event"] == "pass"))
    reviews = FakeProvider.review_requests(c.server)
    reviewer_red = Enum.find(passes, &(&1["green"] == false))
    # These are observed public evidence fields, not helper-call or implementation-structure assertions.
    receipt = %{
      firstTrace: initial_trace, notRun: first["not_run"],
      actualFailure: first["green"] == false and first["failing"] != [] and (feedback =~ "definitive" or feedback =~ "invariant"),
      feedbackNamesNotRun: names.(feedback, expected), logNamesNotRun: first["not_run"] == expected,
      checkpointNamesNotRun: Map.get(saved.last_pass, :not_run) == expected and not saved.last_pass.green,
      resultNamesNotRun: result["not_run"] == expected,
      stoppedSummaryNamesNotRun: names.(output, expected),
      noCommitOnRed: status != 0 and red_custody, indexAndApprovalPreserved: red_custody,
      unchangedRedRetested: length(native_trace.(red)) == first_trace_count * 2 and File.read!(result_path) == first_history and Enum.count(all_passes, &(&1["green"] == false)) >= 2,
      repairedCandidateRunsAll: final_trace == expected_trace and Enum.any?(all_passes, &(&1["green"] == true and &1["not_run"] == [])),
      signedLanding: resume_status == 0 and count == 1 and signed_status == 0 and landed != nil,
      exactFinalTree: landed != nil and git.(["show", "HEAD:app.txt"]) == final_value and git.(["show", "HEAD:policy.qnt"]) == "module policy { val Allowed = true }" and Enum.any?(all_passes, &(&1["green"] == true)),
      oneReviewStage: landed != nil and landed["reviews"] == 1,
      reviewerRedStops: native_trace.("acceptance-red") == ["setup-1", "acceptance-1"] and reviewer_red != nil and reviewer_red["not_run"] == required,
      sameReviewerGetsFailure: length(reviews) == 4 and Enum.any?(reviews, &(JSON.encode!(&1.json["input"]) =~ "Final verification")),
      unchangedGreenReused: length(passes) == 3 and native_trace.("builder-green") == expected_trace and final_trace == expected_trace,
      output: output, resumeOutput: resume_output, passEvidence: all_passes,
      wrapperExecuted: File.exists?(wrapper), runtime: suite.release
    }
    File.write!(System.fetch_env!("FF_RECEIPT"), JSON.encode!(receipt))
  end
  defp f(name, args), do: {:function, name, args}
  defp read_logs(dir), do: Path.join(dir, "log.jsonl") |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
end
`;
When('I exercise installed fail-fast verification in mode {string}', { timeout: 360000 }, async function (mode) {
  assert.ok(['acceptance', 'custom', 'model', 'project', 'setup', 'reviewer'].includes(mode));
  const a = await archive();
  const dir = fs.mkdtempSync(path.join(work, 'case-'));
  const script = path.join(dir, 'fail_fast_test.exs'), receipt = path.join(dir, 'receipt.json');
  fs.writeFileSync(script, driver);
  const r = await run('mix', ['test', script], { cwd: root, env: { ...process.env, KOGEN_ARCHIVE: a, FF_MODE: mode, FF_RECEIPT: receipt } });
  assert.equal(r.code, 0, r.output); assert.ok(fs.existsSync(receipt), r.output);
  this.failFastReceipt = JSON.parse(fs.readFileSync(receipt, 'utf8'));
  await this.attach(JSON.stringify(this.failFastReceipt), 'application/json');
});
Then('the fail-fast verification observations are:', function (table) {
  assert.ok(this.failFastReceipt, 'missing installed observations');
  for (const [key, value] of table.raw()) assert.deepEqual(this.failFastReceipt[key], JSON.parse(value), `${key}: ${JSON.stringify(this.failFastReceipt)}`);
});
