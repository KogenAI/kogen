# Detailed Planning Session Context

## Session Details

- **Mode**: Detailed Planning
- **Feature**: {{FEATURE_NAME}}
- **Model**: Claude Sonnet
- **Started**: {{SESSION_TIMESTAMP}}

## 🚫 FORBIDDEN TOOLS - DO NOT USE

**CRITICAL**: These Claude Code built-in tools CONFLICT with OCG planning workflow:

- ❌ **EnterPlanMode** - NEVER use
- ❌ **ExitPlanMode** - NEVER use

OCG planning writes directly to `codegen/plans/` or `codegen/planning_sessions/` using the **Write** tool. The built-in plan mode creates plans in `~/.claude/plans/` which is NOT how OCG works.

---

## 🛑 BLOCKING: Load Rules BEFORE Anything Else

**STOP! You CANNOT proceed without completing these steps IN ORDER:**

### Step 1: Load Core Planning Rules (REQUIRED)

```
Read file: ./codegen/rules/planning.md
Read file: ./codegen/rules/INDEX.md
```

**Checkpoint**: You must have read BOTH files above before continuing.

### Step 2: Detect Project Type from PROJECT_CONTEXT.md

Look for these indicators in PROJECT_CONTEXT.md:

- **Monorepo**: Has both `backend/` AND `mobile/` directories
- **Backend-only**: Has `lib/` and `mix.exs` at root
- **Flutter-only**: Has `lib/` and `pubspec.yaml` at root

### Step 3: Load Domain Rules Based on Project Type

**For Monorepo (backend + mobile)**:

```
Read file: ./codegen/rules/subagents/phoenix.md
Read file: ./codegen/rules/subagents/phoenix-ui.md
Read file: ./codegen/rules/subagents/elixir-code-generation.md
Read file: ./codegen/rules/subagents/flutter.md
Read file: ./codegen/rules/subagents/mobile-testing.md
```

**For Phoenix/Elixir (includes LiveView UI)**:

```
Read file: ./codegen/rules/subagents/phoenix.md
Read file: ./codegen/rules/subagents/phoenix-ui.md
Read file: ./codegen/rules/subagents/elixir-code-generation.md
```

**For Flutter Mobile-only**:

```
Read file: ./codegen/rules/subagents/flutter.md
Read file: ./codegen/rules/subagents/mobile-testing.md
```

**Note**: Phoenix projects ALWAYS include `phoenix-ui.md` because Phoenix LiveView is inherently a UI framework.

### Step 4: Load Additional Domain Rules Based on Feature

Based on what the user describes as the feature, also load:

- **Figma design implementation**: `rules/subagents/ui-implementation.md` (pixel-perfect from Figma)
- **Testing features**: `rules/subagents/testing.md` + `rules/subagents/feature-tests.md`
- **Translation features**: `rules/subagents/i18n.md`
- **CI/deployment features**: `rules/subagents/github-actions.md` + `rules/subagents/deployment.md`

**Note**: `phoenix-ui.md` (LiveView components, forms, JS hooks) is already loaded in Step 3 for Phoenix projects. `ui-implementation.md` is for Figma-to-code pixel-perfect workflows.

### 🚨 VALIDATION: Prove You Loaded Rules

**Before saying "ready for feature description", you MUST:**

1. **List which rules you loaded** (file paths)
2. **State the project type** you detected (monorepo/backend-only/etc.)
3. **Only THEN** say you're ready for the feature description

**Example correct response after loading rules:**

> "I've loaded the following rules:
>
> - `./codegen/rules/planning.md` (planning structure)
> - `./codegen/rules/INDEX.md` (rule discovery)
> - `./codegen/rules/subagents/phoenix.md` (Phoenix patterns)
> - `./codegen/rules/subagents/phoenix-ui.md` (LiveView UI patterns)
> - `./codegen/rules/subagents/elixir-code-generation.md` (Elixir patterns)
>
> Project type detected: **Phoenix/Elixir** (has lib/ and mix.exs at root)
>
> I'm ready for you to describe the feature."

**Why**: Plans with specific code must follow domain patterns. Loading appropriate rules prevents bad code patterns that won't get fixed during implementation.

## 🚨 MANDATORY: Figma Extraction FIRST (If Figma URLs Provided)

**CRITICAL**: If user provides Figma URLs, you MUST extract designs FIRST before asking questions.

### Understanding Figma URL Types

**IMPORTANT**: Users typically provide URLs to **section/group frames** (containers), NOT individual screens.

| URL Type              | What It Contains                    | How to Handle                                      |
| --------------------- | ----------------------------------- | -------------------------------------------------- |
| Section URL           | Multiple individual screens stacked | Extract child node IDs, screenshot each separately |
| Page URL              | Multiple sections/groups            | Extract children at depth=2 or depth=3             |
| Individual Screen URL | Single screen                       | Screenshot directly                                |

