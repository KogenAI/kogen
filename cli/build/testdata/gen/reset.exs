# Reference for the local working-window reset: runs lib/kogen/working_context.ex prepare/6 on
# a fixed oversize conversation and writes the reduced input, the archive and the history.
#
#   mise exec -- mix run --no-start cli/build/testdata/gen/reset.exs   (in the repository root)
:persistent_term.put(:kogen_caller, %{env: %{}, cwd: File.cwd!(), install_root: File.cwd!()})

root = Path.join(System.tmp_dir!(), "reset-gen-#{System.unique_integer([:positive])}")
File.mkdir_p!(Path.join(root, ".kogen/local/runs/abcd1234"))
{_, 0} = System.cmd("git", ["init", "-q"], cd: root, env: [{"GIT_CONFIG_GLOBAL", "/dev/null"}])
File.write!(Path.join(root, "app.txt"), "app\n")

env = [
  {"GIT_AUTHOR_NAME", "x"}, {"GIT_AUTHOR_EMAIL", "x@example.invalid"},
  {"GIT_COMMITTER_NAME", "x"}, {"GIT_COMMITTER_EMAIL", "x@example.invalid"},
  {"GIT_CONFIG_GLOBAL", "/dev/null"}, {"GIT_CONFIG_NOSYSTEM", "1"}
]

{_, 0} = System.cmd("git", ["add", "."], cd: root, env: env)
{_, 0} = System.cmd("git", ["-c", "core.hooksPath=/dev/null", "commit", "-qm", "base"], cd: root, env: env)
{head, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: root)
head = String.trim(head)

run = %Kogen.Run{
  id: "abcd1234",
  dir: Path.join(root, ".kogen/local/runs/abcd1234"),
  log: Path.join(root, ".kogen/local/runs/abcd1234/log.jsonl")
}

filler = String.duplicate("é€ x\"\\\n", 2000)

opening = %{
  "role" => "user",
  "content" => [%{"type" => "input_text", "text" => "stable é"}, %{"type" => "input_text", "text" => "dynamic"}]
}

exchange = fn i ->
  [
    %{"type" => "reasoning", "id" => "r#{i}", "summary" => [], "encrypted_content" => "enc#{i}"},
    %{"role" => "assistant", "id" => "m#{i}", "phase" => "commentary", "content" => [%{"type" => "output_text", "text" => "I will look #{i}"}], "type" => "message", "status" => "completed"},
    %{"type" => "function_call", "id" => "f#{i}", "call_id" => "c#{i}", "name" => "shell", "arguments" => "{\"command\":\"echo #{i}\"}"},
    %{"type" => "function_call_output", "call_id" => "c#{i}", "output" => "exit status: 0\n" <> filler}
  ]
end

finish = [
  %{"type" => "function_call", "id" => "ff", "call_id" => "cf", "name" => "finish", "arguments" => "{\"summary\":\"all done é\"}"},
  %{"type" => "function_call_output", "call_id" => "cf", "output" => "Verification pass 1 is not green."}
]

input = [opening] ++ Enum.flat_map(1..20, exchange) ++ finish ++ exchange.(21)

b = %{
  root: root,
  start: head,
  excluded: [],
  last_pass: nil,
  last_review: nil,
  repairs: 2,
  continuation: %{stage: :builder, input: input},
  approval_bytes: Base.encode64(JSON.encode!(%{"sha256" => String.duplicate("a", 64)})),
  run: run,
  working_context: %{}
}

role = %{model: "gpt-6.1-sol", effort: "medium"}
tools = [%{"type" => "function", "name" => "sample", "parameters" => %{"type" => "object"}}]
{b2, reduced} = Kogen.WorkingContext.prepare(b, "build", role, "policy text", input, tools)
state = b2.working_context["build"]
[ref] = state.history
archive = File.read!(ref["path"])

strip = fn text -> String.replace(text, root, "<ROOT>") end

File.write!(
  "cli/build/testdata/reset-golden.json",
  JSON.encode!(%{
    "reduced" => JSON.decode!(strip.(JSON.encode!(reduced))),
    "history" => [%{"path" => strip.(ref["path"]), "sha256" => ref["sha256"]}],
    "observations" => JSON.decode!(JSON.encode!(state.observations)),
    "archive" => archive,
    "tree" => (fn -> {t, 0} = System.cmd("git", ["write-tree"], cd: root); String.trim(t) end).()
  })
)

File.rm_rf!(root)
IO.puts("reduced #{length(reduced)} of #{length(input)} items")
