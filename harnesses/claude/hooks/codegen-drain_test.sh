#!/usr/bin/env bash
# codegen-drain_test.sh — hermetic tests for codegen-drain (possession-mover
# between fleet nodes). No real ssh/scp is ever reached: remote-node cases
# use a local-node inventory entry (no `host:` field) so cmd_assign/cmd_status
# take the same-filesystem branch. This is not a compromise — it is the
# fastest way to prove the ack-before-delete, resurrection-guard, and
# checksum-verify logic without a live second box.

set -euo pipefail

HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODEGEN_ROOT="$(cd "$HOOKS_DIR/../../.." && pwd)"
DRAIN="$CODEGEN_ROOT/codegen-drain"

pass=0
fail=0

check() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — expected %q, got %q\n' "$desc" "$expected" "$actual"
        fail=$((fail + 1))
    fi
}

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — expected to find %q\n  got: %s\n' "$desc" "$needle" "${haystack:0:300}"
        fail=$((fail + 1))
    fi
}

make_ws() {
    local name="$1"
    local ws
    ws="$(mktemp -d)/$name"
    mkdir -p "$ws"
    printf '%s' "$ws"
}

# ── (a) no subcommand → usage, exit 2 ───────────────────────────────────────
ec=0
out="$("$DRAIN" 2>&1)" || ec=$?
check "(a) no subcommand exits 2" "2" "$ec"
assert_contains "(a) usage names subcommand required" "$out" "subcommand required"

# ── (b) unknown subcommand → exit 2 ─────────────────────────────────────────
ec=0
out="$("$DRAIN" bogus 2>&1)" || ec=$?
check "(b) unknown subcommand exits 2" "2" "$ec"
assert_contains "(b) usage names unknown subcommand" "$out" "unknown subcommand"

# ── (c) assign missing --slug → exit 2 ──────────────────────────────────────
ec=0
out="$("$DRAIN" assign --node=local 2>&1)" || ec=$?
check "(c) assign without --slug exits 2" "2" "$ec"
assert_contains "(c) names --slug required" "$out" "--slug required"

# ── (d) assign missing --node → exit 2 ──────────────────────────────────────
ec=0
out="$("$DRAIN" assign --slug=foo 2>&1)" || ec=$?
check "(d) assign without --node exits 2" "2" "$ec"
assert_contains "(d) names --node required" "$out" "--node required"

# ── (e) assign with no inventory → exit 2 ───────────────────────────────────
WS_E="$(make_ws e)"
ec=0
out="$(CODEGEN_DRAIN_INVENTORY="$WS_E/drain-nodes.yaml" "$DRAIN" assign --slug=foo --node=local 2>&1)" || ec=$?
check "(e) assign with no inventory exits 2" "2" "$ec"
assert_contains "(e) points at init" "$out" "codegen-drain init"

# ── (f) init writes inventory; re-running refuses ───────────────────────────
WS_F="$(make_ws f)"
ec=0
CODEGEN_DRAIN_INVENTORY="$WS_F/drain-nodes.yaml" "$DRAIN" init >/dev/null 2>&1 || ec=$?
check "(f) init exits 0" "0" "$ec"
check "(f) inventory file written" "1" "$([[ -f "$WS_F/drain-nodes.yaml" ]] && echo 1 || echo 0)"
ec=0
out="$(CODEGEN_DRAIN_INVENTORY="$WS_F/drain-nodes.yaml" "$DRAIN" init 2>&1)" || ec=$?
check "(f) re-init exits 1 (refuses overwrite)" "1" "$ec"
assert_contains "(f) re-init names already exists" "$out" "already exists"

# ── Shared fixture: a two-node inventory (both local-fs, no ssh) ───────────
setup_fixture() {
    local ws="$1"
    mkdir -p "$ws/nodeA/codegen/pitches/ready"
    mkdir -p "$ws/nodeB/codegen/pitches/ready"
    cat >"$ws/drain-nodes.yaml" <<YAML
nodes:
  - name: nodeA
    repo: $ws/nodeA
  - name: nodeB
    repo: $ws/nodeB
YAML
}