**How to detect**: If the Figma frame is very tall (>2000px) or contains multiple distinct UI states, it's a container.

### Two-Phase Extraction Process

**Phase 1: Extract Specs from Parent Frames (Get Structure)**

```bash
# 1. Create feature directory
mkdir -p ./codegen/design-system/features/$FEATURE_NAME

# 2. Create initial node-ids.txt with parent frame IDs from user URLs
# Convert URL format: node-id=7698-6557 → 7698:6557
cat > ./codegen/design-system/features/$FEATURE_NAME/node-ids.txt <<'EOF'
7698:6557|Organization Account Settings - Mobile|Parent section
7732:14533|Job Seeker Account Settings - Mobile|Parent section
8344:26852|Organization Account Settings - Desktop|Parent section
8344:65300|Job Seeker Account Settings - Desktop|Parent section
EOF

# 3. Extract specs ONLY (not screenshots yet) - this gives us child structure
ocg extract-figma-implementation-specs \
    "$FIGMA_FILE_KEY" \
    "./codegen/design-system/features/$FEATURE_NAME/node-ids.txt" \
    "./codegen/design-system/features/$FEATURE_NAME/specs"
```

**Phase 2: Extract Individual Screen Node IDs from Specs**

```bash
# Parse specs to find individual screen frames
for spec_file in ./codegen/design-system/features/$FEATURE_NAME/specs/*-specs.json; do
    echo "=== $(basename $spec_file) ==="
    jq -r '.document.children[] | select(.type == "FRAME" or .type == "INSTANCE") | "\(.id)|\(.name)"' "$spec_file"
done
```

**Phase 3: Create Individual Screen Node IDs File**

After parsing, create a new node-ids.txt with INDIVIDUAL screens (not parent frames):

```bash
# Format: node-id|feature--variant--state|description
# Naming convention: {feature}--{variant}--{state}
cat > ./codegen/design-system/features/$FEATURE_NAME/node-ids.txt <<'EOF'
# Organization Mobile Screens
7698:21514|account-settings--mobile--main|Main settings view
7725:8547|account-settings--mobile--my-info|My info section
7698:26923|account-settings--mobile--update-info|Update account info form
7725:10315|account-settings--mobile--delete-confirm|Delete account confirmation
7725:15111|account-settings--mobile--email-prefs|Email preferences
7920:46496|account-settings--mobile--set-password|Set password form
7920:36808|account-settings--mobile--change-password|Change password form
# Job Seeker Mobile Screens
7732:15011|account-settings--mobile-js--main|Job seeker main settings
7734:2810|account-settings--mobile-js--update-info|Job seeker update info
7734:4105|account-settings--mobile-js--email-prefs|Job seeker email prefs
# Desktop Screens
8344:62923|account-settings--desktop--my-info|Desktop my info view
8344:63299|account-settings--desktop--update-info|Desktop update form
8344:64955|account-settings--desktop--set-password|Desktop set password
EOF
```

**Screenshot Naming Convention:**

| Component | Format                                                    | Example                                    |
| --------- | --------------------------------------------------------- | ------------------------------------------ |
| Feature   | lowercase, kebab-case                                     | `account-settings`                         |
| Variant   | `mobile`, `desktop`, `tablet` + optional user type suffix | `mobile`, `mobile-js` (job seeker)         |
| State     | action or view state                                      | `main`, `edit`, `delete-confirm`, `empty`  |
| Full name | `{feature}--{variant}--{state}`                           | `account-settings--mobile--delete-confirm` |

**Phase 4: Extract Individual Screenshots**

```bash
# Now extract screenshots - each will be reasonably sized
ocg extract-figma-screenshots \
    "$FIGMA_FILE_KEY" \
    "./codegen/design-system/features/$FEATURE_NAME/node-ids.txt" \
    "./codegen/design-system/features/$FEATURE_NAME/screenshots"
```

**Phase 5: Generate Screen Index**

Create `./codegen/design-system/features/$FEATURE_NAME/SCREENS.md`:

```markdown
# Account Settings Screens

## Organization (Employer) Screens

### Mobile

| Screenshot                                  | Node ID    | State | Description                              |
| ------------------------------------------- | ---------- | ----- | ---------------------------------------- |
| `account-settings--mobile--main.png`        | 7698:21514 | Main  | Settings home with My Info/Password tabs |
| `account-settings--mobile--my-info.png`     | 7725:8547  | View  | Account info display                     |
| `account-settings--mobile--update-info.png` | 7698:26923 | Edit  | Account info edit form                   |
| ...                                         | ...        | ...   | ...                                      |

### Desktop

| Screenshot                               | Node ID    | State | Description          |
| ---------------------------------------- | ---------- | ----- | -------------------- |
| `account-settings--desktop--my-info.png` | 8344:62923 | View  | Desktop account info |
| ...                                      | ...        | ...   | ...                  |

## Job Seeker Screens

...
```

### Workflow Summary

