#!/bin/bash
set -e

# Extract Figma file metadata using REST API (NO AI tokens required!)
#
# Gets complete file structure including:
# - Document tree with all nodes
# - Components map
# - Component sets
# - Styles
# - Metadata
#
# Usage: ./extract_figma_metadata.sh <figma-file-key> <output-file>
#
# Example:
#   ./extract_figma_metadata.sh "abc123" ./design-system/metadata.json

FIGMA_FILE_KEY="$1"
OUTPUT_FILE="$2"

if [ -z "$FIGMA_FILE_KEY" ] || [ -z "$OUTPUT_FILE" ]; then
    echo "❌ Error: Missing required arguments"
    echo ""
    echo "Usage: $0 <figma-file-key> <output-file>"
    echo ""
    echo "Example:"
    echo "  $0 abc123 ./design-system/metadata.json"
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

# Create output directory if needed
OUTPUT_DIR=$(dirname "$OUTPUT_FILE")
mkdir -p "$OUTPUT_DIR"

echo "📊 Extracting Figma file metadata via REST API"
echo ""
echo "File key: $FIGMA_FILE_KEY"
echo "Output:   $OUTPUT_FILE"
echo ""

# Call Figma REST API
# Parameters:
#   depth=2 - Limit tree depth (pages -> frames -> children, but not deeper)
#   NO geometry - Skip vector paths to reduce file size
echo "🌐 Requesting file data from Figma API..."
RESPONSE=$(curl -s -X GET \
    "https://api.figma.com/v1/files/$FIGMA_FILE_KEY?depth=2" \
    -H "X-Figma-Token: $FIGMA_API_TOKEN")

# Check for API errors
if echo "$RESPONSE" | jq -e '.err != null and .err != ""' >/dev/null 2>&1; then
    ERROR_MSG=$(echo "$RESPONSE" | jq -r '.err // "Unknown error"')
    echo "❌ Figma API Error: $ERROR_MSG"
    exit 1
fi

if echo "$RESPONSE" | jq -e '.status == 404' >/dev/null 2>&1; then
    echo "❌ File not found: $FIGMA_FILE_KEY"
    echo "   Check that the file key is correct and you have access"
    exit 1
fi

if ! echo "$RESPONSE" | jq -e '.document' >/dev/null 2>&1; then
    echo "❌ Invalid API response (no 'document' field)"
    echo "Response preview:"
    echo "$RESPONSE" | head -20
    exit 1
fi

echo "✅ Got file metadata from Figma API"
echo ""

# Save full response
echo "$RESPONSE" | jq '.' >"$OUTPUT_FILE"

# Extract summary stats
FILE_NAME=$(echo "$RESPONSE" | jq -r '.name')
LAST_MODIFIED=$(echo "$RESPONSE" | jq -r '.lastModified')
VERSION=$(echo "$RESPONSE" | jq -r '.version')
COMPONENT_COUNT=$(echo "$RESPONSE" | jq '.components | length')
STYLE_COUNT=$(echo "$RESPONSE" | jq '.styles | length')

# Count total nodes (approximate - top-level pages)
PAGE_COUNT=$(echo "$RESPONSE" | jq '.document.children | length')

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📄 File: $FILE_NAME"
echo "📅 Last modified: $LAST_MODIFIED"
echo "🔢 Version: $VERSION"
echo ""
echo "📊 Contents:"
echo "   Pages:      $PAGE_COUNT"
echo "   Components: $COMPONENT_COUNT"
echo "   Styles:     $STYLE_COUNT"
echo ""
echo "💾 Saved to: $OUTPUT_FILE"

# Get file size
FILE_SIZE=$(ls -lh "$OUTPUT_FILE" | awk '{print $5}')
echo "📦 Size: $FILE_SIZE"
echo ""

# Show sample of document structure
echo "🌳 Document structure (first 3 pages):"
echo "$RESPONSE" | jq -r '.document.children[:3][] | "   - \(.name) (type: \(.type), children: \(if .children then (.children | length) else 0 end))"'
echo ""

# Extract useful data to separate files for easier access
METADATA_DIR=$(dirname "$OUTPUT_FILE")

# 1. Extract component list
if [ "$COMPONENT_COUNT" -gt 0 ]; then
    COMPONENTS_FILE="$METADATA_DIR/components.json"
    echo "$RESPONSE" | jq '.components' >"$COMPONENTS_FILE"
    echo "📦 Components saved to: $COMPONENTS_FILE"
fi

# 2. Extract styles list
if [ "$STYLE_COUNT" -gt 0 ]; then
    STYLES_FILE="$METADATA_DIR/styles.json"
    echo "$RESPONSE" | jq '.styles' >"$STYLES_FILE"
    echo "🎨 Styles saved to: $STYLES_FILE"
fi

# 3. Extract page list with IDs
PAGES_FILE="$METADATA_DIR/pages.txt"
echo "$RESPONSE" | jq -r '.document.children[] | "\(.id)|\(.name)|\(.type)"' >"$PAGES_FILE"
echo "📑 Pages list saved to: $PAGES_FILE"

# 4. Create lightweight hierarchy (NO geometry - just names and IDs)
HIERARCHY_FILE="$METADATA_DIR/hierarchy.json"
echo "$RESPONSE" | jq '{
  name: .name,
  lastModified: .lastModified,
  pages: [.document.children[] | {
    id: .id,
    name: .name,
    type: .type,
    frames: [.children[]? | {
      id: .id,
      name: .name,
      type: .type,
      childCount: (.children | length // 0)
    }]
  }]
}' >"$HIERARCHY_FILE"

HIERARCHY_SIZE=$(ls -lh "$HIERARCHY_FILE" | awk '{print $5}')
echo "🌲 Lightweight hierarchy saved to: $HIERARCHY_FILE ($HIERARCHY_SIZE)"
echo "   ↳ Use this for planning (no geometry bloat!)"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Extraction complete!"
echo ""
echo "💰 Cost Comparison:"
echo "   ❌ Old approach (claude -p get_metadata): ~13-25K tokens (~$0.01-0.03)"
echo "   ✅ New approach (REST API):               0 tokens (\$0.00 - FREE!)"
echo ""
echo "⚡ Next steps:"
echo "   1. Parse node IDs: jq -r '.document.children[].children[] | ...' $OUTPUT_FILE"
echo "   2. Use extract_figma_nodes.sh to get specific screens"
echo "   3. Use extract_figma_screenshots.sh to render images"
