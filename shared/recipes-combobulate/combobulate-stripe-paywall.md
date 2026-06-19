# Recipe: Combobulate Stripe Paywall

**When to use**: Build request asks for a paywall, subscription gate, "buy" button, checkout page, gated content, or any feature where a visitor must pay before accessing something.

**What it gives you**: A "Buy" or "Subscribe" button that POSTs to the Combobulate hosted payments endpoint and redirects the browser to the Stripe-hosted Checkout page. No combobulate logos or branding appear in the rendered output.

---

## Placeholder contract

The URL below contains the literal string `COMBOBULATE_APP_ID`. The platform patches this with the real app UUID after build — the same convention as `GUMROAD_PLACEHOLDER_URL`. Do NOT replace it yourself; emit it verbatim in the generated HTML/JS.

---

## Endpoint

```
POST https://app.combobulate.dev/api/payments/COMBOBULATE_APP_ID/checkout
Content-Type: application/json
{}

Response 200:
{ "checkout_url": "https://checkout.stripe.com/..." }
```

- `COMBOBULATE_APP_ID` — literal placeholder, patched post-build.
- Body may be empty `{}` or carry optional metadata; the operator configures Stripe prices server-side.
- Response: `checkout_url` is the Stripe Checkout session URL — redirect the browser there.
- CORS: the server echoes `Origin` for allowed `*.combobulate.dev` subdomains — cross-origin fetch works from the static site.

---

## HTML + JS snippet

```html
<button id="checkout-btn">Buy Now</button>
<p id="checkout-status" aria-live="polite" hidden></p>

<script>
  (function () {
    var btn = document.getElementById("checkout-btn");
    var status = document.getElementById("checkout-status");

    btn.addEventListener("click", function () {
      btn.disabled = true;
      status.hidden = false;
      status.textContent = "Redirecting to checkout…";

      fetch(
        "https://app.combobulate.dev/api/payments/COMBOBULATE_APP_ID/checkout",
        {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({}),
        },
      )
        .then(function (res) {
          return res.ok
            ? res.json()
            : res.json().then(function (b) {
                throw new Error(b.error || "Checkout unavailable");
              });
        })
        .then(function (data) {
          window.location.href = data.checkout_url;
        })
        .catch(function (err) {
          status.textContent =
            err.message || "Something went wrong. Please try again.";
          btn.disabled = false;
        });
    });
  })();
</script>
```

---

## Notes

- Change the button label (`Buy Now`, `Subscribe`, `Get Access`, etc.) to match the site's copy.
- Style the button with the site's existing CSS — no combobulate-specific classes.
- The Stripe Checkout session is created server-side using the operator's Stripe keys; the static site only triggers the session and redirects.
- After payment, Stripe redirects to the `success_url` configured server-side by the operator.