```
User provides Figma URLs (section/group frames)
           ↓
Phase 1: Extract specs from parent frames
           ↓
Phase 2: Parse specs → get individual screen node IDs
           ↓
Phase 3: Create node-ids.txt with meaningful names
           ↓
Phase 4: Extract individual screenshots (small, viewable)
           ↓
Phase 5: Generate SCREENS.md index
           ↓
Analyze screenshots and plan implementation
```

### What to Ignore vs Include from Figma Screenshots

- ❌ **IGNORE**: Browser chrome (address bar, browser tabs, window controls)
- ❌ **IGNORE**: Figma section labels/headers (purple bars with section names)
- ✅ **INCLUDE**: Application navigation (top nav, sidebars, breadcrumbs)
- ✅ **INCLUDE**: All UI elements within the application viewport

**🚨 FORBIDDEN: DO NOT ask questions about things visible in Figma designs!**

**Examples of FORBIDDEN questions after Figma extraction**:

- ❌ "How should the UI be organized?" (visible in screenshots)
- ❌ "What should be shown in the list?" (visible in screenshots)
- ❌ "Should both user types see this page?" (visible in screenshots - if shown for both, answer is yes)
- ❌ "How should items be labeled?" (visible in screenshots)
- ❌ "Should we include feature X?" (if shown in Figma, answer is YES)

**Examples of ALLOWED questions after Figma extraction**:

- ✅ "Should messages link to JobApplications or support standalone conversations?" (backend architecture)
- ✅ "What happens when user clicks 'Delete'?" (behavior not shown in static design)
- ✅ "Should we implement real-time updates or polling?" (technical implementation choice)
- ✅ "What permissions should control message access?" (security/authorization)

## 🚨 MANDATORY: Clarifying Questions (After Figma Extraction)

**CRITICAL**: After loading context, rules, AND extracting Figma (if applicable), ask clarifying questions about unclear requirements.

### Required Question Categories

Use the `AskUserQuestion` tool to ask about:

**1. Implementation Preferences**

- Should this be fully automated or include manual steps?
- Are there specific libraries/tools you want to use (or avoid)?
- What level of automation is expected for deployment?

**2. Environment & Infrastructure**

- What accounts/services already exist? (cloud providers, domains, etc.)
- Are there existing credentials/secrets to reuse?
- What environments are needed? (staging only? staging + prod?)

**3. Scope Clarification**

- What's the MVP vs full implementation?
- Are there parts that can be deferred to later iterations?
- Should the plan cover both setup AND ongoing maintenance?

**4. Manual Steps Identification**

- What manual steps are acceptable during implementation?
- What needs to be done BEFORE implementation can start?
- Are there approval/review gates required?

**5. Testing & Verification**

- How should we verify the implementation works?
- What's the rollback strategy if something fails?
- Who needs to sign off on completion?

### Example Questions to Ask

```
- "Do you already have the Vultr account and domain registered?"
- "Should this plan cover staging only, or both staging and production?"
- "Do you want provisioning scripts or manual runbook steps?"
- "What secrets/credentials do you have ready vs need to create?"
- "Should the mobile app config be part of this plan or separate?"
```

### Identify Manual Prerequisites (Bookend Pattern)

**CRITICAL**: Plans should follow the **bookend pattern** - manual steps at START and END, autonomous middle.

```
┌─────────────────┐     ┌─────────────────────────────┐     ┌─────────────────┐
│  MANUAL START   │ ──► │    AUTONOMOUS MIDDLE        │ ──► │   MANUAL END    │
│  (User does)    │     │    (Agent runs unattended)  │     │  (User verifies)│
└─────────────────┘     └─────────────────────────────┘     └─────────────────┘
```

**1. BEFORE Implementation (User does manually):**

- Account creation (cloud providers, services, domains)
- Secret generation (`mix phx.gen.secret`, API keys)
- SSH key setup and access verification
- DNS record creation (can start propagating while agent works)
- Provide all secrets/credentials to agent or config files

**2. DURING Implementation (Agent runs autonomously):**

- ❌ **AVOID manual steps here** - breaks autonomous flow
- If unavoidable (e.g., DNS propagation wait), script should poll/retry automatically
- All secrets should be passed via environment variables or config files, NOT interactive prompts
- Scripts should be idempotent (safe to re-run if interrupted)

**3. AFTER Implementation (User verifies):**

- Final testing on real devices
- Smoke test critical paths
- Verify monitoring/alerting works
- Optional: security review, documentation updates

### Design for Autonomy

When planning, ask yourself:

- **Can this secret be passed as an environment variable?** → Do that instead of interactive prompt
- **Can this wait be automated with polling/retry?** → Do that instead of manual checkpoint
- **Can this be validated programmatically?** → Add health checks instead of manual verification
- **Can prerequisites be verified at script start?** → Fail fast with clear error message

**Example - BAD (requires mid-flow intervention):**

