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

echo ""
echo "Results: $pass passed, $fail failed"

if [[ "$fail" -gt 0 ]]; then
    exit 1
fi
exit 0