# ── (g) assign: slug not in local ready/ → exit 1 ──────────────────────────
WS_G="$(make_ws g)"
setup_fixture "$WS_G"
ec=0
out="$(CODEGEN_DRAIN_INVENTORY="$WS_G/drain-nodes.yaml" "$DRAIN" assign --slug=missing --node=nodeB --cwd="$WS_G/nodeA" 2>&1)" || ec=$?
check "(g) assign of missing slug exits 1" "1" "$ec"
assert_contains "(g) names not in ready/" "$out" "not in ready/"

# ── (h) assign: unknown node → exit 2 ──────────────────────────────────────
WS_H="$(make_ws h)"
setup_fixture "$WS_H"
TEST_SLUG="codegen-drain-test-fixture-$$"
TEST_PITCH="$WS_H/nodeA/codegen/pitches/ready/${TEST_SLUG}.md"
printf '# test fixture pitch\n' >"$TEST_PITCH"
ec=0
out="$(CODEGEN_DRAIN_INVENTORY="$WS_H/drain-nodes.yaml" "$DRAIN" assign --slug="$TEST_SLUG" --node=bogus-node --cwd="$WS_H/nodeA" 2>&1)" || ec=$?
check "(h) assign to unknown node exits 2" "2" "$ec"
assert_contains "(h) names unknown node" "$out" "unknown node"
check "(h) local pitch NOT moved on unknown-node refusal" "1" "$([[ -f "$TEST_PITCH" ]] && echo 1 || echo 0)"

# ── (i) assign: happy path, local-fs node — moves file, removes source ─────
WS_I="$(make_ws i)"
setup_fixture "$WS_I"
TEST_SLUG_I="codegen-drain-test-fixture-i-$$"
TEST_PITCH_I="$WS_I/nodeA/codegen/pitches/ready/${TEST_SLUG_I}.md"
printf '# test fixture pitch\n' >"$TEST_PITCH_I"
ec=0
out="$(CODEGEN_DRAIN_INVENTORY="$WS_I/drain-nodes.yaml" "$DRAIN" assign --slug="$TEST_SLUG_I" --node=nodeB --cwd="$WS_I/nodeA" 2>&1)" || ec=$?
check "(i) happy-path assign exits 0" "0" "$ec"
assert_contains "(i) prints assigned message" "$out" "assigned $TEST_SLUG_I -> nodeB"
check "(i) destination now holds the file" "1" "$([[ -f "$WS_I/nodeB/codegen/pitches/ready/${TEST_SLUG_I}.md" ]] && echo 1 || echo 0)"
check "(i) source no longer holds the file" "1" "$([[ ! -f "$TEST_PITCH_I" ]] && echo 1 || echo 0)"

# ── (j) assign: resurrection guard — destination already holds slug ────────
WS_J="$(make_ws j)"
setup_fixture "$WS_J"
TEST_SLUG_J="codegen-drain-test-fixture-j-$$"
TEST_PITCH_J="$WS_J/nodeA/codegen/pitches/ready/${TEST_SLUG_J}.md"
printf '# already-there pitch\n' >"$WS_J/nodeB/codegen/pitches/ready/${TEST_SLUG_J}.md"
printf '# test fixture pitch\n' >"$TEST_PITCH_J"
ec=0
out="$(CODEGEN_DRAIN_INVENTORY="$WS_J/drain-nodes.yaml" "$DRAIN" assign --slug="$TEST_SLUG_J" --node=nodeB --cwd="$WS_J/nodeA" 2>&1)" || ec=$?
check "(j) assign refuses when destination already holds slug" "1" "$ec"
assert_contains "(j) names refusing / ambiguous" "$out" "refusing"
check "(j) local copy is KEPT on refusal (no data loss)" "1" "$([[ -f "$TEST_PITCH_J" ]] && echo 1 || echo 0)"

# ── (k) status: local-fs nodes report ready counts ─────────────────────────
WS_K="$(make_ws k)"
setup_fixture "$WS_K"
printf '# p1\n' >"$WS_K/nodeA/codegen/pitches/ready/p1.md"
printf '# p2\n' >"$WS_K/nodeA/codegen/pitches/ready/p2.md"
ec=0
out="$(CODEGEN_DRAIN_INVENTORY="$WS_K/drain-nodes.yaml" "$DRAIN" status 2>&1)" || ec=$?
check "(k) status exits 0" "0" "$ec"
assert_contains "(k) nodeA shows ready=2" "$out" "ready=2"
assert_contains "(k) nodeB shows ready=0" "$out" "ready=0"

