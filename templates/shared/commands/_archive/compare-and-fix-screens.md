---
description: Compare all Figma screens with implementation, create reports, then fix all issues
---

Batch workflow: compare all screens against Figma designs, document differences, fix them all.

**CRITICAL: Runs FULLY AUTONOMOUSLY. Do NOT stop, ask questions, or wait for user input. Complete ALL screens in one session.**

## ALWAYS RECHECK FROM SCRATCH

Every execution:

1. Ignore ALL previous comparison results
2. Ignore ALL RESOLVED context files
3. Re-run ALL seeds — fresh data
4. Take NEW screenshots
5. Compare FRESH screenshots to Figma

NEVER:

- Say "screens were already compared"
- Reference RESOLVED files as proof of current state
- Skip any screen because it was "done before"

## CRITICAL RULES

### Path Configuration

Use RELATIVE paths for context files. NEVER absolute.

```bash
# ✅ CORRECT
./codegen/context/PENDING-*.md

# ❌ WRONG — will write to wrong location!
/Users/.../bemeda_personal/codegen/context/PENDING-*.md
```

### Port Configuration

NEVER hardcode ports. Always use `$PORT`:

```bash
curl http://localhost:$PORT/health
node ./playwright/auth/login.js --port $PORT
```

### Workspace Root

ALL commands run from workspace root:

- Design system: `./codegen/design-system/features/{feature}/`
- Seeds: `./codegen/design-system/features/{feature}/seeds/`
- Screenshots: `./codegen/design-system/features/{feature}/screenshots/`
- Specs: `./codegen/design-system/features/{feature}/specs/`

### Symlink Path Resolution

```bash
DESIGN_SYSTEM_PATH=$(readlink -f ./codegen/design-system 2>/dev/null || readlink ./codegen/design-system)
```

## COMPLETE AUTONOMOUS WORKFLOW

### Phase 1: Environment Setup

```bash
echo "Using PORT=$PORT"
curl -s -o /dev/null -w "%{http_code}" http://localhost:$PORT/ || echo "Server not responding - BLOCKED"
cat ./codegen/plan/overview.md | head -20
```

### Phase 2: Discover Screens

```bash
ls ./codegen/design-system/features/
ls ./codegen/design-system/features/{feature}/screenshots/
cat ./codegen/plan/screenshot-content-verification.md
```

Create todo list via TodoWrite with all screens found.

### Phase 3: Reset DB and Run ALL Seeds

```bash
mix ecto.reset
ls ./codegen/design-system/features/{feature}/seeds/*.exs
mix run ./codegen/design-system/features/{feature}/seeds/messages.exs
mix run ./codegen/design-system/features/{feature}/seeds/contracts.exs
# [run all seed files]
```

All seed users MUST have `locale: :en` for Figma comparison.

### Phase 4: Load Project Tailwind Config

```bash
cat ./assets/css/app.css | head -300
```

### Phase 5: For EACH Screen (Loop)

#### 5A. Mark todo as in_progress

#### 5B. Determine screen details

From screenshot-content-verification.md:

- **User type**: employer or job_seeker
- **Viewport**: Mobile (375x812) or Desktop (1280x720)
- **Route**: Phoenix route to screenshot
- **Figma file**: PNG filename

#### 5C. Login (if needed)

```bash
node ./playwright/auth/login-employer.js --port $PORT --save-state --email "{seeded_email}"
# or
node ./playwright/auth/login-job-seeker.js --port $PORT --save-state --email "{seeded_email}"
```

#### 5D. Take implementation screenshot

```bash
node ./playwright/screenshots/take-authenticated.js \
  --url {route} \
  --output /tmp/impl-screen-{N}.png \
  --viewport {375x812|1280x720} \
  --port $PORT
```

#### 5E. Visual comparison (MULTIMODAL)

1. Read Figma screenshot: `./codegen/design-system/features/{feature}/screenshots/{figma-file}.png`
2. Read impl screenshot: `/tmp/impl-screen-{N}.png`
3. Identify ALL differences

For each difference:

