#!/bin/sh
# A fake Developer/Reviewer/Expert/Jev/target process for
# `test/kogen/process_custody_test.exs`. It ignores stdin EOF (so it never
# exits on its own, like a real harness whose CLI hangs) and forks a
# grandchild that ignores SIGTERM and sleeps, exactly the probe's mechanism
# (evidence/probe-custody/probe_scripts). `$1` is a directory the test uses
# to find this process's own pid and its grandchild's pid.
out_dir="${1:?fake_orphaning_provider requires an output directory}"
here="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

echo "$$" > "$out_dir/provider.pid"

python3 "$here/grandchild.py" "$out_dir" &
echo "$!" > "$out_dir/grandchild.pid"

# Never exits on its own: reading stdin to EOF changes nothing, and there is
# no timeout. Only a signal (from custody teardown or the watchdog) ends it.
cat >/dev/null
while true; do
  sleep 1
done
