defmodule Kogen.Build.Tracking do
  @moduledoc """
  Build-owned, append-oriented persistence for one scenario-tracking run.

  A tracking state is deliberately process-local: it contains the exact bytes
  last written by this controller. `verify/1` compares those bytes before an
  external boundary, and `update/2` refuses to replace a record that changed
  underneath the controller. Records are evidence only; continuation may read
  an earlier record after binding it to the report digest, but never rewrites it.

  The record lives under the control checkout's
  `.kogen/runtime/scenario-tracking/<build-id>/`, whose root the Build passes
  explicitly (`root`); the state's `path` is absolute, while every locator
  the record stores (record-version `path` and `sidecar`) is relative to
  that control root, so retained evidence resolves after the Candidate
  worktree is gone.
  """

  @runtime_base ".kogen/runtime/scenario-tracking"
  @record_name "record.json"
  @schema_version 2

  @type tracking_record :: %{required(String.t()) => term()}
  @type state :: %{
          required(:path) => Path.t(),
          required(:bytes) => binary(),
          required(:record) => tracking_record(),
          optional(:root) => Path.t()
        }

  @doc """
  Creates one exclusively-owned runtime record for this Build.

  `contract` is the already validated Approved contract and must contain its
  scenarios and risks under either string or atom keys. `approved_entries` is
  the Build's frozen package-entry snapshot; only its SHA-256 digest is stored.
  `route` is the Build's resolved route (`Kogen.Intent.read_config/2`); its
  name, harness and every role and helper profile are frozen in the record,
  and its complete role matrix under `role_assignment`.
  """
  @spec new(map(), map(), list(), map(), Path.t()) :: {:ok, state()} | {:error, String.t()}
  def new(intent, contract, approved_entries, route, root \\ File.cwd!()),
    do: new(intent, contract, approved_entries, route, root, nil)

  @doc "Creates a tracking record, optionally linking it to a prior report for a continuation."
  @spec new(map(), map(), list(), map(), Path.t(), map() | nil) ::
          {:ok, state()} | {:error, String.t()}
  def new(intent, contract, approved_entries, route, root, continues)
      when is_map(intent) and is_map(contract) and is_map(route) and
             (is_nil(continues) or is_map(continues)) do
    root = Path.expand(root)

    with {:ok, frozen_intent} <- freeze_intent(intent),
         {:ok, frozen_route} <- freeze_route(route),
         {:ok, role_assignment} <- freeze_role_assignment(route),
         {:ok, scenarios} <- required_json_value(contract, "scenarios"),
         {:ok, risks, risks_supplied} <- frozen_risks(contract),
         true <- is_list(scenarios),
         {:ok, path} <- create_record_path(root),
         record <-
           initial_record(
             frozen_intent,
             frozen_route,
             role_assignment,
             scenarios,
             risks,
             risks_supplied,
             approved_entries,
             continues
           ),
         {:ok, state} <- write_initial(path, record) do
      {:ok, Map.put(state, :root, root)}
    else
      false -> {:error, "scenario tracking contract has invalid scenarios"}
      {:error, _reason} = error -> error
    end
  end

  def new(_intent, _contract, _approved_entries, _route, _root, _continues),
    do: {:error, "scenario tracking requires intent, contract and route maps"}

  @doc """
  Confirms that the record on disk remains byte-for-byte the controller's last
  persisted state. It never writes or attempts recovery.
  """
  @spec verify(state()) :: :ok | {:error, String.t()}
  def verify(%{path: path, bytes: expected}) when is_binary(path) and is_binary(expected) do
    case File.read(path) do
      {:ok, ^expected} ->
        :ok

      {:ok, _other} ->
        {:error, "scenario tracking record changed outside Build: #{path}"}

      {:error, reason} ->
        {:error, "could not read scenario tracking record #{path}: #{inspect(reason)}"}
    end
  end

  def verify(_state), do: {:error, "invalid scenario tracking state"}

  @doc """
  Verifies a cited file using its actual owner. Ordinary evidence stays frozen
  to the inspected digest. A citation of this Build's authoritative record is
  retained as a historical version, while the live file must match the latest
  controller-owned bytes. Only this exact path receives that ownership rule;
  external edits still fail `verify/1`, even when a role cited the record.
  """
  @spec verify_reference(state(), Path.t(), map()) :: :ok | {:error, String.t()}
  def verify_reference(state, path, snapshot) do
    if Path.expand(path) == Path.expand(state.path) do
      with :ok <- verify(state), do: verify_record_version(state, snapshot)
    else
      verify_frozen_reference(path, snapshot)
    end
  end

  @doc """
  Retains `bytes`, one cited version of this Build's own record, as an
  immutable sidecar next to the record and returns the metadata snapshot that
  replaces an inline copy. The record therefore never contains an earlier
  version of itself. The sidecar is created exclusively: identical bytes reuse
  it, and different bytes under the same digest name are an integrity failure.
  """
  @spec retain_record_version(state(), binary()) :: {:ok, map()} | {:error, String.t()}
  def retain_record_version(%{path: path} = state, bytes) when is_binary(bytes) do
    sha256 = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
    sidecar = record_version_path(path, sha256)

    with :ok <- mkdir_owned(Path.dirname(sidecar)),
         :ok <- write_record_version(sidecar, bytes) do
      {:ok,
       %{
         "path" => checkout_relative(state, path),
         "sha256" => sha256,
         "byte_count" => byte_size(bytes),
         "binding" => "controller_record_version",
         "sidecar" => checkout_relative(state, sidecar)
       }}
    end
  end

  @doc """
  Verifies every record-version sidecar that any attempt of the record
  references: it exists at its digest name and its exact bytes match the
  snapshot's SHA-256 and byte count. Older inline snapshots carry no sidecar
  and stay valid as written.
  """
  @spec verify_record_versions(state()) :: :ok | {:error, String.t()}
  def verify_record_versions(%{record: record} = state) do
    with {:ok, snapshots} <- reference_snapshot_values(record) do
      verify_record_version_snapshots(state, snapshots)
    end
  end

  defp verify_record_version_snapshots(state, snapshots) do
    snapshots
    |> Enum.filter(&record_version_snapshot?/1)
    |> Enum.uniq()
    |> Enum.reduce_while(:ok, &verify_record_version_step(state, &1, &2))
  end

  defp record_version_snapshot?(%{"binding" => "controller_record_version", "sidecar" => _}),
    do: true

  defp record_version_snapshot?(_snapshot), do: false

  defp verify_record_version_step(state, snapshot, :ok) do
    case verify_record_version(state, snapshot) do
      :ok -> {:cont, :ok}
      error -> {:halt, error}
    end
  end

  defp verify_record_version(state, %{"sidecar" => sidecar} = snapshot) do
    expected = checkout_relative(state, record_version_path(state.path, snapshot["sha256"]))

    with true <- is_binary(sidecar) and sidecar == expected,
         {:ok, bytes} <- File.read(Path.expand(sidecar, root(state))),
         true <- byte_size(bytes) == snapshot["byte_count"],
         true <- Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == snapshot["sha256"] do
      :ok
    else
      {:error, _reason} -> {:error, "record version sidecar missing: #{inspect(sidecar)}"}
      false -> {:error, "record version sidecar mutated: #{inspect(sidecar)}"}
    end
  end

  # Records written before sidecars inline the cited record version.
  defp verify_record_version(_state, _legacy_snapshot), do: :ok

  @doc """
  Retains bytes owned by the tracking record as a small immutable sidecar.

  Only verification state and fixed-file reference snapshots are accepted.
  `name` is preserved in the returned metadata (`file` for verification state,
  `path` for a cited fixed file); it never affects the sidecar path.
  """
  @spec retain_artifact(state(), String.t(), String.t(), binary()) ::
          {:ok, map()} | {:error, String.t()}
  def retain_artifact(state, kind, name, bytes)
      when kind in ["verification_state", "fixed_file"] and is_binary(name) and name != "" and
             is_binary(bytes) do
    sha256 = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
    sidecar = artifact_path(state.path, sha256)

    with :ok <- verify(state),
         :ok <- mkdir_owned(Path.dirname(sidecar)),
         :ok <- write_artifact(sidecar, bytes) do
      locator = checkout_relative(state, sidecar)

      metadata = %{
        if(kind == "verification_state", do: "file", else: "path") => name,
        "sha256" => sha256,
        "byte_count" => byte_size(bytes),
        "binding" => kind,
        "sidecar" => locator
      }

      {:ok, metadata}
    end
  end

  def retain_artifact(_state, _kind, _name, _bytes),
    do: {:error, "invalid tracking artifact"}

  @doc "Validates retained verification-state and fixed-file evidence and legacy inline forms."
  @spec verify_artifacts(state()) :: :ok | {:error, String.t()}
  def verify_artifacts(%{record: record} = state) do
    with {:ok, references} <- reference_snapshot_values(record) do
      verification =
        record
        |> Map.get("attempts", [])
        |> Enum.flat_map(&List.wrap(Map.get(&1, "verification_state")))

      verify_artifact_snapshots(state, verification ++ references)
    end
  end

  def verify_artifacts(_state), do: {:error, "invalid scenario tracking state"}

  defp verify_artifact_snapshots(state, snapshots) do
    snapshots
    |> Enum.filter(&artifact_snapshot?/1)
    |> Enum.uniq()
    |> Enum.reduce_while(:ok, &verify_artifact_step(state, &1, &2))
  end

  defp verify_artifact_step(state, snapshot, :ok) do
    case verify_artifact(state, snapshot) do
      :ok -> {:cont, :ok}
      error -> {:halt, error}
    end
  end

  defp reference_snapshot_values(%{"attempts" => attempts}) when is_list(attempts) do
    Enum.reduce_while(attempts, {:ok, []}, &reference_snapshots_for_attempt/2)
  end

  defp reference_snapshot_values(_record),
    do: {:error, "invalid scenario tracking attempts"}

  defp reference_snapshots_for_attempt(attempt, {:ok, acc}) when is_map(attempt) do
    with {:ok, current} <- references_for_attempt(attempt),
         {:ok, archived} <-
           archived_reference_snapshots(Map.get(attempt, "reference_snapshot_history", [])) do
      {:cont, {:ok, current ++ archived ++ acc}}
    else
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp reference_snapshots_for_attempt(_attempt, _acc),
    do: {:halt, {:error, "invalid scenario tracking attempt"}}

  defp references_for_attempt(attempt) do
    Enum.reduce_while(
      ~w(developer_reference_snapshots reviewer_reference_snapshots reference_snapshots),
      {:ok, []},
      &reference_snapshot_field(attempt, &1, &2)
    )
  end

  defp reference_snapshot_field(attempt, key, {:ok, acc}) do
    case Map.fetch(attempt, key) do
      :error -> {:cont, {:ok, acc}}
      {:ok, nil} -> {:cont, {:ok, acc}}
      {:ok, snapshots} when is_map(snapshots) -> add_reference_snapshots(snapshots, acc)
      _ -> {:halt, {:error, "invalid reference snapshot map"}}
    end
  end

  defp add_reference_snapshots(snapshots, acc) do
    if valid_snapshot_map?(snapshots),
      do: {:cont, {:ok, Map.values(snapshots) ++ acc}},
      else: {:halt, {:error, "invalid reference snapshot map"}}
  end

  defp valid_snapshot_map?(snapshots) do
    Enum.all?(snapshots, fn {path, _snapshot} -> is_binary(path) and path != "" end)
  end

  defp valid_archived_snapshot_map?(snapshots) do
    map_size(snapshots) > 0 and
      Enum.all?(snapshots, fn {path, snapshot} ->
        is_binary(path) and path != "" and valid_archived_snapshot?(snapshot)
      end)
  end

  defp valid_archived_snapshot?(%{"sha256" => digest, "sidecar" => sidecar} = snapshot)
       when is_binary(sidecar) and sidecar != "" do
    valid_digest?(digest) and is_integer(snapshot["byte_count"]) and snapshot["byte_count"] >= 0 and
      snapshot["binding"] in ["controller_record_version", "verification_state", "fixed_file"]
  end

  defp valid_archived_snapshot?(%{"sha256" => digest, "content_base64" => content} = snapshot)
       when is_binary(content) do
    valid_digest?(digest) and
      (is_nil(snapshot["byte_count"]) or
         (is_integer(snapshot["byte_count"]) and snapshot["byte_count"] >= 0))
  end

  defp valid_archived_snapshot?(_snapshot), do: false

  defp archived_reference_snapshots(history) do
    if is_list(history), do: reduce_archived_reference_snapshots(history), else: invalid_history()
  end

  defp reduce_archived_reference_snapshots(history) do
    Enum.reduce_while(history, {:ok, []}, fn
      %{"candidate_id" => candidate_id, "snapshots" => snapshots}, {:ok, acc}
      when is_binary(candidate_id) and candidate_id != "" and is_map(snapshots) ->
        if valid_archived_snapshot_map?(snapshots) do
          {:cont, {:ok, Map.values(snapshots) ++ acc}}
        else
          {:halt, {:error, "invalid historical reference snapshots"}}
        end

      _entry, _acc ->
        {:halt, {:error, "invalid historical reference snapshot entry"}}
    end)
  end

  defp invalid_history, do: {:error, "invalid historical reference snapshot list"}

  defp artifact_snapshot?(%{"binding" => binding})
       when binding in ["verification_state", "fixed_file"],
       do: true

  defp artifact_snapshot?(%{"content_base64" => _content, "sha256" => _sha}), do: true
  defp artifact_snapshot?(_snapshot), do: false

  defp verify_artifact(state, %{"binding" => kind, "sidecar" => sidecar} = snapshot)
       when kind in ["verification_state", "fixed_file"] and is_binary(sidecar) do
    digest = snapshot["sha256"]
    expected = checkout_relative(state, artifact_path(state.path, digest))

    with true <- valid_digest?(digest) and sidecar == expected,
         {:ok, bytes} <- File.read(Path.expand(sidecar, root(state))),
         true <- byte_size(bytes) == snapshot["byte_count"],
         true <- sha256(bytes) == digest,
         true <- snapshot["binding"] == kind do
      :ok
    else
      {:error, _reason} -> {:error, "retained artifact sidecar missing: #{inspect(sidecar)}"}
      false -> {:error, "retained artifact sidecar mutated: #{inspect(sidecar)}"}
    end
  end

  defp verify_artifact(_state, %{"binding" => kind} = snapshot)
       when kind in ["verification_state", "fixed_file"],
       do: verify_inline_artifact(snapshot)

  # Pre-sidecar evidence records stored bytes inline. Keep those records
  # inspectable and bind them to their original digest.
  defp verify_artifact(_state, snapshot), do: verify_inline_artifact(snapshot)

  defp verify_inline_artifact(%{"content_base64" => encoded, "sha256" => digest} = snapshot)
       when is_binary(encoded) and is_binary(digest) do
    with {:ok, bytes} <- Base.decode64(encoded),
         true <- sha256(bytes) == String.downcase(digest),
         true <- is_nil(snapshot["byte_count"]) or snapshot["byte_count"] == byte_size(bytes) do
      :ok
    else
      _ -> {:error, "retained artifact inline content mismatch"}
    end
  end

  defp verify_inline_artifact(_snapshot),
    do: {:error, "retained artifact has an invalid locator or inline content"}

  defp artifact_path(record_path, digest),
    do: Path.join([Path.dirname(record_path), "artifacts", to_string(digest) <> ".bin"])

  defp valid_digest?(digest), do: is_binary(digest) and digest =~ ~r/\A[0-9a-f]{64}\z/

  defp sha256(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp write_artifact(path, bytes) do
    case File.open(path, [:write, :exclusive, :binary]) do
      {:ok, io} ->
        try do
          case IO.binwrite(io, bytes) do
            :ok -> :file.sync(io)
            error -> error
          end
        after
          File.close(io)
        end

      {:error, :eexist} ->
        case File.read(path) do
          {:ok, ^bytes} -> :ok
          _ -> {:error, "retained artifact integrity failure: different bytes under #{path}"}
        end

      {:error, reason} ->
        {:error, "could not create retained artifact sidecar: #{inspect(reason)}"}
    end
  end

  defp record_version_path(record_path, sha256) when is_binary(sha256),
    do: Path.join([Path.dirname(record_path), "record-versions", sha256 <> ".json"])

  defp record_version_path(record_path, _sha256),
    do: Path.join([Path.dirname(record_path), "record-versions", "invalid"])

  defp write_record_version(sidecar, bytes) do
    case File.open(sidecar, [:write, :exclusive, :binary]) do
      {:ok, io} ->
        try do
          with :ok <- IO.binwrite(io, bytes), :ok <- :file.sync(io) do
            :ok
          else
            {:error, reason} ->
              {:error, "could not write record version sidecar: #{inspect(reason)}"}
          end
        after
          File.close(io)
        end

      {:error, :eexist} ->
        case File.read(sidecar) do
          {:ok, ^bytes} ->
            :ok

          _ ->
            {:error, "record version sidecar integrity failure: different bytes under #{sidecar}"}
        end

      {:error, reason} ->
        {:error, "could not create record version sidecar: #{inspect(reason)}"}
    end
  end

  defp mkdir_owned(directory) do
    case File.mkdir(directory) do
      :ok ->
        File.chmod(directory, 0o700)

      {:error, :eexist} ->
        if File.dir?(directory),
          do: :ok,
          else: {:error, "controller evidence directory is not a directory: #{directory}"}

      {:error, reason} ->
        {:error, "could not create controller evidence directory: #{inspect(reason)}"}
    end
  end

  # Locators are relative to the control root the Build passed; a state built
  # without one (a legacy caller) keeps its checkout-relative form.
  defp checkout_relative(state, path) do
    expanded = Path.expand(path)
    root = root(state)

    case Path.relative_to(expanded, root) do
      ^expanded ->
        # Not lexically under the root: the two may name the same directory
        # through a symlink (macOS /var vs /private/var).
        Path.relative_to(real_path(expanded), real_path(root))

      relative ->
        relative
    end
  end

  defp real_path(path) do
    [first | rest] = Path.split(path)
    Enum.reduce(rest, first, fn segment, acc -> resolve_link(Path.join(acc, segment), 0) end)
  end

  defp resolve_link(path, depth) when depth < 16 do
    case File.read_link(path) do
      {:ok, target} -> path |> Path.dirname() |> Path.join(target) |> Path.expand() |> real_path()
      _ -> path
    end
  end

  defp resolve_link(path, _depth), do: path

  @doc "The control root a tracking state's locators are relative to."
  def root(state), do: Map.get(state, :root) || File.cwd!()

  @doc "The record path relative to its control root, as summaries and citations name it."
  def relative_path(state), do: checkout_relative(state, state.path)

  defp verify_frozen_reference(path, snapshot) do
    case File.read(path) do
      {:ok, bytes} ->
        if Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) ==
             String.downcase(snapshot["sha256"] || ""),
           do: :ok,
           else: {:error, "bound evidence reference mutated: #{path}"}

      _ ->
        {:error, "bound evidence reference missing: #{path}"}
    end
  end

  @doc """
  Atomically replaces the record after verifying its previous exact bytes.

  The immutable Approved snapshot fields cannot change through this generic
  update. Callers supply a complete string-keyed record so the controller's
  state remains explicit rather than hidden in this module.
  """
  @spec update(state(), tracking_record()) :: {:ok, state()} | {:error, String.t()}
  def update(%{path: path, record: previous} = state, record)
      when is_binary(path) and is_map(previous) and is_map(record) do
    with :ok <- validate_update(state, record),
         {:ok, bytes} <- encode(record),
         :ok <- atomic_replace(path, bytes) do
      {:ok, %{state | bytes: bytes, record: record}}
    end
  end

  def update(_state, _record), do: {:error, "invalid scenario tracking update"}

  defp validate_update(%{record: previous} = state, record) do
    with :ok <- verify(state),
         :ok <- string_keyed_map(record),
         :ok <- record_has_only_string_keys(record),
         :ok <- preserve_frozen_fields(previous, record),
         :ok <- preserve_finding_history(previous, record),
         :ok <- preserve_reference_snapshot_history(previous, record),
         {:ok, _snapshots} <- reference_snapshot_values(record) do
      :ok
    end
  end

  @doc "Adds a pending Build-owned attempt to the record."
  @spec start_attempt(state(), String.t(), non_neg_integer()) ::
          {:ok, state()} | {:error, String.t()}
  def start_attempt(state, token, number)
      when is_binary(token) and token != "" and is_integer(number) and number >= 0 do
    attempt = %{"attempt_token" => token, "number" => number, "status" => "pending"}
    record = Map.update!(state.record, "attempts", &(&1 ++ [attempt]))
    update(state, record)
  end

  def start_attempt(_state, _token, _number), do: {:error, "invalid scenario tracking attempt"}

  @doc "Returns blocking findings whose latest disposition is still open."
  @spec open_findings(state()) :: [tracking_record()]
  def open_findings(%{record: %{"findings" => findings}}) when is_list(findings) do
    Enum.filter(findings, &(Map.get(&1, "status") == "open"))
  end

  def open_findings(_state), do: []

  @doc """
  Applies a previously validated complete Reviewer verdict in one record update.

  The validator owns verdict correctness and bound-input checks. This helper
  only persists the transition: it attaches the verdict to the latest attempt,
  appends reviewer dispositions, assigns new immutable `F1`, `F2`, … IDs, and
  sets the Build status to `accepted` or `rework`.
  """
  @spec apply_verdict(state(), map(), String.t()) :: {:ok, state()} | {:error, String.t()}
  def apply_verdict(state, verdict, reviewer_session),
    do: apply_verdict(state, verdict, reviewer_session, nil)

  @doc """
  Like `apply_verdict/3`, retaining Build-owned reference snapshots with the
  latest attempt in the same atomic record update.
  """
  @spec apply_verdict(state(), map(), String.t(), map() | nil) ::
          {:ok, state()} | {:error, String.t()}
  def apply_verdict(state, verdict, reviewer_session, reference_snapshots)
      when is_map(verdict) and is_binary(reviewer_session) and reviewer_session != "" do
    with {:ok, record} <-
           proposed_verdict_record(state, verdict, reviewer_session, reference_snapshots) do
      update(state, record)
    end
  end

  def apply_verdict(_state, _verdict, _reviewer_session, _reference_snapshots),
    do: {:error, "invalid scenario tracking verdict"}

  defp proposed_verdict_record(state, verdict, reviewer_session, reference_snapshots) do
    with {:ok, decision} <- verdict_decision(verdict),
         :ok <- valid_reference_snapshots(reference_snapshots) do
      verdict_record(state.record, verdict, reviewer_session, decision, reference_snapshots)
    end
  end

  defp initial_record(
         intent,
         route,
         role_assignment,
         scenarios,
         risks,
         risks_supplied,
         approved_entries,
         continues
       ) do
    %{
      "schema_version" => @schema_version,
      "purpose" => "inspection evidence; not a recovery checkpoint",
      "intent" => intent,
      "route" => route,
      "role_assignment" => role_assignment,
      "approved_package_digest" => approved_digest(approved_entries),
      "scenarios" => scenarios,
      "risks" => risks,
      "risks_supplied" => risks_supplied,
      "attempts" => [],
      "findings" => [],
      "status" => "pending"
    }
    |> maybe_put_continues(continues)
  end

  defp maybe_put_continues(record, continues) when is_map(continues),
    do: Map.put(record, "continues", continues)

  defp maybe_put_continues(record, _continues), do: record

  # The whole resolved route is frozen, not only its name: a later config edit
  # must not change what this record says the Build used. `route` keeps its
  # established shape; the complete role matrix is the additive
  # `role_assignment` (see `freeze_role_assignment/1`).
  defp freeze_route(route) do
    roles = ~w(shaping developer reviewer)

    with {:ok, name} <- route_string(route, ["route"]),
         {:ok, harness} <- route_string(route, ["harness"]),
         {:ok, role_profiles} <- route_profiles(route, roles, []),
         {:ok, helper_profiles} <- route_profiles(route, helper_names(route), ["helpers"]) do
      {:ok,
       %{"name" => name, "harness" => harness}
       |> Map.merge(role_profiles)
       |> Map.put("helpers", helper_profiles)}
    end
  end

  # A role-level route has no native expert helper on the dominant harness
  # when the Expert is assigned elsewhere; a clean route always has one.
  defp helper_names(route) do
    helpers = fetch(route, "helpers")

    if is_map(helpers) and is_nil(fetch(helpers, "expert")) and is_map(fetch(route, "roles")),
      do: ~w(scout worker),
      else: ~w(scout worker expert)
  end

  @assigned_roles ~w(shaping developer reviewer expert)

  # The complete role-to-harness/model/effort matrix and every harness's
  # native helper profiles, frozen once at Build start. A route without an
  # explicit matrix assigns every role its one harness and its expert helper
  # as the Expert.
  defp freeze_role_assignment(route) do
    with {:ok, harness} <- route_string(route, ["harness"]),
         {:ok, roles} <- assigned_roles(route, harness),
         {:ok, helpers} <- assigned_helpers(route, harness, roles["expert"]) do
      {:ok, Map.put(roles, "helpers", helpers)}
    end
  end

  defp assigned_roles(route, harness) do
    assigned = fetch(route, "roles")

    Enum.reduce_while(@assigned_roles, {:ok, %{}}, fn role, {:ok, acc} ->
      role_harness = if is_map(assigned), do: fetch(assigned, role), else: harness

      with true <- is_binary(role_harness) and role_harness != "",
           {:ok, profile} <- route_profile(route, assigned_path(route, role)) do
        {:cont, {:ok, Map.put(acc, role, Map.put(profile, "harness", role_harness))}}
      else
        false -> {:halt, {:error, "scenario tracking route lacks roles.#{role}"}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp assigned_path(route, "expert"),
    do: if(is_map(fetch(route, "expert")), do: ["expert"], else: ["helpers", "expert"])

  defp assigned_path(_route, role), do: [role]

  # Each harness's native scout and worker, plus the native expert on the
  # harness the Expert role is assigned to, exactly as launches see them.
  defp assigned_helpers(route, harness, expert) do
    sources =
      case fetch(route, "native_helpers") do
        native when is_map(native) and map_size(native) > 0 ->
          Enum.map(native, fn {name, _set} ->
            {to_string(name), ["native_helpers", to_string(name)]}
          end)

        _absent ->
          [{harness, ["helpers"]}]
      end

    Enum.reduce_while(sources, {:ok, %{}}, fn {name, prefix}, {:ok, acc} ->
      case route_profiles(route, ~w(scout worker), prefix) do
        {:ok, profiles} -> {:cont, {:ok, Map.put(acc, name, with_expert(profiles, name, expert))}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp with_expert(profiles, harness, %{"harness" => harness} = expert),
    do: Map.put(profiles, "expert", Map.take(expert, ["model", "effort"]))

  defp with_expert(profiles, _harness, _expert), do: profiles

  defp route_profile(route, path) do
    with {:ok, model} <- route_string(route, path ++ ["model"]),
         {:ok, effort} <- route_string(route, path ++ ["effort"]),
         do: {:ok, %{"model" => model, "effort" => effort}}
  end

  defp route_profiles(route, names, prefix) do
    Enum.reduce_while(names, {:ok, %{}}, fn name, {:ok, acc} ->
      with {:ok, model} <- route_string(route, prefix ++ [name, "model"]),
           {:ok, effort} <- route_string(route, prefix ++ [name, "effort"]) do
        {:cont, {:ok, Map.put(acc, name, %{"model" => model, "effort" => effort})}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp route_string(route, keys) do
    case Enum.reduce(keys, route, &(is_map(&2) && fetch(&2, &1))) do
      value when is_binary(value) and value != "" ->
        {:ok, value}

      _ ->
        {:error, "scenario tracking route lacks #{Enum.join(keys, ".")}"}
    end
  end

  defp freeze_intent(intent) do
    raw = fetch(intent, "raw") || intent

    case json_value(raw) do
      {:ok, frozen} when is_map(frozen) ->
        with :ok <- string_keyed_map(frozen), do: {:ok, frozen}

      {:ok, _other} ->
        {:error, "scenario tracking intent is not a string-keyed map"}

      {:error, _reason} = error ->
        error
    end
  end

  defp required_json_value(map, key) do
    case fetch(map, key) do
      nil -> {:error, "scenario tracking contract missing #{key}"}
      value -> json_value(value)
    end
  end

  defp frozen_risks(contract) do
    case fetch(contract, "risks") do
      nil ->
        {:ok, [], false}

      risks ->
        with {:ok, normalized} <- json_value(risks),
             true <- is_list(normalized) do
          {:ok, normalized, fetch(contract, "risks_supplied") != false}
        else
          false -> {:error, "scenario tracking contract has invalid risks"}
          {:error, _reason} = error -> error
        end
    end
  end

  defp fetch(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, String.to_atom(key))
    end
  end

  defp json_value(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: {:ok, value}

  defp json_value(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
      case json_value(item) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end
  end

  defp json_value(map) when is_map(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      with true <- is_binary(key) or is_atom(key),
           {:ok, normalized} <- json_value(value) do
        {:cont, {:ok, Map.put(acc, to_string(key), normalized)}}
      else
        false -> {:halt, {:error, "scenario tracking record must contain JSON values"}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp json_value(_value), do: {:error, "scenario tracking record must contain JSON values"}

  defp string_keyed_map(map) do
    if Enum.all?(Map.keys(map), &is_binary/1),
      do: :ok,
      else: {:error, "scenario tracking record must use string keys"}
  end

  defp record_has_only_string_keys(record) do
    case json_value(record) do
      {:ok, ^record} -> :ok
      _ -> {:error, "scenario tracking record must use string keys at every level"}
    end
  end

  defp preserve_frozen_fields(previous, record) do
    fields =
      ~w(schema_version intent route role_assignment approved_package_digest scenarios risks risks_supplied)

    if Enum.all?(fields, &(Map.get(previous, &1) == Map.get(record, &1))),
      do: :ok,
      else: {:error, "scenario tracking update changed frozen Approved inputs"}
  end

  defp preserve_finding_history(%{"findings" => previous}, %{"findings" => current})
       when is_list(previous) and is_list(current) do
    if Enum.all?(previous, &preserved_finding?(&1, current)) do
      :ok
    else
      {:error, "scenario tracking update changed immutable finding history"}
    end
  end

  defp preserve_finding_history(_previous, _record),
    do: {:error, "scenario tracking record has invalid findings"}

  defp preserve_reference_snapshot_history(previous, record) do
    previous_attempts = Map.get(previous, "attempts", [])
    current_attempts = Map.get(record, "attempts", [])

    preserved? =
      is_list(previous_attempts) and is_list(current_attempts) and
        length(current_attempts) >= length(previous_attempts) and
        previous_attempts
        |> Enum.with_index()
        |> Enum.all?(fn {attempt, index} ->
          current = Enum.at(current_attempts, index)

          is_map(attempt) and is_map(current) and
            attempt_history_preserved?(attempt, current) == :ok
        end)

    if preserved?,
      do: :ok,
      else: {:error, "scenario tracking update changed historical reference snapshots"}
  end

  defp attempt_history_preserved?(previous, current) do
    prior_history = Map.get(previous, "reference_snapshot_history", [])
    current_history = Map.get(current, "reference_snapshot_history", [])
    prior_reviewer = Map.get(previous, "reviewer_reference_snapshots", %{})
    current_reviewer = Map.get(current, "reviewer_reference_snapshots", %{})

    with true <- is_list(prior_history) and is_list(current_history),
         true <- List.starts_with?(current_history, prior_history),
         true <- is_map(prior_reviewer) and is_map(current_reviewer),
         true <- reviewer_history_preserved?(previous, current, prior_reviewer, current_reviewer) do
      :ok
    else
      _ -> {:error, "scenario tracking update changed historical reference snapshots"}
    end
  end

  defp reviewer_history_preserved?(_previous, _current, prior, current) when prior == current,
    do: true

  defp reviewer_history_preserved?(_previous, _current_record, prior, _current_reviewer)
       when map_size(prior) == 0,
       do: true

  defp reviewer_history_preserved?(previous, current, prior, _current) do
    candidate_id = Map.get(previous, "candidate_id")

    Enum.any?(Map.get(current, "reference_snapshot_history", []), fn entry ->
      entry["candidate_id"] == candidate_id and entry["snapshots"] == prior
    end)
  end

  defp preserved_finding?(%{"id" => id, "origin" => origin} = finding, current)
       when is_binary(id) and is_map(origin) do
    case Enum.find(current, &(Map.get(&1, "id") == id)) do
      %{"origin" => ^origin} = replacement ->
        history = Map.get(finding, "disposition_history", [])
        updated_history = Map.get(replacement, "disposition_history", [])

        is_list(history) and is_list(updated_history) and
          List.starts_with?(updated_history, history)

      _ ->
        false
    end
  end

  defp preserved_finding?(_finding, _current), do: false

  defp create_record_path(root) do
    base = Path.join(root, @runtime_base)

    case File.mkdir_p(base) do
      :ok ->
        create_record_directory(base, 0)

      {:error, reason} ->
        {:error, "could not create scenario tracking runtime root: #{inspect(reason)}"}
    end
  end

  defp create_record_directory(base, attempt) when attempt < 10 do
    id = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    directory = Path.join(base, id)

    case File.mkdir(directory) do
      :ok ->
        File.chmod!(directory, 0o700)
        {:ok, Path.join(directory, @record_name)}

      {:error, :eexist} ->
        create_record_directory(base, attempt + 1)

      {:error, reason} ->
        {:error, "could not create exclusive scenario tracking directory: #{inspect(reason)}"}
    end
  end

  defp create_record_directory(_base, _attempt),
    do: {:error, "could not create a unique scenario tracking directory"}

  defp write_initial(path, record) do
    with {:ok, bytes} <- encode(record),
         :ok <- write_exclusive(path, bytes) do
      {:ok, %{path: path, bytes: bytes, record: record}}
    end
  end

  defp encode(record) do
    {:ok, Jason.encode!(record) <> "\n"}
  rescue
    _error -> {:error, "could not encode scenario tracking record"}
  end

  defp write_exclusive(path, bytes) do
    case File.open(path, [:write, :exclusive, :binary]) do
      {:ok, io} ->
        try do
          with :ok <- IO.binwrite(io, bytes), :ok <- :file.sync(io) do
            :ok
          else
            {:error, reason} ->
              {:error, "could not write scenario tracking record: #{inspect(reason)}"}
          end
        after
          File.close(io)
        end

      {:error, reason} ->
        {:error, "could not create scenario tracking record: #{inspect(reason)}"}
    end
  end

  defp atomic_replace(path, bytes) do
    temporary =
      path <> ".tmp-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

    try do
      with :ok <- write_exclusive(temporary, bytes),
           :ok <- File.rename(temporary, path) do
        :ok
      else
        {:error, reason} when is_binary(reason) ->
          {:error, reason}

        {:error, reason} ->
          {:error, "could not replace scenario tracking record: #{inspect(reason)}"}
      end
    after
      File.rm(temporary)
    end
  end

  @doc "Computes the digest of the frozen Approved package entries."
  def approved_digest(entries) do
    entries
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp verdict_decision(verdict) do
    case fetch(verdict, "verdict") do
      "accept" -> {:ok, "accepted"}
      "rework" -> {:ok, "rework"}
      _ -> {:error, "scenario tracking verdict has invalid decision"}
    end
  end

  defp verdict_record(
         %{"attempts" => attempts, "findings" => findings} = record,
         verdict,
         session,
         decision,
         reference_snapshots
       )
       when is_list(attempts) and attempts != [] and is_list(findings) do
    latest = List.last(attempts)
    prior = Enum.drop(attempts, -1)
    dispositions = fetch(verdict, "dispositions") || []
    new_findings = fetch(verdict, "new_findings") || fetch(verdict, "findings") || []

    with true <- is_list(dispositions) and is_list(new_findings),
         {:ok, updated_findings} <- apply_dispositions(findings, dispositions, session, decision),
         {:ok, appended_findings} <-
           append_findings(updated_findings, new_findings, latest, session),
         {:ok, latest} <- archive_replaced_reviewer_snapshots(latest, reference_snapshots) do
      updated_attempt =
        latest
        |> Map.put("verdict", normalize_verdict(verdict))
        |> Map.put("reviewer_session", session)
        |> Map.put("status", decision)
        |> merge_reference_snapshots(reference_snapshots)

      {:ok,
       record
       |> Map.put("attempts", prior ++ [updated_attempt])
       |> Map.put("findings", appended_findings)
       |> Map.put("status", decision)}
    else
      false -> {:error, "scenario tracking verdict has invalid findings or dispositions"}
      {:error, _reason} = error -> error
    end
  end

  defp verdict_record(_record, _verdict, _session, _decision, _reference_snapshots),
    do: {:error, "scenario tracking record has no current attempt"}

  defp valid_reference_snapshots(nil), do: :ok

  defp valid_reference_snapshots(snapshots) when is_map(snapshots) do
    with :ok <- string_keyed_map(snapshots),
         {:ok, ^snapshots} <- json_value(snapshots) do
      :ok
    else
      _ -> {:error, "scenario tracking reference snapshots must be a string-keyed JSON map"}
    end
  end

  defp valid_reference_snapshots(_),
    do: {:error, "scenario tracking reference snapshots must be a string-keyed JSON map"}

  defp archive_replaced_reviewer_snapshots(attempt, nil), do: {:ok, attempt}

  defp archive_replaced_reviewer_snapshots(attempt, _snapshots) do
    previous = Map.get(attempt, "reviewer_reference_snapshots", %{})

    case previous do
      snapshots when is_map(snapshots) and map_size(snapshots) == 0 ->
        {:ok, attempt}

      snapshots when is_map(snapshots) ->
        append_reviewer_snapshot_history(attempt, snapshots)

      _ ->
        {:error, "scenario tracking has invalid prior Reviewer reference snapshots"}
    end
  end

  defp append_reviewer_snapshot_history(attempt, snapshots) do
    candidate_id = Map.get(attempt, "candidate_id")

    if is_binary(candidate_id) and candidate_id != "" and valid_archived_snapshot_map?(snapshots) do
      append_reference_snapshot_history(attempt, candidate_id, snapshots)
    else
      {:error,
       "scenario tracking cannot archive prior Reviewer references without a Candidate id"}
    end
  end

  defp append_reference_snapshot_history(attempt, candidate_id, snapshots) do
    history = Map.get(attempt, "reference_snapshot_history", [])

    case archived_reference_snapshots(history) do
      {:ok, _snapshots} ->
        entry = %{"candidate_id" => candidate_id, "snapshots" => snapshots}
        {:ok, Map.put(attempt, "reference_snapshot_history", history ++ [entry])}

      {:error, _reason} = error ->
        error
    end
  end

  defp merge_reference_snapshots(attempt, nil), do: attempt

  defp merge_reference_snapshots(attempt, snapshots) do
    attempt
    |> Map.put("reviewer_reference_snapshots", snapshots)
    |> Map.update("reference_snapshots", snapshots, &Map.merge(&1, snapshots))
  end

  defp apply_dispositions(findings, dispositions, session, decision) do
    dispositions
    |> Enum.reduce_while({:ok, findings}, fn disposition, {:ok, current} ->
      with {:ok, normalized} <- json_value(disposition),
           true <- is_map(normalized),
           id when is_binary(id) <- Map.get(normalized, "finding_id") || Map.get(normalized, "id"),
           {:ok, status} <- disposition_status(Map.get(normalized, "status")) do
        history = %{
          "reviewer_session" => session,
          "verdict" => decision,
          "status" => status,
          "reason" => Map.get(normalized, "reason", ""),
          "evidence" => Map.get(normalized, "evidence", [])
        }

        put_disposition(current, id, status, history)
      else
        false -> {:halt, {:error, "scenario tracking verdict has invalid disposition"}}
        _ -> {:halt, {:error, "scenario tracking verdict has invalid disposition"}}
      end
    end)
  end

  defp put_disposition(findings, id, status, history) do
    case Enum.find_index(findings, &(Map.get(&1, "id") == id)) do
      nil ->
        {:halt, {:error, "scenario tracking verdict disposes unknown finding #{id}"}}

      index ->
        updated =
          findings
          |> Enum.at(index)
          |> Map.put("status", status)
          |> Map.update("disposition_history", [history], &(&1 ++ [history]))

        {:cont, {:ok, List.replace_at(findings, index, updated)}}
    end
  end

  defp disposition_status("closed"), do: {:ok, "closed"}
  defp disposition_status("open"), do: {:ok, "open"}
  defp disposition_status("remains_open"), do: {:ok, "open"}
  defp disposition_status(_), do: {:error, "invalid disposition status"}

  defp append_findings(findings, new_findings, attempt, session) do
    start = next_finding_number(findings)

    new_findings
    |> Enum.with_index(start)
    |> Enum.reduce_while({:ok, findings}, fn {finding, number}, {:ok, current} ->
      with {:ok, normalized} <- json_value(finding),
           true <- is_map(normalized),
           scenario_ids when is_list(scenario_ids) and scenario_ids != [] <-
             Map.get(normalized, "scenario_ids"),
           true <- Enum.all?(scenario_ids, &(is_binary(&1) and &1 != "")),
           reason when is_binary(reason) and reason != "" <- Map.get(normalized, "reason"),
           evidence when is_list(evidence) <- Map.get(normalized, "evidence") do
        origin = %{
          "scenario_ids" => scenario_ids,
          "reason" => reason,
          "evidence" => evidence,
          "candidate_id" => Map.get(attempt, "candidate_id"),
          "attempt_token" => Map.get(attempt, "attempt_token"),
          "reviewer_session" => session
        }

        item = %{
          "id" => "F#{number}",
          "scenario_ids" => scenario_ids,
          "status" => "open",
          "origin" => origin,
          "disposition_history" => []
        }

        {:cont, {:ok, current ++ [item]}}
      else
        false -> {:halt, {:error, "scenario tracking verdict has invalid new finding"}}
        _ -> {:halt, {:error, "scenario tracking verdict has invalid new finding"}}
      end
    end)
  end

  defp next_finding_number(findings) do
    findings
    |> Enum.map(&Map.get(&1, "id", ""))
    |> Enum.map(fn id -> Regex.run(~r/^F([1-9][0-9]*)$/, id) end)
    |> Enum.flat_map(fn
      [_, number] -> [String.to_integer(number)]
      _ -> []
    end)
    |> case do
      [] -> 1
      numbers -> Enum.max(numbers) + 1
    end
  end

  defp normalize_verdict(verdict) do
    {:ok, normalized} = json_value(verdict)
    normalized
  end
end