# ── (l) --json status is valid-shaped output ───────────────────────────────
WS_L="$(make_ws l)"
setup_fixture "$WS_L"
ec=0
out="$(CODEGEN_DRAIN_INVENTORY="$WS_L/drain-nodes.yaml" "$DRAIN" status --json 2>&1)" || ec=$?
check "(l) status --json exits 0" "0" "$ec"
assert_contains "(l) json has node key" "$out" '"node":"nodeA"'
assert_contains "(l) json has reachable key" "$out" '"reachable":true'

# ── (m) static: scp is never invoked with -p (mtime preservation would
# defeat the drain's quiescence-gate check, which keys on mtime > cutoff) ──
ec=0
scp_p_hits="$(grep -nE '\bscp\b[^|]*-p\b' "$DRAIN" || true)"
check "(m) no 'scp -p' anywhere in codegen-drain (would defeat quiescence gate)" "" "$scp_p_hits"

# ── (n) installed-shape regression: codegen-drain copied to a tmp dir (no
# sibling codegen/ tree, mirroring $INSTALL_DIR after `make install`) must
# resolve the repo root from --cwd, never from its own install location ────
WS_N="$(make_ws n)"
INSTALLED_COPY="$(mktemp -d)/codegen-drain"
cp "$DRAIN" "$INSTALLED_COPY"
chmod +x "$INSTALLED_COPY"

setup_fixture "$WS_N"
TEST_SLUG_N="codegen-drain-test-fixture-n-$$"
TEST_PITCH_N="$WS_N/nodeA/codegen/pitches/ready/${TEST_SLUG_N}.md"
printf '# test fixture pitch\n' >"$TEST_PITCH_N"

# Run from an unrelated cwd (not the fixture, not the real repo) to prove
# resolution follows --cwd, not $PWD and not the installed copy's own path.
ec=0
out="$(cd /tmp && CODEGEN_DRAIN_INVENTORY="$WS_N/drain-nodes.yaml" "$INSTALLED_COPY" assign --slug="$TEST_SLUG_N" --node=nodeB --cwd="$WS_N/nodeA" 2>&1)" || ec=$?
check "(n) installed flat-copy assign exits 0" "0" "$ec"
assert_contains "(n) installed copy prints assigned message" "$out" "assigned $TEST_SLUG_N -> nodeB"
check "(n) installed copy moved file via --cwd, not install location" "1" "$([[ -f "$WS_N/nodeB/codegen/pitches/ready/${TEST_SLUG_N}.md" ]] && echo 1 || echo 0)"
check "(n) installed copy source no longer holds file" "1" "$([[ ! -f "$TEST_PITCH_N" ]] && echo 1 || echo 0)"
rm -rf "$(dirname "$INSTALLED_COPY")"

# ── (o) status: live queue.lock with label=queue + live pid → watcher=yes ──
WS_O="$(make_ws o)"
setup_fixture "$WS_O"
mkdir -p "$WS_O/nodeA/codegen/gate-pending"
printf '%s queue tree=%s\n' "$$" "$$" >"$WS_O/nodeA/codegen/gate-pending/queue.lock"
ec=0
out="$(CODEGEN_DRAIN_INVENTORY="$WS_O/drain-nodes.yaml" "$DRAIN" status 2>&1)" || ec=$?
check "(o) status exits 0" "0" "$ec"
assert_contains "(o) nodeA shows watcher=yes for live queue lock" "$out" "watcher=yes"

# ── (p) status: label=solo + live pid → watcher=no (solo is NOT a watcher) ─
WS_P="$(make_ws p)"
setup_fixture "$WS_P"
mkdir -p "$WS_P/nodeA/codegen/gate-pending"
printf '%s solo tree=%s\n' "$$" "$$" >"$WS_P/nodeA/codegen/gate-pending/queue.lock"
ec=0
out="$(CODEGEN_DRAIN_INVENTORY="$WS_P/drain-nodes.yaml" "$DRAIN" status 2>&1)" || ec=$?
check "(p) status exits 0" "0" "$ec"
assert_contains "(p) nodeA shows watcher=no for solo-labeled lock" "$out" "$(printf '%-12s ready=%-4s incoming=%-4s watcher=%s' "nodeA" "0" "0" "no")"

