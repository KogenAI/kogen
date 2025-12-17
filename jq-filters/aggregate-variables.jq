# Aggregate extracted Figma variable mappings
# Input: JSON lines (one object per line)
# Output: Deduplicated object with VariableID as key

# Helper function: convert 0-1 float to 2-digit hex string
def toHex:
    (. * 255 | floor) as $n |
    ["0","1","2","3","4","5","6","7","8","9","A","B","C","D","E","F"] as $chars |
    ($n / 16 | floor) as $high |
    ($n % 16) as $low |
    "\($chars[$high])\($chars[$low])";

# Read all JSON objects, group by id, convert to final format
[inputs] |
group_by(.id) |
map(
    .[0] |
    if .type == "COLOR" and .value then
        (.value.r | toHex) as $r |
        (.value.g | toHex) as $g |
        (.value.b | toHex) as $b |
        {
            (.id): {
                type: "COLOR",
                hex: "#\($r)\($g)\($b)",
                rgba: .value
            }
        }
    elif .type == "FLOAT" and .value then
        {
            (.id): {
                type: "FLOAT",
                value: .value,
                property: .property
            }
        }
    else
        empty
    end
) |
add // {}