- **Element**: What UI element is wrong
- **Figma value**: What Figma shows
- **Implementation value**: What impl shows
- **In-scope**: YES if Tailwind class change can fix it, NO if structural/logic

#### 5F. Extract exact values from specs

```bash
ocg query-figma-spec ./codegen/design-system/features/{feature}/specs badges
ocg query-figma-spec ./codegen/design-system/features/{feature}/specs style "View contract"
ocg query-figma-spec ./codegen/design-system/features/{feature}/specs text
```

Returns: `textColor`, `bgColor`, `fontSize`, `fontWeight`, `cornerRadius`, `padding`.

#### 5G. Document findings

```markdown
## Screen {N}: {Name} ({Viewport})

**Route**: {route}
**User**: {employer|job_seeker}
**Figma**: {filename}

### Differences Found:

| #   | Element      | Figma                       | Implementation  | In-Scope | Exact Fix                                            |
| --- | ------------ | --------------------------- | --------------- | -------- | ---------------------------------------------------- |
| 1   | Status badge | text-[#6561ce] bg-[#f2f2fe] | text-orange-500 | YES      | `text-[#6561ce] bg-[#f2f2fe] px-3 py-1 rounded-full` |
```

#### 5H. Mark todo complete and CONTINUE IMMEDIATELY to Screen N+1.

### Phase 6: Batch Fix All In-Scope Issues

After ALL screens compared:

1. Collect all in-scope issues (In-Scope = YES)
2. Group fixes by file
3. Apply all fixes via Edit tool
4. Re-screenshot affected screens to verify

### Phase 7: Final Report

- **All styling fixed, no out-of-scope**: `./codegen/context/RESOLVED-figma-comparison-{timestamp}.md`
- **Has out-of-scope items**: `./codegen/context/PENDING-figma-comparison-{timestamp}.md`

### Phase 7B: PENDING Reports for Structural Issues

For each out-of-scope issue, create separate PENDING file:

```markdown
# File: ./codegen/context/PENDING-structural-{issue-slug}-{timestamp}.md

# Structural Issue: {Title}

**Source**: ui-specialist (figma comparison)
**Target**: developer-phoenix-backend
**Priority**: {HIGH|MEDIUM|LOW}
**Figma Screen**: {screenshot filename}

## Problem

{What Figma shows vs what impl shows}

## Required Changes

1. {Specific change needed}

## Acceptance Criteria

- [ ] {Criterion}
- [ ] Screen matches Figma design

## Reference

- Figma screenshot: `./codegen/design-system/features/{feature}/screenshots/{filename}`
- Impl screenshot: `/tmp/impl-screen-{N}.png`
```

### Phase 8: Final Summary

Display all screenshots side-by-side with status: ✅ MATCH | ⚠️ OUT OF SCOPE ITEMS | ❌ NEEDS MORE WORK

## Error Handling

Script fails → try once more, then log and continue to next screen.
Server not responding → report BLOCKED immediately.
Do NOT stop for errors — log and continue.

## In-Scope vs Out-of-Scope

**IN-SCOPE (fix immediately):**

- Tailwind class changes
- CSS styling adjustments
- Layout tweaks within existing structure

**OUT-OF-SCOPE (document for other roles):**

- Component structure changes
- JavaScript hooks or LiveView logic
- Data/backend issues
- Missing routes or pages

## Specification Requirements

Provide EXACT Tailwind classes, not vague descriptions.

❌ BAD: "Status color is wrong" | "Needs more padding"

✅ GOOD:

```markdown
| Element      | Figma               | Implementation | Exact Fix                                                        |
| ------------ | ------------------- | -------------- | ---------------------------------------------------------------- |
| Status badge | Purple pill #6561ce | Orange text    | `text-[#6561ce] bg-[#f2f2fe] px-3 py-1 rounded-full font-normal` |
```

## Screenshot Preservation

- Impl screenshots: `/tmp/impl-screen-{N}.png`
- Fixed screenshots: `/tmp/impl-screen-{N}-fixed.png`
- NEVER delete screenshots during session