# ── (q) status: dead pid in lock → watcher=no (stale lock) ─────────────────
WS_Q="$(make_ws q)"
setup_fixture "$WS_Q"
mkdir -p "$WS_Q/nodeA/codegen/gate-pending"
# Find a pid guaranteed dead: spawn+immediately reap a subshell.
(:) &
DEAD_PID=$!
wait "$DEAD_PID" 2>/dev/null || true
printf '%s queue tree=%s\n' "$DEAD_PID" "$DEAD_PID" >"$WS_Q/nodeA/codegen/gate-pending/queue.lock"
ec=0
out="$(CODEGEN_DRAIN_INVENTORY="$WS_Q/drain-nodes.yaml" "$DRAIN" status 2>&1)" || ec=$?
check "(q) status exits 0" "0" "$ec"
assert_contains "(q) nodeA shows watcher=no for dead pid" "$out" "$(printf '%-12s ready=%-4s incoming=%-4s watcher=%s' "nodeA" "0" "0" "no")"

# ── (r) status: no lock file → watcher=no ───────────────────────────────────
WS_R="$(make_ws r)"
setup_fixture "$WS_R"
ec=0
out="$(CODEGEN_DRAIN_INVENTORY="$WS_R/drain-nodes.yaml" "$DRAIN" status 2>&1)" || ec=$?
check "(r) status exits 0" "0" "$ec"
assert_contains "(r) nodeA shows watcher=no with no lock file" "$out" "$(printf '%-12s ready=%-4s incoming=%-4s watcher=%s' "nodeA" "0" "0" "no")"

# ── (s) status: malformed lock file → watcher=no ────────────────────────────
WS_S="$(make_ws s)"
setup_fixture "$WS_S"
mkdir -p "$WS_S/nodeA/codegen/gate-pending"
printf 'garbage\n' >"$WS_S/nodeA/codegen/gate-pending/queue.lock"
ec=0
out="$(CODEGEN_DRAIN_INVENTORY="$WS_S/drain-nodes.yaml" "$DRAIN" status 2>&1)" || ec=$?
check "(s) status exits 0" "0" "$ec"
assert_contains "(s) nodeA shows watcher=no with malformed lock" "$out" "$(printf '%-12s ready=%-4s incoming=%-4s watcher=%s' "nodeA" "0" "0" "no")"

# ── (t) static: no argv-scanning liveness probe anywhere (self-match class
# is closed by construction — a solo build or an agent quoting the pattern
# must never satisfy the watcher check) ─────────────────────────────────────
ec=0
pgrep_hits="$(grep -cE '\bpgrep -f|ps .*\| *grep' "$DRAIN" || true)"
check "(t) no pgrep-f / ps-pipe-grep liveness probe in codegen-drain" "0" "$pgrep_hits"

# ── (u) status: watcher=no prints remediation in non-JSON output ───────────
WS_U="$(make_ws u)"
setup_fixture "$WS_U"
ec=0
out="$(CODEGEN_DRAIN_INVENTORY="$WS_U/drain-nodes.yaml" "$DRAIN" status 2>&1)" || ec=$?
check "(u) status exits 0" "0" "$ec"
assert_contains "(u) remediation names claude-build --queue --watch" "$out" "claude-build --queue --watch"

# ── (v) --json status watcher=no still valid JSON shape (no extra key) ─────
WS_V="$(make_ws v)"
setup_fixture "$WS_V"
ec=0
out="$(CODEGEN_DRAIN_INVENTORY="$WS_V/drain-nodes.yaml" "$DRAIN" status --json 2>&1)" || ec=$?
check "(v) status --json exits 0" "0" "$ec"
assert_contains "(v) json watcher no" "$out" '"watcher":"no"'

