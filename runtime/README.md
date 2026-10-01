# Native custom runtime

`runtime/kh` is the bounded, production-only import of the pinned kh agent
runtime. It is the source target for both product and standalone consumers;
consumer adapters should call `Kh.Session` and avoid maintaining a second agent
loop. The current import is locally compilable and has an explicit offline
scripted provider. It is not evidence that every Kogen role has completed its
adapter cutover.

Start in [`kh/README.md`](kh/README.md) for the session API, evidence contract,
authentication boundary, build command and known limits. The source selection
and per-file hashes are recorded in [`kh/provenance.json`](kh/provenance.json).

The runtime keeps the c288d11 production base and its B011 parent-death Bash
custody. It applies the qualified B002/V13 continuation source, the B005
elapsed-accounting admission guard, and only the B004 max-effort mapping for
`gpt-6-luna`, `gpt-6-astra` and `gpt-6.1-sol`. The provisional V14
pre-`turn_start` checkpoint change and provider-specific CLI/backend trees are
not imported.
