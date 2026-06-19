# Recipes — Combobulate Hosted Services

Grep this file's trigger table with task keywords before writing a plan. Each recipe solves one problem; the filename answers "what problem does this solve?" The detailed entries below the table give full context — only read an entry after a grep hit.

## Trigger Table

| Keywords                                                                    | Recipe                        | Solution                                                                                                                        |
| --------------------------------------------------------------------------- | ----------------------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| contact form get-in-touch message enquiry send-message feedback reach-out   | combobulate-contact-form.md   | HTML form + vanilla-JS fetch POST to the Combobulate hosted forms endpoint; platform patches COMBOBULATE_APP_ID post-build.     |
| file upload drag-and-drop attachment document image upload-file user-upload | combobulate-file-upload.md    | Two-step presign→PUT→complete against the Combobulate hosted uploads endpoint; vanilla JS, unbranded.                           |
| paywall stripe subscription checkout buy purchase payment gated-content     | combobulate-stripe-paywall.md | POST to Combobulate hosted payments endpoint → redirect to Stripe Checkout URL; platform patches COMBOBULATE_APP_ID post-build. |
| powered-by credit link combobulate attribution footer branding              | combobulate-powered-by.md     | OPT-IN ONLY: footer "Powered by Combobulate" link — use ONLY on explicit operator request; NEVER by default.                    |

## Detailed Entries

### combobulate-contact-form.md

**When**: A build request asks for a contact form, enquiry form, "get in touch" section, or "send us a message" feature.
**What it gives you**: Ordinary unbranded HTML `<form>` with a vanilla-JS `fetch` POST to `https://app.combobulate.dev/api/forms/COMBOBULATE_APP_ID/<form_id>`. The platform patches `COMBOBULATE_APP_ID` with the real app UUID after build.
**Triggers**: contact form get-in-touch message enquiry send-message feedback reach-out

### combobulate-file-upload.md

**When**: A build request asks for file upload, attachment, document upload, or image upload functionality.
**What it gives you**: Two-step presign→PUT→complete flow: POST to presign endpoint, PUT file to the returned URL, POST to complete endpoint. Vanilla JS, zero combobulate branding.
**Triggers**: file upload drag-and-drop attachment document image upload-file user-upload

### combobulate-stripe-paywall.md

**When**: A build request asks for a paywall, subscription gate, checkout, "buy" button, or gated content behind a payment.
**What it gives you**: A "Buy" / "Subscribe" button that POSTs to `https://app.combobulate.dev/api/payments/COMBOBULATE_APP_ID/checkout` and redirects the browser to the returned Stripe Checkout URL. The platform patches `COMBOBULATE_APP_ID` post-build.
**Triggers**: paywall stripe subscription checkout buy purchase payment gated-content

### combobulate-powered-by.md

**When**: The operator EXPLICITLY requests a "powered by" link or attribution footer (e.g. "add a powered by link", "credit combobulate").
**What it gives you**: A footer line `Powered by <a href="https://combobulate.dev">Combobulate</a>` (HTML) and `Powered by [Combobulate](https://combobulate.dev)` (Markdown). NEVER apply by default.
**Triggers**: powered-by credit link combobulate attribution footer branding
