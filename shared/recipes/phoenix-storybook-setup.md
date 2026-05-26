# Recipe: Phoenix Storybook for Design System Documentation

## Problem

How to maintain comprehensive design system documentation for Phoenix LiveView components that stays in sync with implementation, provides interactive examples, and enables both developers and designers to verify component consistency?

## Solution

Implement PhoenixStorybook as a development-only route that showcases all design system components with their variants, states, and usage examples. This creates a single source of truth for component documentation while enabling easy visual verification of design consistency.

## Implementation

### 1. PhoenixStorybook Setup and Configuration

```elixir
# lib/my_app_web/storybook.ex
defmodule MyAppWeb.Storybook do
  @moduledoc """
  Configuration module for Phoenix Storybook.

  This module sets up the Storybook integration for the design system,
  configuring paths for content, CSS, and JavaScript assets.
  """

  use PhoenixStorybook,
    otp_app: :my_app,
    content_path: Path.expand("./storybook", __DIR__),
    css_path: "/assets/app.css",
    js_path: "/assets/storybook.js",
    title: "My App Design System"
end
```

```elixir
# mix.exs - Add PhoenixStorybook dependency
defp deps do
  [
    {:phoenix_storybook, "~> 0.6.4", only: :dev}
    # ... other deps
  ]
end
```

### 2. Router Configuration for Development

```elixir
# lib/my_app_web/router.ex
defmodule MyAppWeb.Router do
  use MyAppWeb, :router

  # Development-only routes
  if Application.compile_env(:my_app, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: MyAppWeb.Telemetry

      # Storybook for design system documentation
      forward "/storybook", PhoenixStorybook, backend_module: MyAppWeb.Storybook
    end
  end
end
```

### 3. Story Structure and Organization

```elixir
# lib/my_app_web/storybook/_root.index.exs
# Main navigation for storybook
defmodule MyAppWeb.Storybook.Root do
  use PhoenixStorybook.Index

  def folder_icon, do: {:fa, "folder"}
  def folder_name, do: "Design System Components"

  def entries do
    [
      %Folder{
        id: :core,
        name: "Core Components"
      },
      %Folder{
        id: :job,
        name: "Job Components"
      },
      %Folder{
        id: :figma,
        name: "Figma Component Library"
      }
    ]
  end
end
```

### 4. Core Component Stories

```elixir
# lib/my_app_web/storybook/core/button.story.exs
defmodule MyAppWeb.Storybook.Core.Button do
  use PhoenixStorybook.Story, :component

  def function, do: &MyAppWeb.Components.Core.button/1
  def imports, do: [{MyAppWeb.Components.Core, [button: 1]}]

  def template do
    """
    <.button {__meta__}>
      {slot}
    </.button>
    """
  end

  def variations do
    [
      %Variation{
        id: :primary,
        attributes: %{
          variant: "primary",
          size: "md"
        },
        slots: ["Click me"]
      },
      %Variation{
        id: :secondary,
        attributes: %{
          variant: "secondary",
          size: "md"
        },
        slots: ["Secondary"]
      },
      %Variation{
        id: :danger,
        attributes: %{
          variant: "danger",
          size: "md"
        },
        slots: ["Delete"]
      },
      %Variation{
        id: :sizes,
        description: "Button sizes",
        attributes: %{
          variant: "primary"
        },
        let: :size,
        slots: ["Button"],
        template: """
        <div class="space-y-4">
          <.button variant="primary" size="sm">Small</.button>
          <.button variant="primary" size="md">Medium</.button>
          <.button variant="primary" size="lg">Large</.button>
        </div>
        """
      }
    ]
  end
end
```

### 5. Typography Component Stories

```elixir
# lib/my_app_web/storybook/core/typography.story.exs
defmodule MyAppWeb.Storybook.Core.Typography do
  use PhoenixStorybook.Story, :component

  def function, do: &MyAppWeb.Components.Core.heading/1
  def imports, do: [{MyAppWeb.Components.Core, [heading: 1, text: 1, caption: 1]}]

  def template do
    """
    <div class="space-y-6">
      <div>
        <h3 class="text-lg font-medium mb-4">Headings</h3>
        <div class="space-y-2">
          <.heading size="h1">Headline 1 - 96px Light</.heading>
          <.heading size="h2">Headline 2 - 60px Light</.heading>
          <.heading size="h3">Headline 3 - 48px Regular</.heading>
          <.heading size="h4">Headline 4 - 34px Regular</.heading>
          <.heading size="h5">Headline 5 - 24px Regular</.heading>
          <.heading size="h6">Headline 6 - 20px Regular</.heading>
        </div>
      </div>

      <div>
        <h3 class="text-lg font-medium mb-4">Body Text</h3>
        <div class="space-y-2">
          <.text size="body">Body 1 - 16px Regular</.text>
          <.text size="body-sm">Body 2 - 15px Regular</.text>
          <.text size="subtitle">Subtitle 1 - 16px Regular</.text>
          <.text size="subtitle-sm">Subtitle 2 - 14px Regular</.text>
          <.caption>Caption - 12px Regular</.caption>
        </div>
      </div>
    </div>
    """
  end

  def variations do
    [
      %Variation{
        id: :typography_scale,
        description: "Complete typography scale from Figma",
        attributes: %{},
        slots: []
      }
    ]
  end
end
```

