#!/bin/sh
set -eu

here=$(cd "$(dirname "$0")" && pwd)
example=$(cd "$here/../tiny_tasks" && pwd)
acceptance="$here/acceptance.feature"
work=$(mktemp -d "${TMPDIR:-/tmp}/tiny-tasks-qualify.XXXXXX")

cleanup() {
  rm -rf "$work"
}
trap cleanup 0
trap 'exit 130' INT
trap 'exit 143' TERM

# npm ci needs the registry unless this user's npm cache already holds the pinned packages
# (--prefer-offline uses it); everything else runs offline.
npm_cache=${npm_config_cache:-$HOME/.npm}
mkdir -p "$work/home" "$work/mix" "$work/hex"
export HOME="$work/home"
export GIT_CONFIG_GLOBAL="$work/gitconfig"
export GIT_CONFIG_NOSYSTEM=1
export MIX_HOME="$work/mix"
export HEX_HOME="$work/hex"
export npm_config_cache="$npm_cache"
: > "$GIT_CONFIG_GLOBAL"

baseline="$work/baseline"
mkdir "$baseline"
cp -R "$example/." "$baseline/"
(cd "$baseline" && npm ci --prefer-offline --no-audit --no-fund)

run=1
while [ "$run" -le 5 ]; do
  printf '\nBaseline check run %s/5\n' "$run"
  (cd "$baseline" && mix format --check-formatted)
  (cd "$baseline" && mix test --warnings-as-errors)
  (cd "$baseline" && npm test)
  run=$((run + 1))
done
printf '\nBaseline: format, ExUnit, and bridge feature passed 5/5 runs.\n'

make_variant() {
  variant=$1
  mkdir "$variant"
  cp -R "$example/." "$variant/"
  ln -s "$baseline/node_modules" "$variant/node_modules"
}

expect_acceptance_failure() {
  name=$1
  patch_file=$2
  marker=$3
  variant="$work/$name"
  log="$work/$name.log"
  make_variant "$variant"
  (cd "$variant" && patch -s -p1 < "$patch_file")

  if (cd "$variant" && ./node_modules/.bin/cucumber-js --strict \
      --require 'features/steps/*.js' "$acceptance") > "$log" 2>&1; then
    cat "$log"
    printf 'Qualification failure: incorrect implementation %s passed.\n' "$name" >&2
    exit 1
  fi

  if ! grep -Fq "$marker" "$log"; then
    cat "$log"
    printf 'Qualification failure: %s failed for a reason other than its expected assertion.\n' "$name" >&2
    exit 1
  fi

  cat "$log"
  printf 'Expected result: %s was rejected by its contract assertion.\n' "$name"
}

expect_acceptance_failure \
  wrong-ignore-old-data \
  "$here/wrong-ignore-old-data.patch" \
  'expected exactly these tasks, in order'
expect_acceptance_failure \
  wrong-filter-direction \
  "$here/wrong-filter-direction.patch" \
  'expected exactly these tasks, in order'
expect_acceptance_failure \
  wrong-reverse-order \
  "$here/wrong-reverse-order.patch" \
  'expected exactly these tasks, in order'

reference="$work/reference"
make_variant "$reference"
(cd "$reference" && patch -s -p1 < "$here/reference.patch")
(cd "$reference" && ./node_modules/.bin/cucumber-js --strict \
  --require 'features/steps/*.js' "$acceptance")
(cd "$reference" && mix format --check-formatted)
(cd "$reference" && mix test --warnings-as-errors)

printf '\nQualification passed: 5 baseline runs, all three incorrect implementations rejected, reference accepted.\n'
