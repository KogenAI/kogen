---
description: Update FIGMA_MAP.md with new Figma screens and component mappings
---

Update the `codegen/FIGMA_MAP.md` file with new Figma design mappings for the project.

## Steps:

1. **Gather Figma Information**:

   - Ask user for Figma URLs or node IDs for new screens
   - Use `mcp__figma__get_image` to capture visual references
   - Use `mcp__figma__get_variable_defs` to extract any custom tokens
   - Use `mcp__figma__get_code_connect_map` to check for existing connections

2. **Identify the Feature/Flow**:

   - Determine which route/LiveView the screens belong to
   - Check if it's a new flow or updates to existing screens
   - Note responsive breakpoints (Mobile/Tablet/Desktop)

3. **Update Screen Mappings Section**:

   ```markdown
   ### [Feature Name] Flow

   **Route**: `/path` → `ModuleName.LiveViewName`

   | Breakpoint | Figma Node ID | Screen Description |
   | ---------- | ------------- | ------------------ |
   | Desktop    | `XXXX-XXXXX`  | Description        |
   | Mobile     | `XXXX-XXXXX`  | Description        |

   **Components**:

   - List specific components used in these screens
   - Note any special interactions or states
   ```

4. **Check for Reusable Components**:

   - Identify components that appear across multiple screens
   - Add to "Reusable Component Library" section if new
   - Update existing component references if modified

5. **Document State Variations**:

   - For interactive components, document all states (hover, active, disabled)
   - Add to "Component State Mappings" section
   - Include exact Tailwind classes for each state

6. **Identify Token Overrides**:

   - Note any screen-specific spacing, colors, or sizes
   - Add to "Design Token Overrides" section
   - Document why these differ from defaults

7. **Extract Assets**:

   - List any new icons or illustrations needed
   - Document their intended location in `/priv/static/images/`
   - Note naming conventions to follow

8. **Update Component Mappings**:

   - Map Figma components to existing Phoenix components
   - If no match exists, note that a new component is needed
   - Include the Phoenix module path

9. **Add Implementation Notes**:

   - Any special considerations for implementation
   - Animations or transitions from Figma
   - Responsive behavior details

10. **Update Last Modified**:
    ```markdown
    _Last Updated: [Date] - Added [feature] screens, [components]_
    ```

## Format Guidelines:

- Use consistent table formatting for screen mappings
- Keep descriptions concise but descriptive
- Always include both Figma Node ID and Phoenix component path
- Group related screens under feature headings
- Use backticks for code/class references

## Example Entry:

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

After updating, inform user about:

- What sections were updated
- Any new components that need implementation
- Any design inconsistencies found
- Assets that need extraction from Figma
