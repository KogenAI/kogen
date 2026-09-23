#!/bin/sh
# Probe Stop hook: block the first stop with feedback, then allow.
cat > /dev/null
if [ ! -f /tmp/kogen-cc-probe/stopped-once ]; then touch /tmp/kogen-cc-probe/stopped-once; printf '{"decision":"block","reason":"Kogen verification failed: reply with exactly FIXED."}\n'; else printf '{"continue":true}\n'; fi
