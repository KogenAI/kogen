---
description: Compare a Figma screen with its implementation screenshot (user)
argument-hint: "[screen number]"
---

Compare a specific Figma design screenshot with the current implementation. Works with the todo list created by `/list-screens`.

**Argument:** Screen number from the todo list (e.g., `1`, `2`, `3`)

## Steps

### 1. Mark todo as in_progress

Update the todo list to mark "Compare Screen N: ..." as `in_progress`

### 2. Find the Figma screenshot

- Read `./codegen/plan/screenshot-content-verification.md` to map screen name to filename
- Locate file in `./codegen/design-system/features/{feature}/screenshots/`

### 3. Analyze the Figma screenshot

Read the Figma screenshot and extract:

- **Data shown**: Names, dates, statuses, counts, order of items
- **UI state**: Flash messages, modals open, selected tabs, etc.
- **User type**: Employer or Job Seeker view
- **Viewport**: Mobile (375x812) or Desktop (1280x720)

Document this analysis - it defines what the implementation screenshot must show.

### 4. Check for existing screenshot script

Look for: `./codegen/design-system/features/{feature}/screenshot-scripts/screen-{N}.js`

**If script exists:**

- Read it and verify it matches the Figma analysis
- If outdated, update it

**If no script:**

- Create it based on the Figma analysis (see Script Structure below)

### 5. Check for existing seed script

Look for: `./codegen/design-system/features/{feature}/seeds/screen-{N}.exs`

**If seed exists:**

- Read it and verify it creates data matching Figma
- **CRITICAL: Verify `locale: :en` is set on all users** (Figma designs are in English)
- If outdated or missing locale, update it

**If no seed:**

- Create it based on the Figma analysis (see Seed Structure below)

### 6. Run the seed script

```bash
mix run ./codegen/design-system/features/{feature}/seeds/screen-{N}.exs
```

### 7. Run the screenshot script

```bash
PORT=$PORT node ./codegen/design-system/features/{feature}/screenshot-scripts/screen-{N}.js
```

### 8. Display both screenshots

- Read the Figma screenshot
- Read the implementation screenshot (from /tmp/impl-screen-{N}.png)

### 9. Load project's Tailwind config

**CRITICAL**: Before documenting differences, load the project's color palette:

```bash
# Find and read Tailwind config
cat ./assets/css/app.css | head -250
```

This gives you the exact color variables available (e.g., `violet-600`, `gray-50`).

### 9b. Extract exact values from Figma specs (RECOMMENDED)

**For pixel-perfect accuracy**, use `ocg query-figma-spec` to extract exact values:

```bash
# Get all status badges with text + background colors
ocg query-figma-spec ./codegen/design-system/features/{feature}/specs badges
# Output:
# {"text": "Sent", "textColor": "#6561ce", "bgColor": "#f2f2fe", "fontSize": 14, "fontWeight": 400, "cornerRadius": 4, "padding": {"h": 8, "v": 4}}

# Get full styling for specific element
ocg query-figma-spec ./codegen/design-system/features/{feature}/specs style "View contract"

# Search by element name
ocg query-figma-spec ./codegen/design-system/features/{feature}/specs element "button"

# List all TEXT nodes
ocg query-figma-spec ./codegen/design-system/features/{feature}/specs text
```

**Key values returned:**

- `textColor`: Hex color for text
- `bgColor`: Hex color for background (from parent container)
- `fontSize`: Font size in px
- `fontWeight`: Font weight (400=normal, 500=medium, 600=semibold)
- `cornerRadius`: Border radius in px
- `padding`: `{h: horizontal, v: vertical}` padding in px

**Why this matters**: Specs extracted with full depth contain 100+ TEXT nodes with exact styling. Visual comparison alone can miss subtle differences.

**⚠️ IMPORTANT**: If specs are <100KB per file, they were extracted with old `depth=3` limit. Re-extract:

```bash
ocg extract-figma-implementation-specs <file-key> ./codegen/design-system/features/{feature}/node-ids.txt ./codegen/design-system/features/{feature}/specs/
```

### 10. Present comparison with EXACT Tailwind specs

```
## Screen {N}: {Screen Name}

### FIGMA Design:
[Figma screenshot displayed]

### IMPLEMENTATION:
[Implementation screenshot displayed]

---

## Analysis:

### Data Match:
- [ ] Same number of items
- [ ] Same names/labels
- [ ] Same statuses/states
- [ ] Same dates
- [ ] Flash message shown (if applicable)

### Visual Match:
- [ ] Colors match
- [ ] Fonts match
- [ ] Spacing/padding match
- [ ] Icons match
- [ ] Backgrounds match

### Differences Found:
| # | Element | Figma | Implementation | Exact Tailwind Fix |
|---|---------|-------|----------------|-------------------|

---

**Your turn to compare!** What differences do you see?
```

### 11. Wait for user feedback

After user provides feedback:

- **Document with EXACT Tailwind classes** (see Specification Requirements below)
- Fix any issues identified
- Re-run screenshot script to verify
- Mark todo as `completed` when approved
- Suggest `/compare-screen {N+1}` for next screen

---

## 🚨 Specification Requirements

**CRITICAL**: When documenting styling differences, you MUST provide exact Tailwind classes, not vague descriptions.

### ❌ BAD (Too Vague):

```
- Status color is wrong
- Needs more padding
- Font should be lighter
- Background is too dark
```

### ✅ GOOD (Exact Specifications):

````markdown
### Issue: Status Badge Styling

**Current:** Plain orange text
**Figma:** Purple pill with light background

