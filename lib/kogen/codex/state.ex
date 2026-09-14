defmodule Kogen.Codex.State do
  @moduledoc false

  def project_id(project),
    do: :crypto.hash(:sha256, Path.expand(project)) |> Base.encode16(case: :lower)

  def scope_name(root, project) do
    path = selector(root, project)

    case File.lstat(path) do
      {:error, :enoent} ->
        :shared

      {:ok, %{type: :regular}} ->
        case File.read!(path) do
          "project\n" -> :project
          "shared\n" -> :shared
          _ -> raise "unrecognized Kogen account selector: #{path}"
        end

      _ ->
        raise "unsafe Kogen account selector: #{path}"
    end
  end

  def select_scope!(root, project, name) do
    path = selector(root, project)
    scope_name(root, project)
    private_directory!(Path.dirname(path))
    atomic_write!(path, "#{name}\n")
  end

  defp selector(root, project), do: Path.join([root, "preferences", project_id(project)])

  def ensure_scope!(path) do
    case File.lstat(path) do
      {:error, :enoent} ->
        private_directory!(path)
        File.write!(Path.join(path, ".kogen-owned"), "account-v1\n", [:exclusive])

      _ ->
        validate_scope!(path)
    end
  end

  def validate_scope!(path) do
    validate_scope_owner!(path)

    case File.lstat(Path.join(path, "auth.json")) do
      {:error, :enoent} -> :ok
      {:ok, %{type: :regular}} -> :ok
      _ -> raise "unexpected credential file type in Kogen scope: #{path}"
    end

    for name <- [
          "config.d",
          "AGENTS.md",
          "AGENTS.override.md",
          "rules",
          "hooks.json",
          "plugins"
        ] do
      case File.lstat(Path.join(path, name)) do
        {:error, :enoent} ->
          :ok

        _ ->
          raise "unexpected discovery settings in Kogen credential store: #{Path.join(path, name)}"
      end
    end

    native_projects!(path)
    :ok
  end

  defp validate_scope_owner!(path) do
    unless File.lstat!(path).type == :directory and
             match?({:ok, %{type: :regular}}, File.lstat(Path.join(path, ".kogen-owned"))) and
             File.read(Path.join(path, ".kogen-owned")) == {:ok, "account-v1\n"} do
      raise "unrecognized Kogen credential store: #{path}"
    end
  end

  def native_projects!(path) do
    config = Path.join(path, "config.toml")

    case File.lstat(config) do
      {:error, :enoent} ->
        read_native_projects!(config)

      {:ok, %{type: :regular}} ->
        read_native_projects!(config)

      _ ->
        raise "unexpected discovery settings in Kogen credential store: #{config}"
    end
  end

  defp read_native_projects!(config) do
    python =
      System.find_executable("python3") ||
        raise "Kogen requires Python 3.11 or newer; use the project mise environment"

    script = Application.app_dir(:kogen, "priv/kogen/codex/native_settings.py")

    case System.cmd(python, [script, config], stderr_to_stdout: true) do
      {output, 0} ->
        Jason.decode!(output)

      {_output, 1} ->
        raise "unexpected discovery settings in Kogen credential store: #{config}"

      {_output, 2} ->
        raise "Kogen requires Python 3.11 or newer with tomllib; use the project mise environment"

      {_output, status} ->
        raise "Kogen native settings validator failed (exit #{status}): #{config}"
    end
  end

  def operation!(root) do
    path = Path.join([root, "operations", nonce()])
    private_directory!(path)
    path
  end

  def lease!(root, runtime, project) do
    path = Path.join([root, "active", nonce() <> ".json"])
    private_directory!(Path.dirname(path))

    value = %{
      pid: System.pid(),
      started: process_start(System.pid()),
      runtime: runtime,
      project: project
    }

    File.write!(path, Jason.encode!(value), [:exclusive])
    path
  end

  def active(root) do
    Path.wildcard(Path.join([root, "active", "*.json"]))
    |> Enum.flat_map(fn path ->
      with {:ok, bytes} <- File.read(path),
           {:ok, %{"pid" => pid, "started" => start} = record} <- Jason.decode(bytes),
           true <- is_binary(pid) and Regex.match?(~r/^\d+$/, pid),
           true <- start != "" and process_start(pid) == start do
        [record]
      else
        _ -> []
      end
    end)
  end

  defp process_start(pid) do
    case System.cmd("/bin/ps", ["-p", pid, "-o", "lstart="], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      _ -> ""
    end
  end

  def private_directory!(path) do
    path = Path.expand(path)

    case File.lstat(path) do
      {:ok, %{type: :directory}} ->
        :ok

      {:error, :enoent} ->
        private_directory!(Path.dirname(path))

        case File.mkdir(path) do
          :ok ->
            File.chmod!(path, 0o700)

          {:error, :eexist} ->
            private_directory!(path)

          {:error, reason} ->
            raise File.Error, reason: reason, action: "create private directory", path: path
        end

      _ ->
        raise "unexpected occupant at Kogen directory: #{path}"
    end
  end

  defp atomic_write!(path, bytes) do
    temporary = path <> "." <> nonce()

    try do
      File.write!(temporary, bytes, [:exclusive])
      File.chmod!(temporary, 0o600)
      File.rename!(temporary, path)
    after
      File.rm(temporary)
    end
  end

  defp nonce, do: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
end
