#!/usr/bin/env python3
"""PreToolUse guard for explicit Developer-owned verification commands.

This is intentionally a small lexical classifier, not a shell interpreter.
It handles only the command forms promised by the Approved Intent; commands
constructed indirectly remain a Developer-contract violation rather than a
runtime-sandbox guarantee.
"""
import json
import os
import pathlib
import sys

DIAGNOSTIC = (
    "Kogen machinery owns verification gates. This Developer request was blocked "
    "before dispatch; use focused non-gate tests instead."
)


def deny(reason=DIAGNOSTIC):
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": reason,
    }}))


def shell_words(command):
    """Split simple shell words and list operators without expansions."""
    words, current, commands = [], [], []
    quote = None
    escaped = False
    index = 0

    def finish_word():
        nonlocal current
        if current:
            words.append("".join(current))
            current = []

    def finish_command():
        finish_word()
        if words:
            commands.append(list(words))
            words.clear()

    while index < len(command):
        char = command[index]
        if escaped:
            current.append(char)
            escaped = False
        elif quote:
            if char == quote:
                quote = None
            elif char == "\\":
                escaped = True
            else:
                current.append(char)
        elif char in "'\"":
            quote = char
        elif char == "\\":
            escaped = True
        elif char.isspace():
            finish_word()
            if char == "\n":
                finish_command()
        elif char == ";" or char == "|":
            finish_command()
            if index + 1 < len(command) and command[index + 1] == char:
                index += 1
        elif char == "&" and index + 1 < len(command) and command[index + 1] == "&":
            finish_command()
            index += 1
        else:
            current.append(char)
        index += 1

    if quote or escaped:
        raise ValueError("could not tokenize Bash command")
    finish_command()
    return commands


def is_assignment(word):
    if "=" not in word or word.startswith("="):
        return False
    name = word.split("=", 1)[0]
    return name.replace("_", "a").isalnum() and not name[0].isdigit()


def is_make(word):
    return pathlib.PurePosixPath(word).name == "make"


def is_hook_path(word, root):
    try:
        return pathlib.Path(word).resolve() == root / ".codex/hooks/check.sh"
    except (OSError, ValueError):
        return False


def make_targets(args):
    targets = []
    index = 0
    takes_value = {
        "-C", "-f", "-I", "-o", "-W",
        "--directory", "--file", "--include-dir", "--old-file", "--what-if",
    }
    optional_jobs = {"-j", "--jobs"}
    while index < len(args):
        arg = args[index]
        if arg == "--":
            targets.extend(args[index + 1:])
            break
        if arg in takes_value:
            if index + 1 >= len(args):
                raise ValueError("Make option is missing its value")
            index += 2
            continue
        if arg in optional_jobs:
            if index + 1 < len(args) and args[index + 1].isdigit():
                index += 2
            else:
                index += 1
            continue
        if (
            arg.startswith("--directory=")
            or arg.startswith("--file=")
            or arg.startswith("--include-dir=")
            or arg.startswith("--old-file=")
            or arg.startswith("--what-if=")
            or arg.startswith("--jobs=")
        ):
            index += 1
            continue
        if arg.startswith("-C") or arg.startswith("-f") or arg.startswith("-I") or arg.startswith("-o") or arg.startswith("-W") or arg.startswith("-j"):
            index += 1
            continue
        if arg.startswith("-"):
            index += 1
            continue
        targets.append(arg)
        index += 1
    return targets


def prohibited(argv, targets, root):
    index = 0
    while index < len(argv) and is_assignment(argv[index]):
        index += 1
    if index >= len(argv):
        return False
    executable = argv[index]
    args = argv[index + 1:]
    if is_hook_path(executable, root):
        return True
    if pathlib.PurePosixPath(executable).name in {"sh", "bash", "zsh"}:
        return any(is_hook_path(arg, root) for arg in args)
    if is_make(executable):
        return any(goal in targets for goal in make_targets(args))
    return False


def policy_targets():
    raw = os.environ.get("KOGEN_VERIFICATION_TARGETS")
    if not raw:
        raise ValueError("required verification policy targets are missing")
    decoded = json.loads(raw)
    if (
        not isinstance(decoded, list)
        or not decoded
        or not all(isinstance(item, str) and item for item in decoded)
        or not {"check", "live"}.issubset(decoded)
    ):
        raise ValueError("required verification policy targets are invalid")
    return set(decoded)


def main():
    if os.environ.get("KOGEN_ROLE") != "developer":
        return
    try:
        event = json.load(sys.stdin)
        if not isinstance(event, dict):
            raise ValueError("hook input is invalid")
        if event.get("tool_name") != "Bash":
            return
        command = event.get("tool_input", {}).get("command")
        if not isinstance(command, str) or not command.strip():
            raise ValueError("Developer Bash command is missing or invalid")
        targets = policy_targets()
        root_value = os.environ.get("KOGEN_PROJECT_ROOT")
        if not root_value:
            raise ValueError("required verification policy project root is missing")
        root = pathlib.Path(root_value).resolve()
        if (
            not root.is_dir()
            or not (root / ".git").exists()
            or not (root / ".codex/hooks/check.sh").is_file()
        ):
            raise ValueError("required verification policy project root is invalid")
        if any(prohibited(argv, targets, root) for argv in shell_words(command)):
            deny()
    except Exception as error:
        deny(f"{DIAGNOSTIC} Policy error: {error}.")


if __name__ == "__main__":
    main()
