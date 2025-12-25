---
description: Compare all Figma screens with implementation, create reports, then fix all issues
---

Batch workflow that compares all screens in a feature against Figma designs, documents differences, then fixes them all at the end.

**CRITICAL: This command runs FULLY AUTONOMOUSLY. Do NOT stop, do NOT ask questions, do NOT wait for user input. Complete ALL screens in one session.**

## ALWAYS RECHECK FROM SCRATCH

**EVERY TIME this command is executed, you MUST:**

1. **Ignore ALL previous comparison results** - Previous sessions don't matter
2. **Ignore ALL RESOLVED context files** - They are historical records, not current state
3. **Re-run ALL seeds and screenshot scripts** - Fresh data every time
4. **Take NEW screenshots** - Implementation may have changed
5. **Compare FRESH screenshots to Figma** - Do the actual visual comparison

**NEVER:**

- Say "screens were already compared"
- Say "all work completed in previous session"
- Reference RESOLVED files as proof of current state
- Skip any screen because it was "done before"
- Assume previous fixes are still correct

**The user explicitly wants FRESH verification every time this command runs.**

## Flow Overview

```
/list-screens
    ↓
┌─────────────────────────────────┐
│  FOR EACH SCREEN:               │
│    1. Run seed + screenshot     │
│    2. Compare Figma vs Impl     │
│    3. /report (append findings) │
│    4. Next screen               │
└─────────────────────────────────┘
    ↓
BATCH FIX all in-scope issues
    ↓
/report (final: fixes applied + out-of-scope for other roles)
```

## Detailed Steps

### 1. Initialize with /list-screens

Invoke `/list-screens` skill to:

- Discover all screens in the feature
- Create a numbered todo list
- Show script status for each screen

### 2. For EACH Screen (Loop)

**Do this for screens 1 through N:**

**A. Run seed and screenshot:**

```bash
# Run seed (only for odd screens - even screens share seed with previous)
mix run ./codegen/design-system/features/{feature}/seeds/screen-{N}.exs

# Run screenshot script
PORT=4007 node ./codegen/design-system/features/{feature}/screenshot-scripts/screen-{N}.js
```

**B. Compare visually:**

- Read Figma screenshot with Read tool
- Read implementation screenshot with Read tool
- Identify ALL differences (colors, spacing, typography, layout, structure)

**C. Invoke `/report` to document findings:**

Append to a single report file for this comparison session. Include:

- Screen name and viewport
- Each issue found with:
  - Description of the difference
  - Whether it's **in-scope** (styling/Tailwind) or **out-of-scope** (structural/logic)
  - File path and suggested fix (for in-scope)
  - Role needed (for out-of-scope): feature-developer, test-engineer, etc.

**D. Update todo and continue:**

- Mark current screen complete
- **IMMEDIATELY** continue to next screen (no pausing)

### 3. After ALL Screens Compared - Batch Fix

1. Read the accumulated report
2. Group all **in-scope** fixes by file
3. Apply all Tailwind/styling changes
4. Re-run screenshot scripts for affected screens
5. Verify fixes visually

### 4. Final /report

Invoke `/report` one final time with:

**A. Fixes Applied (ui-specialist scope):**

```
- File: contract_components.ex
  - Line 77: `rounded-xl border` → `border-b border-gray-100`
  - Line 369: removed `bg-gray-50` from contact buttons
```

**B. Out of Scope (needs other roles):**

```
## feature-developer
1. Desktop slideover: Modal should switch to slideover variant on desktop
   - File: offer_details_form_component.ex
   - Needs: JS hook for viewport detection

## test-engineer
1. [any test issues found]

## verification-engineer
1. [any CI issues found]
```

**C. Key Learnings:**

```
- Figma list items use divider lines, not individual card boxes
- Contact buttons are outline-only without filled background
```

### 5. Final Summary Display

Show ALL screenshots for user review:

```
## Screen 1: {Name} ({Viewport})
### Figma:
[Read figma screenshot]
### Implementation:
[Read impl screenshot]
### Status: ✅ MATCH | ⚠️ OUT OF SCOPE | ❌ NEEDS FIX
---
(repeat for all screens)
```

## In-Scope vs Out-of-Scope

**IN-SCOPE (ui-specialist fixes):**

- Tailwind class changes (colors, spacing, typography)
- CSS styling adjustments
- Layout tweaks within existing structure
- Adding/removing wrapper divs for layout

**OUT-OF-SCOPE (document for other roles):**

- Component structure changes (modal → slideover)
- JavaScript hooks or LiveView logic
- Data/backend issues
- Test failures
- Form handling or validation

## Screen Mapping Reference

Typical mapping (adjust per feature):

| Screen | User Type  | Viewport | Seed         | Figma File Pattern   |
| ------ | ---------- | -------- | ------------ | -------------------- |
| 1      | Employer   | Mobile   | screen-1.exs | org-mobile-\*.png    |
| 2      | Employer   | Desktop  | (same as 1)  | org-desktop-\*.png   |
| 3      | Job Seeker | Mobile   | screen-3.exs | js-mobile-\*.png     |
| 4      | Job Seeker | Desktop  | (same as 3)  | js-desktop-\*.png    |
| 5      | Empty      | Mobile   | screen-5.exs | empty-mobile-\*.png  |
| 6      | Empty      | Desktop  | (same as 5)  | empty-desktop-\*.png |

## Error Handling

**Script fails:** Try once more, if still fails log error and continue to next screen.

**Seed fails:** Log error, continue to next screen, fix seeds during fix phase.

**DO NOT STOP for errors. Log and continue.**

## Screenshot Preservation

- Implementation screenshots: `/tmp/impl-screen-{N}.png`
- NEVER delete screenshots
- User reviews them at the end
