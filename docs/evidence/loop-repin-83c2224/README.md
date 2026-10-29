# Re-pin kogen-loop to 83c2224

Synced with `sh packaging/sync-kogen-loop.sh` from a clean kogen-loop checkout at
83c22247ebbe190ebd1793a762de95f07602c9d5: 137 files, digest
453ed625d763a876c24bbef66d8dbc9be91accd9fc2efeb26794f7afb01fdd95.

New since e1b160c:
- b97ee73: removes Tools.ShellTimeout and the shell-description sentence it added. Kogen
  stopped setting it when the tool_shell_timeout_seconds key was removed (cace62d).
- 83c2224: cancellation and deadlines reach a shell at every point of its start-up, SIGKILL
  escalation completes for a killed host's descendants, and every shell a run started is
  stopped when the run ends.

The vendored copy is a protected path and changes only through the sync script.
