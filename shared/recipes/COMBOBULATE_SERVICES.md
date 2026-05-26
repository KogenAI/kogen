# Combobulate Platform Services

Conventions for integrating user apps with Combobulate platform services.

Services are split by app type — some work only on static sites, some only on Phoenix apps, some on both. Build agent discovers relevant recipes via `INDEX.md` keyword search.

## App Type Compatibility

| Service             | Static Sites | Phoenix Apps | Recipe                               |
| ------------------- | ------------ | ------------ | ------------------------------------ |
| Contact Form        | Yes          | No           | `combobulate-contact-form.md`        |
| File Upload         | Yes          | No           | `combobulate-file-upload.md`         |
| Transactional Email | No           | Yes          | `combobulate-transactional-email.md` |
| Magic Link Auth     | No           | Yes          | `combobulate-magic-link-auth.md`     |
| Stripe Payments     | JS only      | JS + Plug    | `combobulate-stripe-paywall.md`      |

**Static sites** use client-side JS to call platform API endpoints directly. No backend code, no Elixir — just `fetch()` calls with APP_ID in URL.

**Phoenix apps** follow the generator-first pattern below.

## Phoenix Apps: Generators First, Swap Integration Only

1. **Use `mix phx.gen.*`** to scaffold standard Phoenix patterns (auth, mailer, etc.)
2. **Swap only the integration point** — replace the module calling the external service with one calling the Combobulate platform API instead
3. **Embed `APP_ID` and `API_KEY` as module attributes** — system prompt contains the real values under `APP CREDENTIALS`; paste them directly, no credentials in config files or env vars

## APP_ID and API_KEY

Every app has:

- `APP_ID`: UUID (`apps.id` column) — identifies which app is calling
- `API_KEY`: Random 32-byte base64 string (`apps.api_key`) — authenticates the call

System prompt for every user-app build includes `APP CREDENTIALS` block with real values — copy into module attributes verbatim.

```elixir
@app_id "<real UUID from APP CREDENTIALS block>"
@api_key "<real api_key from APP CREDENTIALS block>"
```

## Available Services

### Contact Form (static sites only)

Hosted form endpoint — no backend code needed.

- **Recipe**: `combobulate-contact-form.md`
- **Endpoint**: `POST /api/forms/:app_id/:form_id`
- **Auth**: none (public endpoint, rate limited per IP)
- **Integration**: HTML form action or JS `fetch()` call

### File Upload (static sites only)

Presigned S3 PUT URL flow — visitor uploads directly to Hetzner Object Storage; platform records metadata and notifies owner via WhatsApp.

- **Recipe**: `combobulate-file-upload.md`
- **Endpoints**: `POST /api/uploads/:app_id/:form_id/presign`, `POST /api/uploads/:app_id/:form_id/complete`
- **Auth**: none (public endpoint, rate limited per IP — 20 presign requests per hour)
- **Limits**: 25 MB per file, 100 files per app, 5 GB total per app
- **Integration**: three-step JS flow (presign → PUT to S3 → complete)

### Transactional Email (Phoenix only)

Send email via platform — app never holds mail credentials.

- **Recipe**: `combobulate-transactional-email.md`
- **Endpoint**: `POST /api/email/:app_id/send`
- **Auth**: `Authorization: Bearer <api_key>`
- **Swap point**: `UserNotifier` (from `mix phx.gen.auth`)

### Magic Link Authentication (Phoenix only)

Passwordless login via email — platform manages tokens and issues JWTs.

- **Recipe**: `combobulate-magic-link-auth.md`
- **Endpoints**: `POST /api/auth/:app_id/request`, `GET /api/auth/:app_id/verify`, `GET /api/auth/:app_id/public_key`
- **Auth**: `Authorization: Bearer <api_key>` (request only; verify and public_key are public)
- **Swap point**: `UserNotifier` + add `FetchCurrentUser` plug for JWT verification

### Stripe Connect Payments (static sites + Phoenix)

Accept one-time payments — app owner connects their Stripe account via OAuth, platform handles checkout.

- **Recipe**: `combobulate-stripe-paywall.md`
- **Endpoints**: `GET /api/payments/:app_id/connect`, `POST /api/payments/:app_id/checkout`, `GET /api/payments/:app_id/status`, `POST /api/payments/:app_id/webhook`
- **Auth**: `Authorization: Bearer <api_key>` (checkout and status)
- **Static sites**: buy button JS pattern
- **Phoenix apps**: buy button JS + optional `PaymentGate` plug

## No Credentials in User Apps

User apps MUST NOT:

