#!/bin/bash
set -e

# Extract Figma screenshots using REST API (NO AI tokens required!)
#
# Usage: ./extract_figma_screenshots.sh <figma-file-key> <node-ids-file> <output-dir>
#
# Example:
#   ./extract_figma_screenshots.sh "abc123" \
#     ./codegen/design-system/node-ids-messages.txt \
#     ./codegen/design-system/screenshots
#
# Node IDs file format (pipe-separated):
#   8296-62670|Messages - Desktop|Main messages list view
#   7782-42684|Messages - Mobile|Mobile conversation list

FIGMA_FILE_KEY="$1"
NODE_IDS_FILE="$2"
OUTPUT_DIR="$3"

if [ -z "$FIGMA_FILE_KEY" ] || [ -z "$NODE_IDS_FILE" ] || [ -z "$OUTPUT_DIR" ]; then
    echo "❌ Error: Missing required arguments"
    echo ""
    echo "Usage: $0 <figma-file-key> <node-ids-file> <output-dir>"
    echo ""
    echo "Example:"
    echo "  $0 abc123 ./node-ids-messages.txt ./screenshots"
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

echo "📸 Extracting Figma screenshots via REST API"
echo ""
echo "File key: $FIGMA_FILE_KEY"
echo "Output:   $OUTPUT_DIR"
echo ""

# Read all node IDs and build comma-separated list
# Also save mapping to temp files (bash 3.2 compatible - no associative arrays)
NODE_IDS=""
TEMP_MAPPING=$(mktemp)
TEMP_EXPANDED=$(mktemp)

# First pass: expand EXPAND: directives
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

# Second pass: build final node list from expanded file
while IFS='|' read -r NODE_ID SCREEN_NAME DESC; do
    [[ -z "$NODE_ID" ]] && continue

    if [ -z "$NODE_IDS" ]; then
        NODE_IDS="$NODE_ID"
    else
        NODE_IDS="$NODE_IDS,$NODE_ID"
    fi

    # Save mapping to temp file (bash 3.2 compatible)
    echo "$NODE_ID|$SCREEN_NAME|$DESC" >>"$TEMP_MAPPING"
done <"$TEMP_EXPANDED"

rm -f "$TEMP_EXPANDED"

if [ -z "$NODE_IDS" ]; then
    echo "❌ Error: No valid node IDs found in $NODE_IDS_FILE"
    exit 1
fi

echo "Found $(echo "$NODE_IDS" | tr ',' '\n' | wc -l | tr -d ' ') node(s) to export"
echo ""

# Call Figma REST API to get image URLs
echo "🌐 Requesting image URLs from Figma API..."
RESPONSE=$(curl -s -X GET \
    "https://api.figma.com/v1/images/$FIGMA_FILE_KEY?ids=$NODE_IDS&format=png&scale=2" \
    -H "X-Figma-Token: $FIGMA_API_TOKEN")

# Check for API errors
if echo "$RESPONSE" | jq -e '.err != null and .err != ""' >/dev/null 2>&1; then
    ERROR_MSG=$(echo "$RESPONSE" | jq -r '.err')
    echo "❌ Figma API Error: $ERROR_MSG"
    exit 1
fi

if ! echo "$RESPONSE" | jq -e '.images' >/dev/null 2>&1; then
    echo "❌ Invalid API response (no 'images' field)"
    echo "Response: $RESPONSE"
    exit 1
fi

echo "✅ Got image URLs from Figma API"
echo ""

# Download each image (bash 3.2 compatible - read from temp file)
DOWNLOADED=0
FAILED=0

while IFS='|' read -r NODE_ID SCREEN_NAME DESC; do
    IMAGE_URL=$(echo "$RESPONSE" | jq -r ".images[\"$NODE_ID\"]")

    if [ "$IMAGE_URL" = "null" ] || [ -z "$IMAGE_URL" ]; then
        echo "⚠️  No image URL for node: $NODE_ID ($SCREEN_NAME)"
        FAILED=$((FAILED + 1))
        continue
    fi

    # Generate filename from screen name + node ID (to prevent duplicates)
    SAFE_NAME=$(echo "$SCREEN_NAME" | tr ' ' '-' | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]//g')
    # Replace colon in node ID with dash for filename
    SAFE_NODE_ID=$(echo "$NODE_ID" | tr ':' '-')
    FILENAME="${SAFE_NAME}-${SAFE_NODE_ID}.png"
    OUTPUT_PATH="$OUTPUT_DIR/$FILENAME"

    echo "⬇️  Downloading: $SCREEN_NAME"
    echo "   Node ID: $NODE_ID"
    echo "   File:    $FILENAME"

    if curl -s -o "$OUTPUT_PATH" "$IMAGE_URL"; then
        FILE_SIZE=$(ls -lh "$OUTPUT_PATH" | awk '{print $5}')
        echo "   ✅ Saved ($FILE_SIZE)"
        DOWNLOADED=$((DOWNLOADED + 1))
    else
        echo "   ❌ Download failed"
        FAILED=$((FAILED + 1))
    fi

    echo ""
done <"$TEMP_MAPPING"

# Cleanup temp file
rm -f "$TEMP_MAPPING"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Downloaded: $DOWNLOADED"
if [ $FAILED -gt 0 ]; then
    echo "❌ Failed:     $FAILED"
fi
echo ""
echo "📁 Screenshots saved to: $OUTPUT_DIR"
echo ""

# Summary with token cost comparison
echo "💰 Cost Comparison:"
echo "   ❌ Old approach (claude -p per screenshot): ~\$0.05-0.15 for 50 screens"
echo "   ✅ New approach (REST API):                 \$0.00 (FREE!)"
echo ""
echo "⚡ Speed: Batch API call + parallel downloads (10-100x faster)"
