d = ".kogen/intents/drafts/isolated-candidate-workspace"
i = Kogen.Intent.read("isolated-candidate-workspace", ".kogen/intents/drafts")
IO.puts("Intent.read: " <> inspect(elem(i, 0)) <> (if elem(i,0)==:error, do: " " <> elem(i,1), else: ""))
{:ok, intent} = i
c = Kogen.Build.Contract.load(d)
IO.puts("Contract.load: " <> inspect(elem(c, 0)) <> (if elem(c,0)==:error, do: " " <> elem(c,1), else: ""))
{:ok, contract} = c
{:ok, catalog} = Kogen.Build.VerificationPlan.load()
guards = intent[:may_change_guarded_paths] || intent["may_change_guarded_paths"] || Map.get(intent, :guards)
IO.puts("guards: #{inspect(length(guards || []))}")
p = Kogen.Build.VerificationPlan.build(contract.scenarios, guards, catalog)
IO.puts("VerificationPlan.build: " <> inspect(p, limit: :infinity, pretty: true))
IO.puts("VerificationPolicy.preflight: " <> inspect(Kogen.VerificationPolicy.preflight(contract.targets)))
IO.puts("scenarios=#{length(contract.scenarios)} risks=#{length(contract.risks)} targets=#{inspect(contract.targets)}")