**Exact Tailwind classes:**

```html
<span
  class="px-3 py-1 rounded-full text-sm font-normal text-violet-600 bg-violet-50"
>
  Sent
</span>
```
````

**Key classes:**

- `px-3 py-1` - 12px horizontal, 4px vertical padding
- `rounded-full` - pill shape
- `text-sm` - 14px font
- `font-normal` - weight 400 (not bold)
- `text-violet-600` - #7b4eab text color
- `bg-violet-50` - #f2edf7 background

````

### Required Specificity for Each Issue:

| Property | Must Specify |
|----------|--------------|
| Colors | Exact Tailwind class: `text-violet-600`, `bg-gray-50` |
| Spacing | Exact values: `px-3 py-1`, `gap-2`, `mt-4` |
| Typography | Size + weight: `text-sm font-normal`, `text-xl font-medium` |
| Layout | Flexbox/grid: `flex items-center justify-center` |
| Borders | Full spec: `border border-gray-200 rounded-lg` |
| Responsive | Prefix when needed: `lg:px-6`, `lg:border` |

### How to Determine Exact Values:

1. **Check project's `app.css`** for color palette (violet, gray, green, etc.)
2. **Estimate from Figma screenshot** - compare visually to known colors
3. **Use standard Tailwind scale** - `text-sm` = 14px, `text-base` = 16px, etc.
4. **For responsive changes** - use `lg:` prefix for desktop-only styles

---

## Script Structure

### Seed Script (Elixir)

Location: `./codegen/design-system/features/{feature}/seeds/screen-{N}.exs`

**🚨 CRITICAL: All users MUST have `locale: :en`** - Figma designs are in English. Without this, the implementation will show German/default locale text and comparison will fail.

```elixir
# Screen {N}: {Screen Name}
#
# Data requirements from Figma:
# - User: {employer/job_seeker} "{name}"
# - Items: {describe items, names, statuses, dates}
# - Flash trigger: {action that triggers flash, if any}

alias BemedaPersonal.{Repo, Accounts, JobOffers, ...}

# Clean existing test data for this screen
# ...

# Create users - ALWAYS set locale: :en for Figma comparison
user
|> Ecto.Changeset.change(
  confirmed_at: DateTime.utc_now() |> DateTime.truncate(:second),
  locale: :en  # <-- REQUIRED for Figma comparison
)
|> Repo.update!()

# Create items with specific states
# ...

IO.puts("✅ Screen {N} seed data created")
IO.puts("   Login as: {email}")
````

### Screenshot Script (Playwright)

Location: `./codegen/design-system/features/{feature}/screenshot-scripts/screen-{N}.js`

```javascript
// Screen {N}: {Screen Name}
//
// Figma analysis:
// - Viewport: {width}x{height}
// - User: {employer/job_seeker}
// - Route: {url}
// - Flash: {yes/no - what action triggers it}
// - UI state: {any modals, tabs, etc.}

const { chromium } = require("playwright");
const PORT = process.env.PORT || "4007";

(async () => {
  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({ storageState: "auth-state.json" });
  const page = await context.newPage();

  await page.setViewportSize({ width: { width }, height: { height } });

  // If flash message needed, perform the action that triggers it
  // e.g., send an offer, then navigate to list

  // Navigate to final page
  await page.goto(`http://localhost:${PORT}{route}`);
  await page.waitForLoadState("networkidle");

  // Wait for any animations
  await page.waitForTimeout(300);

  // Screenshot
  await page.screenshot({ path: "/tmp/impl-screen-{N}.png" });
  console.log("✅ Screenshot saved: /tmp/impl-screen-{N}.png");

  await browser.close();
})();
```

---

## Flash Message Handling

**IMPORTANT**: Flash messages require **actually performing the action**, not mocking.

If Figma shows a flash like "Your offer has been sent":

1. Seed must create preconditions (applicant ready to hire)
2. Playwright must perform the action (click Hire → fill form → send)
3. Then navigate to the target page while flash is visible
4. Screenshot captures the real result

---

## Login Scripts

Before running screenshot scripts, authenticate:

```bash
# For employer screens
node ./playwright/auth/login-employer.js --port $PORT --save-state --email "{seeded_email}"

# For job seeker screens
node ./playwright/auth/login-job-seeker.js --port $PORT --save-state --email "{seeded_email}"
```

---

## Auto-Fix Common Issues

**IMPORTANT**: When the first screenshot comparison reveals setup issues (not styling issues), fix them automatically and re-run. Do NOT ask user for permission.

### Issues to Auto-Fix:

| Issue            | Symptom                        | Auto-Fix                                        |
| ---------------- | ------------------------------ | ----------------------------------------------- |
| Wrong locale     | German text instead of English | Add `locale: :en` to user in seed script        |
| Missing flash    | No toast message visible       | Verify Playwright performs the action correctly |
| Wrong data count | Different number of items      | Update seed script to match Figma               |
| Missing user     | Login fails                    | Verify seed creates the user with correct email |

### Auto-Fix Workflow:

1. **Detect issue** - Compare screenshots, identify setup problem
2. **Fix seed/script** - Update the appropriate file
3. **Re-run seed** - `mix run ./codegen/design-system/features/{feature}/seeds/screen-{N}.exs`
4. **Re-run screenshot** - `PORT=$PORT node ./codegen/design-system/features/{feature}/screenshot-scripts/screen-{N}.js`
5. **Re-compare** - Show both screenshots again
6. **Continue** - Only ask user about actual styling differences