### 6. Figma Component Library Documentation

```elixir
# lib/my_app_web/storybook/figma.story.exs
defmodule MyAppWeb.Storybook.Figma do
  use PhoenixStorybook.Story, :page

  def doc, do: "Documentation of Figma Component Library implementation"

  def template do
    """
    <div class="max-w-4xl mx-auto p-8 space-y-12">
      <header>
        <h1 class="text-4xl font-light mb-4">Component Library</h1>
        <p class="text-lg text-gray-600">
          Based on Figma node <code>1956-18958</code> - Complete component library for design system implementation
        </p>
      </header>

      <section>
        <h2 class="text-2xl font-medium mb-6">Navigation & Structure</h2>
        <div class="grid grid-cols-1 md:grid-cols-2 gap-6">

          <div class="p-4 border rounded-lg">
            <h3 class="font-medium mb-2">Brand Logo</h3>
            <div class="space-y-2">
              <img src="/images/logo@2x.png" alt="Logo" class="h-8" />
              <img src="/images/logo-dark@2x.png" alt="Logo Dark" class="h-8" />
            </div>
          </div>

          <div class="p-4 border rounded-lg">
            <h3 class="font-medium mb-2">Header Menu Navigation</h3>
            <div class="flex space-x-4">
              <span class="px-3 py-1 bg-primary-100 text-primary-700 rounded">Organization</span>
              <span class="px-3 py-1 bg-primary-100 text-primary-700 rounded">Medical Personnel</span>
            </div>
          </div>

        </div>
      </section>

      <section>
        <h2 class="text-2xl font-medium mb-6">Content Display</h2>
        <div class="grid grid-cols-1 md:grid-cols-3 gap-4">

          <div class="p-4 border rounded-lg">
            <h3 class="font-medium mb-2">Toast Notifications</h3>
            <div class="p-3 bg-green-50 border border-green-200 rounded text-green-800">
              ✓ Success message example
            </div>
          </div>

          <div class="p-4 border rounded-lg">
            <h3 class="font-medium mb-2">Loading Animation</h3>
            <div class="flex justify-center">
              <div class="w-6 h-6 border-2 border-primary-500 border-t-transparent rounded-full animate-spin"></div>
            </div>
          </div>

          <div class="p-4 border rounded-lg">
            <h3 class="font-medium mb-2">Confirmation Modal</h3>
            <div class="text-center">
              <div class="w-12 h-12 bg-red-100 rounded-full flex items-center justify-center mx-auto mb-2">
                <span class="text-red-600">⚠</span>
              </div>
              <p class="text-sm">Are you sure?</p>
            </div>
          </div>

        </div>
      </section>

      <section>
        <h2 class="text-2xl font-medium mb-6">Data & Forms</h2>
        <div class="space-y-4">

          <div class="p-4 border rounded-lg">
            <h3 class="font-medium mb-4">Form Controls</h3>
            <div class="space-y-4">
              <input
                type="text"
                placeholder="Text Input"
                class="w-full px-3 py-2 border border-gray-300 rounded-md focus:outline-none focus:ring-2 focus:ring-primary-500"
              />
              <select class="w-full px-3 py-2 border border-gray-300 rounded-md focus:outline-none focus:ring-2 focus:ring-primary-500">
                <option>Employment Type</option>
                <option>Full-time</option>
                <option>Part-time</option>
              </select>
              <textarea
                placeholder="Text Box"
                class="w-full px-3 py-2 border border-gray-300 rounded-md focus:outline-none focus:ring-2 focus:ring-primary-500"
                rows="3"
              ></textarea>
            </div>
          </div>

        </div>
      </section>

      <section>
        <h2 class="text-2xl font-medium mb-6">Design Tokens</h2>
        <div class="grid grid-cols-1 md:grid-cols-2 gap-6">

          <div>
            <h3 class="font-medium mb-4">Color Palette</h3>
            <div class="space-y-2">
              <div class="flex items-center space-x-3">
                <div class="w-8 h-8 bg-primary-500 rounded"></div>
                <span class="font-mono text-sm">#7b4eab</span>
                <span class="text-sm">Primary</span>
              </div>
              <div class="flex items-center space-x-3">
                <div class="w-8 h-8 bg-green-500 rounded"></div>
                <span class="font-mono text-sm">#83ce42</span>
                <span class="text-sm">Success</span>
              </div>
              <div class="flex items-center space-x-3">
                <div class="w-8 h-8 bg-red-500 rounded"></div>
                <span class="font-mono text-sm">#e74a4a</span>
                <span class="text-sm">Error</span>
              </div>
            </div>
          </div>

          <div>
            <h3 class="font-medium mb-4">Spacing Scale</h3>
            <div class="space-y-2">
              <div class="flex items-center space-x-3">
                <div class="w-2 h-8 bg-gray-300"></div>
                <span class="font-mono text-sm">8px</span>
                <span class="text-sm">xs</span>
              </div>
              <div class="flex items-center space-x-3">
                <div class="w-4 h-8 bg-gray-300"></div>
                <span class="font-mono text-sm">16px</span>
                <span class="text-sm">sm</span>
              </div>
              <div class="flex items-center space-x-3">
                <div class="w-6 h-8 bg-gray-300"></div>
                <span class="font-mono text-sm">24px</span>
                <span class="text-sm">md</span>
              </div>
            </div>
          </div>

        </div>
      </section>

    </div>
    """
  end
end
```

