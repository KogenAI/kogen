#!/bin/bash
set -e

# Extract detailed Figma implementation specs (for pixel-perfect implementation)
#
# Gets detailed node data including:
# - Text content (actual strings)
# - Exact measurements (width, height, positions)
# - Typography (font size, weight, line height)
# - Layout properties (Auto Layout, padding, gaps)
# - Component hierarchy (what's inside what)
# - NO vector geometry (keeps files manageable)
#
# Usage: ./extract_figma_implementation_specs.sh <file-key> <node-ids-file> <output-dir>
#
# Example:
#   ./extract_figma_implementation_specs.sh "abc123" \
#     ./node-ids-messages.txt \
#     ./design-system/implementation-specs
#
# Creates one JSON file per screen with all implementation details

FIGMA_FILE_KEY="$1"
NODE_IDS_FILE="$2"
OUTPUT_DIR="$3"

if [ -z "$FIGMA_FILE_KEY" ] || [ -z "$NODE_IDS_FILE" ] || [ -z "$OUTPUT_DIR" ]; then
    echo "❌ Error: Missing required arguments"
    echo ""
    echo "Usage: $0 <figma-file-key> <node-ids-file> <output-dir>"
    echo ""
    echo "Example:"
    echo "  $0 abc123 ./node-ids-messages.txt ./implementation-specs"
    exit 1
fi

if [ ! -f "$NODE_IDS_FILE" ]; then
    echo "❌ Error: Node IDs file not found: $NODE_IDS_FILE"
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

echo "📐 Extracting detailed implementation specs via REST API"
echo ""
echo "File key: $FIGMA_FILE_KEY"
echo "Input:    $NODE_IDS_FILE"
echo "Output:   $OUTPUT_DIR"
echo ""

# First pass: expand EXPAND: directives and build final node list
TEMP_EXPANDED=$(mktemp)