```bash
# Script pauses and waits for user
echo "Edit /etc/app/secrets.env with your credentials, then press Enter"
read
```

**Example - GOOD (secrets passed upfront):**

```bash
# Script reads from environment, fails fast if missing
SECRET_KEY="${SECRET_KEY_BASE:?Error: SECRET_KEY_BASE required}"
```

### When to Skip Questions

Only skip if:

- User already answered these in the conversation
- This is a continuation of a previous planning session
- Bird-eye plan already captured all requirements
- User explicitly said "just plan it, I'll handle prerequisites"

**DEFAULT: ASK QUESTIONS FIRST**

---

## Planning Phase: Technical Implementation

You are in the technical planning phase - **detailed implementation planning**. This phase focuses on creating comprehensive technical plans ready for implementation.

### ⚠️ CRITICAL: PLANNING ONLY - NO IMPLEMENTATION

**DO NOT IMPLEMENT OR EDIT CODE** - This is a planning-only session. You should:

- ✅ **Analyze** existing code to understand patterns
- ✅ **Read** files to understand the current implementation
- ✅ **Plan** the technical approach in detail
- ✅ **Write plan files** to `codegen/plans/{{FEATURE_NAME}}/` using Write tool
- ❌ **NEVER use Edit or MultiEdit tools** on code files
- ❌ **NEVER modify code files** - only create/update plan markdown files
- ❌ **NEVER implement the actual solution**
- ❌ **NEVER use EnterPlanMode or ExitPlanMode tools** - these are Claude Code built-in tools that conflict with OCG planning. Write plans directly to `codegen/plans/` instead.

**Your job is to create a detailed plan, not to implement it.**

### What You Should Focus On

**Technical Architecture**

- How will this feature be technically implemented?
- What are the key components and their interactions?
- How does this fit with existing system architecture?

**Code Integration Analysis**

- What existing code can be reused or extended?
- What are the integration points with current features?
- What patterns and conventions should be followed?

**Implementation Details**

- What database changes are needed?
- What API endpoints need to be created/modified?
- What frontend components are required?
- What background jobs or processes are needed?

**Quality Considerations**

- What tests need to be written?
- What are the security implications?
- What are the performance considerations?
- What error handling is required?

### Available Resources

**Codebase Analysis**

- Full read access to the entire codebase
- Use Grep, Glob, Read, and Task tools for thorough analysis
- Look for similar existing implementations to learn from
- Understand current patterns and architectural decisions

**Project Context**

- Review `codegen/PROJECT_CONTEXT.md` to understand the system architecture, patterns, and conventions
- Current planning context is in `codegen/PLANNING_SESSION_CONTEXT.md` (this file)
- Main project instructions remain in `CLAUDE.md`

**Figma Design Integration**

🚨 **CRITICAL**: If the user provides Figma node IDs or design references, you MUST handle them properly:

### Phase 0: Design System Bootstrap (MANDATORY for Figma Projects)

**BLOCKING REQUIREMENT**: Complete bootstrap BEFORE planning implementation steps.

#### Step 1: Detect Figma Usage

```bash
grep "Figma File:" ./codegen/PROJECT_CONTEXT.md
```

**If Figma detected, you MUST complete bootstrap before continuing.**

#### Step 2: Get Figma File Key

Extract from PROJECT_CONTEXT.md:

- Line format: `Figma File: <file-key>`
- Example: `Figma File: 3MHrzLfTHWONfilGE5QU5a`

#### Step 3: Check Cache Status

```bash
ls $REPO_ROOT/codegen/design-system/screenshots/ 2>/dev/null
```

**If cache exists**: Skip bootstrap, use existing cache
**If cache missing**: MUST complete bootstrap below

#### Step 4: Bootstrap Process (Order is CRITICAL)

**4a. Create Node IDs List (Manually identify from Figma)**

**CRITICAL:** You manually identify which node IDs you need (NOT extracting whole file)

Create the node IDs file for your feature by inspecting Figma:

```bash
# Create feature directory
mkdir -p $REPO_ROOT/codegen/design-system/features/$FEATURE_NAME

# Manually create node-ids.txt with format: node-id|screen-name|description
cat > $REPO_ROOT/codegen/design-system/features/$FEATURE_NAME/node-ids.txt <<'EOF'
8296:62670|Messages - Desktop|Desktop screens parent
8322:46182|Messages - Empty state|Desktop empty state
8322:46530|Messages - With messages|Desktop with conversation
7782:42684|Messages - Mobile|Mobile screens parent
8328:10511|Messages - With files|Desktop with file attachments
8325:10075|Messages - Reply preview|Reply preview bar
EOF
```

**How to find node IDs:**

1. Open Figma file in browser
2. Select the frame/screen you need
3. Copy node ID from URL (e.g., `node-id=8296-62670`)
4. Add to node-ids.txt with descriptive name

**EXPAND Directive (When User Provides Section/Page URLs)**

