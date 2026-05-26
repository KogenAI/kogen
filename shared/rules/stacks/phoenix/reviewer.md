# Reviewer — Phoenix

Phoenix-specific checks layered onto reviewer 15-step process.

## Per-Step Additions

- **5 Redundant Files**: also flag empty migrations
- **9 Type/Spec Duplication**: type 2+ times in `@spec` → `@type`. Test modules explicit `async: true/false`.
- **10 Cleanliness**: `assert.*!= nil` (use `assert .id`), `@spec` on `defp`
- **11 Stack Patterns**: verified routes `~p"/path/#{id}"`. Component attrs alphabetical.
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

reviewer-phoenix identifies + provides rule. developer-phoenix-backend applies.
