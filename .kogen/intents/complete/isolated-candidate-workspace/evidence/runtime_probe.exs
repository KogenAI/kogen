alias Kogen.{Codex, Harness, Intent}

root = File.cwd!()
probe = Path.join(System.tmp_dir!(), "kogen-runtime-root-probe-#{System.unique_integer([:positive])}")
candidate = Path.join(probe, "candidate")
independent = Path.join(probe, "independent")
branch = "kogen/probe/#{System.unique_integer([:positive])}"

run! = fn exe, args, opts ->
  case System.cmd(exe, args, Keyword.merge([stderr_to_stdout: true], opts)) do
    {output, 0} -> String.trim(output)
    {output, status} -> raise "#{exe} failed #{status}: #{output}"
  end
end

File.mkdir!(probe)

try do
  run!.(("git"), ["worktree", "add", "-q", "-b", branch, candidate, "HEAD"], cd: root)
  File.write!(Path.join(candidate, "AGENTS.md"), "When reporting repository identity, include CANDIDATE_INSTRUCTION_7B31.\n")
  File.write!(Path.join(candidate, "candidate-sentinel.txt"), "CANDIDATE_SENTINEL_91CC\n")
  File.mkdir!(independent)
  run!.(("git"), ["init", "-q", "-b", "main"], cd: independent)
  File.write!(Path.join(independent, "AGENTS.md"), "INDEPENDENT_INSTRUCTION_WRONG_229A\n")
  File.write!(Path.join(independent, "independent-sentinel.txt"), "INDEPENDENT_SENTINEL_WRONG_B433\n")

  {:ok, config} = Intent.read_config()
  {:ok, selection} = Codex.open(config, candidate)

  prompt = """
  This is a read-only root-routing probe. Do not modify files. Run `pwd` and
  `git rev-parse --show-toplevel`; report both exact outputs, whether
  candidate-sentinel.txt exists and its exact token, which repository instruction
  token applies, and whether the independent-repository token is visible. Spawn
  exactly one explorer helper and ask it independently for pwd, Git root, and the
  applicable instruction token; include its answer. End with ROOT_PROBE_FRESH.
  """

  policy = Kogen.VerificationPolicy.environment(["check"], candidate)
  fresh = Harness.launch_developer(prompt, config.developer.model, config.developer.effort, policy, Codex.launch_context(selection))
  IO.puts("PROBE_ROOT=#{probe}")
  IO.puts("CANDIDATE=#{candidate}")
  IO.puts("INDEPENDENT=#{independent}")
  IO.puts("FRESH=#{inspect(fresh, limit: :infinity, printable_limit: :infinity)}")

  {:ok, fresh_turn} = fresh
  resume = Harness.resume_developer(fresh_turn.session_id, "Repeat pwd, Git root, sentinel and instruction token without editing; end ROOT_PROBE_RESUME.", config.developer.model, config.developer.effort, policy, Codex.launch_context(selection))
  IO.puts("RESUME=#{inspect(resume, limit: :infinity, printable_limit: :infinity)}")

  review_prompt = """
  Read-only root-routing probe. Run pwd and git rev-parse --show-toplevel and inspect
  candidate-sentinel.txt and applicable repository instructions. Then return only a
  schema-valid Reviewer verdict with candidate_id "probe-candidate", attempt_token
  "probe-attempt", verdict "accept", empty dispositions/findings, and one scenario
  object with id "root", satisfied true, summary containing the exact pwd, Git root,
  sentinel token, and instruction token, plus empty references.
  """

  reviewer = Harness.launch_reviewer(review_prompt, config.reviewer.model, config.reviewer.effort, Codex.launch_context(selection))
  IO.puts("REVIEWER=#{inspect(reviewer, limit: :infinity, printable_limit: :infinity)}")
  Codex.close(selection)
after
  System.cmd("git", ["worktree", "remove", "--force", candidate], cd: root, stderr_to_stdout: true)
  System.cmd("git", ["branch", "-D", branch], cd: root, stderr_to_stdout: true)
  File.rm_rf(probe)
  IO.puts("CLEANUP_EXISTS=#{File.exists?(probe)}")
end
