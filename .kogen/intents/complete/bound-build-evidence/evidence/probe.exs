# Bounded source-linked observation, not a production publication test.
[source, work] = System.argv()
Code.compile_file(source)
File.mkdir_p!(work)
File.cd!(work)
alias Kogen.Build.Tracking

results =
  for mode <- [:record_citation, :fixed_artifact_control] do
    {:ok, first} = Tracking.new(%{"id" => "probe", "slug" => "probe", "title" => "Probe"}, %{"scenarios" => [], "risks" => []}, [])

    {last, sizes} =
      Enum.reduce(1..3, {first, []}, fn number, {state, sizes} ->
        {:ok, state} = Tracking.start_attempt(state, "attempt-#{number}", number - 1)
        bytes = if mode == :record_citation, do: state.bytes, else: "fixed evidence"
        # The two-field update matches Build's observed retention boundary.
        refs = %{state.path => %{"content_base64" => Base.encode64(bytes)}}
        attempts = List.update_at(state.record["attempts"], -1, &Map.merge(&1, %{"developer_reference_snapshots" => refs, "reference_snapshots" => refs}))
        {:ok, state} = Tracking.update(state, Map.put(state.record, "attempts", attempts))
        bytes = if mode == :record_citation, do: state.bytes, else: "fixed evidence"
        reviewer = %{state.path => %{"content_base64" => Base.encode64(bytes)}}
        {:ok, state} = Tracking.apply_verdict(state, %{"verdict" => "accept", "findings" => [], "dispositions" => []}, "reviewer-#{number}", reviewer)
        :ok = Tracking.verify(state)
        {state, sizes ++ [byte_size(state.bytes)]}
      end)

    File.write!(last.path, last.bytes <> "tampered")
    {:error, reason} = Tracking.verify(last)
    %{mode: mode, bytes_after_each_attempt: sizes, tamper_rejected: String.contains?(reason, "changed outside Build")}
  end

IO.puts(Jason.encode!(results))
