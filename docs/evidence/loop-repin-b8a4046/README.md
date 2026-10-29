# Re-pin kogen-loop to b8a4046

Synced with `sh packaging/sync-kogen-loop.sh` from a clean kogen-loop checkout at
b8a4046884d27786a8117e9c48b919d68883a4cf: 142 files, digest
fc6db702a6134f994357e4a2d983d305049822724e5d6c9697be7eb921e1d64a.

New since e5054c8:
- e8ac5fa: optional one-hour cache TTL; removed again by b8a4046.
- 48840cb: provider_attempt records stream timings (headers_ms, first_byte_ms, ttft_ms,
  last_byte_ms, max_gap_ms, gap_hist, stream_bytes, end_reason).
- b80fefb: idle-stream timeouts are the default. An attempt with no first byte within 90 s
  (ChatGPT) or 45 s (other providers), or silent for 180 s after the first byte, ends as a
  retryable transient failure with end_reason "idle".
- b8a4046: removes Request.AnthropicCacheTTL, Request.Budget, Direct.Policy and
  ContextPolicy, Round.StopAfterTerminal and SessionConfig.CacheID. Kogen set none of them.

The vendored copy is a protected path and changes only through the sync script.
