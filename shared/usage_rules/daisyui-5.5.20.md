# daisyui

daisyUI is a Tailwind CSS component library providing pre-built semantic components and 35+ themes. It reduces code complexity by 88% compared to vanilla Tailwind while remaining pure CSS with no JavaScript dependencies. Works across React, Vue, Svelte, Next.js, Rails, Laravel, and 10+ other frameworks.

## Quick Start

### Installation

Install via npm, yarn, pnpm, or bun:

```bash
npm i -D daisyui@latest
yarn add -D daisyui@latest
pnpm add -D daisyui@latest
bun add -D daisyui@latest
```

### Add to CSS

Add the plugin to your CSS file:

```css
@import "tailwindcss";
@plugin "daisyui";
```

### Basic Component Usage

Replace lengthy utility classes with semantic component names:

```html
<!-- Instead of complex utilities: -->
<button class="btn">Click Me</button>
<div class="card">...</div>
<input type="checkbox" class="checkbox" />
```

## Core Concepts

### Component System

daisyUI provides **68 components** with semantic class names (`btn`, `card`, `modal`, `navbar`, `badge`, `dropdown`, `table`, etc.). Each component:

- Uses a base class as the primary identifier
- Accepts modifier classes for variants (color, size, style)
- Can be combined with Tailwind utilities for fine-tuning

### Semantic Color Names

Components use meaningful color names instead of raw hex values:

- **primary**, **secondary**, **accent** — brand colors
- **info**, **success**, **warning**, **error** — status indicators
- Applied via modifiers like `btn-primary`, `badge-success`, `input-error`

### Layered Customization Pattern

1. Apply base component class: `class="btn"`
2. Add daisyUI variants: `class="btn btn-primary btn-lg"`
3. Override with Tailwind utilities: `class="btn btn-primary w-64 rounded-full"`

This approach lets components serve as starting points while maintaining full Tailwind flexibility.

### No JavaScript Dependency

All components are pure CSS. Dynamic behavior (dropdowns, modals, carousels) uses HTML attributes and CSS pseudo-classes—no runtime dependencies.

## Configuration

### Theme Setup

Enable themes in your CSS plugin configuration:

```css
@plugin "daisyui" {
  themes:
    light --default,
    dark --prefersdark;
}
```

- Use `--default` to set the primary theme
- Use `--prefersdark` for dark mode system preference detection
- Multiple themes can coexist; only specified ones are included

### Available Built-In Themes

35 themes: light, dark, cupcake, bumblebee, emerald, corporate, synthwave, retro, cyberpunk, valentine, halloween, garden, forest, aqua, lofi, pastel, fantasy, wireframe, black, luxury, dracula, cmyk, autumn, business, acid, lemonade, night, coffee, winter, dim, nord, sunset, caramellatte, abyss, silk

### Apply Themes

Set theme on any HTML element using the data attribute:

```html
<!-- Apply theme to entire page -->
<html data-theme="dark">
  <!-- Apply theme to sections -->
  <div data-theme="cupcake">
    <!-- This section uses the cupcake theme -->
  </div>
</html>
```

Themes can be nested—child elements inherit unless overridden.

### Custom Themes

Create new themes using CSS variables. Customize:

- **Colors** — primary, secondary, accent, base, info, success, warning, error
- **Border radius** — rounded corners for various elements
- **Sizing** — component-specific dimensions
- **Borders** — outline widths and styles
- **Visual effects** — shadows, opacity, transitions

## Best Practices

### Component Composition Strategy

Use base component classes as building blocks, then layer modifications:

```html
<!-- Card with multiple variants -->
<div class="card bg-base-100 shadow-xl">
  <div class="card-body">
    <h2 class="card-title">Title</h2>
    <p>Content</p>
  </div>
</div>

<!-- Button with all layers -->
<button class="btn btn-primary btn-lg gap-2">
  <svg>...</svg>
  Action
</button>
```

### Responsive Components

Use Tailwind's responsive prefixes with component variants:

```html
<button class="btn btn-xs sm:btn-sm md:btn-md lg:btn-lg xl:btn-xl">
  Responsive Button
</button>
```

### State Management

Apply state classes directly to elements:

```html
<button class="btn btn-active">Pressed</button>
<button class="btn btn-disabled" disabled>Disabled</button>
<button class="btn loading">Loading</button>
```

### Framework Integration

daisyUI works with 40+ frameworks and tools. Framework-specific guides are available, covering setup for:

- **Frontend frameworks** — React, Vue, Angular, Solid, Preact
- **Meta-frameworks** — Next.js, Nuxt, SvelteKit, Astro, Remix
- **Backend integration** — Laravel, Rails, Django, Phoenix, WordPress
- **Build tools** — Vite, PostCSS, Tailwind CLI, Rsbuild

### Sizing Variants

Components support consistent size modifiers:

- `btn-xs`, `btn-sm`, `btn-md` (default), `btn-lg`, `btn-xl`
- `badge-xs`, `badge-sm`, `badge-md`, `badge-lg`
- Apply responsive prefixes for adaptive sizing

### Layout Modifiers

Common layout classes for components:

- `btn-wide` — wider button
- `btn-block` — full width
- `btn-square` — equal width and height
- `btn-circle` — circular shape

### Semantic Elements

Components work with multiple HTML elements where appropriate:

```html
<button class="btn">Button element</button>
<a href="#" class="btn">Link button</a>
<input type="submit" class="btn" value="Submit" />
<input type="checkbox" class="checkbox" />
```

### Theme Customization Strategy

For branding:

1. Start with a built-in theme as a base
2. Override CSS variables for brand colors
3. Use the theme generator tool at daisyui.com/theme-generator/

This approach maintains consistency while adapting to brand guidelines.

---

**Version:** 5.5.20
**Source:** [github.com/saadeghi/daisyui](https://github.com/saadeghi/daisyui)
**Documentation:** [daisyui.com](https://daisyui.com)
**Generated:** 2026-08-07
