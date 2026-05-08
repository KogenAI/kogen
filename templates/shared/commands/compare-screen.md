---
description: Compare a Figma screen with its implementation screenshot (user)
argument-hint: "[screen number]"
---

Compare specific Figma design screenshot with current impl. Works with todo list from `/list-screens`.

**Argument:** Screen number (e.g., `1`, `2`, `3`)

## Steps

### 1. Mark todo as in_progress

### 2. Find Figma screenshot

- Read `./codegen/plan/screenshot-content-verification.md` to map screen name to filename
- Locate in `./codegen/design-system/features/{feature}/screenshots/`

### 3. Analyze Figma screenshot

Extract:

- **Data shown**: Names, dates, statuses, counts, item order
- **UI state**: Flash messages, modals, selected tabs
- **User type**: Employer or Job Seeker
- **Viewport**: Mobile (375x812) or Desktop (1280x720)

### 4. Check for existing screenshot script

Look for: `./codegen/design-system/features/{feature}/screenshot-scripts/screen-{N}.js`

If exists → read and verify it matches Figma analysis (update if outdated).
If missing → create based on Figma analysis.

### 5. Find seed by matching screenshot prefix

Convention: seed filename matches screenshot prefix.

```
Screenshot                           →  Seed
─────────────────────────────────────────────────────────
message-*.png                        →  message.exs
s5---jobs-*.png                      →  s5-jobs.exs
s7---review-matched-*.png            →  s7-review-matched-candidates.exs
```

For empty states, append `-empty` to seed name.

Check `./codegen/design-system/features/{feature}/seeds/INDEX.md` for full mapping.

If seed exists → verify creates data matching Figma. **CRITICAL: Verify `locale: :en` on all users.**
If no seed → create with name matching screenshot prefix, add to INDEX.md.

### 6. Run seed script

```bash
mix run ./codegen/design-system/features/{feature}/seeds/{screenshot-prefix}.exs
```

### 7. Run screenshot script

```bash
PORT=$PORT node ./codegen/design-system/features/{feature}/screenshot-scripts/screen-{N}.js
```

### 8. Display both screenshots

### 9. Load Tailwind config

```bash
cat ./assets/css/app.css | head -250
```

### 9b. Extract exact values from Figma specs

```bash
ocg query-figma-spec ./codegen/design-system/features/{feature}/specs badges
ocg query-figma-spec ./codegen/design-system/features/{feature}/specs style "View contract"
ocg query-figma-spec ./codegen/design-system/features/{feature}/specs text
```

Returns: `textColor`, `bgColor`, `fontSize`, `fontWeight`, `cornerRadius`, `padding`.

If specs are <100KB per file, re-extract:

```bash
ocg extract-figma-implementation-specs <file-key> ./codegen/design-system/features/{feature}/node-ids.txt ./codegen/design-system/features/{feature}/specs/
```

### 10. Present comparison

```
## Screen {N}: {Screen Name}

### FIGMA Design:
[Figma screenshot]

### IMPLEMENTATION:
[Impl screenshot]

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

**Your turn to compare!** What differences do you see?
```

### 11. Wait for user feedback

After feedback:

- Document with EXACT Tailwind classes
- Fix issues
- Re-run screenshot to verify
- Mark todo complete when approved
- Suggest `/compare-screen {N+1}`

---

## Specification Requirements

EXACT Tailwind classes required, not vague descriptions.

❌ BAD: "Status color is wrong" | "Needs more padding"

✅ GOOD:

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

| Property   | Must Specify                                     |
| ---------- | ------------------------------------------------ |
| Colors     | Exact class: `text-violet-600`, `bg-gray-50`     |
| Spacing    | Exact values: `px-3 py-1`, `gap-2`, `mt-4`       |
| Typography | Size + weight: `text-sm font-normal`             |
| Layout     | Flexbox/grid: `flex items-center justify-center` |
| Borders    | Full spec: `border border-gray-200 rounded-lg`   |
| Responsive | Prefix when needed: `lg:px-6`                    |

---

## Script Structure

### Seed Script (Elixir)

`./codegen/design-system/features/{feature}/seeds/screen-{N}.exs`

**CRITICAL: All users MUST have `locale: :en`** — Figma designs are in English.

```elixir
# Screen {N}: {Screen Name}
# Data requirements: {describe items}

alias BemedaPersonal.{Repo, Accounts, ...}

user
|> Ecto.Changeset.change(
  confirmed_at: DateTime.utc_now() |> DateTime.truncate(:second),
  locale: :en  # REQUIRED for Figma comparison
)
|> Repo.update!()
```

### Screenshot Script (Playwright)

`./codegen/design-system/features/{feature}/screenshot-scripts/screen-{N}.js`

```javascript
const { chromium } = require("playwright");
const PORT = process.env.PORT || "4007";

(async () => {
  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({ storageState: "auth-state.json" });
  const page = await context.newPage();

  await page.setViewportSize({ width: { width }, height: { height } });
  await page.goto(`http://localhost:${PORT}{route}`);
  await page.waitForLoadState("networkidle");
  await page.waitForTimeout(300);
  await page.screenshot({ path: "/tmp/impl-screen-{N}.png" });

  await browser.close();
})();
```

---

## Flash Message Handling

Flash messages require **actually performing the action**, not mocking.

If Figma shows a flash: seed must create preconditions, Playwright must perform the action, then navigate while flash is visible.

---

## Login Scripts

```bash
node ./playwright/auth/login-employer.js --port $PORT --save-state --email "{seeded_email}"
node ./playwright/auth/login-job-seeker.js --port $PORT --save-state --email "{seeded_email}"
```

---

## Auto-Fix Common Issues

| Issue            | Symptom                        | Auto-Fix                                    |
| ---------------- | ------------------------------ | ------------------------------------------- |
| Wrong locale     | German text instead of English | Add `locale: :en` to user in seed script    |
| Missing flash    | No toast visible               | Verify Playwright performs action correctly |
| Wrong data count | Different item count           | Update seed to match Figma                  |
| Missing user     | Login fails                    | Verify seed creates user with correct email |

Auto-fix workflow: detect → fix seed/script → re-run seed → re-run screenshot → re-compare → continue.