When user provides Figma section or page URLs, use `EXPAND:` to auto-extract all child screens:

```bash
# Create node-ids.txt with EXPAND directives (convert URL dash to colon format)
cat > $REPO_ROOT/codegen/design-system/features/$FEATURE_NAME/node-ids.txt <<'EOF'
EXPAND:8296:62670:depth=1|Desktop Section|Desktop screens
EXPAND:8547:8826:depth=1|Mobile Section|Mobile screens
EOF
```

**EXPAND Syntax:**

- `EXPAND:node-id` - Extract immediate children (depth=1)
- `EXPAND:node-id:depth=2` - Extract grandchildren (for nested pages)
- `EXPAND:node-id:depth=3` - Extract great-grandchildren (rarely needed)

**Depth Guidelines:**

- **Section URLs** (most common): Use `depth=1` - directly reaches screens
- **Page URLs**: Use `depth=2` or `depth=3` - navigates through hierarchy
- **Test if unsure**: Start with `depth=1`, increase if no screens found

**When to use manual node IDs instead:**

- User already provides exact screen node IDs → Just use those directly
- Need precise control over specific screens → Use manual node IDs
- Cherry-picking 2-3 specific screens → Use manual node IDs

See `$OCG_DIR/templates/FIGMA_EXPAND_USAGE.md` for full documentation.

**4b. Extract Design Tokens (ONCE for entire Figma file - FREE)**

**CRITICAL:** Use Figma REST API directly - NO AI tokens required!

**If tokens exist already:**

```bash
ls $REPO_ROOT/codegen/design-system/variables.json
# If exists: Skip extraction, reuse existing tokens
```

**If tokens NOT cached, extract with REST API:**

```bash
# Extract published variables via REST API (requires FIGMA_API_TOKEN)
ocg extract-figma-variables \
    "<file-key-from-PROJECT_CONTEXT>" \
    "$REPO_ROOT/codegen/design-system/variables.json"
```

**What you get:**

- All published variables (colors, spacing, typography, border radius)
- Two files created: `variables.json` + `variables-readable.json`
- **FREE** - no AI tokens burned
- **SHARED across ALL features** - extract once, use everywhere

**Then update:** `./codegen/FIGMA_TOKEN_MAPPING.md` with extracted values

**4c. Extract Screenshots (Only What You Need)**

**CRITICAL:** Use Figma REST API directly - NO AI tokens required!

**Why REST API:** 100% FREE + 10-100x faster (batch API call)

Using node IDs from step 4a:

```bash
# Extract all screenshots via Figma REST API (requires FIGMA_API_TOKEN env var)
ocg extract-figma-screenshots \
    "$FIGMA_FILE_KEY" \
    "$REPO_ROOT/codegen/design-system/features/$FEATURE_NAME/node-ids.txt" \
    "$REPO_ROOT/codegen/design-system/features/$FEATURE_NAME/screenshots"
```

**Setup (one-time):**

```bash
# Get Figma API token from: https://www.figma.com/developers/api#authentication
# Then add to your shell profile (~/.zshrc or ~/.bashrc):
export FIGMA_API_TOKEN='figd_your_token_here'
```

**4d. Extract Implementation Specs (CRITICAL for pixel-perfect implementation)**

**CRITICAL:** Extract detailed specs per screen for implementation phase

**Why this matters:** Agents can't call Figma during implementation - this extraction must be complete

```bash
# Extract detailed implementation specs (depth=3, no geometry)
ocg extract-figma-implementation-specs \
    "$FIGMA_FILE_KEY" \
    "$REPO_ROOT/codegen/design-system/features/$FEATURE_NAME/node-ids.txt" \
    "$REPO_ROOT/codegen/design-system/features/$FEATURE_NAME/specs"
```

**What you get:**

- One JSON file per screen (~50-200K, ~5-10K tokens)
- Text content (actual strings to display)
- Exact measurements (width, height, x, y in pixels)
- Typography (font family, size, weight, line height)
- Colors (RGBA values)
- Layout properties (Auto Layout, padding, gaps, alignment)
- Component hierarchy (depth=3)

**4e. Create URL → Screenshot State Mapping**

**CRITICAL:** Create mapping in plan so ui-specialist knows which screenshot to use for each URL.

Add to `codegen/plans/$FEATURE_NAME/overview.md`:

