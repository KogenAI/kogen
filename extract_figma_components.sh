#!/bin/bash
set -e

# Extract Figma component definitions (master components)
#
# Component INSTANCES in screen specs only contain references (componentId),
# not their internal content. This script extracts the actual master components
# which contain:
# - TEXT nodes (actual button labels, headings, etc.)
# - Full internal structure
# - Design tokens and styles
#
# Usage: ./extract_figma_components.sh <specs-directory> <output-dir> [figma-config.json]
#
# Example:
#   ./extract_figma_components.sh ./design-system/features/jobs/specs/ ./design-system/components/
#
# The script:
# 1. Auto-discovers componentIds from spec files
# 2. Reads figma-config.json for multiple file keys (main file + component library)
# 3. Tries each file until component is found

SPECS_DIR="$1"
OUTPUT_DIR="$2"
CONFIG_FILE="$3"

if [ -z "$SPECS_DIR" ] || [ -z "$OUTPUT_DIR" ]; then
    echo "❌ Error: Missing required arguments"
    echo ""
    echo "Usage: $0 <specs-directory> <output-dir> [figma-config.json]"
    echo ""
    echo "Example:"
    echo "  $0 ./design-system/features/jobs/specs/ ./design-system/components/"
    echo ""
    echo "The script looks for figma-config.json in the design-system directory"
    echo "to find all Figma file keys (main file + component libraries)"
    exit 1
fi

# Find figma-config.json
if [ -z "$CONFIG_FILE" ]; then
    # Try to find it relative to output dir
    DESIGN_SYSTEM_DIR=$(dirname "$OUTPUT_DIR")
    CONFIG_FILE="$DESIGN_SYSTEM_DIR/figma-config.json"
fi

# Read file keys from config or use legacy single-file mode
declare -a FIGMA_FILE_KEYS=()
if [ -f "$CONFIG_FILE" ]; then
    echo "📋 Found figma-config.json"
    while IFS= read -r key; do
        [ -n "$key" ] && FIGMA_FILE_KEYS+=("$key")
    done < <(jq -r '.files | to_entries[] | .value.key' "$CONFIG_FILE" 2>/dev/null)
    echo "   File keys: ${FIGMA_FILE_KEYS[*]}"
else
    echo "⚠️  No figma-config.json found at $CONFIG_FILE"
    echo "   Create one with: {\"files\": {\"main\": {\"key\": \"YOUR_KEY\"}, \"components\": {\"key\": \"LIBRARY_KEY\"}}}"
    echo ""
    echo "   Or provide a single file key as third argument:"
    echo "   $0 <specs-dir> <output-dir> <file-key>"

    # Check if third arg looks like a file key (not a .json file)
    if [ -n "$3" ] && [[ ! "$3" =~ \.json$ ]]; then
        FIGMA_FILE_KEYS=("$3")
        echo "   Using provided file key: ${FIGMA_FILE_KEYS[*]}"
    else
        exit 1
    fi
fi

if [ ! -d "$SPECS_DIR" ]; then
    echo "❌ Error: Specs directory not found: $SPECS_DIR"
    exit 1
fi

# Check for Figma API token
if [ -z "$FIGMA_API_TOKEN" ]; then
    echo "❌ Error: FIGMA_API_TOKEN environment variable not set"
    echo ""
    echo "Get your token from: https://www.figma.com/developers/api#authentication"
    echo ""
    echo "Then export it:"
    echo "  export FIGMA_API_TOKEN='figd_your_token_here'"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

echo "🧩 Extracting Figma component definitions"
echo ""
echo "Specs dir: $SPECS_DIR"
echo "Output:    $OUTPUT_DIR"
echo ""

# Step 1: Extract all unique componentIds from spec files
echo "🔍 Scanning spec files for component references..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JQ_FILTER="$SCRIPT_DIR/jq-filters/extract-component-ids.jq"

# Create jq filter for extracting componentIds if it doesn't exist
if [ ! -f "$JQ_FILTER" ]; then
    mkdir -p "$SCRIPT_DIR/jq-filters"
    cat >"$JQ_FILTER" <<'JQEOF'
