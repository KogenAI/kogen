#!/usr/bin/env bash
# scaffold_args_test.sh — hermetic tests for `--` phx.new flag passthrough.
#
# Covers:
#  1. codegen-scaffold's denylist rejection (parse-time, before any mix work)
#  2. codegen-scaffold's empty-tail no-op (proceeds past parsing)
#  3. scaffold.sh's -- tail forwarding into PHX_NEW_FLAGS (mix stubbed on PATH)
#  4. scaffold.sh's --database capture drives the correct .env DB var
#
# No real `mix phx.new` invocation — mix is stubbed on PATH for cases 3-4 to
# keep this hermetic and fast (see run-tests.sh: this file runs under `make test`).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CODEGEN_SCAFFOLD="$REPO_ROOT/codegen-scaffold"
SCAFFOLD_SH="$SCRIPT_DIR/scaffold.sh"
EEX_RENDER="$SCRIPT_DIR/eex_render.sh"

passed=0
failed=0
fail_lines=()

assert() {
    local label="$1" cond="$2"
    if eval "$cond"; then
        passed=$((passed + 1))
    else
        failed=$((failed + 1))
        fail_lines+=("FAIL: $label")
    fi
}

# ── Case 1: denylist rejects known-breaking flags at parse time, exit 2 ──────
for pair in \
    "--app foo|derived from --slug" \
    "--module Foo|derived from --slug" \
    "--umbrella|umbrella layout" \
    "--no-agents-md|codegen owns AGENTS.md" \
    "--no-html|HTML/LiveView scaffolding" \
    "--no-live|HTML/LiveView scaffolding" \
    "--no-assets|tailwind/esbuild" \
    "--no-esbuild|wires esbuild" \
    "--no-tailwind|wires tailwind"; do
    flag="${pair%%|*}"
    expect_substr="${pair#*|}"
    # shellcheck disable=SC2086
    out="$("$CODEGEN_SCAFFOLD" create --stack=phoenix --cwd=/tmp/scaffold-args-test-nonexistent --slug=probe -- $flag 2>&1)"
    rc=$?
    assert "denylist '$flag' exits 2" '[ "$rc" -eq 2 ]'
    assert "denylist '$flag' names the reason" 'echo "$out" | grep -qF "$expect_substr"'
done

# ── Case 2: empty tail (`--` with nothing after) proceeds past parsing ───────
# Failure here must come from the missing --cwd dir, never from the tail parser.
out2="$("$CODEGEN_SCAFFOLD" create --stack=phoenix --cwd=/tmp/scaffold-args-test-nonexistent --slug=probe -- 2>&1)"
rc2=$?
assert "empty tail: not a parse-time denylist rejection (rc != 2)" '[ "$rc2" -ne 2 ]'

# ── Case 2b: --no-ecto + -- --database <db> conflict is rejected at parse time ──
# phx.new generates ecto-repo migrator code (skip_migrations?/0) whenever
# --database is present, REGARDLESS of --no-ecto — this combination fails the
# generated app's own `make ci` gate (credo unused-parens), so codegen refuses
# it up front instead of letting the operator hit a confusing scaffold-time error.
out2b="$("$CODEGEN_SCAFFOLD" create --stack=phoenix --cwd=/tmp/scaffold-args-test-nonexistent --slug=probe --no-ecto -- --database sqlite3 2>&1)"
rc2b=$?
assert "--no-ecto + --database conflict exits 2" '[ "$rc2b" -eq 2 ]'
assert "--no-ecto + --database conflict names both flags" 'echo "$out2b" | grep -qF "no-ecto" && echo "$out2b" | grep -qF "sqlite3"'

# ── Case 3: scaffold.sh forwards -- tail into the mix phx.new invocation ─────
# Stub `mix` on PATH: capture argv, never actually scaffold anything.
STUB_BIN="$(mktemp -d "${TMPDIR:-/tmp}/scaffold-args-stub-XXXXXX")"
CAPTURE_FILE="$(mktemp "${TMPDIR:-/tmp}/scaffold-args-capture-XXXXXX")"
cat >"$STUB_BIN/mix" <<STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$CAPTURE_FILE"
exit 1
STUBEOF
chmod +x "$STUB_BIN/mix"

TARGET_DIR="$(mktemp -d "${TMPDIR:-/tmp}/scaffold-args-target-XXXXXX")/fixture_app"
PATH="$STUB_BIN:$PATH" "$SCAFFOLD_SH" fixture_app "$TARGET_DIR" \
    --elixir-version 1.19.5 --node-version 24.14.0 --otp-version 28.4.1 \
    -- --database sqlite3 --binary-id >/dev/null 2>&1
captured="$(cat "$CAPTURE_FILE" 2>/dev/null || true)"
assert "scaffold.sh forwards --database sqlite3 to mix phx.new" 'echo "$captured" | grep -qF "database"'
assert "scaffold.sh forwards --database sqlite3 value" 'echo "$captured" | grep -qF "sqlite3"'
assert "scaffold.sh passthrough appended after codegen defaults (--binary-id still present)" 'echo "$captured" | grep -qF "binary-id"'
rm -rf "$STUB_BIN" "$CAPTURE_FILE" "$(dirname "$TARGET_DIR")"

# ── Case 4: --database sqlite3 renders DATABASE_PATH; default renders DATABASE_URL ─
tmp4="$(mktemp -d "${TMPDIR:-/tmp}/scaffold-args-env-XXXXXX")"
"$EEX_RENDER" "$SCRIPT_DIR/templates/.env.eex" "$tmp4/.env.postgres" \
    app_name=myapp secret_key_base=SECRET \
    "db_env_line_dev=DATABASE_URL=ecto://postgres:postgres@localhost/myapp_dev" >/dev/null
assert "default adapter .env has DATABASE_URL" 'grep -qF "DATABASE_URL=ecto://postgres" "$tmp4/.env.postgres"'
assert "default adapter .env has no DATABASE_PATH" '! grep -qF "DATABASE_PATH" "$tmp4/.env.postgres"'

"$EEX_RENDER" "$SCRIPT_DIR/templates/.env.eex" "$tmp4/.env.sqlite3" \
    app_name=myapp secret_key_base=SECRET \
    "db_env_line_dev=DATABASE_PATH=myapp_dev.db" >/dev/null
assert "sqlite3 adapter .env has DATABASE_PATH" 'grep -qF "DATABASE_PATH=myapp_dev.db" "$tmp4/.env.sqlite3"'
assert "sqlite3 adapter .env has no DATABASE_URL" '! grep -qF "DATABASE_URL" "$tmp4/.env.sqlite3"'
rm -rf "$tmp4"

echo "$passed passed, $failed failed"
if [ "$failed" -gt 0 ]; then
    printf '%s\n' "${fail_lines[@]}" >&2
    exit 1
fi