while IFS='|' read -r NODE_ID SCREEN_NAME DESC; do
    # Skip empty lines and comments
    [[ -z "$NODE_ID" || "$NODE_ID" =~ ^# ]] && continue

    # Check for EXPAND: directive with optional depth
    if [[ "$NODE_ID" =~ ^EXPAND: ]]; then
        # Parse EXPAND:node-id or EXPAND:node-id:depth=N
        EXPAND_SPEC="${NODE_ID#EXPAND:}"

        # Check if depth is specified
        if [[ "$EXPAND_SPEC" =~ ^(.+):depth=([0-9]+)$ ]]; then
            PARENT_NODE="${BASH_REMATCH[1]}"
            DEPTH="${BASH_REMATCH[2]}"
        else
            PARENT_NODE="$EXPAND_SPEC"
            DEPTH=1
        fi

        echo "🔄 Expanding parent node: $PARENT_NODE (depth=$DEPTH) - $SCREEN_NAME"

        # Fetch parent node with specified depth
        EXPAND_RESPONSE=$(curl -s -X GET \
            "https://api.figma.com/v1/files/$FIGMA_FILE_KEY/nodes?ids=$PARENT_NODE&depth=$DEPTH" \
            -H "X-Figma-Token: $FIGMA_API_TOKEN")

        # Extract leaf nodes only (nodes that don't have FRAME children)
        # This filters out container frames and gets actual screens
        if [ "$DEPTH" -eq 1 ]; then
            # depth=1: Just get immediate children
            echo "$EXPAND_RESPONSE" | jq -r ".nodes[\"$PARENT_NODE\"].document.children[]? | \"\(.id)|\(.name)|Auto-expanded from $SCREEN_NAME\"" >>"$TEMP_EXPANDED"
        else
            # depth=2+: Recursively find actual screen nodes
            # Strategy: Find FRAME nodes that have substantial content (likely real screens)
            # and are not header/decoration frames
            echo "$EXPAND_RESPONSE" | jq -r "
                .nodes[\"$PARENT_NODE\"].document |
                .. |
                objects |
                select(.type? == \"FRAME\") |
                select(.name? != null) |
                # Filter out obvious header/decoration frames
                select(.name | test(\"^(Frame |Rectangle |Group |Component )[0-9]\") | not) |
                # Must have children (actual content)
                select((.children? // [] | length) > 3) |
                \"\(.id)|\(.name)|Auto-expanded (depth=$DEPTH) from $SCREEN_NAME\"
            " >>"$TEMP_EXPANDED"
        fi
    else
        # Regular node - pass through
        echo "$NODE_ID|$SCREEN_NAME|$DESC" >>"$TEMP_EXPANDED"
    fi
done <"$NODE_IDS_FILE"

echo ""

# Second pass: extract specs for each node (including expanded ones)
TOTAL=0
EXTRACTED=0
FAILED=0

while IFS='|' read -r NODE_ID SCREEN_NAME DESC; do
    [[ -z "$NODE_ID" ]] && continue

    TOTAL=$((TOTAL + 1))

    # Create safe filename from screen name + node ID (to prevent duplicates)
    SAFE_NAME=$(echo "$SCREEN_NAME" | tr ' ' '-' | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]//g')
    # Replace colon in node ID with dash for filename
    SAFE_NODE_ID=$(echo "$NODE_ID" | tr ':' '-')
    OUTPUT_FILE="$OUTPUT_DIR/${SAFE_NAME}-${SAFE_NODE_ID}-specs.json"

    echo "📋 Extracting: $SCREEN_NAME"
    echo "   Node ID: $NODE_ID"

    # Call Figma API with depth=3 to get detailed hierarchy
    # NO geometry parameter = no vector paths (saves space)
    RESPONSE=$(curl -s -X GET \
        "https://api.figma.com/v1/files/$FIGMA_FILE_KEY/nodes?ids=$NODE_ID&depth=3" \
        -H "X-Figma-Token: $FIGMA_API_TOKEN")

    # Check for errors
    if echo "$RESPONSE" | jq -e '.err != null and .err != ""' >/dev/null 2>&1; then
        ERROR_MSG=$(echo "$RESPONSE" | jq -r '.err // "Unknown error"')
        echo "   ❌ API Error: $ERROR_MSG"
        FAILED=$((FAILED + 1))
        continue
    fi

    if ! echo "$RESPONSE" | jq -e ".nodes[\"$NODE_ID\"]" >/dev/null 2>&1; then
        echo "   ⚠️  Node not found"
        FAILED=$((FAILED + 1))
        continue
    fi

    # Save full response
    echo "$RESPONSE" | jq ".nodes[\"$NODE_ID\"]" >"$OUTPUT_FILE"

    # Extract summary info
    FILE_SIZE=$(ls -lh "$OUTPUT_FILE" | awk '{print $5}')
    CHILD_COUNT=$(echo "$RESPONSE" | jq ".nodes[\"$NODE_ID\"].document.children | length // 0")

    echo "   ✅ Saved ($FILE_SIZE, $CHILD_COUNT children)"
    echo "   📄 File: $OUTPUT_FILE"

    EXTRACTED=$((EXTRACTED + 1))
    echo ""
done <"$TEMP_EXPANDED"

rm -f "$TEMP_EXPANDED"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 Results:"
echo "   Total screens:    $TOTAL"
echo "   ✅ Extracted:     $EXTRACTED"
if [ $FAILED -gt 0 ]; then
    echo "   ❌ Failed:        $FAILED"
fi
echo ""
echo "📁 Specs saved to: $OUTPUT_DIR"
echo ""

# Create index file
INDEX_FILE="$OUTPUT_DIR/INDEX.md"
cat >"$INDEX_FILE" <<EOF
# Implementation Specs Index

Extracted: $(date)
File: $FIGMA_FILE_KEY
Screens: $EXTRACTED

## What's in these files

Each JSON file contains detailed implementation specs for one screen:

- **Text content**: Actual strings to display
- **Measurements**: Exact width, height, x, y positions
- **Typography**: Font family, size, weight, line height
- **Colors**: Fill colors, stroke colors (RGBA values)
- **Layout**: Auto Layout properties (padding, gaps, alignment)
- **Hierarchy**: Full component tree (depth=3)

## How to use

1. **Visual reference**: Use screenshots for overall look
2. **Measurements**: Use these JSON files for exact dimensions
3. **Text content**: Copy strings from \`characters\` fields
4. **Layout**: Check \`layoutMode\`, \`primaryAxisAlignItems\`, \`counterAxisAlignItems\`
5. **Spacing**: Look for \`paddingTop\`, \`itemSpacing\`, etc.

## Files

EOF

# List all extracted files
ls -lh "$OUTPUT_DIR"/*.json 2>/dev/null | awk '{print "- " $9 " (" $5 ")"}' | sed 's|.*/||' >>"$INDEX_FILE"

echo "📋 Index created: $INDEX_FILE"
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Extraction complete!"
echo ""
echo "💡 What ui-specialist should read:"
echo "   1. Screenshots (visual reference)"
echo "   2. These spec files (exact measurements + text)"
echo "   3. Haiku comparison during implementation"
echo ""
echo "🎯 With these specs, ui-specialist can implement:"
echo "   ✅ Exact button sizes (width × height from absoluteBoundingBox)"
echo "   ✅ Exact spacing (itemSpacing, padding values)"
echo "   ✅ Exact text content (characters field)"
echo "   ✅ Exact fonts (style.fontSize, fontWeight)"
echo "   ✅ Exact colors (fills[].color.r/g/b/a)"
echo "   ✅ Component nesting (children[] hierarchy)"
echo ""
echo "💰 Cost: \$0.00 (FREE - no AI tokens used!)"
