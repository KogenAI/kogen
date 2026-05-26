# Recipe: Visual Verification Workflow for Figma Implementation

## Problem

How to systematically verify that implemented UI matches Figma designs pixel-perfectly, while maintaining an efficient workflow that catches design discrepancies early and provides clear progress tracking?

## Solution

Use a structured visual verification workflow that combines Figma MCP server tools with systematic screen-by-screen verification, progress tracking, and iterative refinement until exact matches are achieved.

## Implementation

### 1. Initial Design Extraction and Reference Setup

```elixir
# Extract visual reference for comparison
def setup_visual_reference(node_id) do
  # Get the design image for visual comparison
  design_image = get_image(node_id)

  # Extract design tokens for implementation
  design_tokens = get_variable_defs(node_id)

  # Generate initial code structure
  code_structure = get_code(node_id)

  %{
    node_id: node_id,
    design_image: design_image,
    tokens: design_tokens,
    structure: code_structure,
    status: :pending_implementation
  }
end
```

### 2. Structured Verification Tracking

```markdown
# Visual Verification Progress Template

**Figma Design References**:

- `node-id-1` - Screen Name (Initial State)
- `node-id-2` - Screen Name (Filled State)
- `node-id-3` - Screen Name (Error State)

**Completed Verifications**:

1. ✅ **Screen Name** (Node node-id)
   - Issue: Description of what was wrong
   - Fix: What was changed to match Figma
   - Status: Matches Figma design exactly

**Pending Verifications**: 2. ⏳ **Screen Name** (Node node-id)

- Current state description
- Known issues to address

**Critical Design Mismatches Found**:

1. **Color Issues**: Purple shades don't match Figma exactly (#F3E8FF vs implemented)
2. **Spacing Issues**: Padding and margins off throughout (16px vs 24px expected)
3. **Typography**: Font sizes and weights don't match (text-sm vs text-base needed)
```

### 3. Systematic Screen Verification Process

```elixir
defmodule VisualVerificationWorkflow do
  @doc """
  Systematic verification process for each screen/component
  """
  def verify_screen(node_id, description) do
    # Step 1: Get current Figma design
    current_design = get_image(node_id)

    # Step 2: Take screenshot of implementation (manual or automated)
    implementation_screenshot = capture_implementation_screenshot()

    # Step 3: Compare and identify mismatches
    mismatches = identify_visual_mismatches(current_design, implementation_screenshot)

    # Step 4: Document findings
    verification_result = %{
      node_id: node_id,
      description: description,
      mismatches: mismatches,
      status: if(Enum.empty?(mismatches), do: :complete, else: :needs_fixes),
      verified_at: DateTime.utc_now()
    }

    log_verification_result(verification_result)
    verification_result
  end

  defp identify_visual_mismatches(figma_design, implementation) do
    # Document specific differences found during manual comparison
    [
      %{type: :color, element: "warning banner", expected: "#F3E8FF", actual: "#E5D3FF"},
      %{type: :spacing, element: "modal padding", expected: "24px", actual: "16px"},
      %{type: :typography, element: "button text", expected: "font-medium", actual: "font-normal"}
    ]
  end
end
```

### 4. Design Token Extraction and Application

```elixir
defmodule DesignTokenExtractor do
  def extract_and_apply_tokens(node_id) do
    # Extract design tokens from Figma
    tokens = get_variable_defs(node_id)

    # Convert to CSS custom properties
    css_vars = tokens_to_css_vars(tokens)

    # Update design system configuration
    update_design_system(css_vars)

    css_vars
  end

  defp tokens_to_css_vars(tokens) do
    tokens
    |> Enum.map(fn {name, value} ->
      css_name = String.replace(name, "/", "-")
      "--#{css_name}: #{value};"
    end)
    |> Enum.join("\n")
  end

  defp update_design_system(css_vars) do
    # Write to CSS configuration file
    File.write!("assets/css/design-tokens.css", """
    :root {
      #{css_vars}
    }
    """)
  end
end
```

### 5. Asset Management During Verification

```bash
#!/bin/bash
# Script: extract_figma_assets.sh

# Extract assets from Figma MCP during verification
extract_asset() {
    local asset_url="$1"
    local output_path="$2"
    local asset_name="$3"

    echo "Extracting $asset_name..."
    curl "$asset_url" -o "$output_path"

    # Optimize SVG assets
    if [[ "$output_path" == *.svg ]]; then
        npx svgo --config svgo.config.js "$output_path"
    fi

    echo "✅ Asset extracted: $output_path"
}

# Usage during verification process
extract_asset "http://localhost:3845/assets/hash.svg" "priv/static/images/jobs/video-upload-banner.svg" "Video Upload Banner"
```

### 6. Iterative Refinement Pattern