```markdown
## Screenshot State Mapping

| URL Pattern     | State              | Viewport | Base Name                                          | Test User                    |
| --------------- | ------------------ | -------- | -------------------------------------------------- | ---------------------------- |
| `/messages`     | Empty state        | Desktop  | `messages---empty-state-8322-46182`                | empty-screenshot@example.com |
| `/messages`     | Empty state        | Mobile   | `organization-messages---empty-state-8547-8837`    | empty-screenshot@example.com |
| `/messages`     | With conversations | Desktop  | `organization-messages---with-messages-8322-46530` | maria.weber@spitex-zurich.ch |
| `/messages`     | With conversations | Mobile   | `organization-messages---with-messages-8547-8881`  | maria.weber@spitex-zurich.ch |
| `/messages/:id` | Thread view        | Desktop  | `organization-messages---with-messages-8322-46530` | maria.weber@spitex-zurich.ch |
| `/messages/:id` | Thread view        | Mobile   | `organization-messages---view-message-8547-8948`   | maria.weber@spitex-zurich.ch |
| `/messages/:id` | With files         | Desktop  | `organization-messages---with-messages-8328-10511` | maria.weber@spitex-zurich.ch |

**File Paths (derive from Base Name):**

- Screenshot: `./codegen/design-system/features/$FEATURE_NAME/screenshots/{base}.png`
- Specs JSON: `./codegen/design-system/features/$FEATURE_NAME/specs/{base}-specs.json`

**Viewport Detection (from node ID in filename):**

- `7xxx-xxxxx` = Mobile
- `8xxx-xxxxx` = Desktop

**Test User Credentials:** All test users use password `password123456`
```

**4f. Update Seeds for Screenshot Users**

Add to `priv/repo/seeds.exs`:

```elixir
# Screenshot test users - ALWAYS English locale for Figma comparison
empty_screenshot_user = Repo.insert!(%User{
  email: "empty-screenshot@example.com",
  name: "Empty User",
  hashed_password: Bcrypt.hash_pwd_salt("password123456"),
  confirmed_at: ~N[2024-01-01 00:00:00],
  user_type: :employer,
  locale: "en", # CRITICAL: English for Figma matching
  company: some_company
})

# Update existing test users to have English locale for screenshots
Repo.update!(User.changeset(maria_user, %{locale: "en"}))
```

**4g. Document in Plan Overview**

Add design system section to your plan overview.md:

```markdown
## Design System Extractions (Created During Planning)

**Feature:** $FEATURE_NAME

**Global resources** (shared across all features):

- Design tokens: `./codegen/design-system/variables.json`
- Design tokens (readable): `./codegen/design-system/variables-readable.json`

**Feature-specific resources:**

- Node IDs: `./codegen/design-system/features/$FEATURE_NAME/node-ids.txt` (6-8 screens)
- Screenshots: `./codegen/design-system/features/$FEATURE_NAME/screenshots/*.png` (6-8 images)
- Implementation specs: `./codegen/design-system/features/$FEATURE_NAME/specs/*-specs.json` (~5-10K tokens each)

**Implementation Note:** ui-specialist MUST read from these cached files. All needed data extracted.

**Screenshot State Mapping:** See "Screenshot State Mapping" section above for URL → screenshot mappings.
```

**Why This Organization:**

- ✅ No file clashes between features
- ✅ Token usage scales with feature scope (6-8 screens), NOT whole Figma file
- ✅ Easy cleanup: remove entire feature directory when done
- ✅ Parallel development: different features extract independently
- ✅ 100% FREE - no AI tokens burned for extraction
- ✅ Only design tokens are truly global - everything else is feature-specific

#### Step 5: Verify Bootstrap Completion

**Before continuing with planning, verify:**

```bash
# 1. Design tokens extracted?
ls $REPO_ROOT/codegen/design-system/variables.json

# 2. Node IDs created?
ls $REPO_ROOT/codegen/design-system/features/$FEATURE_NAME/node-ids.txt

# 3. Screenshots extracted?
ls $REPO_ROOT/codegen/design-system/features/$FEATURE_NAME/screenshots/*.png

# 4. Implementation specs extracted?
ls $REPO_ROOT/codegen/design-system/features/$FEATURE_NAME/specs/*.json
```

**All four MUST exist before proceeding with implementation planning.**

**If any missing:** Go back and complete bootstrap steps 4a-4g.

**CRITICAL PATH AWARENESS**:

- ✅ Save to PARENT repo: `$REPO_ROOT/codegen/design-system/` (shared across all workspaces)
- ❌ DO NOT save to planning workspace: `./codegen/design-system/` (would be lost after planning)
- Cache will be symlinked to implementation workspaces automatically

**Why Bootstrap During Planning**:

- Extract design data ONCE during planning (when you have full context)
- Implementation agents reuse cached data (98.7% token savings)
- No repeated Figma API calls during implementation
- Prevents context bloat from re-extracting same designs

### Planning Phase Documentation

**After bootstrapping cache, document in your plan:**

```markdown
## Design System Extractions

**Feature:** messages

**Global resources:**

- Design tokens: `./codegen/design-system/variables.json`

**Feature-specific resources:**

- Screenshots: `./codegen/design-system/features/messages/screenshots/` (31 screens)
- Implementation specs: `./codegen/design-system/features/messages/specs/` (31 JSON files)

**Key Screens (viewport mapping for ui-specialist):**

- Desktop empty state: `messages---empty-state-8322-46182.png`
- Desktop with messages: `organization-messages---with-messages-8322-46530.png`
- Desktop with files: `organization-messages---with-messages-8328-10511.png`
- Mobile empty state: `organization-messages---empty-state-8547-8837.png`
- Mobile conversation list: `organization-messages---with-messages-8547-8881.png`
- Mobile thread view: `organization-messages---view-message-8547-8948.png`

**Implementation Note**: ui-specialist reads from cached screenshots. Filenames come from Figma frame names + node IDs. The Key Screens section maps filenames to viewports for Haiku comparisons.
```

**DO NOT create/update FIGMA_MAP.md during planning** - that's for finished implementations only. Just document the Figma cache info in the plan for implementation reference.

### Figma Verification Requirements (CRITICAL)

**1. MANDATORY Figma Verification** (during planning):

- **ALWAYS use extracted screenshots** from `ocg extract-figma-screenshots`
- **NEVER describe Figma screens without looking at extracted screenshots**
- **LIST EVERY visible UI element** (buttons, text, icons)
- **NO ASSUMPTIONS** - If you can't see it, don't claim it exists

**2. "Figma Design References" section** in plans must include:

- Complete list of all Figma URLs provided
- Node IDs extracted from URLs (e.g., `node-id=3474-37626` → Node: `3474-37626`)
- ACCURATE description of what each screen actually shows (verified via extracted screenshots)
- COMPLETE listing of all interactive elements
- Base Figma file URL for easy access
- List of cached screenshots with file paths

**3. Figma Analysis Accuracy**:

- ✅ CORRECT: "The screen shows Call, Mail, Chat, Hire, and Schedule a meeting buttons"
- ❌ WRONG: "The screen shows Call, Mail, Chat, Hire buttons" (missing Schedule)
- VIOLATION: Claiming elements don't exist when visible in screenshot
- VIOLATION: Describing screens without looking at extracted screenshots

**4. Reference Figma nodes AND cache throughout plan**:

- Every UI component must reference source Figma node
- Example: "Create Schedule button - Node `3650-30623` (cached: messages-desktop-actions.png)"

**5. Implementation Instructions in Plan**:

- MUST include: "Read from cache: ./codegen/design-system/screenshots/"
- MUST include: "NO Figma API calls during implementation - use cached files only"
- Missing buttons/features is CRITICAL ERROR

**Detection Commands**:

```bash
grep -i "schedule.*meeting" codegen/plans/*/overview.md  # Check for missing UI elements
```

**WHY THIS MATTERS**: Missing UI elements from Figma leads to incomplete implementations, user confusion, expensive rework cycles.

**Planning Guidelines**

- Be thorough and specific in technical details
- Plan for code reuse and pattern consistency
- Consider both immediate implementation and future extensibility
- Plan comprehensive test coverage from the start

### Output Expectations

**Create Modular Plan Structure:**

For comprehensive features requiring detailed planning, create a modular structure to prevent context overload during implementation:

```
codegen/plans/{{FEATURE_NAME}}/
├── overview.md          # Main plan (50-100 lines): goals, architecture, step sequence
└── steps/
    ├── step-01-setup.md    # Setup and infrastructure (150-250 lines)
    ├── step-02-core.md     # Core implementation (150-250 lines)
    ├── step-03-ui.md       # UI components (150-250 lines)
    └── step-04-tests.md    # Testing implementation (150-250 lines)
```

**Step File Naming Convention:**

- Use format: `step-##-descriptor.md` (e.g., `step-01-setup.md`, `step-02-core.md`)
- Zero-padded numbers for proper sorting
- Kebab-case descriptors (lowercase, hyphens, no spaces)
- Keep descriptors short and clear

**Plan Size Guidelines:**

- **Overview**: 50-100 lines covering goals, architecture, step sequence
- **Step files**: 150-250 lines each with detailed implementation for that step
- Focus on actionable steps, not verbose explanations
- Remember: During implementation, only overview + current step will be loaded (~200-350 lines total)

**What to include:**

**In overview.md:**

- Feature goals and business requirements
- High-level architecture and approach
- Step sequence with explicit file references (e.g., "Step 1: Setup (see step-01-setup.md)")
- Dependencies between steps
- Success criteria

**In step files (TDD APPROACH - CRITICAL):**

- **IMPLEMENTATION + TESTS TOGETHER**: Each step must include both feature implementation AND comprehensive tests
- **Complete CI readiness**: Step completion means ALL verification passes (compilation, tests, Credo, coverage, formatting)
- Specific technical implementation approach for that step
- **Test plans integrated with implementation** - not separated into Step 4
- Database schema changes and migration plans (if applicable)
- API endpoint specifications (if applicable)
- Component and module structure for that step

- **UI/design specifications**: Reference specific Figma screenshots with viewport mapping (if applicable)

**MANDATORY FOR UI STEPS - Include Design Reference section:**

