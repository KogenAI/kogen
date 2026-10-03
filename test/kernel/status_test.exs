defmodule Kogen.Kernel.StatusTest do
  use Kogen.Testkit.Case

  alias Kogen.Kernel.Status
  alias Kogen.State.Json
  alias Kogen.State.Run
  alias Kogen.Testkit.Git

  test "a base commit trailer reports landed without a run record", %{tmp_dir: tmp_dir} do
    slug = "landed-elsewhere"
    {repo, branch, sha} = landed_project!(tmp_dir, slug)

    assert {:ok, [status]} =
             Status.list(repo, Path.join(tmp_dir, "state"), repo, branch, Git.env())

    assert status.slug == slug
    assert status.status == :landed
    assert status.landed_sha == sha
    assert status.run_id == nil
  end

  test "a base commit trailer takes precedence over a stale run record", %{tmp_dir: tmp_dir} do
    slug = "landed-elsewhere"
    {repo, branch, sha} = landed_project!(tmp_dir, slug)
    state_root = Path.join(tmp_dir, "state")
    run_dir = Path.join([state_root, "runs", "stale-run"])

    run = %Run{
      id: "stale-run",
      dir: run_dir,
      slug: slug,
      intent_sha256: String.duplicate("a", 64),
      target_branch: branch,
      approval_commit: nil,
      status: :failed,
      landing: nil
    }

    {:ok, contents} = Json.encode_run(run)
    File.mkdir_p!(run_dir)
    File.write!(Path.join(run_dir, "run.json"), contents)

    assert {:ok, [status]} = Status.list(repo, state_root, repo, branch, Git.env())

    assert status.status == :landed
    assert status.landed_sha == sha
    assert status.run_id == "stale-run"
  end

  defp landed_project!(tmp_dir, slug) do
    repo = Git.create!(tmp_dir)
    intent = Path.join([repo, ".kogen", "intents", slug, "intent.md"])

    File.mkdir_p!(Path.dirname(intent))
    File.write!(intent, "Intent landed by another clone.\n")
    Git.git!(repo, ["add", "--all"])

    Git.git!(repo, [
      "commit",
      "--quiet",
      "-m",
      "Landed by another clone\n\nKogen-Intent: #{slug}"
    ])

    sha = repo |> Git.git!(["rev-parse", "HEAD"]) |> String.trim()
    branch = repo |> Git.git!(["rev-parse", "--abbrev-ref", "HEAD"]) |> String.trim()
    {repo, branch, sha}
  end
end
