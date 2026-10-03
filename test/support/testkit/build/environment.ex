defmodule Kogen.E2e.Build.Environment do
  @moduledoc false

  alias Kogen.Engine.Runtime
  alias Kogen.Testkit.Git

  def runtime!(project_root, home) do
    {:ok, discovered} = Kogen.Kernel.runtime()
    toolchain_home = Map.get(discovered.base_env, "HOME", home)

    mise_data =
      Map.get(
        discovered.base_env,
        "MISE_DATA_DIR",
        Path.join([toolchain_home, ".local", "share", "mise"])
      )

    base_env =
      discovered.base_env
      |> test_runtime_environment()
      |> Map.merge(%{
        "HOME" => home,
        "MIX_HOME" => Path.join(home, ".mix"),
        "HEX_HOME" => Path.join(home, ".hex"),
        "MISE_CACHE_DIR" => Path.join([home, ".cache", "mise"]),
        "MISE_DATA_DIR" => mise_data
      })

    fake_mise = write_fake_mise!(project_root, Map.fetch!(base_env, "PATH"))
    runtime = %{discovered | base_env: base_env, git_env: Git.env(), mise: fake_mise}

    case Kogen.Kernel.project_environment(project_root, runtime) do
      {:ok, env} -> Runtime.for_project(runtime, env)
      {:error, reason} -> raise "test fake mise failed: #{inspect(reason)}"
    end
  end

  def child_env!(home) do
    {:ok, runtime} = Kogen.Kernel.runtime()
    toolchain_home = Map.get(runtime.base_env, "HOME", home)

    mise_data =
      Map.get(
        runtime.base_env,
        "MISE_DATA_DIR",
        Path.join([toolchain_home, ".local", "share", "mise"])
      )

    runtime.base_env
    |> Map.put("HOME", home)
    |> Map.put("MISE_DATA_DIR", mise_data)
  end

  def executable!(env, name) do
    found =
      env
      |> Map.fetch!("PATH")
      |> String.split(":", trim: true)
      |> Enum.find_value(&executable_candidate(&1, name))

    case found do
      nil -> raise "#{name} is unavailable on the test PATH"
      executable -> executable
    end
  end

  defp test_runtime_environment(base_env) do
    allowed = ~w(PATH HOME LANG LC_ALL TERM TMPDIR USER SHELL MIX_HOME HEX_HOME)
    markers = ~w(KOGEN_ERTS_DIR KOGEN_ERTS_BIN KOGEN_ESCRIPT_DIR KOGEN_BIN_DIR)

    base_env
    |> Map.take(allowed ++ markers)
    |> Map.merge(Git.env())
  end

  defp write_fake_mise!(project_root, path_value) do
    path = Path.join([project_root, ".test-bin", "mise"])
    env = %{"PATH" => path_value, "MIX_ENV" => "test", "ERL_FLAGS" => "+S 1:1 +A 1"}
    json = env |> :json.encode() |> IO.iodata_to_binary()
    quoted_json = shell_quote(json)

    script = """
    #!/bin/sh
    if [ "$1" = "env" ]; then
      printf '%s\\n' #{quoted_json}
    else
      echo "test fake mise only supports env" >&2
      exit 64
    fi
    """

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, script)
    File.chmod!(path, 0o755)
    path
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  defp executable_candidate(directory, name) do
    candidate = Path.join(directory, name)

    case File.stat(candidate) do
      {:ok, %File.Stat{mode: mode}} when :erlang.band(mode, 0o111) != 0 -> candidate
      _other -> nil
    end
  end
end
