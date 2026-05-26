---
description: Update FIGMA_MAP.md with new Figma screens and component mappings
---

Update `codegen/FIGMA_MAP.md` with new Figma design mappings.

## Steps

1. **Gather Figma info**:
   - Ask user for Figma URLs or node IDs for new screens
   - Use `ocg extract-figma-screenshots` to capture visual references
   - Use `ocg extract-figma-variables` to extract design tokens
   - Screenshots → `./codegen/design-system/features/[feature]/screenshots/`

2. **Identify feature/flow**:
   - Determine which route/LiveView screens belong to
   - Check if new flow or updates to existing screens
   - Note responsive breakpoints (Mobile/Tablet/Desktop)

3. **Update Screen Mappings section**:

   ```markdown
   ### [Feature Name] Flow

   **Route**: `/path` → `ModuleName.LiveViewName`

   | Breakpoint | Figma Node ID | Screen Description |
   | ---------- | ------------- | ------------------ |
   | Desktop    | `XXXX-XXXXX`  | Description        |
   | Mobile     | `XXXX-XXXXX`  | Description        |

   **Components**:

   - List specific components used
   - Note special interactions or states
   ```

4. **Check for reusable components**:
   - Identify components across multiple screens
   - Add to "Reusable Component Library" section if new
   - Update existing component references if modified

5. **Document state variations**:
   - For interactive components, document all states (hover, active, disabled)
   - Add to "Component State Mappings" section
   - Include exact Tailwind classes for each state

6. **Identify token overrides**:
   - Note screen-specific spacing, colors, or sizes
   - Add to "Design Token Overrides" section
   - Document why these differ from defaults

7. **Extract assets**:
   - List new icons or illustrations needed
   - Document intended location in `/priv/static/images/`
   - Note naming conventions

8. **Update Component Mappings**:
   - Map Figma components to existing Phoenix components
   - If no match, note new component needed with Phoenix module path

9. **Add Implementation Notes**:
   - Special considerations
   - Animations/transitions from Figma
   - Responsive behavior details

10. **Update Last Modified**:
    ```markdown
    _Last Updated: [Date] - Added [feature] screens, [components]_
    ```

## Format Guidelines

- Consistent table formatting for screen mappings
- Keep descriptions concise
- Always include Figma Node ID and Phoenix component path
- Group related screens under feature headings
- Backticks for code/class references

## Example Entry

```markdown
### User Profile Flow

**Route**: `/profile` → `BemedaPersonalWeb.ProfileLive.Show`

| Breakpoint | Figma Node ID | Screen Description  |
| ---------- | ------------- | ------------------- |
| Desktop    | `4521-12345`  | Profile View Page   |
| Mobile     | `4521-67890`  | Profile View Mobile |

**Components**:

- **Profile Header**: `Shared.ProfileHeader` - User avatar with gradient background
- **Info Cards**: `Core.Card` - White cards with edit buttons
- **Stats Section**: Inline template - Achievement badges and counters
```

After updating, report:

- Sections updated
- New components needing impl
- Design inconsistencies found
- Assets needing extraction from Figma
