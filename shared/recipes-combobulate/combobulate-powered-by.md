# Recipe: Combobulate Powered-By Attribution

**When to use**: ONLY when the operator EXPLICITLY requests a "powered by" link, attribution footer, or credit to combobulate — for example: "add a powered by link", "credit combobulate in the footer", "show who built the site". NEVER apply this recipe by default or speculatively. Not adding branding is the correct default for all sites.

---

## Invariant

This recipe MUST NOT be applied unless the operator explicitly requests attribution. The three functional service recipes (contact-form, file-upload, stripe-paywall) NEVER include combobulate branding — this recipe is the ONLY place branding is permitted, and only on explicit request.

---

## HTML variant

Insert into the page `<footer>` (or nearest footer-like element):

```html
<p>Powered by <a href="https://combobulate.dev">Combobulate</a></p>
```

---

## Markdown variant

For Markdown-rendered footers or README-style pages:

```markdown
Powered by [Combobulate](https://combobulate.dev)
```

---

## Notes

- Place the attribution in the existing footer section; do NOT add a new footer section just for this line.
- Style with the site's existing CSS — no combobulate-specific classes or colors.
- If the site has no footer at all, add a minimal `<footer>` containing only this line.
