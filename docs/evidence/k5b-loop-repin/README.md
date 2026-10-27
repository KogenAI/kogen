# Re-pin of the vendored kogen-loop to 2ea31bf5

`cli/third_party/kogen-loop` is now the clean kogen-loop commit
`2ea31bf5438f0bdde537848f678a7331c5fe2a2a` ("Sweep command groups and refuse foreign kills"
and "Retry transient provider stream faults"), replacing `33e7f4ec`. Written only by
`sh packaging/sync-kogen-loop.sh`; `cli/loop-pin.json` records 111 files and digest
`0f2daaefc9f0c6c22851dc29df1f774a7d8c863261200eac16e1489435cecec1`.

Kogen's probes set `KillGroupOnExit` and `RefuseForeignKill`; other Kogen-run commands set
only `KillGroupOnExit`. No timeout default was added. Older notes, including
`docs/evidence/k5-loop-repin/`, are unchanged.
