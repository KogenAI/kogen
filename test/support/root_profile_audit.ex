defmodule Kogen.RootProfileAudit do
  @moduledoc false

  # Native rollout metadata, rather than a root's text or an argv claim, is the
  # authority for the profile that actually ran.  The audit reads only the
  # session header and turn contexts for explicitly supplied root IDs.
  # A bare sessions root is native Codex rollout storage; `{:claude, root}`
  # selects Claude Code transcripts. Callers pass `sessions_root(project)` for
  # the project whose configuration and login scope launched the sessions; the
  # default uses the current directory.
  def audit!(evidence_dir, expected, sessions_root \\ sessions_root()) when is_map(expected) do
    case sessions_root do
      {:claude, root} -> claude_audit!(evidence_dir, expected, root)
      root -> codex_audit!(evidence_dir, expected, root)
    end
  end

  defp codex_audit!(evidence_dir, expected, sessions_root) do
    index = session_index!(sessions_root, &Map.has_key?(expected, &1.id))

    receipts =
      expected
      |> Enum.sort_by(fn {id, _} -> id end)
      |> Enum.map(fn {id, profile} -> audit_session!(index, id, profile, evidence_dir) end)

    File.mkdir_p!(evidence_dir)
    receipt = %{"sessions" => receipts}

    File.write!(
      Path.join(evidence_dir, "root-profile-receipt.json"),
      Jason.encode!(receipt) <> "\n"
    )

    receipt
  end

  # Interactive Shape does not expose its native root ID through the pty. Its
  # unique disposable fixture cwd identifies exactly the fresh and continued
  # sessions; their exact IDs are then retained in the receipt and snapshots.
  def audit_shape!(evidence_dir, fixture, profile, sessions_root \\ sessions_root()) do
    index =
      case sessions_root do
        {:claude, root} ->
          claude_index!(root, {:cwd, fixture})

        root ->
          session_index!(root, &(&1.meta["cwd"] == fixture and root_metadata?(&1.meta)))
      end

    matches = Map.values(index)

    require!(length(matches) == 2, "expected exactly fresh and continued Shape native sessions")

    expected =
      Map.new(matches, fn %{id: id} ->
        {id, Map.merge(profile, %{role: "shaping"})}
      end)

    audit!(evidence_dir, expected, sessions_root)
  end

  # The harness comes from `project`'s own configuration and the Kogen login
  # scope from `project`'s selector, never from whatever directory the caller
  # happens to be in (a live driver may be inside a disposable fixture).
  def sessions_root(project \\ File.cwd!()) do
    project = Path.expand(project)

    if claude?(project),
      do: {:claude, claude_sessions_root(project)},
      else: codex_sessions_root(project)
  end

  defp codex_sessions_root(project) do
    codex_home =
      System.get_env("CODEX_HOME") ||
        managed_scope_home(project) ||
        Path.join(System.user_home!(), ".codex")

    Path.join(codex_home, "sessions")
  end

  defp managed_scope_home(project) do
    with {:ok, %{path: path}} <- Kogen.Codex.effective_scope(project),
         true <- File.dir?(path) do
      path
    else
      _ -> nil
    end
  end

  # Claude Code keeps each session transcript at
  # `<CLAUDE_CONFIG_DIR>/projects/<encoded cwd>/<session id>.jsonl` inside the
  # selected Kogen scope. Assistant message metadata, not model text, is the
  # authority for the executed root model; efforts recorded in the transcript
  # must match the configured effort.
  defp claude?(project) do
    case Kogen.Intent.read_config(Path.join(project, ".kogen/config.yaml")) do
      {:ok, %{harness: harness}} -> harness == "claude"
      {:error, reason} -> fail!("cannot select the audited harness for #{project}: #{reason}")
    end
  end

  defp claude_sessions_root(project) do
    {:ok, %{path: path}} = Kogen.ClaudeCode.effective_scope(project)
    Path.join(path, "projects")
  end

  # The shared scope also holds unrelated sessions: select by transcript id
  # (its file name) or by the first recorded cwd before reading a whole file.
  defp claude_index!(root, selection) do
    require!(File.dir?(root), "Claude Code session directory is missing: #{root}")

    root
    |> Path.join("*/*.jsonl")
    |> Path.wildcard()
    |> Enum.filter(&claude_selected?(&1, selection))
    |> Enum.reduce(%{}, fn path, index ->
      id = Path.basename(path, ".jsonl")

      if root_lines(transcript_lines(File.read!(path))) != [] do
        require!(not Map.has_key?(index, id), "duplicate Claude Code session id: #{id}")
        Map.put(index, id, %{id: id, path: path, meta: %{"cwd" => cwd(path)}})
      else
        index
      end
    end)
  end

  defp claude_selected?(path, {:ids, ids}), do: Path.basename(path, ".jsonl") in ids
  defp claude_selected?(path, {:cwd, cwd}), do: cwd(path) == cwd

  defp claude_audit!(evidence_dir, expected, sessions_root) do
    index = claude_index!(sessions_root, {:ids, Map.keys(expected)})

    receipts =
      expected
      |> Enum.sort_by(fn {id, _} -> id end)
      |> Enum.map(fn {id, profile} ->
        %{path: path} = Map.get(index, id) || fail!("missing Claude Code transcript for #{id}")
        bytes = File.read!(path)
        lines = transcript_lines(bytes)
        roots = root_lines(lines)
        models = roots |> Enum.map(&get_in(&1, ["message", "model"])) |> Enum.uniq()
        efforts = roots |> Enum.flat_map(&efforts/1) |> Enum.uniq()

        require!(models != [], "Claude Code session #{id} has no root assistant messages")

        require!(
          models == [profile.model],
          "Claude Code session #{id} root responses came from #{inspect(models)}, expected #{profile.model}"
        )

        require!(
          Enum.all?(efforts, &(&1 == profile.effort)),
          "Claude Code session #{id} recorded effort #{inspect(efforts)}, expected #{profile.effort}"
        )

        File.mkdir_p!(evidence_dir)
        snapshot = Path.join(evidence_dir, "root-profile-#{profile.role}-#{id}.jsonl")
        File.write!(snapshot, bytes)

        %{
          "id" => id,
          "role" => profile.role,
          "model" => profile.model,
          "effort" => profile.effort,
          "observed_root_models" => models,
          "observed_efforts" => efforts,
          "root_message_count" => length(roots),
          "snapshot_sha256" => :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower),
          "snapshot" => Path.basename(snapshot)
        }
      end)

    File.mkdir_p!(evidence_dir)
    receipt = %{"harness" => "claude", "sessions" => receipts}

    File.write!(
      Path.join(evidence_dir, "root-profile-receipt.json"),
      Jason.encode!(receipt) <> "\n"
    )

    receipt
  end

  defp cwd(path) do
    path
    |> File.stream!()
    |> Stream.take(50)
    |> Enum.find_value(fn line ->
      case Jason.decode(line) do
        {:ok, %{"cwd" => cwd}} when is_binary(cwd) -> cwd
        _ -> nil
      end
    end)
  end

  defp transcript_lines(bytes) do
    bytes
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, value} when is_map(value) -> [value]
        _ -> []
      end
    end)
  end

  defp root_lines(lines) do
    Enum.filter(lines, fn line ->
      line["type"] == "assistant" and line["isSidechain"] != true and
        is_binary(get_in(line, ["message", "model"])) and
        get_in(line, ["message", "model"]) != "<synthetic>"
    end)
  end

  defp efforts(value) when is_map(value) do
    Enum.flat_map(value, fn
      {"effort", effort} when is_binary(effort) -> [effort]
      {"content", _content} -> []
      {_key, nested} -> efforts(nested)
    end)
  end

  defp efforts(_value), do: []

  defp session_index!(root, selected?) do
    require!(File.dir?(root), "native session directory is missing: #{root}")

    root
    |> Path.join("**/*.jsonl")
    |> Path.wildcard()
    |> Enum.reduce(%{}, fn path, index ->
      case selected_session(path, selected?) do
        {:ok, %{id: id} = session} ->
          require!(not Map.has_key?(index, id), "duplicate native session id: #{id}")
          Map.put(index, id, session)

        :skip ->
          index
      end
    end)
  end

  defp selected_session(path, selected?) do
    case session_meta(path) do
      {:ok, session} -> if selected?.(session), do: {:ok, session}, else: :skip
      :skip -> :skip
    end
  end

  defp session_meta(path) do
    case File.open(path, [:read], fn file -> IO.read(file, :line) end) do
      {:ok, line} when is_binary(line) ->
        with {:ok, %{"type" => "session_meta", "payload" => meta}} <- Jason.decode(line),
             id when is_binary(id) and id != "" <- meta["id"] do
          {:ok, %{id: id, path: path, meta: meta}}
        else
          _ -> :skip
        end

      _ ->
        :skip
    end
  end

  defp audit_session!(index, id, expected, evidence_dir) do
    %{path: path} = Map.get(index, id) || fail!("missing native session metadata for #{id}")
    bytes = File.read!(path)
    meta = session_meta_from_bytes!(bytes, id)
    require!(root_metadata?(meta), "native session #{id} is a child, not a root session")
    contexts = turn_contexts!(bytes, id)
    profile = %{model: Map.fetch!(expected, :model), effort: Map.fetch!(expected, :effort)}

    require!(
      Enum.all?(contexts, &matches_profile?(&1, profile)),
      "native session #{id} has a mismatched root model or effort"
    )

    File.mkdir_p!(evidence_dir)
    snapshot = Path.join(evidence_dir, "root-profile-#{expected.role}-#{id}.jsonl")
    File.write!(snapshot, bytes)

    %{
      "id" => id,
      "role" => expected.role,
      "model" => profile.model,
      "effort" => profile.effort,
      "turn_context_count" => length(contexts),
      "observed_turn_contexts" => Enum.map(contexts, &Map.take(&1, ["model", "effort"])),
      "snapshot_sha256" => :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower),
      "snapshot" => Path.basename(snapshot)
    }
  end

  defp session_meta_from_bytes!(bytes, id) do
    case String.split(bytes, "\n", parts: 2) do
      [line | _] ->
        case Jason.decode(line) do
          {:ok, %{"type" => "session_meta", "payload" => %{"id" => ^id} = meta}} -> meta
          _ -> fail!("native session #{id} has invalid session metadata")
        end

      _ ->
        fail!("native session #{id} has invalid session metadata")
    end
  end

  defp turn_contexts!(bytes, id) do
    contexts =
      bytes
      |> String.split("\n", trim: true)
      |> Enum.flat_map(fn line ->
        case Jason.decode(line) do
          {:ok, %{"type" => "turn_context", "payload" => context}} when is_map(context) ->
            [context]

          _ ->
            []
        end
      end)

    require!(contexts != [], "native session #{id} has no turn_context metadata")
    contexts
  end

  defp matches_profile?(context, profile),
    do: context["model"] == profile.model and context["effort"] == profile.effort

  defp root_metadata?(meta), do: meta["parent_thread_id"] in [nil, ""]

  defp require!(true, _message), do: :ok
  defp require!(false, message), do: fail!(message)
  defp fail!(message), do: raise(ArgumentError, message)
end
