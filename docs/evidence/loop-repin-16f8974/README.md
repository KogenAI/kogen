# Re-pin kogen-loop to 16f8974

Synced with `sh packaging/sync-kogen-loop.sh` from a clean kogen-loop checkout at
16f89745ca6a93101b89ab8af7d20c3a85f65b69: 145 files, digest
5b18e5b0226b9c80bffad57e8d56597220f20ee8d862a7cfd09c49a01326f37e.

New since 38e08ea:
- 7433007: a failed write_file leaves the previous file intact (temporary sibling, renamed
  only on success); Direct.Request without a Session returns an error instead of panicking.
- 16f8974: each streaming attempt stops at 64 MiB of response body, counted over every byte;
  the overflowing read is not kept and the attempt fails with no partial output.

Tool descriptions are unchanged, so no recorded request bytes change.

The vendored copy is a protected path and changes only through the sync script.
