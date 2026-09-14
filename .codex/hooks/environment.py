#!/usr/bin/env python3
"""Restore ordinary shell-tool variables after native Codex starts hooks.

The managed launcher leaves CODEX_HOME in place.  It records caller HOME/XDG
values separately because Codex's shell environment policy did not restore hook
HOME in the isolation probe. Environment.prepare owns this marker contract;
hooks consume it here, while the immutable native executor snapshot consumes it
for ordinary shell tools.
"""
import os
import sys

XDG = ("XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME", "XDG_STATE_HOME")


def restore_environment(environ=None):
    env = os.environ if environ is None else environ
    if env.get("KOGEN_ENV_RESTORE_PENDING") != "1":
        return False

    env["HOME"] = env.get("KOGEN_CALLER_HOME", "")
    for name in XDG:
        caller_name = "KOGEN_CALLER_" + name
        if env.get(caller_name + "_ABSENT") == "1":
            env.pop(name, None)
        elif env.get(caller_name + "_EMPTY") == "1":
            env[name] = ""
        else:
            value = env.get(caller_name)
            if value is None:
                env.pop(name, None)
            else:
                env[name] = value
        env.pop(caller_name, None)
        env.pop(caller_name + "_ABSENT", None)
        env.pop(caller_name + "_EMPTY", None)

    env.pop("KOGEN_CALLER_HOME", None)
    env.pop("KOGEN_ENV_RESTORE_PENDING", None)
    return True


def main():
    if len(sys.argv) >= 3 and sys.argv[1] == "sh":
        restore_environment()
        os.execvpe("sh", ["sh", sys.argv[2]], os.environ)
    restore_environment()


if __name__ == "__main__":
    main()
