# Heroicons

High-quality, MIT-licensed SVG icons for Phoenix components. Heroicons provides reusable Phoenix components for integrating a comprehensive icon library into web applications with support for multiple style variants and custom styling.

## Quick Start

### Installation

Add to `mix.exs` dependencies:

```elixir
defp deps do
  [
    {:heroicons, "~> 0.5.5"}
  ]
end
```

Run `mix deps.get` to fetch the package.

### Basic Usage

In HEEx templates, use the `Heroicons` module to render icons:

```html
<Heroicons.cake />
```

All icons are available as function components with the icon name.

## Core Concepts

### Icon Variants

Heroicons provides four style variants for each icon:

1. **Outline** (default) - Thin stroked design

   ```html
   <Heroicons.cake />
   ```

2. **Solid** - Filled design

   ```html
   <Heroicons.cake solid />
   ```

3. **Mini** - Smaller proportions

   ```html
   <Heroicons.cake mini />
   ```

4. **Micro** - Minimal proportions
   ```html
   <Heroicons.cake micro />
   ```

### Icon Catalog

Browse the complete icon collection at [heroicons.com](https://heroicons.com). Icons include common UI patterns: arrows, checkmarks, charts, communication, media controls, navigation symbols, and more.

### Component-Based Architecture

Each icon is a standalone Phoenix component, enabling:

- Direct integration into HEEx templates
- Composition with other components
- Dynamic icon selection through component variables

## Configuration

### Custom Styling

Apply standard HTML attributes to customize appearance:

```html
<!-- Size: Using Tailwind utility classes -->
<Heroicons.cake class="w-4 h-4" />
<Heroicons.cake class="w-6 h-6" />
<Heroicons.cake class="w-8 h-8" />

<!-- Color: Apply text color classes -->
<Heroicons.cake class="text-gray-500" />
<Heroicons.cake class="text-blue-600" />

<!-- Combined styling -->
<Heroicons.cake solid class="w-6 h-6 text-indigo-500" />
```

### Variant + Styling

Combine style variants with custom classes:

```html
<Heroicons.arrow_right class="w-5 h-5" />
<Heroicons.arrow_right solid class="w-5 h-5 text-green-600" />
<Heroicons.arrow_right mini class="w-4 h-4" />
<Heroicons.arrow_right micro class="w-3 h-3" />
```

### HTML Attributes

Pass additional HTML attributes for accessibility and interactivity:

```html
<Heroicons.information_circle class="w-6 h-6" aria-label="Information" />
<Heroicons.bell class="w-6 h-6" data-testid="notification-icon" />
```

## Best Practices

### Icon Sizing

- **Micro (12-16px)**: Inline text, compact UI
- **Mini (16-20px)**: List items, badges, compact buttons
- **Default**: Outline for 20-24px icons (standard UI controls)
- **Larger (28-32px+)**: Use `w-8 h-8` or larger classes with outline or solid

### Accessibility

- Add `aria-label` for icon-only buttons to describe purpose
- Use semantic HTML wrapper for interactive icons (buttons, links)
- Provide text context when icons appear without labels

```html
<!-- Icon-only button (needs aria-label) -->
<button aria-label="Close dialog">
  <Heroicons.x_mark class="w-6 h-6" />
</button>

<!-- Icon with text context (no aria-label needed) -->
<a href="/help">
  <Heroicons.question_mark_circle class="w-5 h-5 inline" />
  Help
</a>
```

### Performance Considerations

- Icons render as inline SVG: no additional HTTP requests
- Components are pure—no state management overhead
- Tailwind classes handle sizing and color (CSS-based)
- Minimize icon count per page for optimal performance

### Consistent Icon Selection

- Choose outline for UI controls, buttons, and navigation
- Use solid for emphasis, highlights, or status indicators
- Mini variant for dense layouts, lists, and compact components
- Establish icon conventions across your application

### Color Integration

- Leverage Tailwind color utilities for consistency
- Use design system colors (from `tailwind.config.js`)
- Apply colors through CSS classes rather than inline styles
- Consider dark mode by using utility classes that respond to theme

### Component Composition

Combine icons with text and other elements:

```html
<!-- Icon + Text Button -->
<button class="flex items-center gap-2">
  <Heroicons.download class="w-4 h-4" />
  Download
</button>

<!-- Icon in Badge -->
<span class="inline-flex items-center gap-1 px-3 py-1 rounded bg-green-100">
  <Heroicons.check_circle solid class="w-4 h-4 text-green-600" />
  <span class="text-sm font-medium">Verified</span>
</span>
```

---

**Version:** 2.2.0
**Source:** [hexdocs.pm/heroicons](https://hexdocs.pm/heroicons/)
**Generated:** 2025-10-28
