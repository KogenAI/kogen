# Providers

This page compares every provider name that `kogen provider login` accepts. The names come from `cli/main.go`, and a Go test in `cli/` fails when a name is missing from the table.
A role is marked verified only when the same cell names a qualification record, a path in this repository that exists. Every other role is marked not qualified.
A qualification record is not a promise of access or availability; it names the exact evidence behind one role.

| Provider | Account or key needed | Roles verified | Built in or custom endpoint | Setup |
| --- | --- | --- | --- | --- |
| `chatgpt` | ChatGPT account, browser sign-in | Shape: verified (`spec/reference/model-family-qualification.md`); Build: verified (`spec/reference/model-family-qualification.md`); Review: verified (`spec/reference/model-family-qualification.md`) | Built in | [Sign in](getting-started.md#2-sign-in) |
| `supergrok` | SuperGrok subscription | Shape: not qualified; Build: not qualified; Review: not qualified | Built in | [Sign in](getting-started.md#2-sign-in) |
| `opencode-go` | OpenCode Go subscription | Shape: not qualified; Build: not qualified; Review: not qualified | Built in | [Sign in](getting-started.md#2-sign-in) |
| `anthropic` | Anthropic API key on stdin | Shape: not qualified; Build: not qualified; Review: verified (`spec/reference/model-family-qualification.md`) | Built in | [Sign in](getting-started.md#2-sign-in) |
| `claude-code` | Claude subscription, signed in through Kogen's pinned Claude Code | Shape: not qualified; Build: not qualified; Review: not qualified | Built in | [Sign in](getting-started.md#2-sign-in) |
| `openai-compatible` | Base URL and key of the host | Shape: not qualified; Build: not qualified; Review: not qualified | Custom endpoint | [openai-compatible](#openai-compatible) |

## openai-compatible

`openai-compatible` talks to a host you choose. Kogen has no qualification record for any compatible host, so every role of this provider is not qualified, whatever the host advertises.
Run `kogen provider login openai-compatible`, enter the base URL on line 1 and the key on line 2, then set the role in `.kogen/models.yaml` with `provider: openai-compatible`, a `base_url`, a `model` and an `effort`.
See [configuration.md](configuration.md) for the lineup file.

### QwenCloud

experimental: Build verified with Claude Review; Shape and Review not qualified

The label above is not a qualification record. No file in this repository records it, so the table keeps every role of `openai-compatible` as not qualified.

Setup:

1. Run `kogen provider login openai-compatible`.
2. Enter the base URL on line 1 and the key on line 2.
3. Add this line under `models:` in `.kogen/models.yaml`:

```yaml
build: {provider: openai-compatible, base_url: https://token-plan.maas.qwencloudapi.com/compatible-mode/v1, model: qwen4-max, effort: high}
```

The Singapore pay-as-you-go base URL is `https://ap-southeast-1.maas.qwencloudapi.com/compatible-mode/v1`.

Honesty note: Token Plan terms restrict automation and non-interactive batch use, so read them before you choose between a Token Plan and pay-as-you-go.
The Chat Completions route does not yet stream, so a reply arrives whole and the 45 seconds first-byte watchdog applies to the wait for it.