# Extract unique componentIds from Figma spec files
# Finds all INSTANCE nodes and extracts their componentId
[
    .. | objects |
    select(.type? == "INSTANCE") |
    select(.componentId != null) |
    .componentId
] | unique | .[]
JQEOF
fi

# Collect all unique componentIds
TEMP_COMPONENT_IDS=$(mktemp)

for SPEC_FILE in "$SPECS_DIR"/*.json; do
    [ -f "$SPEC_FILE" ] || continue
    jq -r -f "$JQ_FILTER" "$SPEC_FILE" 2>/dev/null >>"$TEMP_COMPONENT_IDS" || true
done

# Deduplicate
UNIQUE_COMPONENTS=$(sort -u "$TEMP_COMPONENT_IDS")
rm -f "$TEMP_COMPONENT_IDS"

COMPONENT_COUNT=$(echo "$UNIQUE_COMPONENTS" | grep -c . || echo 0)

if [ "$COMPONENT_COUNT" -eq 0 ]; then
    echo "⚠️  No component references found in spec files"
    echo ""
    echo "This could mean:"
    echo "  - Specs were extracted with insufficient depth"
    echo "  - No component instances in the screens"
    exit 0
fi

echo "   Found $COMPONENT_COUNT unique component references"
echo ""

# Step 2: Extract each component definition
echo "📦 Extracting component definitions from Figma API..."
echo ""

EXTRACTED=0
FAILED=0
SKIPPED=0

# Create component usage index
USAGE_FILE="$OUTPUT_DIR/component-usage.json"
echo "{" >"$USAGE_FILE"
echo '  "components": {' >>"$USAGE_FILE"

FIRST_COMPONENT=true

for COMPONENT_ID in $UNIQUE_COMPONENTS; do
    [ -z "$COMPONENT_ID" ] && continue

    # Create safe filename
    SAFE_ID=$(echo "$COMPONENT_ID" | tr ':' '-')
    OUTPUT_FILE="$OUTPUT_DIR/component-${SAFE_ID}.json"

    # Handle already extracted (for incremental updates)
    if [ -f "$OUTPUT_FILE" ]; then
        echo "⏭️  Using cached: $COMPONENT_ID"
        SKIPPED=$((SKIPPED + 1))

        # Still add to usage index from cached file
        CACHED_DATA=$(cat "$OUTPUT_FILE")
        CACHED_NAME=$(echo "$CACHED_DATA" | jq -r '.document.name // "Unknown"')
        CACHED_TEXT_COUNT=$(echo "$CACHED_DATA" | jq '[.. | objects | select(.type? == "TEXT")] | length')
        CACHED_FIGMA_FILE=$(echo "$CACHED_DATA" | jq -r '.components | to_entries[0].value.remote // false' | grep -q "true" && echo "library" || echo "unknown")

        # Add to usage index
        if [ "$FIRST_COMPONENT" = true ]; then
            FIRST_COMPONENT=false
        else
            echo "," >>"$USAGE_FILE"
        fi
        echo "    \"$COMPONENT_ID\": {" >>"$USAGE_FILE"
        echo "      \"name\": \"$CACHED_NAME\"," >>"$USAGE_FILE"
        echo "      \"file\": \"component-${SAFE_ID}.json\"," >>"$USAGE_FILE"
        echo "      \"figmaFile\": \"cached\"," >>"$USAGE_FILE"
        echo "      \"textNodes\": $CACHED_TEXT_COUNT" >>"$USAGE_FILE"
        echo -n "    }" >>"$USAGE_FILE"

        continue
    fi

    echo "📋 Extracting: $COMPONENT_ID"

    # Try each file key until we find the component
    COMPONENT_DATA=""
    FOUND_IN_FILE=""
    for FILE_KEY in "${FIGMA_FILE_KEYS[@]}"; do
        RESPONSE=$(curl -s -X GET \
            "https://api.figma.com/v1/files/$FILE_KEY/nodes?ids=$COMPONENT_ID&depth=10" \
            -H "X-Figma-Token: $FIGMA_API_TOKEN")

        # Check for errors
        if echo "$RESPONSE" | jq -e '.err != null and .err != ""' >/dev/null 2>&1; then
            continue # Try next file
        fi

        if echo "$RESPONSE" | jq -e ".nodes[\"$COMPONENT_ID\"]" >/dev/null 2>&1; then
            COMPONENT_DATA=$(echo "$RESPONSE" | jq ".nodes[\"$COMPONENT_ID\"]")
            FOUND_IN_FILE="$FILE_KEY"
            break
        fi
    done

    if [ -z "$COMPONENT_DATA" ] || [ "$COMPONENT_DATA" = "null" ]; then
        echo "   ⚠️  Component not found in any file"
        FAILED=$((FAILED + 1))
        continue
    fi

    # Get component name
    COMPONENT_NAME=$(echo "$COMPONENT_DATA" | jq -r '.document.name // "Unknown"')

    # Count TEXT nodes to verify we got content
    TEXT_COUNT=$(echo "$COMPONENT_DATA" | jq '[.. | objects | select(.type? == "TEXT")] | length')

    # Save component
    echo "$COMPONENT_DATA" >"$OUTPUT_FILE"

    FILE_SIZE=$(ls -lh "$OUTPUT_FILE" | awk '{print $5}')
    echo "   ✅ Saved: $COMPONENT_NAME ($FILE_SIZE, $TEXT_COUNT TEXT nodes)"

    # Add to usage index
    if [ "$FIRST_COMPONENT" = true ]; then
        FIRST_COMPONENT=false
    else
        echo "," >>"$USAGE_FILE"
    fi
    echo "    \"$COMPONENT_ID\": {" >>"$USAGE_FILE"
    echo "      \"name\": \"$COMPONENT_NAME\"," >>"$USAGE_FILE"
    echo "      \"file\": \"component-${SAFE_ID}.json\"," >>"$USAGE_FILE"
    echo "      \"figmaFile\": \"$FOUND_IN_FILE\"," >>"$USAGE_FILE"
    echo "      \"textNodes\": $TEXT_COUNT" >>"$USAGE_FILE"
    echo -n "    }" >>"$USAGE_FILE"

    EXTRACTED=$((EXTRACTED + 1))

    # Small delay to avoid rate limiting
    sleep 0.2
done

# Close usage index
echo "" >>"$USAGE_FILE"
echo "  }," >>"$USAGE_FILE"
echo "  \"extractedAt\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"," >>"$USAGE_FILE"
echo "  \"figmaFiles\": [$(printf '"%s",' "${FIGMA_FILE_KEYS[@]}" | sed 's/,$//')]," >>"$USAGE_FILE"
echo "  \"totalComponents\": $((EXTRACTED + SKIPPED))" >>"$USAGE_FILE"
echo "}" >>"$USAGE_FILE"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 Results:"
echo "   Components found:     $COMPONENT_COUNT"
echo "   ✅ Extracted:         $EXTRACTED"
if [ $SKIPPED -gt 0 ]; then
    echo "   ⏭️  Skipped (cached):  $SKIPPED"
fi
if [ $FAILED -gt 0 ]; then
    echo "   ❌ Failed:            $FAILED"
fi
echo ""
echo "📁 Components saved to: $OUTPUT_DIR"
echo "📋 Usage index: $USAGE_FILE"
echo ""

# Count total TEXT nodes across all components
TOTAL_TEXT_NODES=$(jq '[.. | objects | select(.type? == "TEXT")] | length' "$OUTPUT_DIR"/component-*.json 2>/dev/null | paste -sd+ - | bc 2>/dev/null || echo "0")

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Component extraction complete!"
echo ""
echo "📝 TEXT nodes extracted: $TOTAL_TEXT_NODES"
echo ""
echo "💡 These component definitions contain:"
echo "   ✅ Button labels (TEXT nodes)"
echo "   ✅ Icon references"
echo "   ✅ Full internal structure"
echo "   ✅ Typography settings"
echo "   ✅ Spacing and layout"
echo ""
echo "🔗 ui-specialist can now resolve:"
echo "   INSTANCE { componentId: \"$COMPONENT_ID\" }"
echo "   → component-${SAFE_ID}.json (full definition with TEXT nodes)"
echo ""
echo "💰 Cost: \$0.00 (FREE - no AI tokens used!)"
