# JavaScript — Static Sites

## Check app.js Before Inline onclick

`static/js/app.js` may already handle a toggle. Inline `onclick` on same element double-fires.

```html
<!-- ❌ fights app.js — fires twice -->
<button id="mobile-menu-btn" onclick="menu.classList.toggle('hidden')">
  <!-- ✅ all logic in app.js -->
</button>
```

Grep `app.js` for element ID before adding inline handlers.

## Viewport-Width Overlays: `fixed`, Not `absolute`

`absolute` inside CSS grid constrained by grid columns — won't span full viewport.

```html
<!-- ❌ clipped by parent grid padding -->
<div class="absolute left-0 right-0 ...">
  <!-- ✅ escapes grid, spans full viewport -->
  <div class="fixed left-0 w-full ..."></div>
</div>
```

`fixed` for mobile menus, modals, full-width overlays.