# ── assign --auto: hermetic tests via CODEGEN_DRAIN_SCOPE_CMD stub. No real
# mix/BEAM run — the stub emits canned JSON in the exact shape
# `mix codegen.pitches.scope --json` produces; this proves the JSON->lane->
# node wiring, not the mix task itself (that is proven by the ExUnit suite
# for Mix.Tasks.Codegen.Pitches.Scope). Inventories for these cases list only
# DESTINATION nodes (never the --cwd/source box itself) — the source box's
# own ready/ is what --auto partitions FROM, not a placement target; listing
# it as a destination would make lane-1 a same-slug self-assign no-op. ─────
setup_auto_fixture() {
    local ws="$1"
    mkdir -p "$ws/nodeA/codegen/pitches/ready"
    mkdir -p "$ws/nodeB/codegen/pitches/ready"
    mkdir -p "$ws/nodeC/codegen/pitches/ready"
    cat >"$ws/drain-nodes.yaml" <<YAML
nodes:
  - name: nodeB
    repo: $ws/nodeB
  - name: nodeC
    repo: $ws/nodeC
YAML
}

# ── (w) assign --auto: happy path, 2 disjoint lanes -> 2 distinct nodes ────
WS_W="$(make_ws w)"
setup_auto_fixture "$WS_W"
printf '# p1\n' >"$WS_W/nodeA/codegen/pitches/ready/p1.md"
printf '# p2\n' >"$WS_W/nodeA/codegen/pitches/ready/p2.md"
STUB_W='printf %s '"'"'{"lanes":[["p1"],["p2"]],"global_hot":[],"unrouted":[]}'"'"''
ec=0
out="$(CODEGEN_DRAIN_INVENTORY="$WS_W/drain-nodes.yaml" CODEGEN_DRAIN_SCOPE_CMD="$STUB_W" "$DRAIN" assign --auto --cwd="$WS_W/nodeA" 2>&1)" || ec=$?
check "(w) assign --auto happy path exits 0" "0" "$ec"
assert_contains "(w) p1 assigned to nodeB (lane 1 -> node 1)" "$out" "assigned p1 -> nodeB"
assert_contains "(w) p2 assigned to nodeC (lane 2 -> node 2)" "$out" "assigned p2 -> nodeC"
check "(w) p1 landed on nodeB ready/" "1" "$([[ -f "$WS_W/nodeB/codegen/pitches/ready/p1.md" ]] && echo 1 || echo 0)"
check "(w) p2 landed on nodeC ready/" "1" "$([[ -f "$WS_W/nodeC/codegen/pitches/ready/p2.md" ]] && echo 1 || echo 0)"
check "(w) p1 source removed from nodeA" "1" "$([[ ! -f "$WS_W/nodeA/codegen/pitches/ready/p1.md" ]] && echo 1 || echo 0)"
check "(w) p2 source removed from nodeA" "1" "$([[ ! -f "$WS_W/nodeA/codegen/pitches/ready/p2.md" ]] && echo 1 || echo 0)"

# ── (x) assign --auto: UNROUTED slug printed by name, never moved ─────────
WS_X="$(make_ws x)"
setup_auto_fixture "$WS_X"
printf '# p1\n' >"$WS_X/nodeA/codegen/pitches/ready/p1.md"
printf '# u1\n' >"$WS_X/nodeA/codegen/pitches/ready/u1.md"
STUB_X='printf %s '"'"'{"lanes":[["p1"],[]],"global_hot":[],"unrouted":["u1"]}'"'"''
ec=0
out="$(CODEGEN_DRAIN_INVENTORY="$WS_X/drain-nodes.yaml" CODEGEN_DRAIN_SCOPE_CMD="$STUB_X" "$DRAIN" assign --auto --cwd="$WS_X/nodeA" 2>&1)" || ec=$?
check "(x) assign --auto exits 0 with unrouted present" "0" "$ec"
assert_contains "(x) UNROUTED printed by name" "$out" "UNROUTED"
assert_contains "(x) u1 named in UNROUTED line" "$out" "u1"
check "(x) u1 NOT moved (stays on nodeA)" "1" "$([[ -f "$WS_X/nodeA/codegen/pitches/ready/u1.md" ]] && echo 1 || echo 0)"

