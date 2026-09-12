defmodule Kogen.RootProfileAudit do
  @moduledoc false

  # Native rollout metadata, rather than a root's text or an argv claim, is the
  # authority for the profile that actually ran.  The audit reads only the
  # session header and turn contexts for explicitly supplied root IDs.
  def audit!(evidence_dir, expected, sessions_root \\ sessions_root()) when is_map(expected) do
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
    matches =
      sessions_root
      |> session_index!(&(&1.meta["cwd"] == fixture and root_metadata?(&1.meta)))
      |> Map.values()

    require!(length(matches) == 2, "expected exactly fresh and continued Shape native sessions")

    expected =
      Map.new(matches, fn %{id: id} ->
        {id, Map.merge(profile, %{role: "shaping"})}
      end)

    audit!(evidence_dir, expected, sessions_root)
  end

  def sessions_root do
    Path.join(
      System.get_env("CODEX_HOME") || Path.join(System.user_home!(), ".codex"),
      "sessions"
    )
  end

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
