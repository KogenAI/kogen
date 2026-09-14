#!/usr/bin/env python3
"""Exec one test-owned exact resume with an immutable managed launch context."""
import json
import os
import sys


def main():
    if len(sys.argv) < 3:
        raise SystemExit("usage: managed_resume.py CONTEXT ARGS...")
    context = json.loads(open(sys.argv[1], encoding="utf-8").read())
    if set(context) != {"executable", "args", "env"}:
        raise SystemExit("invalid managed launch context fields")
    if not isinstance(context["executable"], str) or not os.path.isabs(context["executable"]):
        raise SystemExit("invalid managed launch executable")
    if not isinstance(context["args"], list) or not all(isinstance(value, str) for value in context["args"]):
        raise SystemExit("invalid managed launch arguments")
    if not isinstance(context["env"], list):
        raise SystemExit("invalid managed launch environment")
    environment = os.environ.copy()
    # The outer lifecycle owns role authority. A retained context can have been
    # prepared before final role stamping (or by a different prior turn), so it
    # must not be allowed to turn a Shaper resume into a Developer invocation.
    outer_role = environment.get("KOGEN_ROLE")
    for entry in context["env"]:
        if (not isinstance(entry, list) or len(entry) != 2 or
                not isinstance(entry[0], str) or
                (entry[1] is not None and not isinstance(entry[1], str))):
            raise SystemExit("invalid managed launch environment entry")
        name, value = entry
        if value is None:
            environment.pop(name, None)
        else:
            environment[name] = value
    if outer_role is None:
        environment.pop("KOGEN_ROLE", None)
    else:
        environment["KOGEN_ROLE"] = outer_role
    executable = context["executable"]
    arguments = [executable, *context["args"], *sys.argv[2:]]
    os.execve(executable, arguments, environment)


if __name__ == "__main__":
    main()
