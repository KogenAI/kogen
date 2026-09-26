# Controller citation probe — 2026-09-22

Read-only source-linked experiment before reopening the package. The actual
current `lib/kogen/build/contract.ex` was compiled in memory, using the installed
development dependency BEAMs; no `mix`, gate, provider, source edit or receipt
mutation ran. The Candidate-root stand-in was the then-existing Approved package;
the real retained outer tracking/state files were used only as regular-file
inputs. Contract source Git blob:
`80185b7ff107d286ccb1bf4815adcf16ea3f4ec0`.

Command: `elixir -pa '_build/dev/lib/*/ebin' -e '<script below>'`.

```elixir
Code.compiler_options(ignore_module_conflict: true)
Code.compile_file("lib/kogen/build/contract.ex")
root = Path.expand(".kogen/intents/approved/isolated-candidate-workspace")
record = Path.expand(".kogen/runtime/scenario-tracking/IBs1pJmboiW9BAGHIDd_ee4O/record.json")
state = Path.expand(".kogen/runtime/scenario-tracking/IBs1pJmboiW9BAGHIDd_ee4O/verification/attempt-0-lELCwRn-OjriG9oxD_tYKHHkt_Bu4lWG/state.json")
foreign = Path.expand(".kogen/runtime/scenario-tracking/suowZ26kyb7Qag3tKvPPC4n1/record.json")
contract = %{scenarios: [%{"id" => "one"}], risks: []}
binding = %{candidate_id: "probe-candidate", attempt_token: "probe-token"}
for {label, path} <- [
  {"candidate-relative control", "INTENT.md"},
  {"exact-controller-record control", record},
  {"relative-controller-state", Path.relative_to_cwd(state)},
  {"absolute-controller-state", state},
  {"foreign-controller-record", foreign}
] do
  message = %{
    "candidate_id" => binding.candidate_id, "attempt_token" => binding.attempt_token,
    "verdict" => "accept", "dispositions" => [], "findings" => [],
    "scenarios" => [%{"id" => "one", "status" => "satisfied", "reason" => "path validation probe only",
      "evidence" => [%{"path" => path, "locator" => "probe"}]}]
  }
  result = Kogen.Build.Contract.with_reference_root(root, record, fn ->
    Kogen.Build.Contract.verdict(message, contract, binding, [])
  end)
  status = case result do {:ok, _} -> "accepted"; {:error, error} -> error end
  IO.puts(label <> ": " <> status)
end
```

Exit 0. Output:

```text
candidate-relative control: accepted
exact-controller-record control: accepted
relative-controller-state: verdict scenarios: entry "one" at position 1: evidence[1], path ".kogen/runtime/scenario-tracking/IBs1pJmboiW9BAGHIDd_ee4O/verification/attempt-0-lELCwRn-OjriG9oxD_tYKHHkt_Bu4lWG/state.json": file does not exist
absolute-controller-state: verdict scenarios: entry "one" at position 1: evidence[1], path "/Users/almirsarajcic/Areas/Kogen/kogen/.kogen/runtime/scenario-tracking/IBs1pJmboiW9BAGHIDd_ee4O/verification/attempt-0-lELCwRn-OjriG9oxD_tYKHHkt_Bu4lWG/state.json": unsafe path; expected a relative path without traversal or NUL
foreign-controller-record: verdict scenarios: entry "one" at position 1: evidence[1], path "/Users/almirsarajcic/Areas/Kogen/kogen/.kogen/runtime/scenario-tracking/suowZ26kyb7Qag3tKvPPC4n1/record.json": unsafe path; expected a relative path without traversal or NUL
```

The positive Candidate-relative and exact tracking-record controls distinguish
reference-policy failure from malformed verdict/setup. The state exists, but
its relative and absolute spellings both fail in the current contract. A
foreign controller record remains rejected.

Limits: this isolates production verdict/path validation. It does not exercise
the whole handoff/retention/cleanup chain, prove native Reviewer behavior, or
establish acceptance of the failed Build. That full deterministic chain is now
explicit in `../repair-plan.md`. After reopening, the probe's original
Approved-root path is historical; any replay must select the same maintained
package's current location rather than infer absence is the original result.
