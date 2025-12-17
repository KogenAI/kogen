#!/bin/bash
set -e

# Build variable map from extracted Figma specs
#
# Since file_variables:read scope is Enterprise-only, this script extracts
# variable values from the actual node data where both the variable reference
# AND computed value exist together.
#
# Usage: ./build_variable_map.sh <specs-directory> <output-file>
#
# Example:
#   ./build_variable_map.sh ./design-system/features/jobs/specs/ ./design-system/variables-resolved.json

SPECS_DIR="$1"
OUTPUT_FILE="$2"

if [ -z "$SPECS_DIR" ] || [ -z "$OUTPUT_FILE" ]; then
    echo "❌ Error: Missing required arguments"
    echo ""
    echo "Usage: $0 <specs-directory> <output-file>"
    echo ""
    echo "Example:"
    echo "  $0 ./design-system/features/jobs/specs/ ./design-system/variables-resolved.json"
    exit 1
fi

if [ ! -d "$SPECS_DIR" ]; then
    echo "❌ Error: Specs directory not found: $SPECS_DIR"
    exit 1
fi

echo "🔍 Building variable map from extracted specs"
echo ""
echo "Specs directory: $SPECS_DIR"
echo "Output file:     $OUTPUT_FILE"
echo ""

# Create output directory if needed
OUTPUT_DIR=$(dirname "$OUTPUT_FILE")
mkdir -p "$OUTPUT_DIR"

# Temporary file to collect all variable mappings
TEMP_FILE=$(mktemp)

echo "📂 Processing spec files..."

# Use external jq filter file (avoids all shell escaping issues)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JQ_FILTER="$SCRIPT_DIR/jq-filters/extract-variables.jq"

if [ ! -f "$JQ_FILTER" ]; then
    echo "❌ Error: jq filter not found: $JQ_FILTER"
    exit 1
fi

# Process each spec file
FILE_COUNT=0
for SPEC_FILE in "$SPECS_DIR"/*.json; do
    [ -f "$SPEC_FILE" ] || continue
    FILE_COUNT=$((FILE_COUNT + 1))
    jq -f "$JQ_FILTER" "$SPEC_FILE" >>"$TEMP_FILE" 2>/dev/null || true
done

# Debug: show temp file stats
TEMP_LINES=$(wc -l <"$TEMP_FILE" 2>/dev/null || echo "0")
echo "   Processed $FILE_COUNT spec files"
echo "   Extracted $TEMP_LINES variable references"

echo "✅ Extracted variable references"
echo ""

# Deduplicate and convert to final format
echo "🔧 Deduplicating and formatting..."

# Use external aggregation filter
AGG_FILTER="$SCRIPT_DIR/jq-filters/aggregate-variables.jq"

if [ ! -f "$AGG_FILTER" ]; then
    echo "❌ Error: Aggregation filter not found: $AGG_FILTER"
    exit 1
fi

jq -n -f "$AGG_FILTER" "$TEMP_FILE" >"$OUTPUT_FILE" 2>/dev/null || {
    echo "⚠️  Aggregation failed, using simple format..."
    jq -s 'group_by(.id) | map(.[0]) | map({(.id): .}) | add // {}' "$TEMP_FILE" >"$OUTPUT_FILE" 2>/dev/null || echo "{}" >"$OUTPUT_FILE"
}

rm -f "$TEMP_FILE"

# Count results
VARIABLE_COUNT=$(jq 'keys | length' "$OUTPUT_FILE" 2>/dev/null || echo "0")
COLOR_COUNT=$(jq '[.[] | select(.type == "COLOR")] | length' "$OUTPUT_FILE" 2>/dev/null || echo "0")
FLOAT_COUNT=$(jq '[.[] | select(.type == "FLOAT")] | length' "$OUTPUT_FILE" 2>/dev/null || echo "0")

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 Results:"
echo "   Total variables mapped: $VARIABLE_COUNT"
echo "   🎨 Colors:              $COLOR_COUNT"
echo "   📏 Numbers (spacing):   $FLOAT_COUNT"
echo ""

# Show sample
if [ "$VARIABLE_COUNT" -gt 0 ]; then
    echo "📋 Sample mappings (first 5):"
    jq -r 'to_entries | .[0:5][] | "   \(.key) → \(.value.hex // .value.value) (\(.value.type))"' "$OUTPUT_FILE" 2>/dev/null || true
    echo ""
fi

FILE_SIZE=$(ls -lh "$OUTPUT_FILE" | awk '{print $5}')
echo "💾 Saved to: $OUTPUT_FILE ($FILE_SIZE)"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Variable map built successfully!"
echo ""
echo "💡 Usage: Reference this file to resolve VARIABLE_ALIAS IDs in specs"
echo "   Example: VariableID:6014:3723 → #FFFFFF (COLOR)"
