# Combobulate Transactional Email

Shows how Phoenix user app sends transactional email via Combobulate platform API. `UserNotifier` calls platform instead of Swoosh directly — user apps never hold mail credentials.

## UserNotifier pattern

```elixir
defmodule MyApp.Accounts.UserNotifier do
  @platform_url "https://app.combobulate.dev"
  @app_id "<YOUR_APP_ID>"       # substituted at build time
  @api_key "<YOUR_API_KEY>"     # substituted at build time

  def deliver_confirmation_instructions(user, url) do
    send_email(
      to: user.email,
      subject: "Confirm your account",
      html_body: "<p>Click <a href=\"#{url}\">here</a> to confirm.</p>",
      text_body: "Confirm your account: #{url}"
    )
  end

  defp send_email(opts) do
    Req.post!(
      "#{@platform_url}/api/email/#{@app_id}/send",
      json: Map.new(opts),
      headers: [{"Authorization", "Bearer #{@api_key}"}]
    )
    :ok
  end
end
```

## Request format

`POST https://app.combobulate.dev/api/email/:app_id/send`

Headers:

- `Authorization: Bearer <api_key>` — app's `api_key` from platform

Body (JSON):

```json
{
  "to": "user@example.com",
  "subject": "Subject line",
  "html_body": "<p>HTML content</p>",
  "text_body": "Plain text content"
}
```

`html_body` and `text_body` are both optional but at least one is required.

## Response codes

| Status | Meaning                                        |
| ------ | ---------------------------------------------- |
| 200    | Email sent successfully                        |
| 401    | Invalid or missing api_key                     |
| 422    | Missing required fields (to, subject, body)    |
| 429    | Rate limited (10 emails/minute per app per IP) |

## Where to find your api_key

`api_key` is auto-generated when app is created. Retrieve from `apps` table or expose through admin interface. Unique per app, stored in `api_key` column.

## From address

All emails sent from `noreply@mail.combobulate.dev`. Recipient sees this as sender — user apps cannot customize From address.
