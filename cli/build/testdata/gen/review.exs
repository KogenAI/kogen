# Reference for what the independent reviewer reads: runs lib/kogen/review.ex material/2 on a
# fixed repository (changed, deleted, added text, added binary, executable and gitlink paths)
# and lib/kogen/review_material.ex prepare/7 on a fixed oversize source, and writes both
# results (commit and tree ids replaced by placeholders where they depend on this run).
#
#   mise exec -- mix run --no-start cli/build/testdata/gen/review.exs   (in the repository root)
:persistent_term.put(:kogen_caller, %{env: %{}, cwd: File.cwd!(), install_root: File.cwd!()})

# material/2 is private: compile a copy of the module that exports it.
src =
  File.read!("lib/kogen/review.ex")
  |> String.replace("defmodule Kogen.Review do", "defmodule Kogen.ReviewGen do")
  |> String.replace("defp material(", "def material(")

Code.compile_string(src)

root = Path.join(System.tmp_dir!(), "review-gen-#{System.unique_integer([:positive])}")
File.mkdir_p!(Path.join(root, ".kogen/local/runs/abcd1234"))
File.chmod!(Path.join(root, ".kogen/local/runs/abcd1234"), 0o700)

env = [
  {"GIT_AUTHOR_NAME", "x"}, {"GIT_AUTHOR_EMAIL", "x@example.invalid"},
  {"GIT_COMMITTER_NAME", "x"}, {"GIT_COMMITTER_EMAIL", "x@example.invalid"},
  {"GIT_AUTHOR_DATE", "2026-10-22T00:00:00Z"}, {"GIT_COMMITTER_DATE", "2026-10-22T00:00:00Z"},
  {"GIT_CONFIG_GLOBAL", "/dev/null"}, {"GIT_CONFIG_NOSYSTEM", "1"}
]

git = fn args, dir ->
  {out, 0} = System.cmd("git", ["-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false"] ++ args, cd: dir, env: env, stderr_to_stdout: true)
  out
end

write = fn path, content ->
  File.mkdir_p!(Path.dirname(Path.join(root, path)))
  File.write!(Path.join(root, path), content)
end

git.(["init", "-q"], root)
write.("README.md", "# Gen project\nΔ🙂 readme\n")
write.("app.txt", "line one\nold marker\nline three\n")
write.("gone.txt", "to be deleted\n")
write.("keep.txt", "unchanged\n")
write.(".gitignore", ".kogen/local/\n")
git.(["add", "."], root)
git.(["commit", "-qm", "base"], root)
start = git.(["rev-parse", "HEAD"], root) |> String.trim()

write.("app.txt", "line one\nnew marker\nline three\n")
File.rm!(Path.join(root, "gone.txt"))
write.("new.txt", "added Δ🙂 text\r\nsecond \"line\"\n")
File.write!(Path.join(root, "new.bin"), <<0, 1, 2, 255>>)
write.("tool.sh", "#!/bin/sh\necho tool\n")
File.chmod!(Path.join(root, "tool.sh"), 0o755)
git.(["init", "-q", "sub"], root)
git.(["commit", "--allow-empty", "-qm", "Nested fixture"], Path.join(root, "sub"))
sub = git.(["rev-parse", "HEAD"], Path.join(root, "sub")) |> String.trim()
write.(".kogen/intents/fixture/acceptance.feature", "Feature: Gen\n  Scenario: One\n    Then it holds\n")
write.(".kogen/intents/fixture/model.qnt", "module m { val x = 1 }\n")

tree = Kogen.Snapshot.tree(root, start, [])

b = %{
  root: root,
  start: start,
  slug: "fixture",
  excluded: [],
  baseline: [".kogen/intents/fixture/acceptance.feature", ".kogen/project.yaml"],
  config: %{fix: ["fmt", "lint --fix"], checks: [{"tidy", "make tidy"}, {"unit", "make unit"}], acceptance_run: "npx cucumber"},
  intent: %{text: "# Gen intent\n\nSlug: fixture\n\nDo the thing.\n"},
  source_provenance: nil,
  run: %Kogen.Run{id: "abcd1234", dir: Path.join(root, ".kogen/local/runs/abcd1234"), log: Path.join(root, ".kogen/local/runs/abcd1234/log.jsonl")},
  review: 1,
  working_context: %{},
  continuation: %{stage: :review},
  repairs: 0,
  last_pass: nil,
  last_review: nil,
  approval_bytes: Base.encode64(JSON.encode!(%{"sha256" => "exact approval"}))
}

pass = %{
  tree: tree,
  model: :none,
  acceptance: %{scenarios: [1]},
  checks: [%{name: "tidy"}, %{name: "unit"}]
}

m = Kogen.ReviewGen.material(b, pass)

hex = fn text ->
  text |> String.replace(start, "<START>") |> String.replace(String.slice(start, 0, 8), "<START8>")
end

# prepare/7: a fixed oversize source with every character class the parts must carry.
source = String.duplicate("literal Δ🙂\r\n\t\"\\\u0001é€", 24_000) <> String.duplicate(<<1>>, 12_000)

big = %{
  authority: "exact approved literal Δ🙂\r\n\t  ",
  source: source,
  checks: "acceptance: passed (1 scenarios)",
  files: m.files
}

diagnostic = [%{"role" => "user", "content" => "frozen diagnostic\r\nΔ🙂"}]
role = %{model: "gpt-6.1-sol", effort: "high"}
{b2, input} = Kogen.ReviewMaterial.prepare(b, tree, big, role, "policy", [], diagnostic)
refs = b2.working_context["review"].history
dir = Path.join([b.run.dir, "review-source", "1-#{tree}"])

strip = fn text -> text |> String.replace(root, "<ROOT>") |> hex.() end

File.write!(
  "cli/build/testdata/review/material-golden.json",
  JSON.encode!(%{
    "start" => start,
    "tree" => tree,
    "gitlink" => sub,
    "authority" => hex.(m.authority),
    "source" => hex.(m.source),
    "checks" => m.checks,
    "files" => JSON.decode!(hex.(JSON.encode!(m.files))),
    "prepared" => %{
      "input" => JSON.decode!(strip.(JSON.encode!(input))),
      "dir" => strip.(dir),
      "parts" => for(ref <- refs, do: %{"sha256" => ref["sha256"]}),
      "first_part" => File.read!(hd(refs)["path"]),
      "last_part" => File.read!(List.last(refs)["path"]),
      "source_sha256" => Kogen.WorkingContext.hash(source)
    }
  })
)

File.rm_rf!(root)
IO.puts("files #{length(m.files)}, parts #{length(refs)}")
