defmodule Kogen.PreconditionFixture do
  @moduledoc false

  def create!(source, files, git_env) do
    template =
      Path.join(
        System.tmp_dir!(),
        "kogen-precondition-template-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(template)

    Enum.each(files, fn {relative, contents} ->
      path = Path.join(template, relative)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, contents)
    end)

    copy!(source, template, ".codex/hooks.json")
    copy!(source, template, ".codex/hooks/verification_policy.py")
    copy!(source, template, ".codex/hooks/check.sh")

    {_out, 0} = System.cmd("git", ["init", "-q", "-b", "main"], cd: template)
    {_out, 0} = System.cmd("git", ["add", "-A"], cd: template)

    {_out, 0} =
      System.cmd("git", ["commit", "-q", "-m", "precondition template"],
        cd: template,
        env: git_env
      )

    template
  end

  def copy!(template) do
    destination =
      Path.join(
        System.tmp_dir!(),
        "kogen-precond-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.cp_r!(template, destination)
    destination
  end

  def child_template! do
    System.fetch_env!("KOGEN_ISOLATED_PARAMETERS")
    |> Base.decode64!()
    |> :erlang.binary_to_term()
    |> Map.fetch!(:template)
  end

  defp copy!(source, template, relative) do
    destination = Path.join(template, relative)
    File.mkdir_p!(Path.dirname(destination))
    File.cp!(Path.join(source, relative), destination)
  end
end
