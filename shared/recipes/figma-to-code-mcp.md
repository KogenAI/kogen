# Recipe: Figma-to-Code Workflow with MCP Server

## Problem

How to efficiently implement pixel-perfect UI designs from Figma while ensuring proper asset management, responsive behavior, and maintainable code? Traditional workflows often result in hardcoded values, missing assets, and poor cross-device implementation.

## Solution

Use the Figma MCP server to extract designs and assets programmatically, combined with a structured workflow for responsive implementation and asset optimization. This ensures pixel-perfect results while maintaining code quality.

## Implementation

### 1. Figma MCP Server Setup and Usage

Extract designs and assets using MCP tools:

```elixir
# Use get_code to extract component specifications
# This provides exact styling, measurements, and asset URLs
def extract_design_specs(node_id) do
  # Extract from Figma using node ID
  # Returns: HTML structure, CSS classes, asset URLs, responsive breakpoints
end

# Use get_image for visual reference during development
def get_visual_reference(node_id) do
  # Capture design screenshot for comparison
  # Use during implementation validation
end

# Use get_variable_defs for design tokens
def extract_design_tokens(node_id) do
  # Get color values, spacing, typography
  # Returns: color definitions, spacing values, font specifications
end
```

### 2. Asset Extraction and Optimization Workflow

Handle Figma MCP assets properly for production use:

```bash
# Step 1: Extract assets from localhost URLs during development
curl "http://localhost:3845/assets/4ff23f3a85e54a6609bfd818e51fa79b89bbbee8.svg" \
  -o "priv/static/images/onboarding/email-confirmation.svg"

# Step 2: Optimize SVGs for production
npx svgo priv/static/images/onboarding/email-confirmation.svg

# Step 3: Convert to descriptive names
mv "4ff23f3a85e54a6609bfd818e51fa79b89bbbee8.svg" "email-confirmation.svg"
```

```elixir
# lib/my_app_web/components/onboarding/email_confirmation.ex
defmodule MyAppWeb.Components.Onboarding.EmailConfirmation do
  use Phoenix.Component
  use MyAppWeb, :verified_routes

  def illustration(assigns) do
    ~H"""
    <!-- CRITICAL: Replace localhost URLs with Phoenix verified routes -->
    <img
      src={~p"/images/onboarding/email-confirmation.svg"}
      alt="Email confirmation"
      class="w-32 h-32 mx-auto mb-6"
    />
    """
  end
end
```

### 3. Responsive Implementation Strategy

Implement cross-viewport designs systematically:

```css
/* tailwind.config.js - Define semantic breakpoints */
module.exports = {
  theme: {
    screens: {
      'mobile': '0px',
      'tablet': '768px',
      'desktop': '1024px',
    },
    extend: {
      colors: {
        // Extract exact colors from Figma
        primary: {
          50: '#f2edf7',
          500: '#7b4eab', // Exact Figma color
          600: '#6d4296',
        }
      },
      spacing: {
        // Maintain 8px grid system
        'xs': '8px',
        'sm': '16px',
        'md': '24px',
        'lg': '32px',
      }
    }
  }
}
```

```elixir
# Responsive component implementation
def user_type_card(assigns) do
  ~H"""
  <div class={[
    # Mobile-first base styles
    "w-full p-4 border border-gray-200 rounded-lg",
    # Tablet adaptations
    "tablet:p-6 tablet:max-w-md",
    # Desktop adaptations
    "desktop:flex-1 desktop:max-w-sm"
  ]}>
    <!-- Component content -->
  </div>
  """
end
```

### 4. Multi-Step Form Pattern with User Type Differentiation

Implement forms that adapt based on user context:

