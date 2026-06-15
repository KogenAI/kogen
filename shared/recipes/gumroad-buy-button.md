# Gumroad Buy Button — GUMROAD_PLACEHOLDER_URL

## When to use this recipe

Use when user's brief mentions:

- Gumroad (any form: "sell on Gumroad", "my Gumroad product", "Gumroad link")
- Selling a digital product (ebook, course, template, preset, plugin, etc.)
- "Buy" or "purchase" button on one-pager or landing page
- "Download after payment" or similar purchase flow

When these keywords appear, render buy button href as literal string `GUMROAD_PLACEHOLDER_URL` (not a real URL). Platform detects this after build and asks user for their Gumroad product URL, then patches all occurrences automatically.

**Do NOT invent a Gumroad URL.** Do NOT use `#` or leave href empty. Use `GUMROAD_PLACEHOLDER_URL` verbatim.

---

## Snippet 1 — Plain HTML `<a>` tag

```html
<a
  href="GUMROAD_PLACEHOLDER_URL"
  class="buy-button"
  target="_blank"
  rel="noopener"
>
  Buy Now
</a>
```

Use in any static HTML page with buy or purchase call-to-action.

---

## Snippet 2 — Hugo partial (`layouts/partials/buy-button.html`)

```html
{{- $url := "GUMROAD_PLACEHOLDER_URL" -}}
<a href="{{ $url }}" class="buy-button" target="_blank" rel="noopener">
  {{ .ButtonText | default "Get It Now" }}
</a>
```

Call from layout or page template:

```html
{{ partial "buy-button.html" (dict "ButtonText" "Buy the Ebook") }}
```

---

## Snippet 3 — Landing page section (full hero + CTA)

```html
<section class="hero">
  <div class="hero-content">
    <h1>{{ .Title }}</h1>
    <p class="subtitle">{{ .Description }}</p>
    <a
      href="GUMROAD_PLACEHOLDER_URL"
      class="cta-button"
      target="_blank"
      rel="noopener"
    >
      Buy Now — ${{ .Price }}
    </a>
    <p class="guarantee">30-day money-back guarantee</p>
  </div>
</section>
```

---

## Notes

- Placeholder is case-sensitive — use all caps: `GUMROAD_PLACEHOLDER_URL`.
- Can use placeholder in multiple places in same file (e.g. header nav link + hero CTA). All occurrences replaced in one patch.
- Gumroad overlay widget (`<script src="https://gumroad.com/js/gumroad.js">` + `data-gumroad-overlay-checkout="true"`) is optional and compatible — add overlay attributes to `<a>` tag if user wants in-page overlay checkout.
