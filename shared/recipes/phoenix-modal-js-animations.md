# Phoenix Modal JS Animations

**Problem**: Modal backdrop and panel need smooth show/hide animations without a round-trip to the server.
**When**: Building a modal component in Phoenix LiveView that should animate in on mount and out on close using Phoenix.JS.
**See also**: `phoenix-dropdown-blur.md`

## Solution

Use `phx-mounted` with chained `JS.show/2` calls — one for the backdrop (opacity fade) and one for the panel (slide in). Set `display: none` on both elements by default so they are invisible before mount.

```heex
<div
  id="modal-backdrop"
  class="fixed inset-0 bg-black/50 opacity-0"
  style="display: none"
  phx-mounted={
    JS.show(to: "#modal-backdrop", transition: {"transition opacity-0", "opacity-0", "opacity-100"})
    |> JS.show(
      to: "#modal-panel",
      transition: {"transition translate-x-full", "translate-x-full", "translate-x-0"}
    )
  }
/>
<div id="modal-panel" class="fixed right-0 ..." style="display: none" />
```

For hiding, use `JS.hide/2` with the reversed transition classes on the close button or `phx-remove`.

## Gotchas

- Both elements must start with `style="display: none"` — Tailwind's `hidden` class conflicts with `JS.show` which sets `display: block`.
- Chain `JS.show` calls with `|>` on the same `phx-mounted` attribute; do not use two separate `phx-mounted` attributes (only the last one runs).
