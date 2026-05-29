# Benchmarking Prohibition

Agents MUST NEVER invoke `make test-stacks BENCH=1` or any benchmark-capture variant (`BENCH=1 REASON=...`). These commands burn real LLM token budget and run only at human-operator discretion. `make test-stacks` without `BENCH=1` stays agent-callable for the default pass/fail sweep.
