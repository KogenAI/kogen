# Third-Party API Verification

**Problem**: Integration code fails in production because the actual API behaves differently from its documentation.
**When**: Before writing any function that calls an external API — Namecheap, Stripe, Bunny, Cloudflare, or any other third-party service.
**See also**: none

## Solution

Test the raw API call locally first (IEx, curl, or a throwaway script), confirm the real endpoint, supported parameters, and response format — then write the integration code to match verified behavior.

```
❌ Write integration code → commit → discover in production it doesn't work
✅ Test the raw API call first → write code that matches verified behavior → commit
```

Concrete steps:

1. If credentials or a sandbox environment are required, set them up before writing any code.
2. Call the endpoint directly — e.g. `curl -X POST https://api.namecheap.com/...` or an IEx one-liner.
3. Confirm: correct endpoint URL, which parameters are actually supported, exact response shape (field names, types, error envelopes).
4. Only then write the Elixir integration module against the verified behavior.

## Gotchas

Third-party docs often lag behind the API. For example, the Namecheap or Bunny UI may expose features that the API does not yet support. Always verify against the live API, not documentation alone.
