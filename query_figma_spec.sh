#!/bin/bash
set -e

# Query Figma spec files for specific UI elements and their styling
#
# This makes it easy to find exact styling values without manually parsing JSON
#
# Usage: ./query_figma_spec.sh <specs-directory> <query-type> [options]
#
# Query types:
#   text     - Find all TEXT nodes with their styling
#   colors   - Find all unique colors used
#   buttons  - Find button-like elements (TEXT inside FRAME with backgrounds)
#   pills    - Find pill/badge elements (small rounded containers)
#   element  - Search by element name (case-insensitive partial match)
#   style    - Get all style properties for elements matching a name
#
# Examples:
#   ./query_figma_spec.sh ./specs text
#   ./query_figma_spec.sh ./specs colors
#   ./query_figma_spec.sh ./specs element "status"
#   ./query_figma_spec.sh ./specs style "Sent"

SPECS_DIR="$1"
QUERY_TYPE="$2"
SEARCH_TERM="$3"

if [ -z "$SPECS_DIR" ] || [ -z "$QUERY_TYPE" ]; then
    echo "❌ Error: Missing required arguments"
    echo ""
    echo "Usage: $0 <specs-directory> <query-type> [search-term]"
    echo ""
    echo "Query types:"
    echo "  text       Find all TEXT nodes with content and styling"
    echo "  colors     List all unique colors (hex codes)"
    echo "  badges     Find status badges with text + bg colors: $0 <dir> badges"
    echo "  buttons    Find button-like elements"
    echo "  pills      Find pill/badge elements"
    echo "  element    Search by element name: $0 <dir> element \"status\""
    echo "  style      Get full style for element: $0 <dir> style \"Sent\""
    echo "  variables  Show all resolved variable values"
    echo ""
    echo "Examples:"
    echo "  $0 ./design-system/features/negotiation/specs text"
    echo "  $0 ./design-system/features/negotiation/specs element \"contract\""
    echo "  $0 ./design-system/features/negotiation/specs style \"View contract\""
    exit 1
fi

if [ ! -d "$SPECS_DIR" ]; then
    echo "❌ Error: Specs directory not found: $SPECS_DIR"
    exit 1
fi

# Helper: Convert RGBA to hex
rgba_to_hex() {
    local r="$1" g="$2" b="$3"
    printf "#%02X%02X%02X" "$(echo "$r * 255" | bc | cut -d. -f1)" "$(echo "$g * 255" | bc | cut -d. -f1)" "$(echo "$b * 255" | bc | cut -d. -f1)"
}

echo "🔍 Querying Figma specs: $QUERY_TYPE"
echo "   Directory: $SPECS_DIR"
[ -n "$SEARCH_TERM" ] && echo "   Search: $SEARCH_TERM"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

