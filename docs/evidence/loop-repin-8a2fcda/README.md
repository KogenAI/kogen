# Re-pin kogen-loop to 8a2fcda

Synced with `sh packaging/sync-kogen-loop.sh` from a clean kogen-loop checkout at
8a2fcdaefb6b6d40308c88da83b5d18cebd686ad: 149 files, digest
89467b8bf5e737e3c9edcb9f8888f277dc4662c6e1e8f7b74e3fa40bdc2666f3.

New since 16f8974:
- b4a4185: the process-group keeper no longer counts its own ps process as a member of the
  group it inspects, so leftover-group checks pass on macOS.
- 8a2fcda: a provider attempt that sends only keep-alive bytes now ends at the existing idle
  limit; only real response progress renews the first-response and idle timers.

The vendored copy is a protected path and changes only through the sync script.
