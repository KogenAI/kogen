# Diagnostic only: production Workspace.open against owned disposable Git roots.
# Synthetic regular seeds are an admission control, not proof of Mix validity.
alias Kogen.Build.Workspace

run! = fn root, args ->
  case System.cmd("git", ["-c", "commit.gpgsign=false" | args], cd: root, stderr_to_stdout: true) do
    {output, 0} -> String.trim(output)
    {output, status} -> raise "git failed #{status}: #{output}"
  end
end

for variant <- [:regular, :contained_mix_link, :runtime_link] do
  root = Path.join(System.tmp_dir!(), "kogen-shaping-seed-#{System.pid()}-#{variant}-#{System.unique_integer([:positive])}")
  File.mkdir!(root)

  try do
    File.mkdir_p!(Path.join(root, "deps/example"))
    File.mkdir_p!(Path.join(root, "_build/dev/lib/kogen"))
    File.mkdir_p!(Path.join(root, "priv"))
    File.write!(Path.join(root, "deps/example/source"), "seed\n")
    File.write!(Path.join(root, "_build/dev/lib/kogen/artifact"), "synthetic-admission-control\n")
    File.write!(Path.join(root, "priv/probe"), "tracked-private-resource\n")
    File.write!(Path.join(root, ".gitignore"), "deps/\n_build/\n.kogen/\n")
    run!.(root, ["init", "-q", "-b", "main"])
    run!.(root, ["add", ".gitignore", "priv/probe"])
    run!.(root, ["-c", "user.name=Shaping probe", "-c", "user.email=probe@example.invalid", "commit", "-qm", "seed admission control"])

    case variant do
      :regular -> :ok
      :contained_mix_link -> File.ln_s!("../../../../priv", Path.join(root, "_build/dev/lib/kogen/priv"))
      :runtime_link ->
        File.mkdir_p!(Path.join(root, ".kogen/runtime/unsafe"))
        File.ln_s!("../../../../.kogen/runtime/unsafe", Path.join(root, "_build/dev/lib/kogen/priv"))
    end

    source_before = File.read!(Path.join(root, "deps/example/source"))
    result = Workspace.open(root, %{id: "shaping-seed-control"}, "seed-probe", [{"", :directory, 0o755}, {"INTENT.md", :regular, 0o644, "probe only\n"}])

    observation = case result do
      {:ok, workspace} ->
        candidate_link = File.read_link(Path.join(workspace.path, "_build/dev/lib/kogen/priv"))
        retirement = Workspace.retire(workspace)
        %{admission: :accepted, candidate_link: candidate_link, retirement: retirement}
      {:error, reason} -> %{admission: :rejected, reason: reason}
    end

    IO.inspect(%{variant: variant, observation: observation, source_unchanged: source_before == File.read!(Path.join(root, "deps/example/source")), worktrees: run!.(root, ["worktree", "list", "--porcelain"]) |> String.split("\n") |> Enum.count(&String.starts_with?(&1, "worktree ")), remaining_candidate_branches: run!.(root, ["branch", "--list", "kogen/build/*"])}, limit: :infinity)
  after
    File.rm_rf!(root)
    IO.puts("owned_fixture_removed=#{not File.exists?(root)} variant=#{variant}")
  end
end
