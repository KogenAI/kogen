#!/bin/sh
# Probe Stop hook: first Stop "passes" (continue:true); every later Stop answers like
# stop_runner.py does for a terminal passed state.
cat > /private/tmp/claude-501/-Users-almirsarajcic-Areas-Kogen-kogen/c5f540c2-7e25-48e0-a65a-10535201a2ec/scratchpad/stop-terminal-probe/last-stop-input.json
n=$(cat /private/tmp/claude-501/-Users-almirsarajcic-Areas-Kogen-kogen/c5f540c2-7e25-48e0-a65a-10535201a2ec/scratchpad/stop-terminal-probe/stops 2>/dev/null || echo 0); n=$((n+1)); echo $n > /private/tmp/claude-501/-Users-almirsarajcic-Areas-Kogen-kogen/c5f540c2-7e25-48e0-a65a-10535201a2ec/scratchpad/stop-terminal-probe/stops
if [ "$n" -eq 1 ]; then printf '{"continue":true}\n'; else printf '{"continue":false,"stopReason":"verification already terminal: passed"}\n'; fi
