defmodule CodegenTestHarness.TestCoverageFloor do
  @moduledoc """
  Fail-closed pre-commit backstop for silently deleted tests.

  `check/2` compares every modified, renamed, or deleted test file in the
  cycle diff with its own blob at `base_sha`. A lower assertion-block count is
  refused unless the associated subject disappeared in the same diff or an
  added, reasoned `test-deletion-exempt: <path> — <reason>` marker names that
  file. It is deliberately a stable block-count floor, not coverage tooling.

  The check is wired into both the solo loop and queue-drain ship floors. Git
  command, diff-decoding, or blob-read failures are violations: a floor that
  cannot read its evidence must not silently pass.
  """

  @type reason :: String.t()
  @type change :: %{old_path: String.t(), new_path: String.t() | nil, status: String.t()}

  @spec check(String.t(), String.t() | nil) :: :ok | {:error, reason()}
  def check(_cwd, nil), do: :ok

  def check(cwd, base_sha) do
    with true <- File.dir?(cwd),
         {:ok, changes} <- changed_test_files(cwd, base_sha),
         {:ok, exempt_paths} <- exemption_paths(cwd, base_sha) do
      Enum.reduce_while(changes, :ok, fn change, :ok ->
        case check_change(cwd, base_sha, change, exempt_paths) do
          :ok -> {:cont, :ok}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    else
      false -> {:error, "test-coverage-floor: #{inspect(cwd)} is not a readable work tree"}
      {:error, _reason} = error -> error
    end
  end

  defp check_change(cwd, base_sha, %{old_path: old_path, new_path: new_path}, exempt_paths) do
    path_for_dialect = new_path || old_path

    case dialect_for(path_for_dialect) || dialect_for(old_path) do
      nil ->
        :ok

      dialect ->
        with {:ok, before} <- read_blob(cwd, base_sha, old_path),
             {:ok, after_blob} <- read_after_blob(cwd, new_path),
             before_count <- assertion_block_count(old_path, before),
             after_count <- assertion_block_count(path_for_dialect, after_blob) do
          cond do
            after_count >= before_count ->
              :ok

            MapSet.member?(exempt_paths, path_for_dialect) ->
              :ok

            subject_died?(cwd, base_sha, path_for_dialect, dialect.subject) ->
              :ok

            true ->
              {:error,
               "test-coverage-floor: #{path_for_dialect} lost test coverage — #{before_count} -> " <>
                 "#{after_count} assertion-bearing blocks (was #{old_path} at #{base_sha}). " <>
                 "This deletes coverage without removing the subject module. Escape: (1) delete " <>
                 "the subject module in the SAME diff, or (2) add a line " <>
                 "`test-deletion-exempt: #{path_for_dialect} — <reason>` naming why."}
          end
        end
    end
  end

  defp changed_test_files(cwd, base_sha) do
    case System.cmd("git", ["diff", "--name-status", "-z", "-M", base_sha, "HEAD"],
           cd: cwd,
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        decode_name_status(out)

      {out, _} ->
        {:error,
         "test-coverage-floor: `git diff --name-status -z -M #{base_sha} HEAD` failed: #{out}"}
    end
  end

  # `--name-status -z` keeps paths with spaces and rename pairs unambiguous.
  # New test files cannot decrease a floor, so only M/D/R records participate.
  defp decode_name_status(out) do
    out
    |> String.split("\0", trim: true)
    |> decode_name_status([])
  end

  defp decode_name_status([], acc), do: {:ok, Enum.reverse(acc)}

  defp decode_name_status([status, path | rest], acc) when status in ["M", "D"] do
    new_path = if status == "D", do: nil, else: path
    decode_name_status(rest, [%{status: status, old_path: path, new_path: new_path} | acc])
  end

  defp decode_name_status([<<"R", _::binary>> = status, old_path, new_path | rest], acc) do
    decode_name_status(rest, [%{status: status, old_path: old_path, new_path: new_path} | acc])
  end

  defp decode_name_status(["A", _path | rest], acc), do: decode_name_status(rest, acc)

  defp decode_name_status([status, _path | _rest], _acc),
    do: {:error, "test-coverage-floor: unsupported git diff status #{inspect(status)}"}

  defp decode_name_status(tokens, _acc),
    do: {:error, "test-coverage-floor: malformed git name-status output: #{inspect(tokens)}"}

  defp exemption_paths(cwd, base_sha) do
    case System.cmd("git", ["diff", "--unified=0", base_sha, "HEAD"],
           cd: cwd,
           stderr_to_stdout: true
         ) do
      {diff, 0} ->
        paths =
          diff
          |> String.split("\n")
          |> Enum.reduce(MapSet.new(), fn line, acc ->
            if String.starts_with?(line, "+") and not String.starts_with?(line, "+++") do
              case String.split(line, "test-deletion-exempt:", parts: 2) do
                [_, declaration] ->
                  case Regex.run(~r/^(\S+)\s+(?:-|–|—)\s+(\S.*)$/, String.trim(declaration)) do
                    [_, path, _reason] -> MapSet.put(acc, path)
                    _ -> acc
                  end

                _ ->
                  acc
              end
            else
              acc
            end
          end)

        {:ok, paths}

      {out, _} ->
        {:error,
         "test-coverage-floor: `git diff #{base_sha} HEAD` failed while reading exemptions: #{out}"}
    end
  end

  defp read_after_blob(_cwd, nil), do: {:ok, ""}
  defp read_after_blob(cwd, path), do: read_blob(cwd, "HEAD", path)

  defp read_blob(cwd, ref, path) do
    case System.cmd("git", ["show", "#{ref}:#{path}"], cd: cwd, stderr_to_stdout: true) do
      {content, 0} -> {:ok, content}
      {out, _} -> {:error, "test-coverage-floor: cannot read #{ref}:#{path}: #{out}"}
    end
  end

  defp marker_count(content, marker) do
    content |> String.split("\n") |> Enum.count(&Regex.match?(marker, &1))
  end

  @doc false
  @spec assertion_block_count(String.t(), String.t()) :: non_neg_integer() | nil
  def assertion_block_count(path, content) do
    case dialect_for(path) do
      nil -> nil
      dialect -> marker_count(content, dialect.marker)
    end
  end

  defp dialect_for(path) do
    Enum.find(dialects(), & &1.test?.(path))
  end

  defp dialects do
    [
      %{
        test?: &String.ends_with?(&1, "_test.exs"),
        marker: ~r/^\s*(describe|test)\s+"/,
        subject: &elixir_subjects/1
      },
      %{
        test?: &String.ends_with?(&1, "_test.sh"),
        marker: ~r/\b(pass|passed|ok|PASS_COUNT)=|\bassert[a-z_]*\b|\brun_test\b|\bPASS\b/,
        subject: &shell_subjects/1
      },
      %{
        test?:
          &(String.starts_with?(Path.basename(&1), "test_") and String.ends_with?(&1, ".py")),
        marker: ~r/^\s*def\s+test_/,
        subject: &python_subjects/1
      },
      %{
        test?: &String.ends_with?(&1, ".test.ts"),
        marker: ~r/\b(test|it)\(/,
        subject: &typescript_subjects/1
      }
    ]
  end

  defp elixir_subjects(path) do
    base = String.replace_suffix(path, "_test.exs", "")

    source_base =
      cond do
        String.starts_with?(base, "test_harness/test/") ->
          String.replace_prefix(base, "test_harness/test/", "test_harness/lib/")

        String.starts_with?(base, "test/") ->
          String.replace_prefix(base, "test/", "lib/")

        true ->
          base
      end

    [base, source_base]
    |> Enum.uniq()
    |> Enum.flat_map(&[&1 <> ".ex", &1 <> ".exs"])
  end

  defp shell_subjects(path), do: [String.replace_suffix(path, "_test.sh", ".sh")]

  defp python_subjects(path) do
    dir = Path.dirname(path)
    base = path |> Path.basename() |> String.replace_prefix("test_", "")
    [Path.join(dir, base), Path.join(Path.dirname(dir), base)]
  end

  defp typescript_subjects(path), do: [String.replace_suffix(path, ".test.ts", ".ts")]

  defp subject_died?(cwd, base_sha, test_path, subject_fn) do
    Enum.any?(subject_fn.(test_path), fn subject_path ->
      blob_exists?(cwd, base_sha, subject_path) and not blob_exists?(cwd, "HEAD", subject_path)
    end)
  end

  defp blob_exists?(cwd, ref, path) do
    match?(
      {_out, 0},
      System.cmd("git", ["cat-file", "-e", "#{ref}:#{path}"], cd: cwd, stderr_to_stdout: true)
    )
  end
end