```elixir
defmodule IterativeRefinement do
  def refine_until_match(node_id, max_iterations \\ 5) do
    Enum.reduce_while(1..max_iterations, :mismatch, fn iteration, _acc ->
      IO.puts("Verification iteration #{iteration} for node #{node_id}")

      case verify_screen(node_id, "Iteration #{iteration}") do
        %{status: :complete} ->
          IO.puts("✅ Perfect match achieved in #{iteration} iterations")
          {:halt, :match}

        %{status: :needs_fixes, mismatches: mismatches} ->
          IO.puts("❌ Found #{length(mismatches)} mismatches:")
          Enum.each(mismatches, &log_mismatch/1)

          # Apply fixes based on identified mismatches
          apply_fixes(mismatches)

          if iteration == max_iterations do
            IO.puts("⚠️  Max iterations reached, manual review needed")
            {:halt, :needs_manual_review}
          else
            {:cont, :mismatch}
          end
      end
    end)
  end

  defp apply_fixes(mismatches) do
    Enum.each(mismatches, fn mismatch ->
      case mismatch.type do
        :color -> fix_color_mismatch(mismatch)
        :spacing -> fix_spacing_mismatch(mismatch)
        :typography -> fix_typography_mismatch(mismatch)
        _ -> log_manual_fix_needed(mismatch)
      end
    end)
  end
end
```

### 7. Component-Level Verification

```elixir
defmodule ComponentVerification do
  @doc """
  Verify individual components match their Figma counterparts
  """
  def verify_component(component_name, figma_node_id) do
    verification_checklist = [
      :colors_match_design_tokens,
      :spacing_follows_8px_grid,
      :typography_matches_scale,
      :responsive_behavior_correct,
      :interactive_states_implemented,
      :accessibility_requirements_met
    ]

    results =
      verification_checklist
      |> Enum.map(&verify_component_aspect(component_name, figma_node_id, &1))
      |> Enum.group_by(& &1.status)

    %{
      component: component_name,
      node_id: figma_node_id,
      passed: Map.get(results, :pass, []),
      failed: Map.get(results, :fail, []),
      overall_status: if(Map.has_key?(results, :fail), do: :needs_work, else: :complete)
    }
  end

  defp verify_component_aspect(component, node_id, aspect) do
    # Implement specific verification logic for each aspect
    case aspect do
      :colors_match_design_tokens ->
        verify_colors(component, node_id)
      :spacing_follows_8px_grid ->
        verify_spacing(component)
      # ... other verification functions
    end
  end
end
```

## Considerations

### Workflow Efficiency

- **Batch verification**: Group related screens for efficient comparison sessions
- **Progress tracking**: Maintain clear documentation of what's verified vs pending
- **Asset organization**: Extract and organize assets systematically during verification
- **Design token sync**: Keep design tokens updated as Figma designs evolve

### Quality Assurance

- **Pixel-perfect requirement**: Don't accept "close enough" - Figma designs should match exactly
- **Multiple viewport testing**: Verify responsive behavior across all breakpoints
- **Interactive state verification**: Test hover, focus, and error states match designs
- **Cross-browser testing**: Ensure consistency across different browsers

### When to Use This Workflow

- ✅ Implementing pixel-perfect UI from detailed Figma designs
- ✅ Complex applications where visual consistency is critical
- ✅ Projects with multiple designers and developers requiring coordination
- ✅ Applications with strict brand guidelines and design standards

### When NOT to Use This Workflow

- ❌ Rapid prototyping where exact visual match isn't critical
- ❌ Internal tools where functionality matters more than pixel-perfect design
- ❌ Projects without detailed Figma designs or design system
- ❌ Simple applications with minimal UI complexity

### Common Pitfalls

- **Localhost asset URLs**: Always replace MCP localhost URLs with static paths before production
- **Design drift**: Figma designs may change during implementation - re-verify regularly
- **Color approximation**: Don't approximate colors - extract exact hex values from Figma
- **Responsive assumptions**: Verify all breakpoints, don't assume smaller screens work automatically

## Example Usage

From the job-applications-figma feature implementation:

```elixir
# Systematic verification of application modal
verification_results = [
  verify_screen("3474-37626", "Application Modal (Initial State)"),
  verify_screen("3474-38430", "Application Modal (Filled)"),
  verify_screen("3474-39209", "Application Warning (Already Applied)"),
  verify_screen("2449-8787", "Application Success")
]

# Results tracking showed:
# ✅ 5 screens verified and matching perfectly
# ⏳ 3 screens pending verification
# ❌ 2 screens with color/spacing issues requiring fixes

# Iterative refinement process:
refine_until_match("3474-37626") # Application Modal
# Iteration 1: Found color mismatches in warning banner
# Iteration 2: Fixed colors, found spacing issues in video section
# Iteration 3: Fixed spacing, typography weight incorrect
# Iteration 4: ✅ Perfect match achieved
```

This systematic approach resulted in pixel-perfect implementation matching all Figma designs exactly while maintaining clear progress tracking throughout the development process.

## Related Recipes

- [Figma-to-Code with MCP](./figma-to-code-mcp.md)
- [Semantic Component API Design](./semantic-component-api-design.md)
- [Test Coverage Strategies](./test-coverage-strategies.md)
