# Per-project role configuration

Custom role settings belong to the target project's `.kogen/config.yaml`.
`Kogen.RoleConfig` resolves a named configuration and freezes its five role
profiles, exact prompt bytes, prompt digests, raw configuration digest, project
identity, and effective fingerprint. Admission and resume code should persist
and validate that frozen JSON-safe map; editing the live YAML or prompt files
must not change a frozen run.

This leaf validates local files and pinned model/effort support. It does not
dispatch a role, inspect credentials, contact a provider, or implement a full
custom adapter. The controller still owns explicit approval, project checks,
independent Review, isolation, and publication safeguards.

If `.kogen/config.yaml` is absent, resolution uses the engine-owned `default`
configuration. Its profiles are shaping and developer on `gpt-6-luna` at
`medium`, then reviewer, auditor, and expert on `gpt-6.1-sol` at `high`. All
profiles use `context: full`; shaping and developer receive `read`, `write`,
`edit`, and `bash`, while reviewer, auditor, and expert receive only `read` and
`bash`. Each default prompt identity names its same-named engine prompt under
`priv/kogen/custom/prompts/`.

When a project file is present, it must use this strict top-level shape. Every
configuration defines all five retained roles, with no inherited role
profiles. The accepted source grammar is deliberately small: ignore blank and
comment-only lines; use plain, unquoted keys immediately followed by a colon;
indent top-level keys at column 0, configuration names at 2 spaces, roles at 4,
and profile fields at 6. Keys match `[A-Za-z_][A-Za-z0-9_-]*`, with no spaces
before the colon. A scalar is one plain token matching
`[A-Za-z0-9][A-Za-z0-9._:/#-]*` or a one-line, single/double-quoted YAML
scalar. The colon is followed by one or more spaces or tabs and a scalar, or
nothing for a mapping. `runtime` and `default_configuration` take one scalar;
`configurations`, configuration names, and role names open block mappings with
no inline value. Profile fields take one scalar, except `tools`, which uses an
inline list of plain tool names matching `[A-Za-z][A-Za-z0-9_-]*`, such as
`[read, bash]`. No other nonblank line form is accepted. Comments are
recognized outside quoted scalar values, so `#` inside a quoted prompt path is
kept as part of that value.

Flow mappings, block lists, quoted or escaped mapping keys, spaces before a
mapping colon, YAML anchors, aliases, tags, explicit mapping keys, document
markers, and duplicate mapping keys are refused before parsing. This prevents
the YAML library's first-value handling from hiding a later contradictory key.

```yaml
runtime: custom
default_configuration: default
configurations:
  default:
    shaping:
      model: gpt-6-luna
      effort: medium
      prompt: shaping
      tools: [read, write, edit, bash]
      context: full
    developer:
      model: gpt-6-luna
      effort: medium
      prompt: developer
      tools: [read, write, edit, bash]
      context: full
    reviewer:
      model: gpt-6.1-sol
      effort: high
      prompt: reviewer
      tools: [read, bash]
      context: full
    auditor:
      model: gpt-6.1-sol
      effort: high
      prompt: auditor
      tools: [read, bash]
      context: full
    expert:
      model: gpt-6.1-sol
      effort: high
      prompt: expert
      tools: [read, bash]
      context: full
```

The `prompt` field accepts one of the five engine identities (`shaping`,
`developer`, `reviewer`, `auditor`, `expert`) or an explicit project-relative
Markdown path such as `project:prompts/reviewer.md`. Project overrides resolve
from the canonical project root. Absolute paths, traversal, symbolic links,
missing files, and non-regular files are refused. The exact bytes are copied
into the frozen map before dispatch.

Allowed tools are `read`, `write`, `edit`, and `bash`. Reviewer, Auditor, and
Expert profiles are restricted to `read` and `bash`; Shaping and Developer may
use all four. `context: full` is the only supported context profile in this
initial slice. Unknown keys, policy-disable settings, credential fields or
credential-shaped values, malformed YAML, incomplete roles, unsupported model
and effort pairs, and unsafe paths fail resolution before dispatch.

Model/effort validation mirrors the custom ChatGPT adapter in pinned kh source
`c288d11`. This slice accepts `gpt-6-luna`, `gpt-6.1-sol`, and `gpt-6-astra`
with `low`, `medium`, `high`, or `xhigh`. It refuses other kh model-table
entries because those require a different provider. The ChatGPT adapter does
not support `max`; although the separate OpenCode Go model table lists Luna at
`max`, that is not a supported custom ChatGPT dispatch setting here. Thus
`gpt-6.1-sol`/`high` is accepted and `gpt-6-luna`/`max` is refused until the
runtime has a matching dispatch path. Validation uses this local pinned table;
it performs no model or provider lookup.

To select an experiment without changing the project default, add a second
complete named profile and resolve it explicitly, for example:

```yaml
  luna-max:
    shaping:
      model: gpt-6-luna
      effort: max
      prompt: shaping
      tools: [read, write, edit, bash]
      context: full
    # developer, reviewer, auditor, and expert are also required here.
```

The role-config API and its tests are an integration leaf. No claim of full
runtime, provider, lifecycle, or input parity follows from this module alone.
