defmodule Kogen.Harness.HookInterpreter do
  @moduledoc """
  Resolves, in the controller's own trusted environment, the absolute Python
  interpreter that Kogen's Claude Code role hooks run under.

  A bare `python3` in a hook command resolves through the role's PATH, whose
  first entry can be a mise shim. Inside a project whose `mise.toml` mise has
  not trusted, that shim exits 1 ("Config files ... are not trusted"), which
  Claude Code treats as a non-blocking hook error, so the verification-policy
  guard would silently not run. The project's mise config is never trusted
  automatically; instead the interpreter is resolved once, from a neutral
  working directory, to its real `sys.executable`, and hook commands use that
  absolute path. The tracked Stop script (`check.sh`) itself calls `python3`,
  so a private directory holding only a `python3` link to the resolved
  interpreter is prepended to PATH for that one hook command.

  A missing or too-old interpreter is a launch error, never a silent
  fallback to the bare command.
  """

  @minimum {3, 11}
  @probe "import sys; print(sys.version_info[0], sys.version_info[1]); print(sys.executable)"

  @doc "The minimum interpreter version the hook scripts are run with."
  def minimum, do: @minimum

  @doc """
  Rewrites the `python3`/`sh` hook commands of a decoded Claude settings map so
  they use the absolute interpreter. Raises with a clear message when no
  suitable interpreter exists.
  """
  def settings!(settings) when is_map(settings) do
    case resolve() do
      {:ok, python} -> apply_interpreter(settings, python)
      {:error, reason} -> raise "Kogen cannot launch Claude Code role hooks: #{reason}"
    end
  end

  @doc "Pure rewrite of hook commands for a resolved absolute interpreter path."
  def apply_interpreter(%{"hooks" => hooks} = settings, python) when is_map(hooks) do
    bin = link_directory!(python)

    hooks =
      Map.new(hooks, fn {event, entries} ->
        {event, Enum.map(List.wrap(entries), &rewrite_entry(&1, python, bin))}
      end)

    %{settings | "hooks" => hooks}
  end

  def apply_interpreter(settings, _python), do: settings

  defp rewrite_entry(%{"hooks" => commands} = entry, python, bin),
    do: %{entry | "hooks" => Enum.map(commands, &rewrite_command(&1, python, bin))}

  defp rewrite_entry(entry, _python, _bin), do: entry

  # Claude Code treats any hook exit other than 2 as non-blocking, so a crashed
  # guard would silently let the tool call through. A guard that exits nonzero
  # is turned into exit 2 (block, with the reason on stderr); a guard that
  # exits 0 keeps its own allow or deny decision.
  defp rewrite_command(%{"command" => "python3 " <> rest} = hook, python, _bin) do
    guard = shell_quote(python) <> " " <> rest

    %{
      hook
      | "command" =>
          guard <>
            "; s=$?; [ \"$s\" -eq 0 ] || " <>
            "{ echo \"Kogen verification-policy hook failed (exit $s); blocking the tool call.\" >&2; exit 2; }"
    }
  end

  defp rewrite_command(%{"command" => "sh " <> _ = command} = hook, _python, bin),
    do: %{hook | "command" => "PATH=#{shell_quote(bin)}:\"$PATH\" " <> command}

  defp rewrite_command(hook, _python, _bin), do: hook

  @doc """
  The absolute interpreter meeting the minimum version, resolved from `python3`
  on the controller's PATH (mise shims are followed to the real interpreter
  from a neutral directory, never from the project).
  """
  def resolve(candidate \\ System.find_executable("python3")) do
    with {:ok, executable} <- present(candidate),
         {output, 0} <- probe(executable),
         [version, path] <- String.split(String.trim(output), "\n", parts: 2),
         [major, minor] <- String.split(version, " "),
         true <- Path.type(path) == :absolute and File.regular?(path) do
      if {String.to_integer(major), String.to_integer(minor)} >= @minimum do
        {:ok, path}
      else
        {:error, too_old(path, version)}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, "python3 (#{inspect(candidate)}) did not report a usable interpreter"}
    end
  end

  defp present(nil),
    do: {:error, "no python3 found on PATH; Kogen requires Python #{version(@minimum)} or newer"}

  defp present(executable), do: {:ok, executable}

  defp probe(executable) do
    System.cmd(executable, ["-c", @probe], cd: System.tmp_dir!(), stderr_to_stdout: true)
  rescue
    _ -> :error
  end

  defp too_old(path, version),
    do:
      "#{path} is Python #{String.replace(version, " ", ".")}; Kogen requires " <>
        "Python #{version(@minimum)} or newer"

  defp version({major, minor}), do: "#{major}.#{minor}"

  # A private, owner-only directory holding only `python3` for the hook.
  defp link_directory!(python) do
    hash = :crypto.hash(:sha256, python) |> Base.encode16(case: :lower) |> binary_part(0, 16)
    dir = Path.join(System.tmp_dir!(), "kogen-hook-python-#{hash}")
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    link = Path.join(dir, "python3")

    case File.read_link(link) do
      {:ok, ^python} ->
        :ok

      _ ->
        File.rm(link)
        File.ln_s!(python, link)
    end

    dir
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
end
