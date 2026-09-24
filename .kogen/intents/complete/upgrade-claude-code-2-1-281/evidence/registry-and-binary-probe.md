# Probe: Claude Code 2.1.281 artifacts (2026-09-24, Shaping)

Commands and results. Unauthenticated; no model calls; no personal credentials
were used; everything was scratch-only.

1. `curl https://registry.npmjs.org/@anthropic-ai/claude-code` returned the
   dist-tags `latest: 2.1.281`, `next: 2.1.281` and `stable: 2.1.273`.
   2.1.281 was published at 2026-09-23T17:01:17Z. The current pin, 2.1.280, was
   published at 2026-09-22T15:44:39Z. There is no 2.1.279.
2. Platform package metadata for 2.1.281:
   - darwin-arm64: https://registry.npmjs.org/@anthropic-ai/claude-code-darwin-arm64/-/claude-code-darwin-arm64-2.1.281.tgz sha512-rEI/YGBDX4YTfdq5w1B86NicoLgpFHGp4IrKM6sDrmUemruePSXF7ybICthHClIsRY8a/Kp7PQ6UJah1VWTbSA==
   - darwin-x64: https://registry.npmjs.org/@anthropic-ai/claude-code-darwin-x64/-/claude-code-darwin-x64-2.1.281.tgz sha512-nGJBmWAMlyHAlf0i/vwBzjvTfEC86KcGZT4VNlpInL03jufnBztZr8+ILcXcwg5h94McpmvI/tu8lgHJtHKLVQ==
3. I downloaded the arm64 tarball directly from registry.npmjs.org. The local
   check `openssl dgst -sha512 -binary | base64` gave
   `sha512-rEI/YGBDX4YTfdq5w1B86NicoLgpFHGp4IrKM6sDrmUemruePSXF7ybICthHClIsRY8a/Kp7PQ6UJah1VWTbSA==`,
   which equals the registry integrity. I did not download the x64 tarball.
4. I ran `package/claude --version` under `env -i` with a scratch HOME and
   `DISABLE_AUTOUPDATER=1`. Output: `2.1.281 (Claude Code)`.
5. `--help` still lists every flag Kogen launches with:
   --dangerously-skip-permissions, --setting-sources, --agents, --disallowedTools,
   --json-schema, --session-id, --resume, --output-format, --effort and --model.

Limitations: step 5 shows that the flags are listed. It does not show that they
behave the same way. The Build's paid targets must prove semantics. The personal
`claude` on PATH is also 2.1.281, but it was not used for any claim here.

Changelog items relevant to Kogen, from 2.1.281:
- Resume replay fixes: no changed re-sends, large-session restore, a tool-call
  outcome reported as "unknown", and no hidden "Continue" message on manual
  resume.
- Prompt-cache retention fixes, and `--max-turns` is now honored in the
  unparseable-tool-call loop.
- A recursive `rm` on command-substitution output now prompts even under
  --dangerously-skip-permissions. The opt-out is
  `CLAUDE_CODE_DISABLE_SUBSTITUTION_RM_PROMPT=1`.
- `--setting-sources` is now forwarded to spawned sessions (teammates, /bg,
  agents). Kogen already passes it.
- `-p` sessions no longer fail after their start directory is deleted.
No Opus-specific speed change is listed.
