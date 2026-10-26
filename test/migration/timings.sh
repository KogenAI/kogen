#!/bin/sh
# Measures the Go program's build, focused unit check and installed startup for
# docs/evidence/go-core-migration/qualification.json. Usage: sh test/migration/timings.sh <archive>
set -eu
cd "$(dirname "$0")/../.."
archive=$1
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
now() { perl -MTime::HiRes=time -e 'printf "%.6f\n", time'; }
(cd cli && go build ./... >/dev/null)            # warm the build cache once
t0=$(now); (cd cli && go build -a -o "$work/kogen-forced" .) ; t1=$(now)
t2=$(now); (cd cli && go build -o "$work/kogen" .) ; t3=$(now)
t4=$(now); (cd cli && go test -count=1 ./project >/dev/null) ; t5=$(now)
tar -xzf "$archive" -C "$work"
top=$(ls -d "$work"/kogen-*/ | head -1)
HOME="$work/home" sh "$top/install.sh" --prefix "$work/prefix" >/dev/null
starts=""
for i in 1 2 3 4 5; do
  s=$(now); HOME="$work/home" "$work/prefix/bin/kogen" provider list >/dev/null; e=$(now)
  starts="$starts $(echo "($e - $s) * 1000" | bc -l)"
done
printf '{"forced_go_build_s":%s,"cached_go_build_s":%s,"focused_unit_check_s":%s,"installed_provider_list_ms":[%s]}\n' \
  "$(echo "$t1 - $t0" | bc -l)" "$(echo "$t3 - $t2" | bc -l)" "$(echo "$t5 - $t4" | bc -l)" \
  "$(echo $starts | tr ' ' ',')"
