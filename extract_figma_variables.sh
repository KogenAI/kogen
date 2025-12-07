#!/bin/bash
set -e

# Extract Figma variables (design tokens) using REST API (NO AI tokens required!)
#
# Gets published design variables including:
# - Color tokens
# - Number tokens (spacing, sizing, etc.)
# - String tokens (font families, etc.)
# - Boolean tokens
# - Variable collections and modes
#
# Usage: ./extract_figma_variables.sh <figma-file-key> <output-file>
#
# Example:
#   ./extract_figma_variables.sh "abc123" ./design-system/tokens/variables.json

FIGMA_FILE_KEY="$1"
OUTPUT_FILE="$2"

if [ -z "$FIGMA_FILE_KEY" ] || [ -z "$OUTPUT_FILE" ]; then
    echo "❌ Error: Missing required arguments"
    echo ""
    echo "Usage: $0 <figma-file-key> <output-file>"
    echo ""
    echo "Example:"
    echo "  $0 abc123 ./design-system/tokens/variables.json"
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

echo "🎨 Extracting Figma variables (design tokens) via REST API"
echo ""
echo "File key: $FIGMA_FILE_KEY"
echo "Output:   $OUTPUT_FILE"
echo ""

# Call Figma REST API
echo "🌐 Requesting published variables from Figma API..."
RESPONSE=$(curl -s -X GET \
    "https://api.figma.com/v1/files/$FIGMA_FILE_KEY/variables/published" \
    -H "X-Figma-Token: $FIGMA_API_TOKEN")

# Check for API errors
if echo "$RESPONSE" | jq -e '.status == 404' >/dev/null 2>&1; then
    echo "❌ File not found or no published variables: $FIGMA_FILE_KEY"
    echo "   Make sure:"
    echo "   1. File key is correct"
    echo "   2. File has published variables"
    echo "   3. You have access to the file"
    exit 1
fi

if echo "$RESPONSE" | jq -e '.err != null and .err != ""' >/dev/null 2>&1; then
    ERROR_MSG=$(echo "$RESPONSE" | jq -r '.err // "Unknown error"')
    echo "❌ Figma API Error: $ERROR_MSG"
    exit 1
fi

# Check for empty response (no variables published)
if ! echo "$RESPONSE" | jq -e '.meta' >/dev/null 2>&1; then
    echo "⚠️  No published variables found in this file"
    echo ""
    echo "To use this endpoint, you need to:"
    echo "1. Create variables in Figma (colors, spacing, etc.)"
    echo "2. Publish them to a team library"
    echo ""
    echo "Creating empty output file..."
    echo '{"meta": {"variables": {}, "variableCollections": {}}}' | jq '.' >"$OUTPUT_FILE"
    exit 0
fi

echo "✅ Got variables from Figma API"
echo ""

# Save full response
echo "$RESPONSE" | jq '.' >"$OUTPUT_FILE"

# Extract summary stats
VARIABLE_COUNT=$(echo "$RESPONSE" | jq '.meta.variables | length')
COLLECTION_COUNT=$(echo "$RESPONSE" | jq '.meta.variableCollections | length')

# Count by type
COLOR_COUNT=$(echo "$RESPONSE" | jq '[.meta.variables[] | select(.resolvedType == "COLOR")] | length')
FLOAT_COUNT=$(echo "$RESPONSE" | jq '[.meta.variables[] | select(.resolvedType == "FLOAT")] | length')
STRING_COUNT=$(echo "$RESPONSE" | jq '[.meta.variables[] | select(.resolvedType == "STRING")] | length')
BOOLEAN_COUNT=$(echo "$RESPONSE" | jq '[.meta.variables[] | select(.resolvedType == "BOOLEAN")] | length')

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 Variables found: $VARIABLE_COUNT"
echo "📚 Collections: $COLLECTION_COUNT"
echo ""
echo "By type:"
echo "   🎨 Colors:  $COLOR_COUNT"
echo "   📏 Numbers: $FLOAT_COUNT"
echo "   📝 Strings: $STRING_COUNT"
echo "   ☑️  Booleans: $BOOLEAN_COUNT"
echo ""

# List collections
if [ "$COLLECTION_COUNT" -gt 0 ]; then
    echo "📚 Collections:"
    echo "$RESPONSE" | jq -r '.meta.variableCollections | to_entries[] | "   - \(.value.name) (\(.value.modes | length) mode(s))"'
    echo ""
fi

# Show sample variables
if [ "$VARIABLE_COUNT" -gt 0 ]; then
    echo "📋 Sample variables (first 5):"
    echo "$RESPONSE" | jq -r '.meta.variables | to_entries | .[0:5][] | "   - \(.value.name) (\(.value.resolvedType))"'
    echo ""
fi

echo "💾 Saved to: $OUTPUT_FILE"

# Get file size
FILE_SIZE=$(ls -lh "$OUTPUT_FILE" | awk '{print $5}')
echo "📦 Size: $FILE_SIZE"
echo ""

# Extract human-readable tokens to separate file
TOKENS_FILE="${OUTPUT_FILE%.json}-readable.json"
echo "📄 Creating human-readable tokens file..."

# Transform to simpler format: { "colors": {...}, "spacing": {...}, etc. }
echo "$RESPONSE" | jq '{
  colors: [.meta.variables[] | select(.resolvedType == "COLOR") | {
    name: .name,
    value: .valuesByMode[.modes[0]].resolvedValue
  }],
  spacing: [.meta.variables[] | select(.resolvedType == "FLOAT" and (.name | test("spacing|gap|padding|margin"; "i"))) | {
    name: .name,
    value: .valuesByMode[.modes[0]].resolvedValue
  }],
  sizing: [.meta.variables[] | select(.resolvedType == "FLOAT" and (.name | test("size|width|height"; "i"))) | {
    name: .name,
    value: .valuesByMode[.modes[0]].resolvedValue
  }],
  typography: [.meta.variables[] | select(.resolvedType == "STRING" or (.resolvedType == "FLOAT" and (.name | test("font|text|line-height"; "i")))) | {
    name: .name,
    value: .valuesByMode[.modes[0]].resolvedValue
  }],
  other: [.meta.variables[] | select(
    .resolvedType != "COLOR" and
    (.name | test("spacing|gap|padding|margin|size|width|height|font|text|line-height"; "i") | not)
  ) | {
    name: .name,
    type: .resolvedType,
    value: .valuesByMode[.modes[0]].resolvedValue
  }]
}' >"$TOKENS_FILE"

echo "✅ Readable tokens saved to: $TOKENS_FILE"
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Extraction complete!"
echo ""
echo "💰 Cost Comparison:"
echo "   ❌ Old approach (claude -p get_variable_defs): ~5-10K tokens (~$0.005-0.01)"
echo "   ✅ New approach (REST API):                     0 tokens (\$0.00 - FREE!)"
echo ""
echo "⚡ Next steps:"
echo "   1. Review tokens: cat $TOKENS_FILE"
echo "   2. Use in Tailwind config"
echo "   3. Reference in FIGMA_TOKEN_MAPPING.md"
