defmodule Kogen.Build.WriteBoundary do
  @moduledoc """
  The Build-wide role write boundary (BLD-12): one macOS Seatbelt profile,
  applied by the kernel at launch (`/usr/bin/sandbox-exec -p <profile>`)
  around every role process tree of a Build. Descendants inherit it and
  cannot remove it.

  The profile is rendered once at admission from canonical, symlink-resolved
  paths: `(allow default)`, then `(deny file-write*)`, then writes allowed
  only under the Candidate, the Build's harness home, the spaceless per-Build
  temp dir and the stdio and pty devices, plus the named shared login state:
  the login keychain file and its `.sb-` temp files, the Claude scope's
  `.oauth_refresh.lock` when the route uses Claude Code, and the Codex scope
  minus the entries Kogen's scope validation refuses or owns when the route
  uses Codex. `/bin/ps` is the one executable run outside the profile;
  LaunchServices opens and Apple Events are denied.

  Every failure is closed: a missing `sandbox-exec`, a grant that does not
  resolve to an existing directory, a forbidden grant (`/`, `/private/tmp`,
  `/private/var`, `$HOME`, the control root, one of its ancestors or a path
  inside it) or a failed admission self-test stops the Build before any
  readiness call or launch. There is no unwrapped fallback.

  Confinement is decided by the kernel, never by the environment: applying
  `(version 1)(allow default)` to `/usr/bin/true` exits 71 only inside a
  sandbox. `KOGEN_WRITE_BOUNDARY` (the profile sha256 every wrapped launch
  carries) only distinguishes a Kogen boundary from a foreign sandbox once
  the kernel reports confinement.
  """

  @default_sandbox_exec "/usr/bin/sandbox-exec"
  @marker "KOGEN_WRITE_BOUNDARY"
  @confined_exit 71
  @probe_profile "(version 1)(allow default)"
  @codex_denied_literals ~w(hooks.json AGENTS.md AGENTS.override.md environments.toml .kogen-owned)
  @codex_denied_subpaths ~w(plugins rules config.d agents)
  @devices ~w(/dev/null /dev/zero /dev/tty /dev/ptmx /dev/dtracehelper)
  @device_patterns ["^/dev/fd/[0-9]+$", "^/dev/ttys[0-9]+$"]
  @ps "/bin/ps"

  @doc "The environment variable naming the boundary's profile sha256."
  def marker, do: @marker

  @doc "The `sandbox-exec` executable (application env `:sandbox_exec` for offline tests)."
  def sandbox_exec, do: Application.get_env(:kogen, :sandbox_exec, @default_sandbox_exec)

  @doc "Scope entries a role may never create or change inside a granted Codex scope."
  def codex_denied_entries, do: @codex_denied_literals ++ @codex_denied_subpaths

  @doc """
  Kernel confinement of the current process: `:unconfined`, `:confined`, or
  an error when `sandbox-exec` is missing or answers otherwise.
  """
  @spec confinement() :: {:ok, :unconfined | :confined} | {:error, String.t()}
  def confinement do
    executable = sandbox_exec()

    if File.regular?(executable) do
      case System.cmd(executable, ["-p", @probe_profile, "/usr/bin/true"], stderr_to_stdout: true) do
        {_out, 0} ->
          {:ok, :unconfined}

        {_out, @confined_exit} ->
          {:ok, :confined}

        {out, status} ->
          {:error,
           "write boundary confinement self-test failed (#{executable} exit #{status}): #{String.trim(out)}"}
      end
    else
      {:error, "write boundary unavailable: #{executable} is missing"}
    end
  rescue
    error -> {:error, "write boundary unavailable: #{Exception.message(error)}"}
  end

  @doc """
  Decides how a Build started in this process is bounded, before admission.

  Unconfined: `{:ok, :apply}` (an inherited marker is ignored). Confined with
  the marker and roles that are `KOGEN_HARNESS` test executables:
  `{:ok, {:inherited, sha256}}`. Confined with managed roles, or confined
  without the marker (a foreign sandbox): an error. A missing `sandbox-exec`
  is reported by `prepare/1` after admission, never here.
  """
  @spec admission_mode() :: {:ok, :apply | {:inherited, String.t()}} | {:error, String.t()}
  def admission_mode do
    if File.regular?(sandbox_exec()), do: decide(confinement()), else: {:ok, :apply}
  end

  defp decide({:ok, :unconfined}), do: {:ok, :apply}

  defp decide({:ok, :confined}) do
    case {System.get_env(@marker), System.get_env("KOGEN_HARNESS")} do
      {marker, fixture} when is_binary(marker) and marker != "" and is_binary(fixture) ->
        {:ok, {:inherited, marker}}

      {marker, _fixture} when is_binary(marker) and marker != "" ->
        {:error, "a Build cannot start inside another Build's role boundary"}

      _ ->
        {:error,
         "a Build cannot start inside a foreign sandbox: the kernel reports this process is confined and no Kogen write boundary is named"}
    end
  end

  defp decide({:error, _reason} = error), do: error

  @doc """
  Resolves and validates every grant, renders the Build-wide profile and runs
  the admission self-test (the profile applied to `/usr/bin/true`).

  `input` holds `:candidate`, `:harness_home`, `:tmp_dir` and `:control`, and
  optionally `:claude_scope`, `:codex_scope` and `:keychain`. Returns the
  boundary with mode `applied`.
  """
  @spec prepare(map()) :: {:ok, map()} | {:error, String.t()}
  def prepare(input) do
    executable = sandbox_exec()

    with :ok <- executable_present(executable),
         {:ok, grants} <- resolve(input),
         :ok <- no_forbidden(grants, input),
         profile = render(grants),
         :ok <- self_test(executable, profile) do
      {:ok,
       %{
         mode: "applied",
         profile: profile,
         sha256: sha256(profile),
         grants: grants,
         sandbox_exec: executable
       }}
    end
  end

  @doc "An inherited boundary: the enclosing profile's marker, applied by nobody here."
  @spec inherited(String.t(), map()) :: map()
  def inherited(sha256, input) do
    %{
      mode: "inherited",
      profile: nil,
      sha256: sha256,
      grants: %{
        candidate: input.candidate,
        harness_home: input.harness_home,
        tmp_dir: input.tmp_dir
      },
      sandbox_exec: sandbox_exec()
    }
  end

  defp executable_present(executable) do
    if File.regular?(executable),
      do: :ok,
      else:
        {:error,
         "write boundary unavailable: #{executable} is missing; no role is launched without it"}
  end

  defp resolve(input) do
    with {:ok, candidate} <- directory(input, :candidate, "Candidate"),
         {:ok, home} <- directory(input, :harness_home, "harness home"),
         {:ok, tmp} <- directory(input, :tmp_dir, "Build temp dir"),
         {:ok, claude} <- optional_directory(input, :claude_scope, "Claude scope"),
         {:ok, codex} <- optional_directory(input, :codex_scope, "Codex scope") do
      {:ok,
       %{
         candidate: candidate,
         harness_home: home,
         tmp_dir: tmp,
         claude_lock: claude && Path.join(claude, ".oauth_refresh.lock"),
         codex_scope: codex,
         keychain: keychain(Map.get(input, :keychain, default_keychain()))
       }}
    end
  end

  defp directory(input, key, label) do
    case Map.get(input, key) do
      path when is_binary(path) and path != "" ->
        canonical = canonical(path)

        if canonical && File.dir?(canonical),
          do: {:ok, canonical},
          else:
            {:error,
             "write boundary grant for the #{label} cannot be resolved to an existing directory: #{path}"}

      other ->
        {:error, "write boundary grant for the #{label} is missing: #{inspect(other)}"}
    end
  end

  defp optional_directory(input, key, label) do
    if Map.get(input, key), do: directory(input, key, label), else: {:ok, nil}
  end

  defp default_keychain,
    do: Path.join(System.user_home!(), "Library/Keychains/login.keychain-db")

  # The login keychain is a file; when it does not exist there is nothing a
  # role could need to write, so no grant is rendered.
  defp keychain(path) when is_binary(path) do
    case canonical(path) do
      nil -> nil
      real -> if File.regular?(real), do: real
    end
  end

  defp keychain(_path), do: nil

  @doc "The canonical, symlink-resolved path of an existing file or directory, or nil."
  @spec canonical(Path.t()) :: Path.t() | nil
  def canonical(path) do
    case System.cmd("/bin/realpath", [Path.expand(path)], stderr_to_stdout: true) do
      {out, 0} -> String.trim_trailing(out, "\n")
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp no_forbidden(grants, input) do
    home = canonical(System.user_home!()) || Path.expand(System.user_home!())
    control = canonical(Map.fetch!(input, :control)) || Path.expand(input.control)

    grants
    |> Map.take([:candidate, :harness_home, :tmp_dir, :codex_scope])
    |> Enum.reject(fn {_key, path} -> is_nil(path) end)
    |> Enum.find_value(:ok, fn {key, path} ->
      case forbidden(key, path, home, control) do
        nil -> nil
        why -> {:error, "write boundary refused the #{key} grant #{path}: #{why}"}
      end
    end)
  end

  # The Build's own trees must also lie outside the control checkout; a
  # login scope is shared state the profile names wherever it lives.
  defp forbidden(key, path, home, control) do
    cond do
      path in ["/", "/private/tmp", "/private/var", "/tmp", "/var"] -> "it is a system root"
      path == home -> "it is $HOME"
      ancestor?(path, home) -> "it is an ancestor of $HOME"
      path == control -> "it is the control root"
      ancestor?(path, control) -> "it is an ancestor of the control root"
      key != :codex_scope and ancestor?(control, path) -> "it is inside the control root"
      true -> nil
    end
  end

  defp ancestor?(ancestor, path),
    do: String.starts_with?(path, String.trim_trailing(ancestor, "/") <> "/")

  @doc """
  Renders the profile from canonical grants (`:candidate`, `:harness_home`,
  `:tmp_dir`, and optional `:claude_lock`, `:codex_scope`, `:keychain`).
  """
  @spec render(map()) :: String.t()
  def render(grants) do
    allowed =
      [
        subpath(grants.candidate),
        subpath(grants.harness_home),
        subpath(grants.tmp_dir)
      ] ++
        optional(grants[:claude_lock], &subpath/1) ++
        optional(grants[:codex_scope], &subpath/1) ++
        optional(grants[:keychain], &[literal(&1), sb_prefix(&1 <> ".sb-")]) ++
        Enum.map(@devices, &literal/1) ++ Enum.map(@device_patterns, &regex/1)

    codex_denials =
      case grants[:codex_scope] do
        nil ->
          ""

        scope ->
          denied =
            Enum.map(@codex_denied_literals, &literal(Path.join(scope, &1))) ++
              Enum.map(@codex_denied_subpaths, &subpath(Path.join(scope, &1)))

          "(deny file-write*\n  " <> Enum.join(denied, "\n  ") <> ")\n"
      end

    """
    (version 1)
    ;; Kogen Build role write boundary (BLD-12).
    (allow default)
    (deny file-write*)
    (allow file-write*
      #{Enum.join(List.flatten(allowed), "\n  ")})
    #{codex_denials}(allow process-exec (with no-sandbox) #{literal(@ps)})
    (deny lsopen)
    (deny appleevent-send)
    """
  end

  defp optional(nil, _fun), do: []
  defp optional(value, fun), do: List.wrap(fun.(value))

  defp subpath(path), do: "(subpath #{quote_string(path)})"
  defp literal(path), do: "(literal #{quote_string(path)})"
  defp sb_prefix(path), do: "(prefix #{quote_string(path)})"
  defp regex(pattern), do: "(regex #\"#{pattern}\")"

  @doc "An SBPL string literal."
  @spec quote_string(String.t()) :: String.t()
  def quote_string(value) do
    escaped = value |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")
    "\"" <> escaped <> "\""
  end

  defp self_test(executable, profile) do
    case System.cmd(executable, ["-p", profile, "/usr/bin/true"], stderr_to_stdout: true) do
      {_out, 0} ->
        :ok

      {out, status} ->
        {:error,
         "write boundary admission self-test failed (#{executable} exit #{status}): #{String.trim(out)}"}
    end
  rescue
    error -> {:error, "write boundary admission self-test failed: #{Exception.message(error)}"}
  end

  @doc """
  The argv prefix a launch runs under: `sandbox-exec -p <profile>` when the
  boundary is applied, nothing when it is inherited.
  """
  @spec prefix(map() | nil) :: [String.t()]
  def prefix(%{mode: "applied", sandbox_exec: executable, profile: profile}),
    do: [executable, "-p", profile]

  def prefix(%{mode: "inherited"}), do: []

  @doc """
  The environment every launch inside the boundary carries: the marker, the
  Build temp dir as `TMPDIR`, `TMPPREFIX` and `CLAUDE_CODE_TMPDIR`, and the
  harness home's `raw-log/` as `KOGEN_RAW_LOG_DIR`.
  """
  @spec environment(map()) :: [{String.t(), String.t()}]
  def environment(%{sha256: sha256, grants: grants}) do
    [
      {@marker, sha256},
      {"TMPDIR", grants.tmp_dir},
      {"TMPPREFIX", Path.join(grants.tmp_dir, "zsh")},
      {"CLAUDE_CODE_TMPDIR", grants.tmp_dir},
      {"KOGEN_RAW_LOG_DIR", Path.join(grants.harness_home, "raw-log")}
    ]
  end

  @doc "The tracking-record `boundary` block."
  @spec record_block(map()) :: map()
  def record_block(boundary) do
    grants =
      boundary.grants
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)

    %{
      "mode" => boundary.mode,
      "profile_sha256" => boundary.sha256,
      "grants" => grants,
      "denied_scope_entries" =>
        if(boundary.grants[:codex_scope], do: codex_denied_entries(), else: []),
      "sandbox_exec" => boundary.sandbox_exec
    }
  end

  defp sha256(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
