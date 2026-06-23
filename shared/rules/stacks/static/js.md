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

## Node Child Processes — `execFileSync` Over Shell Strings

When spawning build commands from Node.js, always use `execFileSync(cmd, args, options)` (array form) instead of `execSync(\`${cmd} ${args.join(" ")}\`)` (shell-string form).

Shell strings are **vulnerable to mangling** when args contain spaces, special characters, or operator output:

```js
// ❌ shell-string form — args can be mangled
const args = ["deploy", "app-name"];
execSync(`mix ${args.join(" ")}`, { cwd });
// If args[1] unexpectedly contains " ", shell splits it

// ✅ execFileSync array form — args passed directly, no shell parsing
execFileSync("mix", ["deploy", "app-name"], { cwd });
```

Use `execFileSync(file, args, options)` for all process invocations. The options object (cwd, env, stdio, timeout) signature is **identical** between the two forms; only the invocation changes.

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
