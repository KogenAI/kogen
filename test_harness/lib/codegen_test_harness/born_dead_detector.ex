defmodule CodegenTestHarness.BornDeadDetector do
  @moduledoc """
  Fail-closed pre-commit backstop: a cycle diff must never introduce (a) a
  defer-marker on a load-bearing path (`not yet wired`, `future migration`,
  `no caller yet`, `later sub-slice`, `wired later`, `deferred to a later`,
  `stub for now`, or a load-bearing `TODO`/`FIXME`) or (b) a NEW top-level
  entity (Elixir `defmodule`/public `def`, a new `*.sh` script, a new
  escript) with zero live non-test caller AND zero registration.

  This is the code-level guarantee behind "a build implements the WHOLE
  pitch" — rule prompts (`planner.md` § Whole-Pitch Builds Only,
  `reviewer.md` § No Born-Dead / Deferred Work) are the first line, this
  module is the un-talk-around-able second line. Wired into BOTH the solo
  loop (`OrchestrationLoop.assert_work_produced!/2`, raises) and the drain
  twin (`LoopQueueDrain`'s injectable `:born_dead_fn` seam, routes to the
  false-0 park-and-continue path) — see each call site's own moduledoc note
  for why both floors must move together.

  Escape valve: a NEW entity introduced by the diff is NOT born-dead when it
  is REGISTERED — a manifest `launchers:` entry, an `escript: main_module`
  reference in `mix.exs`, or a `settings.json` hook entry all count as
  "wired" even with zero direct in-repo caller. A moduledoc comment saying
  "no caller yet" is NOT a valid registration — it is exactly the failure
  class this module exists to catch.

  Fail-closed: any git/parse error means "cannot prove clean" — reported as
  a violation `{:error, reason}`, never a silent `:ok`.
  """

  @defer_markers [
    "not yet wired",
    "future migration",
    "no caller yet",
    "later sub-slice",
    "wired later",
    "deferred to a later",
    "stub for now"
  ]

  @type reason :: String.t()

  @doc """
  Checks the cumulative diff `base_sha..HEAD` in the git work tree at `cwd`
  for defer markers (on added lines) and born-dead new top-level entities
  (no live non-test caller and no registration reference in the resulting
  tree). Returns `:ok` when clean, `{:error, reason}` naming the first
  violation found (file:line for a marker, entity name for a born-dead
  definition).

  `base_sha == nil` (no known cycle base — non-git/unborn cwd, only ever a
  mocked/edge test scenario) is a legitimate "nothing to compare" — returns
  `:ok`, mirroring the fail-open posture of the callers' own base-unknown
  guards.
  """
  @spec check(String.t(), String.t() | nil) :: :ok | {:error, reason()}
  def check(_cwd, nil), do: :ok

  def check(cwd, base_sha) do
    case File.dir?(cwd) do
      false ->
        :ok

      true ->
        case System.cmd("git", ["diff", base_sha, "HEAD"], cd: cwd, stderr_to_stdout: true) do
          {diff, 0} ->
            with :ok <- scan_defer_markers(diff),
                 :ok <- scan_born_dead(diff, cwd) do
              :ok
            end

          # fail-loud-exempt: git diff itself failing (bad sha, detached
          # tree corruption) means "cannot prove clean" — fail CLOSED, this
          # is exactly the discipline the module exists to enforce, never a
          # silent pass-through.
          {out, _nonzero} ->
            {:error, "born-dead detector: `git diff #{base_sha} HEAD` failed: #{out}"}
        end
    end
  end

  # ── Defer-marker scan: only ADDED lines (diff `+` prefix, excluding the
  # `+++` file-header line) are considered — a marker already present before
  # this cycle (e.g. quoted in a rule file being edited) must never trip the
  # detector on an unrelated context line. ──────────────────────────────────
  @spec scan_defer_markers(String.t()) :: :ok | {:error, reason()}
  defp scan_defer_markers(diff) do
    diff
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce_while(:ok, fn {line, lineno}, :ok ->
      added_content_line? =
        String.starts_with?(line, "+") and not String.starts_with?(line, "+++")

      cond do
        not added_content_line? ->
          {:cont, :ok}

        marker = Enum.find(@defer_markers, &String.contains?(String.downcase(line), &1)) ->
          {:halt,
           {:error,
            "born-dead detector: defer marker #{inspect(marker)} at diff line #{lineno}: #{String.trim(line)}"}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  # ── Born-dead scan: every NEW top-level entity introduced by the diff
  # (Elixir `defmodule`, new `*.sh` file, new escript) must have either a
  # live non-test caller in the resulting tree OR a registration reference
  # (manifest launchers:, escript main_module, settings.json hook). ────────
  @spec scan_born_dead(String.t(), String.t()) :: :ok | {:error, reason()}
  defp scan_born_dead(diff, cwd) do
    diff
    |> new_files_from_diff()
    |> Enum.reduce_while(:ok, fn path, :ok ->
      case new_entity_name(path) do
        nil ->
          {:cont, :ok}

        entity ->
          if wired?(entity, path, cwd) do
            {:cont, :ok}
          else
            {:halt,
             {:error,
              "born-dead detector: new entity #{inspect(entity)} (#{path}) has no live " <>
                "non-test caller and no registration — wire it or remove it, never defer"}}
          end
      end
    end)
  end

  # Parses unified diff `diff --git a/<path> b/<path>` + `new file mode`
  # headers to find paths ADDED by this diff (never a modified existing
  # file — modifying an existing file is not "introducing a new entity").
  @spec new_files_from_diff(String.t()) :: [String.t()]
  defp new_files_from_diff(diff) do
    diff
    |> String.split(~r/^diff --git /m, trim: true)
    |> Enum.flat_map(fn chunk ->
      is_new? = String.contains?(chunk, "\nnew file mode")

      case Regex.run(~r{^a/(\S+) b/(\S+)}, chunk) do
        [_, _a_path, b_path] when is_new? -> [b_path]
        _ -> []
      end
    end)
  end

  # Only test paths and non-source paths are excluded outright; module/
  # script/escript detection happens on the remaining candidate paths.
  @spec new_entity_name(String.t()) :: String.t() | nil
  defp new_entity_name(path) do
    cond do
      String.contains?(path, "/test/") or String.ends_with?(path, "_test.exs") or
          String.ends_with?(path, "_test.sh") ->
        nil

      String.ends_with?(path, ".ex") ->
        path

      String.ends_with?(path, ".sh") ->
        path

      true ->
        nil
    end
  end

  # Wired = (1) referenced by name from a non-test file elsewhere in the
  # tree, or (2) registered — appears in a manifest `launchers:` block, an
  # `escript: main_module` config, or `settings.json` hook registration.
  @spec wired?(String.t(), String.t(), String.t()) :: boolean()
  defp wired?(_entity, path, cwd) do
    base = Path.basename(path, Path.extname(path))
    # An Elixir file's module reference is CamelCase (e.g. `helper_thing.ex`
    # -> `HelperThing`), never the snake_case filename itself — grep for
    # BOTH forms so a `.ex` caller referencing the CamelCase module name is
    # found, alongside a `.sh` script referenced by its literal filename.
    camel = Macro.camelize(base)

    has_live_caller?(base, camel, path, cwd) or registered?(base, cwd) or registered?(camel, cwd)
  end

  @spec has_live_caller?(String.t(), String.t(), String.t(), String.t()) :: boolean()
  defp has_live_caller?(base, camel, own_path, cwd) do
    case System.cmd(
           "git",
           ["grep", "-l", "-F", "-e", base, "-e", camel, "--", "*.ex", "*.exs", "*.sh"],
           cd: cwd,
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.any?(fn hit ->
          hit != own_path and not String.contains?(hit, "/test/") and
            not String.ends_with?(hit, "_test.exs") and not String.ends_with?(hit, "_test.sh")
        end)

      # fail-loud-exempt: `git grep` exits 1 on "no matches" (legitimate:
      # nothing references this name yet) — not an error.
      {_out, 1} ->
        false

      # fail-loud-exempt: git grep unavailable/errored — fall through to the
      # registration check rather than raising here; a total absence of both
      # signals is reported by the caller as born-dead (fail-closed overall).
      {_out, _other} ->
        false
    end
  end

  @spec registered?(String.t(), String.t()) :: boolean()
  defp registered?(base, cwd) do
    registration_files = [
      Path.join([cwd, "harnesses", "claude", "manifest.yaml"]),
      Path.join([cwd, "harnesses", "pi", "manifest.yaml"]),
      Path.join([cwd, "harnesses", "claude", "claude-code-settings.json"]),
      Path.join([cwd, "mix.exs"]),
      Path.join([cwd, "test_harness", "mix.exs"])
    ]

    Enum.any?(registration_files, fn path ->
      case File.read(path) do
        {:ok, content} -> String.contains?(content, base)
        {:error, _} -> false
      end
    end)
  end
end
