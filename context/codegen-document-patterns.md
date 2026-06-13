# Codegen-Document Implementation Patterns

Implementation patterns and data structures used in `codegen-document` script for dependency documentation generation.

## Record Format and Parsing

`extract_dependencies` emits pipe-delimited records that carry git coordinates alongside version info:

```
dep_name:version|repo_url|tree_ref
```

- **Colon-delimited head** (`dep_name:version`) — parsed by `cut -d:` at four sites (main pass1, pass2, count loop, single-dep mode). Colon separator is stable across usage.
- **Pipe-delimited tail** (`|repo_url|tree_ref`) — optional, present only for git deps. Hex deps have no tail (empty tail fields safe for nil-guards).

**Parsing coordination**: Chain cuts when extracting intermediate fields:

- `cut -d: -f2 | cut -d'|' -f1` extracts version only (strips pipe tail).
- `cut -d: -f2 | cut -d'|' -f2` extracts repo_url (second pipe-delimited field).

## Function Signature: Backward-Compatible Record Passing

`generate_usage_rule` accepts an optional third parameter (`$3`) containing the full record; single-dep mode must construct it explicitly:

```bash
dep_record="${dep_arg}:${dep_version}|${dep_repo_url}|${dep_tree_ref}"
generate_usage_rule "$hex_url_stub" "$output_dir" "$dep_record"
```

Backward compatibility: calling without `$3` (hex deps) is safe; no git coordinates are parsed. This keeps the function signature flexible as dispatch logic evolves.

## Pass Distinction: Full Records vs. Stripped Head

- **Pass 1** (`usage_rule_needs_update` check) — only needs `dep_name:version` to test freshness. Strips pipe tail at this site because the full record is not yet needed.
- **Pass 2** (rule generation loop) — passes full record directly as `$3` to `generate_usage_rule`. This is the definitive invocation where git coordinates matter.

**Single-dep mode**: Constructs full record from inputs (`$dep_arg`, `$dep_version`, `$dep_repo_url`, `$dep_tree_ref`) before calling `generate_usage_rule`, matching the pass 2 behavior.

## URL Priority Logic

`generate_usage_rule` applies three-tier branching:

1. **Git fork primary** — if `repo_url` non-empty, fetch from GitHub tree URL at locked commit.
2. **Hex versioned docs fallback** — if no git coords, use version-format regex to route to `hexdocs.pm/${dep_name}/${version}`.
3. **Hex latest fallback** — if neither condition met, use latest hexdocs.

The fork check MUST come first so that tag deps (e.g., `2.2.0`) routing via GitHub tree are not shadowed by version-format regex matching.

## Trigger Keywords

codegen-document, record format, generate_usage_rule, extract_dependencies, git fork, hex fallback, pipe-delimited, backward-compatible
