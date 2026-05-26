# Combobulate Contact Form

Use when user asks for contact form on static site (HTML, Hugo, React, Vue).

Platform hosts form endpoint — no backend code needed.

## Endpoint

```
POST https://app.combobulate.dev/api/forms/APP_ID/FORM_ID
```

- `APP_ID` — app's UUID (substitute real value, never leave as literal placeholder)
- `FORM_ID` — short identifier, e.g. `contact`, `quote-request`, `newsletter`
- Returns: `{"ok": true}` on success, `{"error": "..."}` on failure
- Rate limited: 10 submissions per minute per IP per app

## Pattern A — Inline fetch (show thank-you message without page reload)

```html
<form id="contact-form">
  <input name="name" placeholder="Your name" required />
  <input name="email" type="email" placeholder="Your email" required />
  <textarea name="message" placeholder="Your message" required></textarea>
  <button type="submit">Send message</button>
  <p id="form-status" style="display:none"></p>
</form>

<script>
  document
    .getElementById("contact-form")
    .addEventListener("submit", async function (e) {
      e.preventDefault();
      const form = e.target;
      const status = document.getElementById("form-status");
      const data = Object.fromEntries(new FormData(form));
      try {
        const res = await fetch(
          "https://app.combobulate.dev/api/forms/APP_ID/contact",
          {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify(data),
          },
        );
        if (res.ok) {
          form.style.display = "none";
          status.textContent = "Thanks! We'll be in touch soon.";
          status.style.display = "block";
        } else {
          status.textContent = "Something went wrong. Please try again.";
          status.style.display = "block";
        }
      } catch {
        status.textContent = "Something went wrong. Please try again.";
        status.style.display = "block";
      }
    });
</script>
```

## Pattern B — HTML form action (redirect to thank-you page)

```html
<form
  action="https://app.combobulate.dev/api/forms/APP_ID/contact"
  method="POST"
>
  <input name="name" placeholder="Your name" required />
  <input name="email" type="email" placeholder="Your email" required />
  <textarea name="message" placeholder="Your message" required></textarea>
  <button type="submit">Send message</button>
</form>
```

With this pattern, create a `thank-you.html` page and redirect there after submission, or let browser show JSON response.

## Important

- **Always substitute real app UUID** for `APP_ID` — never leave as literal placeholder
- Owner receives every submission as WhatsApp notification immediately
- Fields are flexible — add any `name` attributes needed (phone, subject, company, etc.)
- `email` field (if named exactly `email`) is extracted for filtering/export