# ── (y) assign --auto: zero reachable nodes -> exit 1, named ──────────────
WS_Y="$(make_ws y)"
mkdir -p "$WS_Y/nodeA/codegen/pitches/ready"
cat >"$WS_Y/drain-nodes.yaml" <<YAML
nodes:
  - name: nodeUnreachable
    host: definitely-not-a-real-host.invalid
    repo: /nonexistent
YAML
printf '# p1\n' >"$WS_Y/nodeA/codegen/pitches/ready/p1.md"
ec=0
out="$(CODEGEN_DRAIN_INVENTORY="$WS_Y/drain-nodes.yaml" "$DRAIN" assign --auto --cwd="$WS_Y/nodeA" 2>&1)" || ec=$?
check "(y) assign --auto with zero reachable nodes exits 1" "1" "$ec"
assert_contains "(y) names zero reachable nodes" "$out" "zero reachable nodes"

# ── (z) assign --auto: GLOBAL-HOT slug printed by name, never moved ───────
WS_Z="$(make_ws z)"
setup_auto_fixture "$WS_Z"
printf '# hot\n' >"$WS_Z/nodeA/codegen/pitches/ready/hot.md"
printf '# p1\n' >"$WS_Z/nodeA/codegen/pitches/ready/p1.md"
STUB_Z='printf %s '"'"'{"lanes":[["p1"],[]],"global_hot":["hot"],"unrouted":[]}'"'"''
ec=0
out="$(CODEGEN_DRAIN_INVENTORY="$WS_Z/drain-nodes.yaml" CODEGEN_DRAIN_SCOPE_CMD="$STUB_Z" "$DRAIN" assign --auto --cwd="$WS_Z/nodeA" 2>&1)" || ec=$?
check "(z) assign --auto exits 0 with global_hot present" "0" "$ec"
assert_contains "(z) GLOBAL-HOT printed by name" "$out" "GLOBAL-HOT"
assert_contains "(z) hot named in GLOBAL-HOT line" "$out" "hot"
check "(z) hot NOT moved (stays on nodeA)" "1" "$([[ -f "$WS_Z/nodeA/codegen/pitches/ready/hot.md" ]] && echo 1 || echo 0)"

# ── (aa) assign --auto: --slug/--node mutually exclusive with --auto ──────
WS_AA="$(make_ws aa)"
setup_auto_fixture "$WS_AA"
ec=0
out="$(CODEGEN_DRAIN_INVENTORY="$WS_AA/drain-nodes.yaml" "$DRAIN" assign --auto --slug=foo --cwd="$WS_AA/nodeA" 2>&1)" || ec=$?
check "(aa) --auto with --slug exits 2 (mutually exclusive)" "2" "$ec"
assert_contains "(aa) names mutually exclusive" "$out" "mutually exclusive"

# ── (ab) assign: same-node placement is a no-op (source == dest) ──────────
WS_AB="$(make_ws ab)"
setup_fixture "$WS_AB"
TEST_SLUG_AB="codegen-drain-test-fixture-ab-$$"
TEST_PITCH_AB="$WS_AB/nodeA/codegen/pitches/ready/${TEST_SLUG_AB}.md"
printf '# test fixture pitch\n' >"$TEST_PITCH_AB"
ec=0
out="$(CODEGEN_DRAIN_INVENTORY="$WS_AB/drain-nodes.yaml" "$DRAIN" assign --slug="$TEST_SLUG_AB" --node=nodeA --cwd="$WS_AB/nodeA" 2>&1)" || ec=$?
check "(ab) same-node assign exits 0 (no-op, not a refusal)" "0" "$ec"
assert_contains "(ab) prints already at" "$out" "already at"
assert_contains "(ab) prints no-op" "$out" "no-op"
check "(ab) pitch still exists at its original path" "1" "$([[ -f "$TEST_PITCH_AB" ]] && echo 1 || echo 0)"
check "(ab) pitch content unchanged" "1" "$([[ "$(cat "$TEST_PITCH_AB")" == "# test fixture pitch" ]] && echo 1 || echo 0)"

