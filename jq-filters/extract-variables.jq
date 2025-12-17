# Extract Figma variable mappings from spec files
# Combines boundVariables references with actual computed values
#
# Structure notes:
# - fills/strokes in boundVariables are ARRAYS (skip them, handle via fills[].boundVariables.color)
# - padding/itemSpacing/gap in boundVariables are OBJECTS with {type: "VARIABLE_ALIAS", id: ...}

# Part 1: Colors from fills (embedded boundVariables in fill items)
(
    [
        .. | objects |
        select(has("fills")) |
        .fills[] |
        select(has("color") and has("boundVariables") and (.boundVariables.color | type) == "object") |
        {
            id: .boundVariables.color.id,
            type: "COLOR",
            value: .color
        }
    ] // []
) +

# Part 2: Colors from strokes (embedded boundVariables in stroke items)
(
    [
        .. | objects |
        select(has("strokes")) |
        .strokes[] |
        select(has("color") and has("boundVariables") and (.boundVariables.color | type) == "object") |
        {
            id: .boundVariables.color.id,
            type: "COLOR",
            value: .color
        }
    ] // []
) +

# Part 3: Spacing variables (only object values, skip arrays like fills/strokes)
(
    [
        .. | objects |
        select(has("boundVariables")) |
        . as $node |
        .boundVariables | to_entries[] |
        select((.value | type) == "object") |
        select(.value.type == "VARIABLE_ALIAS") |
        select(.key | test("padding|itemSpacing|gap"; "i")) |
        {
            id: .value.id,
            type: "FLOAT",
            property: .key,
            value: $node[.key]
        }
    ] // []
) +

# Part 4: Corner radius variables
(
    [
        .. | objects |
        select(has("boundVariables") and (.boundVariables.rectangleCornerRadii | type) == "object") |
        . as $node |
        .boundVariables.rectangleCornerRadii | to_entries[] |
        select((.value | type) == "object") |
        select(.value.type == "VARIABLE_ALIAS") |
        {
            id: .value.id,
            type: "FLOAT",
            property: .key,
            value: $node.cornerRadius
        }
    ] // []
) +

# Part 5: Individual stroke weight variables
(
    [
        .. | objects |
        select(has("boundVariables") and (.boundVariables.individualStrokeWeights | type) == "object") |
        . as $node |
        .boundVariables.individualStrokeWeights | to_entries[] |
        select((.value | type) == "object") |
        select(.value.type == "VARIABLE_ALIAS") |
        {
            id: .value.id,
            type: "FLOAT",
            property: .key,
            value: (
                if .key == "BORDER_TOP_WEIGHT" then $node.individualStrokeWeights.top
                elif .key == "BORDER_BOTTOM_WEIGHT" then $node.individualStrokeWeights.bottom
                elif .key == "BORDER_LEFT_WEIGHT" then $node.individualStrokeWeights.left
                elif .key == "BORDER_RIGHT_WEIGHT" then $node.individualStrokeWeights.right
                else null end
            )
        }
    ] // []
)

| .[]
