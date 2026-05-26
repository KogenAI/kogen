# Recipe: Domain-Based Browser Test Organization

## Problem

Browser tests are often organized by technology (unit tests, integration tests, JavaScript tests, mobile tests) which creates fragmented coverage and makes it difficult to ensure complete user journey testing. This approach leads to gaps where a feature works in unit tests but fails in real user scenarios due to missing JavaScript interactions or responsive design issues.

## Solution

Organize browser tests by user story domains rather than technology, with each test file representing a complete user journey across all technical aspects (JavaScript, responsive design, real-time features, error handling).

## Implementation

### 1. Domain-Based Test Structure

Instead of technology-based organization:

```
# ❌ Technology-based (fragmented coverage)
test/
├── unit/
│   ├── authentication_test.exs
│   └── drop_crud_test.exs
├── integration/
│   ├── live_view_test.exs
│   └── form_test.exs
├── javascript/
│   ├── search_test.exs
│   └── infinite_scroll_test.exs
└── mobile/
    └── responsive_test.exs
```

Use domain-based organization:

```elixir
# ✅ Domain-based (complete user journeys)
test/elixir_drops_web/features/
├── authentication_domain_test.exs       # Complete auth journey
├── drop_creation_domain_test.exs        # End-to-end drop creation
├── search_functionality_domain_test.exs # All search scenarios
├── navigation_domain_test.exs           # Navigation patterns
├── realtime_features_domain_test.exs    # Live updates
├── responsive_behavior_domain_test.exs  # Mobile/desktop UX
├── error_handling_domain_test.exs       # Error scenarios
└── javascript_interactions_domain_test.exs # Complex UI
```

### 2. Comprehensive Domain Test Structure

Each domain test covers ALL technical aspects for that user journey:

```elixir
# test/elixir_drops_web/features/search_functionality_domain_test.exs
defmodule ElixirDropsWeb.Features.SearchFunctionalityDomainTest do
  use ElixirDropsWeb.FeatureCase

  describe "Search Domain - Complete User Journey" do
    test "unauthenticated user search experience", %{conn: conn} do
      conn
      # JavaScript: Search suggestions
      |> visit("/")
      |> focus("#navbar-search")
      |> wait_for_element(".search-suggestions")
      |> assert_element(".search-suggestion-item", count: 5) # Popular only

      # Form interaction: Search execution
      |> fill_in("#navbar-search", Query: "Phoenix LiveView")
      |> press_key("Enter")
      |> assert_text("Search results for \"Phoenix LiveView\"")

      # Responsive: Mobile search overlay
      |> resize_window(375, 667)
      |> click("#mobile-search-trigger")
      |> wait_for_element("#search-overlay.active")
      |> fill_in("#mobile-search-overlay input", Query: "Elixir")
      |> press_key("Enter")
      |> refute_element("#search-overlay.active")

      # Error handling: No results
      |> fill_in("#navbar-search", Query: "nonexistent query")
      |> press_key("Enter")
      |> assert_text("No drops found")

      # Real-time: Search persistence in URL
      |> assert_url_params(q: "nonexistent query")
    end

    test "authenticated user search with history", %{conn: conn} do
      user = user_fixture()

      conn
      |> sign_in_user(user)
      # Test 2+3 rule: 2 history + 3 popular suggestions
      |> visit("/")
      |> focus("#navbar-search")
      |> assert_element(".search-history-item", count: 2)
      |> assert_element(".popular-search-item", count: 3)

      # JavaScript interaction: Clear history
      |> click(".clear-history-button")
      |> refute_element(".search-history-item")

      # Test user's drops search (different context)
      |> visit("/profile")
      |> fill_in("#profile-search", Query: "my drop")
      |> press_key("Enter")
      # Should only search user's drops, not all drops
    end
  end
end
```

### 3. PhoenixTest.Playwright Integration

Use browser automation for realistic user interactions:

```elixir
# test/support/feature_case.ex
defmodule ElixirDropsWeb.FeatureCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      use PhoenixTest.Playwright.Case,
        async: true,
        parameterize: [%{browser: :chromium}]

      import ElixirDrops.FeatureHelpers
      import ElixirDrops.AccountsFixtures
      import ElixirDrops.DropsFixtures
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(ElixirDrops.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end
end
```

### 4. Domain Test Planning Template

For each domain, cover these aspects:

```elixir
describe "#{Domain} - Complete User Journey" do
  # 1. Core functionality (happy path)
  test "primary user flow - #{domain} works end-to-end"

  # 2. JavaScript interactions
  test "#{domain} JavaScript features (modals, dropdowns, dynamic UI)"

  # 3. Responsive behavior
  test "#{domain} mobile experience (touch, overlays, responsive layout)"

  # 4. Real-time features
  test "#{domain} live updates (WebSocket, PubSub, streaming)"

  # 5. Error handling
  test "#{domain} error scenarios (validation, 404s, network failures)"

  # 6. Edge cases
  test "#{domain} boundary conditions (empty states, limits, permissions)"

  # 7. Cross-browser validation
  test "#{domain} browser compatibility (if needed)"
end
```

## Considerations

### Benefits

- **Complete Coverage**: Each user journey tested across all technical layers
- **User-Focused**: Tests match actual user stories and acceptance criteria
- **Maintainable**: Related functionality grouped together, easier to update
- **Gap Prevention**: Impossible to miss JavaScript or responsive issues
- **Realistic Testing**: Real browser execution catches integration issues

### Trade-offs

- **Test Duration**: More comprehensive tests take longer to run
- **Setup Complexity**: Requires browser automation infrastructure
- **Resource Usage**: Real browsers consume more CI resources
- **Learning Curve**: Team needs PhoenixTest.Playwright knowledge

### When to Use

- ✅ When you have complex JavaScript interactions (infinite scroll, modals, search)
- ✅ When responsive design is critical to user experience
- ✅ When real-time features (WebSocket, LiveView) are core functionality
- ✅ When user experience quality is more important than test speed
- ✅ When you have CI resources for browser automation

### When NOT to Use

- ❌ For pure API testing (use lightweight integration tests)
- ❌ When JavaScript is minimal (basic Phoenix LiveView only)
- ❌ For performance testing (use dedicated performance tools)
- ❌ When CI resources are severely limited

## Example Usage

This pattern was successfully applied in an Elixir code-sharing platform:

```elixir
# Before: Fragmented testing
- Unit tests passed ✅
- LiveView tests passed ✅
- JavaScript worked in browser ✅
- BUT: Search suggestions didn't work on mobile ❌

# After: Domain organization
- Search Domain Test: Mobile overlay + suggestions + real-time ✅
- Complete user journey validated in single comprehensive test
- Issues caught before production deployment
```

### Key Test Files Created

1. **Authentication Domain**: Sign in, protected routes, permissions across devices
2. **Drop Creation Domain**: Form validation, live preview, screenshot generation
3. **Search Functionality Domain**: Suggestions, mobile overlay, result filtering
4. **Navigation Domain**: Menu interactions, breadcrumbs, responsive navigation
5. **Real-time Features Domain**: Live updates, WebSocket stability, notification handling
6. **Responsive Behavior Domain**: Mobile/tablet/desktop layout validation
7. **Error Handling Domain**: 404 pages, validation feedback, permission errors
8. **JavaScript Interactions Domain**: Modals, infinite scroll, dynamic UI elements

## Related Recipes

- [PhoenixTest.Playwright Browser Testing](phoenix-verified-routes-dynamic.md) - For route testing strategies
- [Flaky Test Fix](flaky-test-fix.md) - For maintaining test reliability
- [Test Coverage Strategies](test-coverage-strategies.md) - For managing comprehensive test suites