# ── (ac) assign: genuine distinct-file collision still refuses ────────────
WS_AC="$(make_ws ac)"
setup_fixture "$WS_AC"
TEST_SLUG_AC="codegen-drain-test-fixture-ac-$$"
TEST_PITCH_AC="$WS_AC/nodeA/codegen/pitches/ready/${TEST_SLUG_AC}.md"
printf '# already-there pitch\n' >"$WS_AC/nodeB/codegen/pitches/ready/${TEST_SLUG_AC}.md"
printf '# test fixture pitch\n' >"$TEST_PITCH_AC"
ec=0
out="$(CODEGEN_DRAIN_INVENTORY="$WS_AC/drain-nodes.yaml" "$DRAIN" assign --slug="$TEST_SLUG_AC" --node=nodeB --cwd="$WS_AC/nodeA" 2>&1)" || ec=$?
check "(ac) distinct-file collision still refuses" "1" "$ec"
assert_contains "(ac) names refusing / ambiguous" "$out" "refusing"
check "(ac) local copy is KEPT on refusal (no data loss)" "1" "$([[ -f "$TEST_PITCH_AC" ]] && echo 1 || echo 0)"

# ── health-verdict cases: a stub `ps` on PATH makes process state hermetic
# — the real box's own live claude/beam.smp processes must never leak into
# these assertions. make_stub_ps <rows...> writes a fake `ps` binary into a
# fresh dir and prints that dir (caller prepends it to PATH).
make_stub_ps() {
    local dir
    dir="$(mktemp -d)"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'printf "PID PPID ELAPSED COMMAND\\n"\n'
        local row
        for row in "$@"; do
            printf 'printf "%s\\n"\n' "$row"
        done
    } >"$dir/ps"
    chmod +x "$dir/ps"
    printf '%s' "$dir"
}

# ── (ad) status: no lock, no role process → health=idle ───────────────────
WS_AD="$(make_ws ad)"
setup_fixture "$WS_AD"
STUB_AD="$(make_stub_ps)"
ec=0
out="$(PATH="$STUB_AD:$PATH" CODEGEN_DRAIN_INVENTORY="$WS_AD/drain-nodes.yaml" "$DRAIN" status 2>&1)" || ec=$?
check "(ad) status exits 0" "0" "$ec"
assert_contains "(ad) nodeA shows health=idle" "$out" "health=idle"
rm -rf "$STUB_AD"

# ── (ae) --json carries health/head/dirty/builds keys ─────────────────────
WS_AE="$(make_ws ae)"
setup_fixture "$WS_AE"
STUB_AE="$(make_stub_ps)"
ec=0
out="$(PATH="$STUB_AE:$PATH" CODEGEN_DRAIN_INVENTORY="$WS_AE/drain-nodes.yaml" "$DRAIN" status --json 2>&1)" || ec=$?
check "(ae) status --json exits 0" "0" "$ec"
assert_contains "(ae) json has health key" "$out" '"health"'
assert_contains "(ae) json has head key" "$out" '"head"'
assert_contains "(ae) json has dirty key" "$out" '"dirty"'
assert_contains "(ae) json has builds key" "$out" '"builds"'
rm -rf "$STUB_AE"

# ── (af) additive-parity guard: all 6 pre-existing keys still present ─────
WS_AF="$(make_ws af)"
setup_fixture "$WS_AF"
STUB_AF="$(make_stub_ps)"
ec=0
out="$(PATH="$STUB_AF:$PATH" CODEGEN_DRAIN_INVENTORY="$WS_AF/drain-nodes.yaml" "$DRAIN" status --json 2>&1)" || ec=$?
check "(af) status --json exits 0" "0" "$ec"
assert_contains "(af) json has node key" "$out" '"node"'
assert_contains "(af) json has reachable key" "$out" '"reachable"'
assert_contains "(af) json has ready_count key" "$out" '"ready_count"'
assert_contains "(af) json has incoming_count key" "$out" '"incoming_count"'
assert_contains "(af) json has watcher key" "$out" '"watcher"'
assert_contains "(af) json has building_count key" "$out" '"building_count"'
rm -rf "$STUB_AF"