```markdown
## Design Reference

**Screenshots** (from `./codegen/design-system/features/[feature]/screenshots/`):

- Desktop view: `organization-messages---with-messages-8322-46530.png`
- Mobile view: `organization-messages---with-messages-8547-8881.png`
- Empty state desktop: `messages---empty-state-8322-46182.png`
- Empty state mobile: `organization-messages---empty-state-8547-8837.png`
```

**WHY**: Screenshot filenames are cryptic (from Figma frame names + node IDs).
The ui-specialist needs to know which file is desktop vs mobile for Haiku comparisons.

- Detailed test plans for that step
- Code examples and patterns to follow
- Prerequisites and dependencies for that step
- **Coverage requirements**: Ensure new code meets project coverage thresholds
- **MANDATORY FOR UI FEATURES**: Include translation requirements for all user-facing text, labels, messages
- **MANDATORY FOR DEPLOYMENT**: Include deployment configuration requirements for devops-manager
- **MANDATORY IF SEEDS EXIST**: Document available seed users for browser testing, note seed updates needed for new features

**🚨 CRITICAL CHANGE: TDD-First Planning**

**OLD APPROACH (causes ping-pong)**:

- Step 1: Auth implementation
- Step 2: Dashboard features
- Step 3: Charts
- Step 4: Tests for everything

**NEW APPROACH (TDD - prevents ping-pong)**:

- Step 1: Auth implementation + auth tests
- Step 2: Dashboard features + dashboard tests
- Step 3: Charts + chart tests
- Step 4: Integration tests only

**WHY**: Writing tests separately in Step 4 causes CI failures during Steps 1-3, leading to back-and-forth between verification-engineer and feature-developer. TDD approach ensures each step is CI-ready before moving forward.

### Implementation Readiness

Your plan should be detailed enough that an engineer can:

- Understand exactly what needs to be built
- Follow a clear implementation sequence
- Know what tests to write
- Understand integration requirements
- Identify potential risks and challenges

### 🚨 MANDATORY: Hallucination Check Before Finalizing

**CRITICAL**: After writing your plan, you MUST verify it against official documentation to catch hallucinations.

**PROCESS**:

1. **Identify External Dependencies**: List all libraries, frameworks, tools mentioned in your plan
2. **Verify Each Dependency**:
   - Use WebFetch or WebSearch to check official documentation
   - Verify syntax, API patterns, configuration options
   - Confirm features and capabilities actually exist
3. **Check Common Hallucination Risks**:
   - ❌ Library/function names (e.g., claiming "PhoenixTest.Playwright" exists)
   - ❌ Configuration order (e.g., wrong setup sequence in test_helper.exs)
   - ❌ API return values (e.g., returning `context` instead of `{:ok, context}`)
   - ❌ Parameter syntax (e.g., wrong pattern matching format)
   - ❌ Module names (e.g., incorrect namespace paths)
4. **Document Verification**: Add "Verified Against Documentation" section to overview.md:

```markdown
## Verified Against Documentation

- ✅ Cucumber 0.4.1: Verified setup, step syntax, return values
- ✅ Phoenix LiveView: Confirmed testing patterns from hexdocs
- ✅ Ecto: Verified migration syntax and schema patterns
```

5. **Fix Hallucinations**: Update ALL affected files (overview + step files) with corrections

**WHEN TO VERIFY**:

- **NEW dependencies**: Any library/framework not already in project dependencies
- **SPECIFIC syntax**: Code examples, configuration, API calls
- **TECHNICAL details**: Setup order, return types, pattern matching
- **CRITICAL features**: Core functionality that plan depends on

**Example Hallucinations This Would Catch**:

- ❌ Using `Cucumber.compile_features!()` before `ExUnit.start()` (wrong order)
- ❌ Step definitions returning `context` instead of `{:ok, context}`
- ❌ Claiming a library exists when it doesn't
- ❌ Wrong parameter extraction syntax

**If you find hallucinations**: Correct them immediately in ALL plan files before claiming plan is complete.

### Next Steps

After completing detailed planning AND hallucination check:

1. Use `ocg new {{FEATURE_NAME}}` to create implementation workspace
2. The workspace will include your modular plan structure
3. **Orchestrator implements using delegation patterns**: Main agent delegates ALL step requirements to appropriate subagents
4. **Step completeness**: Every requirement in each step (code, tests, deployment config) must be delegated
5. Update `PROJECT_CONTEXT.md` after implementation with learnings

**CRITICAL: Plan → Implementation Alignment**

- **Your plans will be executed by orchestrator agents** using delegation patterns
- **Each step must be complete and self-contained** - orchestrator cannot skip parts
- **Include ALL requirements per step**: If step includes deployment config, mark clearly for devops-manager delegation
- **TDD approach aligns with orchestrator workflow**: feature-developer implements code+tests, then verification-engineer checks

Remember: This is about technical precision and implementation readiness. The better your plan, the smoother the orchestrated implementation will be.
