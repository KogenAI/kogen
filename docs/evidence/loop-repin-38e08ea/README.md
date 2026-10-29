# Re-pin kogen-loop to 38e08ea

Synced with `sh packaging/sync-kogen-loop.sh` from a clean kogen-loop checkout at
38e08ea37eaa566bd1491129532c3a1cb64b5551: 143 files, digest
693709cde1118f35516c368767ffee1baa099dcdda98b318cdfc28b0bfbb49dc.

New since 83c2224:
- c6e67a5: a saved openai-compatible key is bound to the origin it was saved for and sent only
  there; `Client.LoginWithBaseURL` saves it with its origin. Kogen's login for that provider
  changes in the same landing (K-CRED-ORIGIN).
- c4920e9: read_file and every caller-named read stay inside the tool root.
- 38e08ea: refusal-only answers are reported as refusals; duplicate tool call IDs are rejected;
  failure diagnostics, usage and response identity are kept.

The vendored copy is a protected path and changes only through the sync script.