# ── (ag) no lock, no role process → health=idle (explicit fixture form) ───
WS_AG="$(make_ws ag)"
setup_fixture "$WS_AG"
STUB_AG="$(make_stub_ps)"
ec=0
out="$(PATH="$STUB_AG:$PATH" CODEGEN_DRAIN_INVENTORY="$WS_AG/drain-nodes.yaml" "$DRAIN" status 2>&1)" || ec=$?
check "(ag) status exits 0" "0" "$ec"
assert_contains "(ag) nodeA health=idle with no lock/process" "$out" "health=idle"
rm -rf "$STUB_AG"

# ── (ah) live queue lock + healthy-age stub process → health=working ──────
WS_AH="$(make_ws ah)"
setup_fixture "$WS_AH"
mkdir -p "$WS_AH/nodeA/codegen/gate-pending"
printf '%s queue tree=%s\n' "$$" "$$" >"$WS_AH/nodeA/codegen/gate-pending/queue.lock"
STUB_AH="$(make_stub_ps "88001 2000 60 claude")"
ec=0
out="$(PATH="$STUB_AH:$PATH" CODEGEN_DRAIN_INVENTORY="$WS_AH/drain-nodes.yaml" "$DRAIN" status 2>&1)" || ec=$?
check "(ah) status exits 0" "0" "$ec"
assert_contains "(ah) nodeA health=working" "$out" "health=working"
rm -rf "$STUB_AH"

# ── (ai) role process with ppid=1 (orphan) → health=wedged ────────────────
WS_AI="$(make_ws ai)"
setup_fixture "$WS_AI"
STUB_AI="$(make_stub_ps "88002 1 60 claude")"
ec=0
out="$(PATH="$STUB_AI:$PATH" CODEGEN_DRAIN_INVENTORY="$WS_AI/drain-nodes.yaml" "$DRAIN" status 2>&1)" || ec=$?
check "(ai) status exits 0" "0" "$ec"
assert_contains "(ai) nodeA health=wedged for orphaned process" "$out" "health=wedged"
assert_contains "(ai) build line marks ORPHANED" "$out" "ORPHANED"
rm -rf "$STUB_AI"

# ── (aj) role process over CODEGEN_DRAIN_ROLE_MAX_ETIME_SECS → wedged ─────
WS_AJ="$(make_ws aj)"
setup_fixture "$WS_AJ"
STUB_AJ="$(make_stub_ps "88003 2000 120 claude")"
ec=0
out="$(PATH="$STUB_AJ:$PATH" CODEGEN_DRAIN_ROLE_MAX_ETIME_SECS=60 CODEGEN_DRAIN_INVENTORY="$WS_AJ/drain-nodes.yaml" "$DRAIN" status 2>&1)" || ec=$?
check "(aj) status exits 0" "0" "$ec"
assert_contains "(aj) nodeA health=wedged when over etime threshold" "$out" "health=wedged"
rm -rf "$STUB_AJ"

# ── (ak) probe failure on a reachable node → health=unknown, never idle ───
WS_AK="$(make_ws ak)"
setup_fixture "$WS_AK"
STUB_AK_DIR="$(mktemp -d)"
cat >"$STUB_AK_DIR/ps" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$STUB_AK_DIR/ps"
cat >"$STUB_AK_DIR/git" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$STUB_AK_DIR/git"
cat >"$STUB_AK_DIR/stat" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$STUB_AK_DIR/stat"
cat >"$STUB_AK_DIR/ls" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$STUB_AK_DIR/ls"
ec=0
out="$(PATH="$STUB_AK_DIR:$PATH" CODEGEN_DRAIN_INVENTORY="$WS_AK/drain-nodes.yaml" "$DRAIN" status 2>&1)" || ec=$?
check "(ak) status exits 0" "0" "$ec"
assert_contains "(ak) nodeA health=unknown on probe failure" "$out" "health=unknown"
if [[ "$out" == *"health=idle"* ]]; then
    printf 'FAIL: (ak) probe failure must never render as health=idle\n'
    fail=$((fail + 1))
else
    pass=$((pass + 1))
fi
rm -rf "$STUB_AK_DIR"

echo ""
echo "Results: $pass passed, $fail failed"

if [[ "$fail" -gt 0 ]]; then
    exit 1
fi
exit 0
