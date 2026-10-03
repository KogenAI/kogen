defmodule Kogen.Acceptance.ProtectedWritesTest do
  use Kogen.Testkit.Case

  alias Kogen.Contracts.Project
  alias Kogen.Contracts.ToolCall
  alias Kogen.Harness.Opts
  alias Kogen.Harness.Tools

  @moduletag :acceptance
  @protected "test/acceptance/probe_test.exs"

  @tag intent: "protected-writes/A1"
  test "edit and write refuse protected paths", %{tmp_dir: tmp_dir} do
    opts = %{options(tmp_dir) | protected: [@protected]}
    path = Path.join(opts.workdir, @protected)

    edit = run(opts, "edit", %{"path" => @protected, "old_text" => "approved", "new_text" => "x"})
    assert edit.is_error
    assert edit.output =~ @protected

    write = run(opts, "write", %{"path" => @protected, "content" => "rewritten\n"})
    assert write.is_error
    assert write.output =~ @protected

    assert File.read!(path) == "approved\n"
  end

  @tag intent: "protected-writes/A2"
  test "edit still changes unprotected paths", %{tmp_dir: tmp_dir} do
    opts = options(tmp_dir)

    result =
      run(opts, "edit", %{"path" => "lib/app.ex", "old_text" => "old", "new_text" => "new"})

    refute result.is_error
    assert File.read!(Path.join(opts.workdir, "lib/app.ex")) == "new\n"
  end

  @tag intent: "protected-writes/A3"
  test "protected defaults to an empty list", %{tmp_dir: tmp_dir} do
    assert options(tmp_dir).protected == []
  end

  defp run(opts, name, arguments) do
    Tools.run(opts, %ToolCall{id: "call-#{name}", name: name, arguments: arguments}, [
      :edit,
      :write
    ])
  end

  defp options(tmp_dir) do
    workdir = Kogen.Testkit.Git.create!(Path.join(tmp_dir, "candidate"))
    File.mkdir_p!(Path.join(workdir, "test/acceptance"))
    File.mkdir_p!(Path.join(workdir, "lib"))
    File.write!(Path.join(workdir, @protected), "approved\n")
    File.write!(Path.join(workdir, "lib/app.ex"), "old\n")

    project = %Project{
      root: workdir,
      name: "probe",
      checks: [],
      setup: [],
      fix: [],
      diagnose: [],
      protected_paths: [],
      domains: %{"app" => ["lib", "test"]}
    }

    %Opts{
      workdir: workdir,
      run_dir: Path.join(tmp_dir, "run"),
      project: project,
      provider_mod: Kogen.Provider.Fake,
      provider_config: nil,
      proc_mod: Kogen.Proc
    }
  end
end