### 7. Asset Development Workflow

```javascript
// assets/js/storybook.js
// Storybook-specific JavaScript for enhanced functionality

import "phoenix_html";
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import topbar from "../vendor/topbar";

// Development-only console logging for Storybook
const isDevelopment = window.location.hostname === "localhost";

let liveSocket = new LiveSocket("/live", Socket, {
  params: { _csrf_token: csrfToken },
  logger: isDevelopment
    ? (kind, msg, data) => {
        console.log(`${kind}: ${msg}`, data);
      }
    : false,
});

// Show progress bar on live navigation and form submits
topbar.config({
  barColors: { 0: "#7b4eab" },
  shadowColor: "rgba(0, 0, 0, .3)",
});
window.addEventListener("phx:page-loading-start", (info) => topbar.show());
window.addEventListener("phx:page-loading-stop", (info) => topbar.hide());

// Connect to LiveSocket
liveSocket.connect();

// Expose liveSocket on window for debugging
if (isDevelopment) {
  window.liveSocket = liveSocket;
}
```

### 8. Design Token Integration

```elixir
# lib/my_app_web/storybook/core.index.exs
defmodule MyAppWeb.Storybook.Core do
  use PhoenixStorybook.Index

  def folder_icon, do: {:fa, "puzzle-piece"}
  def folder_name, do: "Core Components"

  def entries do
    [
      %Story{
        id: :button,
        name: "Button"
      },
      %Story{
        id: :typography,
        name: "Typography"
      },
      %Story{
        id: :card,
        name: "Card"
      },
      %Story{
        id: :modal,
        name: "Modal"
      },
      %Story{
        id: :input,
        name: "Form Input"
      },
      %Story{
        id: :icon,
        name: "Icon System"
      }
    ]
  end
end
```

## Considerations

### Development Workflow Integration

- **Route Protection**: Storybook only available in development mode
- **Asset Management**: Use same CSS/JS pipeline as main application
- **Component Sync**: Stories automatically reflect component changes
- **Design Token Updates**: Storybook showcases latest design tokens

### Documentation Best Practices

- **Complete Coverage**: Document all public component variants and states
- **Usage Examples**: Show realistic usage scenarios, not just component demos
- **Design System Rules**: Include design token documentation and usage guidelines
- **Figma Mapping**: Reference Figma node IDs for design-to-code traceability

### When to Use This Pattern

- ✅ Complex applications with comprehensive design systems
- ✅ Teams with multiple developers and designers requiring coordination
- ✅ Projects requiring design system consistency and documentation
- ✅ Applications with frequent UI updates requiring visual verification

### When NOT to Use This Pattern

- ❌ Simple applications with minimal UI components
- ❌ Prototypes or temporary applications
- ❌ Projects without design systems or component libraries
- ❌ Applications where documentation overhead outweighs benefits

### Performance Considerations

- **Development Only**: Storybook routes excluded from production builds
- **Asset Optimization**: Same asset pipeline as main application
- **Memory Usage**: Additional routes and documentation don't affect production
- **Build Time**: Minimal impact on compilation time

## Example Usage

From the BemedaPersonal figma-2-code implementation:

```elixir
# Complete Storybook setup with design system documentation
def setup_comprehensive_storybook do
  # 1. Configure PhoenixStorybook module
  setup_storybook_config()

  # 2. Create story structure matching component organization
  create_story_directories()

  # 3. Document all core components with variants
  document_core_components()

  # 4. Create Figma component library reference
  create_figma_documentation()

  # 5. Include design token showcase
  showcase_design_tokens()
end

# Results:
# - Complete design system documentation at /dev/storybook
# - All components showcased with variants and usage examples
# - Design token reference with Figma mappings
# - Interactive examples for development and design review
```

This approach provided a comprehensive design system reference that kept documentation in sync with implementation and enabled easy visual verification of design consistency.

## Related Recipes

- [Figma-to-Code with MCP](./figma-to-code-mcp.md)
- [Figma Visual Verification](./figma-visual-verification.md)
- [Semantic Component API Design](./semantic-component-api-design.md)
