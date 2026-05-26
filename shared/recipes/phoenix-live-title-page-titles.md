# Phoenix LiveView Page Titles

**Problem**: Each LiveView needs a unique browser tab title without duplicating the app name suffix everywhere.
**When**: Setting per-page `<title>` tags in a Phoenix LiveView application with a shared root layout.
**See also**: none

## Solution

Put `<.live_title>` with a `suffix` in the root layout once. Each LiveView assigns only the page-specific part.

```heex
<%# root.html.heex %>
<.live_title suffix=" - Acme">
  <%= assigns[:page_title] %>
</.live_title>
```

```elixir
# in each LiveView mount/2 or handle_params/3
def mount(_params, _session, socket) do
  {:ok, assign(socket, page_title: "About")}
end
```

This produces `<title>About - Acme</title>`. LiveView streams title updates to the browser without a full page reload.

## Gotchas

- Use `assigns[:page_title]` (bracket syntax) in the layout so pages that forget to assign it render an empty string rather than raising a `KeyError`.
- For dynamic titles (e.g. a record name), update `page_title` in `handle_params/3` after the record is loaded, not only in `mount/2`.
