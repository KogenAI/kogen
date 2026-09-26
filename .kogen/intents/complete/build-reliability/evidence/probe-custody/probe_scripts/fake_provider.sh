#!/bin/sh
# Fake provider: ignores stdin EOF (keeps running), forks a grandchild that
# ignores SIGTERM and sleeps 300s. Records pids for inspection.
out_dir="${FAKE_OUT_DIR:-/tmp}"
here="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
echo "provider pid=$$ pgid=$(ps -o pgid= -p $$ | tr -d ' ')" > "$out_dir/provider.info"
python3 "$here/grandchild.py" "$out_dir" &
gpid=$!
echo "grandchild pid=$gpid" >> "$out_dir/provider.info"
sleep 2
