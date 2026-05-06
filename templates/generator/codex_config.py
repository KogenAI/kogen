#!/usr/bin/env python3
"""Render Codex config.toml.

Single source of truth for the [features] / [agents] / [[hooks.<event>]]
block sequence emitted by both:

  - templates/generator/generate-codex.sh (global ~/.codex/config.toml)
  - Combobulate.Apps.do_provision_codex_artifacts/1 (per-app .codex/config.toml)

Stdlib only — no PyYAML, no tomli_w. Plain string templating.

Usage:
    codex_config.py --target {app|global} \\
        --hook EVENT:COMMAND [--hook EVENT:COMMAND ...] \\
        [--out PATH]

If --out is omitted, output is written to stdout.
"""

import argparse
import sys

ALLOWED_EVENTS = {"PreToolUse"}
ALLOWED_TARGETS = {"app", "global"}


def parse_hook(spec):
    """Parse 'EVENT:COMMAND' into (event, command).

    The command may itself contain colons (e.g. 'PreToolUse:$HOME/.codex/...'),
    so we split on the first colon only.
    """
    if ":" not in spec:
        raise ValueError(
            "invalid --hook value %r: expected 'EVENT:COMMAND'" % spec
        )
    event, command = spec.split(":", 1)
    if event not in ALLOWED_EVENTS:
        raise ValueError(
            "unsupported hook event %r (allowed: %s)"
            % (event, ", ".join(sorted(ALLOWED_EVENTS)))
        )
    if not command:
        raise ValueError("empty command in --hook %r" % spec)
    return event, command


def render(target, hooks):
    """Return the canonical config.toml text for the given hooks list.

    `target` is currently informational — both per-app and global outputs
    share the same canonical layout. The argument exists so future
    target-specific tweaks (e.g. an [agents] override) have a hook point
    without changing every call site.
    """
    if target not in ALLOWED_TARGETS:
        raise ValueError(
            "invalid --target %r (allowed: %s)"
            % (target, ", ".join(sorted(ALLOWED_TARGETS)))
        )

    lines = []
    lines.append("[features]")
    lines.append("codex_hooks = true")
    lines.append("")
    lines.append("[agents]")
    lines.append("max_depth = 5")
    lines.append("max_threads = 6")
    lines.append("")
    # Bucket hooks by event so each event gets one inline-table-array entry.
    # Codex's TOML parser preserves `PreToolUse = [...]` across operator hand-
    # edits; the older `[[hooks.PreToolUse]]` array-of-tables form was rewritten
    # on every provision, fighting hand-edits.
    by_event = {}
    for event, command in hooks:
        by_event.setdefault(event, []).append(command)

    if by_event:
        lines.append("[hooks]")
        for event, commands in by_event.items():
            lines.append("%s = [" % event)
            for command in commands:
                lines.append('    { command = "%s" },' % command)
            lines.append("]")
        lines.append("")
    return "\n".join(lines)


def main(argv=None):
    parser = argparse.ArgumentParser(description="Render Codex config.toml")
    parser.add_argument("--target", required=True, choices=sorted(ALLOWED_TARGETS))
    parser.add_argument(
        "--hook",
        action="append",
        default=[],
        metavar="EVENT:COMMAND",
        help="repeatable; e.g. --hook PreToolUse:/path/to/hook.sh",
    )
    parser.add_argument(
        "--out",
        default=None,
        metavar="PATH",
        help="output file path (default: stdout)",
    )
    args = parser.parse_args(argv)

    hooks = [parse_hook(h) for h in args.hook]
    output = render(args.target, hooks)

    if args.out is None:
        sys.stdout.write(output)
    else:
        with open(args.out, "w") as f:
            f.write(output)

    return 0


if __name__ == "__main__":
    sys.exit(main())