```elixir
# lib/my_app_web/live/user_registration_live.ex
defmodule MyAppWeb.UserRegistrationLive do
  use MyAppWeb, :live_view

  def mount(_params, _session, socket) do
    {:ok, assign(socket,
      step: 1,
      max_steps: nil, # Set based on user type
      user_type: nil,
      form: to_form(Accounts.change_user_registration(%User{}))
    )}
  end

  def handle_event("select_user_type", %{"type" => type}, socket) do
    max_steps = case type do
      "job_seeker" -> 3  # Type selection + Personal info + Work info
      "employer" -> 2    # Type selection + Company info
    end

    {:noreply, assign(socket, user_type: type, max_steps: max_steps)}
  end

  def handle_event("next_step", params, socket) do
    case validate_current_step(socket.assigns, params) do
      {:ok, updated_assigns} ->
        {:noreply, assign(socket, updated_assigns) |> assign(step: socket.assigns.step + 1)}
      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp validate_current_step(%{step: 1, user_type: "job_seeker"}, params) do
    # Step 1: Personal information validation
    changeset = User.step_1_changeset(%User{}, params)
    if changeset.valid?, do: {:ok, %{form_data: params}}, else: {:error, changeset}
  end

  defp validate_current_step(%{step: 2, user_type: "job_seeker"}, params) do
    # Step 2: Work information validation
    changeset = User.step_2_changeset(%User{}, params)
    if changeset.valid?, do: {:ok, %{form_data: params}}, else: {:error, changeset}
  end
end
```

### 5. Timer Component with State Management

Implement countdown functionality for email confirmation:

```elixir
# lib/my_app_web/components/core/timer.ex
defmodule MyAppWeb.Components.Core.Timer do
  use Phoenix.Component

  attr :duration, :integer, default: 23
  attr :on_complete, :string, default: nil
  attr :class, :any, default: []

  def countdown_timer(assigns) do
    ~H"""
    <div
      id="countdown-timer"
      phx-hook="CountdownTimer"
      data-duration={@duration}
      data-on-complete={@on_complete}
      class={["text-sm text-gray-600", @class]}
    >
      <span data-timer-display>Resend in <span data-timer-seconds><%= @duration %></span> sec</span>
      <a
        href="#"
        data-timer-link
        class="text-primary-600 hover:text-primary-500 hidden"
        phx-click="resend_confirmation"
      >
        Resend
      </a>
    </div>
    """
  end
end
```

```javascript
// assets/js/hooks/countdown_timer.js
const CountdownTimer = {
  mounted() {
    this.duration = parseInt(this.el.dataset.duration);
    this.onComplete = this.el.dataset.onComplete;
    this.display = this.el.querySelector("[data-timer-display]");
    this.seconds = this.el.querySelector("[data-timer-seconds]");
    this.link = this.el.querySelector("[data-timer-link]");

    this.startTimer();
  },

  startTimer() {
    this.timer = setInterval(() => {
      this.duration--;
      this.seconds.textContent = this.duration;

      if (this.duration <= 0) {
        this.handleComplete();
      }
    }, 1000);
  },

  handleComplete() {
    clearInterval(this.timer);
    this.display.classList.add("hidden");
    this.link.classList.remove("hidden");

    if (this.onComplete) {
      this.pushEvent(this.onComplete);
    }
  },

  destroyed() {
    if (this.timer) {
      clearInterval(this.timer);
    }
  },
};

export default CountdownTimer;
```

### 6. I18n Module Refactoring Pattern

Separate translation concerns from option generation:

```elixir
# BEFORE: Mixing concerns in I18n module
defmodule I18n do
  def translate_profession(profession), do: dgettext("jobs", profession)

  def get_profession_options do  # WRONG - belongs in LiveView
    Enum.map(Enums.professions(), fn profession ->
      {translate_profession(to_string(profession)), to_string(profession)}
    end)
  end
end

# AFTER: Clean separation of concerns
defmodule I18n do
  @moduledoc "Pure translation functions only"

  def translate_profession(profession), do: dgettext("jobs", profession)
  def translate_department(department), do: dgettext("jobs", department)
end

# Option generation belongs in LiveView/context
defmodule MyAppWeb.UserRegistrationLive do
  defp get_profession_options do
    Enum.map(Enums.professions(), fn profession ->
      {I18n.translate_profession(to_string(profession)), to_string(profession)}
    end)
  end
end
```

