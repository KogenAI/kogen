defmodule Kogen.Tools do
  @moduledoc """
  The model tools: the builder's `shell`, `read_file`, `write_file` (LOOP-3..5, LOOP-8) and the
  read-only `read_file`, `list_files`, `search_text` of the shaper (SHP-3), the reviewer's
  protected file/command tools (REV-3), plus the shaper's `probe` (SHP-10). A refused path is a tool result, not a failure.
  """
  alias Kogen.{Bridge, Git}

  @max 16_384

  # ---- Definitions ----

  defp fun(name, description, props, required) do
    %{
      "type" => "function",
      "name" => name,
      "description" => description,
      "parameters" => %{
        "type" => "object",
        "properties" => props,
        "required" => required,
        "additionalProperties" => false
      },
      "strict" => false
    }
  end

  @str %{"type" => "string"}
  @int %{"type" => "integer"}

  def defs(names), do: Enum.map(names, &def_for/1)

  defp def_for("shell"),
    do:
      fun(
        "shell",
        "Run a command with /bin/sh -c in the repository root. stdin is closed. Returns the exit status and the combined stdout and stderr. Commands have no time limit. Run finite commands, including tests and browser suites, in the foreground until completion; do not poll them through repeated sleep/tail/ps calls. Only persistent commands (dev servers, watch modes) belong in the background with output to a log file; read their logs and stop them yourself.",
        %{"command" => @str},
        ["command"]
      )

  defp def_for("read_file"),
    do:
      fun(
        "read_file",
        "Read a file of the repository, with line numbers. Paths are relative to the repository root.",
        %{"path" => @str, "start_line" => @int, "end_line" => @int},
        ["path"]
      )

  defp def_for("write_file"),
    do:
      fun(
        "write_file",
        "Write the whole content of a file of the repository (created with its folders if needed).",
        %{"path" => @str, "content" => @str},
        ["path", "content"]
      )

  defp def_for("finish"),
    do:
      fun(
        "finish",
        "Say the implementation is complete. Kogen then runs the fixers and every check, and a reviewer reviews the code; failures come back to you.",
        %{"summary" => @str},
        ["summary"]
      )

  defp def_for("list_files"),
    do:
      fun(
        "list_files",
        "List the repository's files (tracked and untracked, not ignored), optionally under a folder.",
        %{"path" => @str},
        []
      )

  defp def_for("search_text"),
    do:
      fun(
        "search_text",
        "Search the repository's files for a regular expression (git grep syntax). Returns path:line:text matches.",
        %{"pattern" => @str, "path" => @str},
        ["pattern"]
      )

  defp def_for("probe"),
    do:
      fun(
        "probe",
        "Run a quick throwaway command with /bin/sh -c in a scratch copy of the working tree (with its installed dependencies and builds), never in the project, to prove a risky assumption. Optional scratch files are written first. Stopped after 5 minutes. Returns the exit status, whether it timed out, the wall time and the combined output.",
        %{
          "command" => @str,
          "files" => %{
            "type" => "array",
            "items" => %{
              "type" => "object",
              "properties" => %{"path" => @str, "content" => @str},
              "required" => ["path", "content"]
            }
          }
        },
        ["command"]
      )

  # ---- Paths ----

  # Paths resolve against the repository root. There is no containment: shell and probe could
  # reach anything anyway; only protected paths are refused for writing (LOOP-4, VER-8).
  defp resolve(root, path) do
    abs = Path.expand(path, root)
    {abs, Path.relative_to(abs, root)}
  end

  # ---- Running ----

  @doc """
  Runs one tool call when its name is one of `ctx.tools` (a model can ask for any name).
  `ctx` also has `:root` and `:protected` (the paths write_file refuses).
  """
  def run(name, args, ctx) do
    if name in ctx.tools, do: call(name, args, ctx), else: "error: unknown tool #{name}"
  end

  defp call("read_file", args, ctx) do
    with {:ok, path} <- arg(args, "path") do
      {abs, _rel} = resolve(ctx.root, path)

      case File.read(abs) do
        {:ok, text} -> number(text, args["start_line"], args["end_line"])
        {:error, :enoent} -> "error: #{path} does not exist"
        {:error, :eisdir} -> "error: #{path} is a folder; use list_files"
        {:error, reason} -> "error: #{path}: #{reason}"
      end
    else
      {:error, msg} -> msg
    end
  end

  defp call("write_file", args, ctx) do
    with {:ok, path} <- arg(args, "path"),
         {:ok, content} <- arg(args, "content") do
      {abs, rel} = resolve(ctx.root, path)

      if rel in ctx.protected do
        "refused: #{rel} is part of the approved acceptance baseline"
      else
        with :ok <- File.mkdir_p(Path.dirname(abs)), :ok <- File.write(abs, content) do
          "ok"
        else
          {:error, reason} -> "error: #{path}: #{reason}"
        end
      end
    else
      {:error, msg} -> msg
    end
  end

  defp call("list_files", args, ctx) do
    {_abs, rel} = resolve(ctx.root, optional_path(args))
    pathspec = if rel in ["", "."], do: [], else: [rel]

    case Git.run(
           ctx.root,
           ["ls-files", "--cached", "--others", "--exclude-standard", "--deduplicate", "--"] ++
             pathspec
         ) do
      {"", 0} -> "(no files)"
      {out, 0} -> String.trim_trailing(out)
      {out, _} -> "error: " <> String.trim(out)
    end
  end

  defp call("search_text", args, ctx) do
    with {:ok, pattern} <- arg(args, "pattern") do
      {_abs, rel} = resolve(ctx.root, optional_path(args))
      pathspec = if rel in ["", "."], do: [], else: [rel]

      case Git.run(
             ctx.root,
             ["grep", "-n", "-I", "-E", "--untracked", "-e", pattern, "--"] ++ pathspec
           ) do
        {out, 0} -> String.trim_trailing(out)
        {_, 1} -> "(no matches)"
        {out, _} -> "error: " <> String.trim(out)
      end
    else
      {:error, msg} -> msg
    end
  end

  defp call("shell", args, ctx) do
    case arg(args, "command") do
      {:ok, command} ->
        r = Bridge.exec(command, ctx.root)
        "exit status: #{r.status}\n" <> r.output

      {:error, msg} ->
        msg
    end
  end

  defp call("probe", args, ctx) do
    case arg(args, "command") do
      {:ok, command} -> probe(command, args["files"] || [], ctx)
      {:error, msg} -> msg
    end
  end

  defp optional_path(%{"path" => p}) when is_binary(p), do: p
  defp optional_path(_), do: "."

  defp arg(args, key) do
    case args do
      %{^key => v} when is_binary(v) -> {:ok, v}
      _ -> {:error, "error: argument #{key} must be a string"}
    end
  end

  defp number(text, from, to) do
    lines = String.split(text, "\n")
    lines = if List.last(lines) == "", do: Enum.drop(lines, -1), else: lines
    from = if is_integer(from) and from > 0, do: from, else: 1
    to = if is_integer(to) and to >= from, do: to, else: length(lines)

    lines
    |> Enum.with_index(1)
    |> Enum.filter(fn {_, i} -> i >= from and i <= to end)
    |> Enum.map_join("\n", fn {l, i} -> "#{i}\t#{l}" end)
  end

  # SHP-10: a scratch copy of the tracked files under the system temporary folder, 5 minutes.
  defp probe(command, files, ctx) do
    scratch =
      Path.join(
        System.tmp_dir!(),
        "kogen-probe-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      )

    File.mkdir_p!(scratch)

    try do
      copy_tree(ctx.root, scratch)

      case Enum.flat_map(files, &write_scratch(&1, scratch)) do
        [] ->
          t0 = System.monotonic_time(:millisecond)
          r = Bridge.exec(command, scratch, timeout_ms: 300_000)
          wall = Float.round((System.monotonic_time(:millisecond) - t0) / 1000, 1)
          "exit status: #{r.status}\ntimed_out: #{r.timed_out}\nwall: #{wall} s\n" <> r.output

        problems ->
          "error: " <> Enum.join(problems, "; ")
      end
    after
      File.rm_rf!(scratch)
    end
  end

  # A scratch file stays in the scratch copy: no `..` out of it and no copied symlink on the way.
  defp write_scratch(%{"path" => p, "content" => c}, scratch)
       when is_binary(p) and is_binary(c) do
    dest = Path.expand(p, scratch)
    rel = Path.relative_to(dest, scratch)

    through_link =
      rel
      |> Path.split()
      |> Enum.scan(scratch, &Path.join(&2, &1))
      |> Enum.any?(&match?({:ok, %{type: :symlink}}, File.lstat(&1)))

    cond do
      rel == dest or String.starts_with?(rel, "..") -> ["#{p} is outside the scratch copy"]
      through_link -> ["#{p} would be written through a symlink"]
      true -> write_new(dest, c, p)
    end
  end

  defp write_scratch(_, _), do: ["every file needs a path and a content string"]

  defp write_new(dest, content, p) do
    with :ok <- File.mkdir_p(Path.dirname(dest)), :ok <- File.write(dest, content) do
      []
    else
      {:error, reason} -> ["#{p}: #{reason}"]
    end
  end

  # The working tree with its ignored files (dependencies, builds), without .git/ and
  # .kogen/local/: a copy-on-write clone where the file system has one (SHP-10, SET-12).
  def copy_tree(root, scratch) do
    entries =
      for e <- File.ls!(root) -- [".git", ".kogen"],
          do: {Path.join(root, e), Path.join(scratch, e)}

    kogen = Path.join(root, ".kogen")

    entries =
      if File.dir?(kogen) do
        File.mkdir_p!(Path.join(scratch, ".kogen"))

        entries ++
          for e <- File.ls!(kogen) -- ["local"],
              do: {Path.join(kogen, e), Path.join([scratch, ".kogen", e])}
      else
        entries
      end

    flags = if :os.type() == {:unix, :darwin}, do: ["-cRp"], else: ["-a", "--reflink=auto"]

    for {src, dst} <- entries do
      {out, status} = System.cmd("cp", flags ++ [src, dst], stderr_to_stdout: true)
      if status != 0, do: raise("copying #{src} for a probe failed: #{out}")
    end
  end

  @doc "A tool result as given to the model: at most 16 KiB, the first 4 KiB and the last part (LOOP-8)."
  def cut(text) when byte_size(text) <= @max, do: text

  def cut(text) do
    marker = fn n -> "\n[... #{n} bytes omitted ...]\n" end
    head = valid_prefix(binary_part(text, 0, 4096))
    tail_size = 12_288 - byte_size(marker.(byte_size(text)))
    tail = valid_suffix(binary_part(text, byte_size(text) - tail_size, tail_size))
    head <> marker.(byte_size(text) - byte_size(head) - byte_size(tail)) <> tail
  end

  defp valid_prefix(b),
    do: if(String.valid?(b), do: b, else: valid_prefix(binary_part(b, 0, byte_size(b) - 1)))

  defp valid_suffix(b),
    do: if(String.valid?(b), do: b, else: valid_suffix(binary_part(b, 1, byte_size(b) - 1)))
end
