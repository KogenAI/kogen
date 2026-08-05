#!/usr/bin/env bash
# Codegen's own per-repo gate config. The loop's gate selector reads GATE_COMMAND
# as the sole gate resolver — there is no per-cycle override tier. Codegen's
# repo gate is the fast hermetic self-test (bash hook tests + generator tests +
# hermetic ExUnit + rule-render-freshness), NOT the downstream-app `make ci`.
GATE_STACK=codegen
GATE_COMMAND="make test"

# `make test` matches neither of gate_timeout_for's patterns (`make ci`,
# `make llm`), so the heuristic derives 0 — "no budget declared". The consumer
# (LoopGate.run_with_deadline/4) floors a 0 to its own 900s default, so the
# effective budget was already 900; declaring it here makes it OURS rather than
# a coincidence of the consumer's fallback, and gives us one place to raise it
# when the suite outgrows 15 minutes.
GATE_TIMEOUT=900
