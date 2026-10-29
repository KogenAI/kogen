# Re-pin kogen-loop to f942878

Synced with `sh packaging/sync-kogen-loop.sh` from a clean kogen-loop checkout at
f942878ac94b3c8d8f588b35a3a79b4c44aae8eb: 134 files, digest
ef1abd27836c17ad2aec065d247ccc1725f38b588840e94b1c017645fd142897.

New since b8a4046:
- c4308cb: removes allocation races in the gone-group test fixtures.
- 2136ebb: removes queued experimental levers that nothing set.
- 2dd4c9b: removes optional loop stopping bounds that nothing set.
- f942878: removes the climb option levers. Kogen stopped setting them when its internal
  research options were removed (d99584e).

The vendored copy is a protected path and changes only through the sync script.
