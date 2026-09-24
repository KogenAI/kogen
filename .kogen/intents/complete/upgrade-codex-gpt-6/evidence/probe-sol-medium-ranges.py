def compact_ranges(values):
    """Return inclusive ranges for consecutive integer values."""
    ordered = sorted(set(values))
    if not ordered:
        return []

    ranges = []
    start = previous = ordered[0]
    for value in ordered[1:]:
        if value != previous + 1:
            ranges.append((start, previous))
            start = value
        previous = value

    ranges.append((start, previous))
    return ranges
