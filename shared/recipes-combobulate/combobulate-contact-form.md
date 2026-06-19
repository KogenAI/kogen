# Recipe: Combobulate Contact Form

**When to use**: Build request asks for a contact form, "get in touch" section, enquiry form, "send us a message", feedback form, or any form where a visitor submits a message to the site owner.

**What it gives you**: An ordinary, unbranded HTML `<form>` with a vanilla-JS `fetch` POST handler wired to the Combobulate hosted forms endpoint. No combobulate logos, colors, or branding appear in the rendered output.

---

## Placeholder contract

The URL below contains the literal string `COMBOBULATE_APP_ID`. The platform patches this with the real app UUID after build — the same convention as `GUMROAD_PLACEHOLDER_URL`. Do NOT replace it yourself; emit it verbatim in the generated HTML/JS.

---

## Endpoint

```
POST https://app.combobulate.dev/api/forms/COMBOBULATE_APP_ID/<form_id>
Content-Type: application/json

{
  "name": "...",
  "email": "...",
  "message": "..."
}
```

- `COMBOBULATE_APP_ID` — literal placeholder, patched post-build.
- `<form_id>` — a slug you choose (e.g. `contact`, `enquiry`). Use a short, descriptive slug.
- Response: `200 { "ok": true }` on success; `4xx` with `{ "error": "..." }` on validation error.
- CORS: the server echoes `Origin` for allowed `*.combobulate.dev` subdomains — cross-origin fetch works from the static site.

---

## HTML + JS snippet

Emit this verbatim (substitute `contact` with your chosen `form_id` slug):

```html
<form id="contact-form" novalidate>
  <div>
    <label for="cf-name">Name</label>
    <input id="cf-name" name="name" type="text" required autocomplete="name" />
  </div>
  <div>
    <label for="cf-email">Email</label>
    <input
      id="cf-email"
      name="email"
      type="email"
      required
      autocomplete="email"
    />
  </div>
  <div>
    <label for="cf-message">Message</label>
    <textarea id="cf-message" name="message" required rows="5"></textarea>
  </div>
  <button type="submit">Send</button>
  <p id="cf-status" aria-live="polite" hidden></p>
</form>

<script>
  (function () {
    var form = document.getElementById("contact-form");
    var status = document.getElementById("cf-status");

    form.addEventListener("submit", function (e) {
      e.preventDefault();
      status.hidden = false;
      status.textContent = "Sending…";

      var data = {
        name: form.elements["name"].value.trim(),
        email: form.elements["email"].value.trim(),
        message: form.elements["message"].value.trim(),
      };

      fetch(
        "https://app.combobulate.dev/api/forms/COMBOBULATE_APP_ID/contact",
        {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(data),
        },
      )
        .then(function (res) {
          return res.ok
            ? res.json()
            : res.json().then(function (b) {
                throw new Error(b.error || "Submission failed");
              });
        })
        .then(function () {
          status.textContent = "Message sent. Thank you!";
          form.reset();
        })
        .catch(function (err) {
          status.textContent =
            err.message || "Something went wrong. Please try again.";
        });
    });
  })();
</script>
```

---

## Notes

- Adjust field names (`name`, `email`, `message`) to match the form's purpose.
- Style the form with the site's existing CSS — no combobulate-specific classes.
- The `form_id` slug (`contact` in the snippet) is arbitrary; keep it consistent across build and any future updates.
- The platform POST returns a 422 with `{ "error": "..." }` for validation failures; the JS surfaces the message in `#cf-status`.
