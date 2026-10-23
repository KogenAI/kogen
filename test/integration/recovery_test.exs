Code.require_file(Path.expand("../support/integration_helpers.ex", __DIR__))

defmodule Kogen.Integration.RecoveryTest do
  use ExUnit.Case, async: true, group: :installed_release
  alias Kogen.{Intent, Run}
  alias Kogen.Integration.{FakeProvider, Helpers}
  @moduletag :integration
  @moduletag timeout: 300_000

  setup_all do
    suite = Helpers.setup_suite!()
    on_exit(fn -> Helpers.cleanup_suite(suite) end)
    {:ok, suite: suite}
  end

  defp blocked!(suite, commands) do
    c = Helpers.project!(suite, [], staged_intent: false)
    on_exit(fn -> Helpers.cleanup_case(c) end)
    File.mkdir_p!(Path.join(c.repo, "locked"))
    File.write!(Path.join(c.repo, "locked/value"), "before\n")
    File.write!(Path.join(c.repo, "filtered"), "before\n")
    File.write!(Path.join(c.repo, ".gitattributes"), "filtered filter=normalize\n")
    Helpers.git!(c, ["config", "filter.normalize.clean", "tr a-z A-Z"])
    Helpers.git!(c, ["add", "locked/value", "filtered", ".gitattributes"])
    Helpers.git!(c, ["commit", "-qm", "Recovery inputs"])
    File.write!(Path.join(c.repo, ".git/info/exclude"), "ignored/\n")

    report = %{
      "paths" => [Intent.feature("fixture")],
      "reason" => "local fixture contradiction",
      "evidence" => "local retained reproducer: mutually exclusive assertions"
    }

    FakeProvider.append(c.server, [
      {:function, "shell", %{"command" => commands}},
      {:function, "report_blocker", report}
    ])

    {out, code} = Helpers.run_kogen(c, ["intent", "build", "fixture"])
    assert code == 1, out
    assert out =~ "candidate/build_blocked"
    [cp] = Path.wildcard(Path.join(c.repo, ".kogen/local/runs/*/checkpoint.json"))
    {:ok, doc, b} = Run.decode_checkpoint(File.read!(cp))
    {c, doc, b}
  end

  test "raw filtered bytes, binary, executable modes, symlink targets and deleted paths are archived without index or ignored-output changes",
       %{suite: suite} do
    {c, _, b} =
      blocked!(
        suite,
        "printf 'candidate raw\n' > filtered; printf '\\000\\377' > binary; chmod +x filtered; rm locked/value; ln -s filtered link; mkdir -p ignored; printf warm > ignored/cache"
      )

    output = Path.join(c.root, "raw archive")
    index = File.read!(b.git_index)
    {out, code} = Helpers.run_kogen(c, ["intent", "recover", b.run.id, "--output", output])
    assert code == 0, out
    manifest = JSON.decode!(File.read!(Path.join(output, "manifest.json")))
    assert File.read!(Path.join(output, "candidate/filtered")) == "candidate raw\n"
    assert File.read!(Path.join(output, "before/filtered")) == "BEFORE\n"
    assert File.read!(Path.join(output, "candidate/binary")) == <<0, 255>>
    assert File.read!(Path.join(output, "candidate/link")) == "filtered"
    assert File.lstat!(Path.join(output, "candidate/link")).type == :regular
    modes = Map.new(manifest["changes"], &{&1["path"], &1["after"]})
    assert modes["filtered"]["mode"] == "100755"
    assert modes["link"]["mode"] == "120000"
    assert File.read!(Path.join(c.repo, "filtered")) == "BEFORE\n"
    assert Bitwise.band(File.stat!(Path.join(c.repo, "filtered")).mode, 0o111) == 0
    assert File.read!(Path.join(c.repo, "locked/value")) == "before\n"
    refute File.exists?(Path.join(c.repo, "binary"))
    assert File.lstat(Path.join(c.repo, "link")) == {:error, :enoent}
    assert File.read!(Path.join(c.repo, "ignored/cache")) == "warm"
    assert File.read!(b.git_index) == index

    assert Enum.map(manifest["artifacts"], & &1["path"]) ==
             Enum.sort(Enum.map(manifest["artifacts"], & &1["path"]))
  end

  test "file-directory replacements preserve both leaf sets and clean only the delta", %{
    suite: suite
  } do
    {c, _, b} =
      blocked!(
        suite,
        "rm app.txt; mkdir app.txt; printf nested > app.txt/child; rm locked/value; rmdir locked; printf replacement > locked"
      )

    output = Path.join(c.root, "transitions")
    index = File.read!(b.git_index)

    {out, code} =
      Helpers.run_kogen(
        c,
        ["intent", "recover", b.run.id, "--output", output, "--project", c.repo],
        cd: c.root
      )

    assert code == 0, out
    assert File.read!(Path.join(output, "before/app.txt")) == "baseline\n"
    assert File.read!(Path.join(output, "candidate/app.txt/child")) == "nested"
    assert File.read!(Path.join(output, "before/locked/value")) == "before\n"
    assert File.read!(Path.join(output, "candidate/locked")) == "replacement"
    assert File.read!(Path.join(c.repo, "app.txt")) == "baseline\n"
    assert File.read!(Path.join(c.repo, "locked/value")) == "before\n"
    assert File.read!(b.git_index) == index
    assert out =~ "--project #{Kogen.Init.shell_quote(c.repo)}"
  end

  test "publication precedes a controlled local cleanup write failure; candidate rollback and preserved receipt remain honest",
       %{suite: suite} do
    {c, _, b} = blocked!(suite, "printf candidate > app.txt; printf after > locked/value")
    locked = Path.join(c.repo, "locked")
    File.chmod!(locked, 0o555)
    on_exit(fn -> File.chmod(locked, 0o755) end)
    root_caller? = match?({:ok, _}, File.write(Path.join(locked, "write-probe"), "probe"))

    if root_caller? do
      File.rm!(Path.join(locked, "write-probe"))
      # Root bypasses mode bits. Give this disposable checkout to an unprivileged
      # process, using the identical installed CLI/core and inode-bound checkpoint.
      {_, 0} = System.cmd("chown", ["-R", "65534:65534", c.root])
      File.chmod!(c.suite.root, 0o755)
      File.chmod!(c.root, 0o755)
    end

    output = Path.join(c.root, "archive")
    index = File.read!(b.git_index)
    approval = File.read!(Intent.approval_path(c.repo, "fixture"))
    requests = FakeProvider.provider_requests(c.server)
    args = ["intent", "recover", b.run.id, "--output", output]

    {out, code} =
      if root_caller? do
        script =
          "import os,sys; os.setgroups([]); os.setgid(65534); os.setuid(65534); os.execv(sys.argv[1],sys.argv[1:])"

        System.cmd("python3", ["-c", script, c.suite.release | args],
          cd: c.repo,
          env: Map.to_list(c.env),
          stderr_to_stdout: true
        )
      else
        Helpers.run_kogen(c, args)
      end

    assert code == 1, out
    assert out =~ "cleanup incomplete"
    assert out =~ "candidate bytes restored"
    assert File.read!(Path.join(output, "candidate/app.txt")) == "candidate"
    assert File.read!(Path.join(c.repo, "app.txt")) == "candidate"
    assert File.read!(Path.join(locked, "value")) == "after"

    receipt =
      JSON.decode!(File.read!(Path.join(c.repo, ".kogen/local/recoveries/#{b.run.id}.json")))

    assert receipt["state"] == "preserved"
    assert receipt["archive"] == output
    assert File.read!(b.git_index) == index
    assert File.read!(Intent.approval_path(c.repo, "fixture")) == approval
    assert FakeProvider.provider_requests(c.server) == requests
    assert File.regular?(Path.join(output, "manifest.json"))
    File.chmod!(locked, 0o755)
  end
end