- Store SMTP credentials, Mailgun keys, or other mail provider credentials
- Store JWT signing keys (use platform's public key endpoint to verify)
- Store Stripe credentials (use platform payment endpoints when available)

Platform handles all credential management. User apps only need `APP_ID` and `API_KEY` — both provided in system prompt under `APP CREDENTIALS`.

## Request Patterns

### Phoenix apps (Elixir)

```elixir
Req.post!(
  "https://app.combobulate.dev/api/<service>/<app_id>/<action>",
  json: %{...},
  headers: [{"Authorization", "Bearer #{@api_key}"}]
)
```

### Static sites (JavaScript)

```javascript
fetch(`https://app.combobulate.dev/api/<service>/${APP_ID}/<action>`, {
  method: "POST",
  headers: {
    "Content-Type": "application/json",
    Authorization: `Bearer ${API_KEY}`,
  },
  body: JSON.stringify({ ... }),
});
```

Contact forms don't need `Authorization` — they are public endpoints.

## Error Handling

All platform service endpoints return a standard envelope built by `CombobulateWeb.APIResponse`:

```json
// Success
{"ok": true, "error": null, "message": null, "details": null, ...extra_fields}

// Failure
{"ok": false, "error": "not_found", "message": "app not found", "details": null}
```

- `ok` — boolean, always present
- `error` — stable atom code serialised as string (see table below), `null` on success
- `message` — human-readable description, `null` on success
- `details` — optional map with extra context (e.g. field names), `null` when absent
- Success responses merge endpoint-specific fields (e.g. `token`, `session_url`) at top level

### Stable Error Codes

| HTTP | `error` code                | Used by                                                                                                        |
| ---- | --------------------------- | -------------------------------------------------------------------------------------------------------------- |
| 400  | `validation_failed`         | auth verify missing token, payments status missing session_id, oauth missing code/state                        |
| 401  | `unauthorized`              | email send, payments checkout/status (401 masks 404 for enumeration safety)                                    |
| 401  | `invalid_token`             | auth verify — invalid, expired, or reused token                                                                |
| 402  | `no_stripe_connection`      | payments checkout — no connected Stripe account                                                                |
| 404  | `not_found`                 | auth request — unknown app, forms — unknown app, uploads presign/complete — unknown app or missing pending row |
| 422  | `validation_failed`         | email send missing fields, payments checkout missing/invalid fields                                            |
| 422  | `invalid_submission`        | forms — changeset error on insert                                                                              |
| 422  | `delivery_failed`           | email — Swoosh/Mailgun delivery error                                                                          |
| 409  | `quota_exceeded`            | uploads presign/complete — app file count or total storage limit exceeded                                      |
| 413  | `payload_too_large`         | uploads presign — requested file size exceeds 25 MB                                                            |
| 422  | `object_missing`            | uploads complete — blob not found in S3 after PUT                                                              |
| 422  | `size_exceeded`             | uploads complete — actual S3 size exceeds 25 MB                                                                |
| 429  | `rate_limited`              | email send, forms submit, uploads presign (20/hour per IP per app)                                             |
| 500  | `session_creation_failed`   | auth verify — JWT session creation failure                                                                     |
| 500  | `connection_save_failed`    | payments oauth callback — failed to persist conn                                                               |
| 502  | `oauth_exchange_failed`     | payments oauth callback — Stripe token exchange error                                                          |
| 502  | `checkout_failed`           | payments checkout — Stripe session creation error                                                              |
| 503  | `public_key_not_configured` | auth public_key — JWT signing key not set                                                                      |

### Client snippets

**JavaScript**

```javascript
const res = await fetch(url, { method: "POST", headers, body });
const data = await res.json();

if (!data.ok) {
  console.error(data.error, data.message);
  if (data.details) console.error("details:", data.details);
} else {
  // success — access top-level fields like data.token, data.session_url, etc.
}
```

**Elixir (Req)**

```elixir
case Req.post(url, json: body, headers: headers) do
  {:ok, %{status: 200, body: %{"ok" => true} = body}} ->
    {:ok, body}

  {:ok, %{body: %{"ok" => false, "error" => code, "message" => msg}}} ->
    {:error, code, msg}

  {:error, reason} ->
    {:error, "request_failed", inspect(reason)}
end
```

Status codes follow HTTP conventions: 200 success, 400 bad request, 401 unauthorized, 402 payment required, 404 not found, 422 unprocessable, 429 rate limited, 500/502/503 server errors.

## Platform Base URL

`https://app.combobulate.dev` — hardcode this in recipes, not configurable.
