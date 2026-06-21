# Reviewer — Phoenix

Phoenix-specific checks layered onto reviewer 15-step process.

## Per-Step Additions

- **5 Redundant Files**: also flag empty migrations
- **9 Type/Spec Duplication**: type 2+ times in `@spec` → `@type`. Test modules explicit `async: true/false`.
- **10 Cleanliness**: `assert.*!= nil` (use `assert .id`), `@spec` on `defp`
- **11 Stack Patterns**: verified routes `~p"/path/#{id}"`. Component attrs alphabetical.
- **11 LiveView Correctness** (changed `.heex` / `*_live.ex`):
  1. **Form events** — `phx-change`, `phx-submit`, `phx-keyup`/`phx-keydown` INTENDED as form input: require a `<.form>`/`<form>` ancestor. Carve-out: bare `phx-keyup`+`phx-key` (deliberate keystroke binding outside a form) is LEGITIMATE — flag intent-mismatch, not mere ancestor absence.
  2. **Child LiveView nesting** — `live_render` of a child LiveView without `layout: false` causes double-layout render; flag if absent.
  3. **Autofocus** — keyboard-first overlay/modal input with no `phx-mounted={JS.focus()}` or `mounted()` hook; flag if absent.
  4. **Cursor** — interactive element (`<.link>`, `phx-click` row, button-styled `<div>`) without `cursor-pointer` (Tailwind preflight resets to `cursor: default`); flag if absent.
  5. **Handler wiring** — every `phx-click`/`phx-submit`/`phx-change`/`phx-keyup` handler has a LiveView test that drives the REAL rendered element (`element("#id") |> render_*`) and asserts a SIDE EFFECT (not just the rendered label); a handler with no such test, or a test that asserts only `render(view) =~ "…"`, is a blocking review issue.
- **13 Masking Defaults**: Flag masking defaults (required value + sentinel fallback) per `_core/fail-fast-required-values.md`. Apply the 3-part test: required? sentinel papers over absence? proceeds wrong silently? All three → blocking issue. The related error-swallowing rule is the no-defensive-code discipline (also loaded for this role).
- **14 Deployment**: GitHub workflows edit `.github/github_workflows.ex` → `mix github_workflows.generate`. Never `.yml` directly.
- **15 Translation**: empty `msgstr ""` in `en/*.po` is CORRECT (Gettext fallback). Flag only non-English locales.

## ast-grep Example

```bash
grep -r "conn = conn |>" test/ --include="*.exs" | wc -l
ast-grep --pattern 'conn = conn |> $METHOD($$$PARAMS)' test/
cat > /tmp/rule.yml << 'EOF'
id: standardize-conn-pipes
language: elixir
rule:
  pattern: conn = conn |> $METHOD($$$PARAMS)
fix: |
  conn |> $METHOD($$$PARAMS)
EOF
ast-grep --config /tmp/rule.yml test/ --dry-run
ast-grep --config /tmp/rule.yml test/ --update-all
git diff --stat
```

reviewer-phoenix identifies + provides rule. Route fixes to the correct subagent: `lib/<app>_web/` (LiveView `*_live.ex`, HEEx, JS hooks) → developer-phoenix-frontend; `lib/<app>/` (contexts, schemas, workers) → developer-phoenix-backend.
