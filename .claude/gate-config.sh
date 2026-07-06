#!/usr/bin/env bash
# Codegen's own per-repo gate config. The loop's gate selector reads GATE_COMMAND
# as the explicit floor when a cycle carries no planner **Gate**: line. Codegen's
# repo gate is the fast hermetic self-test (bash hook tests + generator tests +
# hermetic ExUnit + rule-render-freshness), NOT the downstream-app `make ci`.
GATE_STACK=codegen
GATE_COMMAND="make test"
