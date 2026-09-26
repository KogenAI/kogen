# Private dependency and build probe

## Invalid first control

The first disposable run copied only `~/.hex/packages/hexpm/yamerl-0.10.0.tar` into a private Hex home and invoked `HEX_OFFLINE=1 mix deps.get`. It failed before compilation:

```text
** (Mix) Hex is running in offline mode and the registry entry for package yamerl is not cached locally
```

This is valid negative evidence: a package tarball alone is not a sufficient authorized cold seed. The failed disposable root `/tmp/kogen-deps.gcXZfC` was then explicitly removed.

## Corrected private-cache control

The corrected run copied the admitted local Hex cache and Mix archives into each disposable Candidate/peer, created independently writable path and local-Git dependency copies, mutated only Candidate copies, then ran from the Candidate app:

```sh
HOME="$candidate/cache/home" MIX_HOME="$candidate/cache/mix" \
HEX_HOME="$candidate/cache/hex" REBAR_CACHE_DIR="$candidate/cache/rebar" \
MIX_BUILD_PATH="$candidate/_build" MIX_DEPS_PATH="$candidate/deps" \
HEX_OFFLINE=1 mix deps.get

# same environment
mix compile
```

Exact observed output summary:

```text
PROBE_ROOT=/tmp/kogen-deps.rFJFku
GIT_DEP_PIN=02439cb344180c9f248b878e085c687564a8a5d9
DEPS_GET_TAIL=Resolution completed in 0.006s|New:|  yamerl 0.10.0|* Getting yamerl (Hex package)|* creating /tmp/kogen-deps.rFJFku/candidate/cache/mix/elixir/1-20-otp-29/rebar3|
COMPILE_TAIL=Compiling 1 file (.ex)|Generated git_dep app|==> path_dep|Compiling 1 file (.ex)|Generated path_dep app|==> probe_app|Compiling 1 file (.ex)|Generated probe_app app|
PRIVATE_HEX_SOURCE=yes
PRIVATE_BUILD=no
CONTROL_UNCHANGED=yes
PEER_UNCHANGED=yes
SIBLING_UNCHANGED=yes
ESCAPED_PATH_RESOLVES=/private/tmp/kogen-deps.rFJFku/sibling
ESCAPE_CONTROL=must-refuse-before-mix
DANGLING_EXISTS=yes
COLLISION_COPY=merged-by-cp-wrong
COLLISION_SENTINEL=foreign
CLEANUP_EXISTS=no
```

`PRIVATE_BUILD=no` tested an incorrect assumed path (`_build/dev/lib/...`) while `MIX_BUILD_PATH` was explicitly the build root; the successful compiler transcript is the valid build observation, not that invalid path assertion. The collision intentionally used ordinary `cp -R`, which merged and therefore demonstrates why the production owner must reject existing destinations before copying. Mix also accepts relative path dependency syntax, so canonical containment must be enforced before invoking it.

