# Hook Development Domain — Patterns & Pitfalls

Specialized domain for hook development, relocation, and porting learnings. Split from `context/hooks.md` to focus domain-specific anti-patterns.

## Hook Relocation & Porting

- **[shared] Diff-scanning hook scope independence — when widening diff source** — When relocating a hook from staged-only (`git diff --cached`) to working-tree (`git diff HEAD`) scope, preserve the file-extension scope (`.ex`/`.exs`) independently. Widening the diff SOURCE is orthogonal to narrowing the diff TARGET files. A hook that scans string-literal patterns in source diffs will false-positive on its OWN test-fixture files (`.sh`/`.ts` test scripts constructing the same literal text) if file-type scoping is dropped — self-referential blast radius, especially dangerous for hooks that develop/test themselves in the same repo they protect. Always gate content scans to target file type BEFORE pattern matching. **Fast diagnostic**: `git diff HEAD --name-only` cross-referenced against the hook's scoping predicate confirms whether the predicate (not detection logic) is the defect.

## Update When Changing

- Hook relocation + scope changes
- New enforcement patterns needing scope independence
