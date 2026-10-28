# Re-pin kogen-loop to e5054c8

Synced with `sh packaging/sync-kogen-loop.sh` from a clean kogen-loop checkout at
e5054c849478ddd0ed1bd2bc38f768f3cd7bd200: 136 files, digest
a93251d1f3c8a1692cc2c5cedb380afec6d8c09c72a68c8030cd54edb38ddbd4.

New since 4afed06, all library options that are off by default: Round.TerminalReminders
(1857100), Round.StopAfterTerminal (7468a4c), provider.Client.PrefixLog (59d1cfe),
SessionConfig.CacheID (f7b8f70), tools.Tools.CompactDescriptions (2ed6c54),
Round.ReadLedger (b9e36b4), tools.Tools.OmitViewImage (16f3507) and
provider.Request.ToolChoice (e5054c8). Kogen sets none of them in this commit; the
vendored copy is a protected path and changes only through the sync script.