case "$QUERY_TYPE" in
text)
    echo "📝 TEXT Nodes with Styling:"
    echo ""
    for SPEC_FILE in "$SPECS_DIR"/*.json; do
        [ -f "$SPEC_FILE" ] || continue
        SCREEN_NAME=$(basename "$SPEC_FILE" -specs.json)

        jq -r '
                [.. | objects | select(.type == "TEXT")] |
                .[] |
                "  \(.characters // "—")"
                + "\n    font: \(.style.fontFamily // "?") \(.style.fontWeight // "?")@\(.style.fontSize // "?")px"
                + (if .fills[0].color then
                    "\n    color: rgb(\(.fills[0].color.r | . * 255 | floor),\(.fills[0].color.g | . * 255 | floor),\(.fills[0].color.b | . * 255 | floor))"
                  else "" end)
            ' "$SPEC_FILE" 2>/dev/null | head -100
    done
    ;;

colors)
    echo "🎨 Unique Colors Found:"
    echo ""
    for SPEC_FILE in "$SPECS_DIR"/*.json; do
        [ -f "$SPEC_FILE" ] || continue

        jq -r '
                [.. | objects | select(has("fills")) | .fills[]] |
                map(select(.color != null) | .color) |
                unique |
                .[] |
                "  #\((.r * 255 | floor | . as $n | if $n < 16 then "0" else "" end)\((.r * 255 | floor) | @base64d // (. | tostring | split(".")[0]))\((.g * 255 | floor) | . as $n | if $n < 16 then "0" else "" end)\((.g * 255 | floor))\((.b * 255 | floor) | . as $n | if $n < 16 then "0" else "" end)\((.b * 255 | floor))) - rgba(\(.r),\(.g),\(.b),\(.a))"
            ' "$SPEC_FILE" 2>/dev/null
    done | sort -u
    ;;

element)
    if [ -z "$SEARCH_TERM" ]; then
        echo "❌ Error: element query requires a search term"
        echo "   Usage: $0 <dir> element \"status\""
        exit 1
    fi

    echo "🔎 Elements matching '$SEARCH_TERM':"
    echo ""
    for SPEC_FILE in "$SPECS_DIR"/*.json; do
        [ -f "$SPEC_FILE" ] || continue
        SCREEN_NAME=$(basename "$SPEC_FILE" -specs.json)

        RESULTS=$(jq -r --arg search "$SEARCH_TERM" '
                [.. | objects | select(.name != null) | select(.name | ascii_downcase | contains($search | ascii_downcase))] |
                .[] |
                "  [\(.type)] \(.name)"
                + (if .characters then "\n    text: \"\(.characters)\"" else "" end)
                + (if .style then "\n    style: \(.style.fontFamily // "")@\(.style.fontSize // "")px weight=\(.style.fontWeight // "")" else "" end)
                + (if .fills[0].color then "\n    fill: rgba(\(.fills[0].color.r | . * 255 | floor),\(.fills[0].color.g | . * 255 | floor),\(.fills[0].color.b | . * 255 | floor),\(.fills[0].color.a))" else "" end)
                + (if .cornerRadius then "\n    radius: \(.cornerRadius)px" else "" end)
                + (if .paddingTop then "\n    padding: \(.paddingTop // 0) \(.paddingRight // 0) \(.paddingBottom // 0) \(.paddingLeft // 0)" else "" end)
            ' "$SPEC_FILE" 2>/dev/null)

        if [ -n "$RESULTS" ]; then
            echo "📄 $SCREEN_NAME:"
            echo "$RESULTS"
            echo ""
        fi
    done
    ;;

style)
    if [ -z "$SEARCH_TERM" ]; then
        echo "❌ Error: style query requires a search term"
        echo "   Usage: $0 <dir> style \"View contract\""
        exit 1
    fi

    echo "🎨 Full styling for elements containing '$SEARCH_TERM':"
    echo ""
    for SPEC_FILE in "$SPECS_DIR"/*.json; do
        [ -f "$SPEC_FILE" ] || continue
        SCREEN_NAME=$(basename "$SPEC_FILE" -specs.json)

        RESULTS=$(jq -r --arg search "$SEARCH_TERM" '
                def to_hex: . * 255 | floor | if . < 16 then "0\(. | @base64d // tostring)" else (. | tostring) end;

                [.. | objects |
                 select(.name != null or .characters != null) |
                 select(
                   (.name // "" | ascii_downcase | contains($search | ascii_downcase)) or
                   (.characters // "" | ascii_downcase | contains($search | ascii_downcase))
                 )
                ] |
                .[] |
                {
                    type: .type,
                    name: .name,
                    text: .characters,
                    width: .absoluteBoundingBox.width,
                    height: .absoluteBoundingBox.height,
                    font: (if .style then {
                        family: .style.fontFamily,
                        size: .style.fontSize,
                        weight: .style.fontWeight,
                        lineHeight: .style.lineHeightPx
                    } else null end),
                    fill: (if .fills[0].color then {
                        r: (.fills[0].color.r * 255 | floor),
                        g: (.fills[0].color.g * 255 | floor),
                        b: (.fills[0].color.b * 255 | floor),
                        a: .fills[0].color.a
                    } else null end),
                    stroke: (if .strokes[0].color then {
                        r: (.strokes[0].color.r * 255 | floor),
                        g: (.strokes[0].color.g * 255 | floor),
                        b: (.strokes[0].color.b * 255 | floor)
                    } else null end),
                    radius: .cornerRadius,
                    padding: (if .paddingTop then {
                        top: .paddingTop,
                        right: .paddingRight,
                        bottom: .paddingBottom,
                        left: .paddingLeft
                    } else null end),
                    gap: .itemSpacing,
                    layout: .layoutMode
                }
            ' "$SPEC_FILE" 2>/dev/null)

        if [ -n "$RESULTS" ] && [ "$RESULTS" != "null" ]; then
            echo "📄 $SCREEN_NAME:"
            echo "$RESULTS" | jq .
            echo ""
        fi
    done
    ;;

variables)
    VARS_FILE="$(dirname "$SPECS_DIR")/../variables-resolved.json"
    if [ ! -f "$VARS_FILE" ]; then
        VARS_FILE="$(dirname "$SPECS_DIR")/../../variables-resolved.json"
    fi

    if [ -f "$VARS_FILE" ]; then
        echo "📋 Resolved Design Variables:"
        echo "   File: $VARS_FILE"
        echo ""
        jq -r 'to_entries | .[] |
                "  \(.key)"
                + "\n    type: \(.value.type)"
                + (if .value.hex then "\n    hex: \(.value.hex)" else "" end)
                + (if .value.value then "\n    value: \(.value.value)" else "" end)
                + (if .value.property then "\n    property: \(.value.property)" else "" end)
            ' "$VARS_FILE"
    else
        echo "⚠️  Variables file not found. Run: ocg build-variable-map"
    fi
    ;;

badges)
    # Special query for status badges - finds TEXT nodes and their parent container
    if [ -z "$SEARCH_TERM" ]; then
        SEARCH_TERM="Sent|Accepted|Declined|Expired"
    fi

    echo "🏷️  Status Badges matching '$SEARCH_TERM':"
    echo ""
    for SPEC_FILE in "$SPECS_DIR"/*.json; do
        [ -f "$SPEC_FILE" ] || continue
        SCREEN_NAME=$(basename "$SPEC_FILE" -specs.json)

        python3 -c "
import json
import re
import sys

def rgb_to_hex(r, g, b):
    return '#{:02x}{:02x}{:02x}'.format(int(r*255), int(g*255), int(b*255))

def find_badges_with_parents(obj, pattern, parent=None):
    results = []
    if isinstance(obj, dict):
        name = obj.get('name', '')
        obj_type = obj.get('type', '')

        # Check children for matching TEXT nodes
        children = obj.get('children', [])
        for child in children:
            if isinstance(child, dict) and child.get('type') == 'TEXT':
                if re.search(pattern, child.get('name', ''), re.IGNORECASE) or \
                   re.search(pattern, child.get('characters', ''), re.IGNORECASE):
                    # Found matching text - extract both text and parent styling
                    text_fills = child.get('fills', [])
                    text_color = None
                    if text_fills and text_fills[0].get('color'):
                        c = text_fills[0]['color']
                        text_color = rgb_to_hex(c['r'], c['g'], c['b'])

                    style = child.get('style', {})

                    parent_fills = obj.get('fills', [])
                    bg_color = None
                    if parent_fills and parent_fills[0].get('color'):
                        c = parent_fills[0]['color']
                        bg_color = rgb_to_hex(c['r'], c['g'], c['b'])

                    results.append({
                        'text': child.get('characters'),
                        'textColor': text_color,
                        'fontSize': style.get('fontSize'),
                        'fontWeight': style.get('fontWeight'),
                        'bgColor': bg_color,
                        'cornerRadius': obj.get('cornerRadius'),
                        'padding': {
                            'h': obj.get('paddingLeft'),
                            'v': obj.get('paddingTop')
                        }
                    })

        for v in obj.values():
            results.extend(find_badges_with_parents(v, pattern, obj))
    elif isinstance(obj, list):
        for item in obj:
            results.extend(find_badges_with_parents(item, pattern, parent))
    return results

with open('$SPEC_FILE') as f:
    data = json.load(f)

badges = find_badges_with_parents(data, '$SEARCH_TERM')
for b in badges:
    print(json.dumps(b, indent=2))
    print('---')
" 2>/dev/null

    done
    ;;

pills | buttons)
    echo "🔘 Finding $QUERY_TYPE elements (FRAME with rounded corners and text):"
    echo ""
    for SPEC_FILE in "$SPECS_DIR"/*.json; do
        [ -f "$SPEC_FILE" ] || continue
        SCREEN_NAME=$(basename "$SPEC_FILE" -specs.json)

        jq -r '
                [.. | objects |
                 select(.type == "FRAME" or .type == "INSTANCE") |
                 select(.cornerRadius != null and .cornerRadius > 0) |
                 select(.absoluteBoundingBox.height != null and .absoluteBoundingBox.height < 60) |
                 select(.children != null and (.children | length) > 0)
                ] |
                .[] |
                "  \(.name) (\(.absoluteBoundingBox.width | floor)x\(.absoluteBoundingBox.height | floor))"
                + "\n    radius: \(.cornerRadius)px"
                + (if .fills[0].color then "\n    bg: rgba(\(.fills[0].color.r | . * 255 | floor),\(.fills[0].color.g | . * 255 | floor),\(.fills[0].color.b | . * 255 | floor),\(.fills[0].color.a))" else "" end)
                + (if .paddingLeft then "\n    padding: \(.paddingTop // 0) \(.paddingRight // 0) \(.paddingBottom // 0) \(.paddingLeft // 0)" else "" end)
            ' "$SPEC_FILE" 2>/dev/null | head -50
    done
    ;;

*)
    echo "❌ Unknown query type: $QUERY_TYPE"
    echo ""
    echo "Valid types: text, colors, element, style, variables, pills, buttons"
    exit 1
    ;;
esac

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Query complete"
