# Extract unique componentIds from Figma spec files
# Finds all INSTANCE nodes and extracts their componentId
[
    .. | objects |
    select(.type? == "INSTANCE") |
    select(.componentId != null) |
    .componentId
] | unique | .[]
