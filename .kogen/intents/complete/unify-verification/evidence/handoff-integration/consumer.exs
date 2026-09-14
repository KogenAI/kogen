[repo, fixture, mode] = System.argv()
Mix.start()
Code.require_file(Path.join(repo, "mix.exs"))
for file <- ["lib/kogen/harness.ex", "lib/kogen/build/developer_handoff.ex", "lib/kogen/build/contract.ex"] do
  Code.compile_file(Path.join(repo, file))
end
File.cd!(fixture)
contract = %{scenarios: [%{"id" => "s1"}], risks: []}
{:ok, schema} = Kogen.Build.DeveloperHandoff.schema(contract, "probe-token", [])
File.write!("schema.json", schema)
prompt = "Return only the required structured handoff. Use attempt_token probe-token, one scenario s1 status ready, claim 'The probe source exists', implementation and evidence each [{path: source.txt, locator: line 1}], and empty risks/findings. Do not use tools or modify any file. If Stop blocks, return that same handoff again."
File.write!("prompt.txt", prompt)
result = Kogen.Harness.launch_build_developer(prompt, "gpt-5.6-sol", "low", schema)
File.write!("harness-result.txt", inspect(result, pretty: true, limit: :infinity, printable_limit: :infinity))
summary = case result do
  {:ok, turn} ->
    File.write!("invocation.json", Jason.encode!(turn.invocation_evidence))
    semantic = Kogen.Build.Contract.handoff(turn.message, contract, "probe-token", [])
    %{mode: mode, result: "ok", session_id: turn.session_id, semantic: inspect(semantic), message: turn.message}
  {:error, {kind, evidence}} when is_map(evidence) ->
    File.write!("invocation.json", Jason.encode!(evidence))
    %{mode: mode, result: "error", kind: to_string(kind)}
  other -> %{mode: mode, result: inspect(other)}
end
File.write!("consumer-summary.json", Jason.encode!(summary))
IO.puts(Jason.encode!(summary))
