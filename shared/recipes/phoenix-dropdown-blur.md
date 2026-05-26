# Recipe: Phoenix Dropdown with Proper Blur Handling

## Problem

Creating interactive dropdowns in Phoenix LiveView that stay open when users click on internal elements but close when clicking outside. The standard phx-click-away approach fails with complex interactive content, causing premature dropdown closure.

## Solution

Use JavaScript blur event handlers with relatedTarget checks to determine if focus is moving within the dropdown. This provides precise control over when dropdowns should close while maintaining proper accessibility.

## Implementation

### 1. Template Structure

```elixir
<div class="relative">
  <input
    type="text"
    phx-focus="show_suggestions"
    phx-blur="blur_search_input"
    phx-hook="SearchSuggestions"
    id="search-input"
  />

  <div
    :if={@show_suggestions and length(@suggestions) > 0}
    id="search-dropdown"
    class="absolute z-10 bg-white border rounded-lg shadow-lg"
  >
    <div
      :for={suggestion <- @suggestions}
      class="px-4 py-3 cursor-pointer hover:bg-gray-50"
      tabindex="0"
      phx-click="select_suggestion"
      phx-value-query={suggestion.query}
    >
      <%= suggestion.text %>
    </div>
  </div>
</div>
```

### 2. JavaScript Hook Implementation

```javascript
// assets/js/hooks/search_suggestions.js
export default {
  mounted() {
    this.setupBlurHandler();
  },

  setupBlurHandler() {
    const input = this.el.querySelector("input");
    const dropdown = this.el.querySelector('[id$="-dropdown"]');

    if (input) {
      input.addEventListener("blur", (e) => {
        // Check if focus is moving to an element within the dropdown
        if (e.relatedTarget && dropdown && dropdown.contains(e.relatedTarget)) {
          return; // Don't close dropdown
        }

        // Focus moved outside - close dropdown
        this.pushEvent("hide_suggestions");
      });
    }
  },
};
```

### 3. LiveView Event Handlers

```elixir
def handle_event("show_suggestions", _params, socket) do
  {:noreply, assign(socket, show_suggestions: true)}
end

def handle_event("hide_suggestions", _params, socket) do
  {:noreply, assign(socket, show_suggestions: false)}
end

def handle_event("blur_search_input", _params, socket) do
  # This runs but doesn't close dropdown - JavaScript handles it
  {:noreply, socket}
end
```

### 4. Critical Template Requirements

```elixir
# ALL attr declarations must be present for template compilation
attr :show_suggestions, :boolean, required: true
attr :suggestions, :list, required: true
```

## Considerations

### Accessibility Requirements

- **tabindex="0"**: Required on all clickable divs for proper blur event handling
- **Focus management**: Ensure proper focus flow within dropdown elements
- **Keyboard navigation**: Consider arrow key navigation for enhanced UX

### Testing Patterns

- **Manual verification**: Test dropdown stays open for 3+ seconds when clicking internal elements
- **DOM element testing**: Check for actual element presence, not CSS classes
- **Conditional rendering**: Use `:if` conditions rather than CSS `hidden` class for reliable testing

### Common Pitfalls

1. **phx-click-away conflicts**: Remove phx-click-away when using blur handlers - they conflict
2. **Missing tabindex**: Interactive divs need `tabindex="0"` for blur events
3. **Template compilation**: Missing `attr` declarations cause silent failures
4. **relatedTarget null**: Always check for null before calling `.contains()`

### When to Use vs Not Use

- **Use when**: Dropdown contains interactive elements (buttons, links, form inputs)
- **Don't use when**: Simple dropdown with non-interactive content - phx-click-away is simpler
- **Alternative**: Consider modal dialogs for complex interactions requiring guaranteed focus management

## Example Usage

This pattern was used in the ElixirDrops search feature for implementing search suggestion dropdowns that needed to:

- Stay open when users clicked delete buttons on history items
- Close when users clicked outside the dropdown
- Handle both desktop and mobile interactions properly
- Maintain accessibility with keyboard navigation

## Related Recipes

- [Phoenix Component Migration](phoenix-component-migration.md)
- [Semantic Component API Design](semantic-component-api-design.md)