### 7. Circular Dependency Resolution

Avoid import conflicts in component modules:

```elixir
# WRONG - causes circular dependency
defmodule MyAppWeb.Components.Core.Form do
  use Phoenix.Component
  use MyAppWeb, :html  # Imports too much, causes conflicts
end

# CORRECT - minimal imports for specific needs
defmodule MyAppWeb.Components.Core.Form do
  use Phoenix.Component
  use MyAppWeb, :verified_routes  # Only imports route helpers

  # Import specific modules as needed
  import MyAppWeb.Components.Core.Error
end
```

## Considerations

### Asset Management

- **Never commit localhost URLs**: Always extract and convert to Phoenix static paths
- **Descriptive naming**: Use meaningful filenames instead of hash names from Figma
- **Optimization**: Run SVG optimization tools before committing assets
- **Organization**: Group assets by feature/workflow (e.g., `/images/onboarding/`)

### Responsive Implementation

- **Mobile-first approach**: Start with mobile design, enhance for larger screens
- **Semantic breakpoints**: Use meaningful names (mobile/tablet/desktop) not px values
- **Progressive enhancement**: Add features as screen size increases
- **Touch considerations**: Ensure proper touch targets on mobile devices

### Component Architecture

- **Domain separation**: Organize components by business domain
- **State management**: Use LiveView assigns for step management
- **Validation patterns**: Implement step-specific validation
- **User type adaptation**: Design flows that accommodate different user journeys

### Testing Strategy

- **Visual validation**: Use Playwright MCP for screenshot comparison
- **Cross-viewport testing**: Test all responsive breakpoints
- **User flow testing**: Test complete multi-step workflows
- **Asset loading**: Verify all assets load correctly in production

### Translation Management

- **Clean separation**: Keep translation functions separate from business logic
- **Option generation**: Move to appropriate context (LiveView/context modules)
- **Missing translations**: Always provide fallbacks for incomplete translations
- **Multi-language testing**: Test workflows in all supported languages

## Example Usage

From the BemedaPersonal onboarding implementation:

```elixir
# Figma node extraction
def implement_email_confirmation_screen do
  # 1. Extract design using MCP server
  design_data = get_code("3392:5035")  # Email confirmation mobile design

  # 2. Extract assets
  illustration_url = extract_asset_url(design_data, "email-illustration")

  # 3. Download and optimize
  download_and_optimize_asset(illustration_url, "email-confirmation.svg")

  # 4. Implement component with responsive design
  implement_responsive_component(design_data)
end

# Multi-step form implementation
def render(assigns) do
  ~H"""
  <div class="min-h-screen bg-gray-50">
    <!-- Progress indicator -->
    <.progress_indicator current_step={@step} max_steps={@max_steps} />

    <!-- Step content -->
    <div :if={@step == 1} class="max-w-md mx-auto px-4">
      <.user_type_selection form={@form} />
    </div>

    <div :if={@step == 2 && @user_type == "job_seeker"} class="max-w-lg mx-auto px-4">
      <.personal_information_form form={@form} />
    </div>

    <div :if={@step == 3 && @user_type == "job_seeker"} class="max-w-lg mx-auto px-4">
      <.work_information_form form={@form} />
    </div>
  </div>
  """
end
```

Results achieved:

- **Pixel-perfect implementation**: Exact match with Figma designs across all viewports
- **90.9% test coverage**: Maintained high coverage through implementation
- **Zero hardcoded values**: All styling uses design tokens
- **Production-ready assets**: All localhost URLs converted to static paths

## Related Recipes

- **Semantic Component API Design**: For creating intuitive component interfaces
- **Phoenix Component Migration with Backward Compatibility**: For integrating new components
- **Test Coverage Optimization Strategies**: For maintaining coverage during implementation
