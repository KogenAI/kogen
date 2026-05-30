# Rule File Organization

One file, one concern. Line caps per STYLE_GUIDE.md: shared rules <50 lines, subagent/orchestration rules <150 lines.

New rule → (1) update `shared/rules/INDEX.md` § Folder Layout, (2) follow `shared/rules/STYLE_GUIDE.md`.

Rules baked at install via Jinja include. After editing any rule OR adding an include: run `make install` or baked agent prompts go stale.

Include path is relative to `shared/`: e.g. `rules/shared/foo.md` resolves to `shared/rules/shared/foo.md`.

Recency-bias: reference/framework knowledge TOP, hard must-follow rules BOTTOM.

❌ absolute-style path: `{pct include 'shared/rules/shared/foo.md' pct}`
✅ relative path: `{pct include 'rules/shared/foo.md' pct}`
