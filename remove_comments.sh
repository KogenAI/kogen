#!/bin/bash

set -euo pipefail

# Process git diff output and remove comments only from added lines
process_diff() {
    local file="$1"

    # Get the line numbers of added lines from git diff (unstaged only)
    local all_lines=$(git diff --unified=0 "$file" 2>/dev/null | grep '^@@' | sed -E 's/@@ -[0-9,]+ \+([0-9]+)(,([0-9]+))?.*/\1 \3/' | while read start count; do
        if [[ -z "$count" ]] || [[ "$count" == "1" ]]; then
            echo "$start"
        else
            seq "$start" $((start + count - 1))
        fi
    done)

    if [[ -z "$all_lines" ]]; then
        return
    fi

    local ext="${file##*.}"

    # Process each line
    echo "$all_lines" | while read -r line_num; do
        case "$ext" in
        css | scss | less)
            # Check if line contains only a comment
            if sed -n "${line_num}p" "$file" | grep -qE '^\s*/\*.*\*/\s*$'; then
                sed -i '' "${line_num}d" "$file" 2>/dev/null || true
            else
                sed -i '' "${line_num}s|/\*.*\*/||g" "$file" 2>/dev/null || true
            fi
            ;;
        js | jsx | ts | tsx)
            # Check if line contains only a comment
            if sed -n "${line_num}p" "$file" | grep -qE '^\s*//.*$'; then
                sed -i '' "${line_num}d" "$file" 2>/dev/null || true
            else
                sed -i '' "${line_num}s|//.*$||" "$file" 2>/dev/null || true
            fi
            ;;
        ex | exs)
            # Check if line contains only a comment
            if sed -n "${line_num}p" "$file" | grep -qE '^\s*#.*$'; then
                sed -i '' "${line_num}d" "$file" 2>/dev/null || true
            else
                sed -i '' "${line_num}s|#.*$||" "$file" 2>/dev/null || true
            fi
            ;;
        esac
    done
}

# Get modified files (unstaged only)
files=$(git diff --name-only --diff-filter=AMR)
files=$(echo "$files" | sort -u | grep -v '^$' || true)

# Process each file
echo "$files" | while read -r file; do
    [[ -f "$file" ]] || continue
    process_diff "$file"
done

# Process untracked files (all lines are new)
untracked=$(git ls-files --others --exclude-standard)
echo "$untracked" | while read -r file; do
    [[ -f "$file" ]] || continue
    case "${file##*.}" in
    css | scss | less)
        # Delete lines with only comments, otherwise just remove the comment
        sed -i '' -e '/^\s*\/\*.*\*\/\s*$/d' -e 's|/\*.*\*/||g' "$file"
        ;;
    js | jsx | ts | tsx)
        # Delete lines with only comments, otherwise just remove the comment
        sed -i '' -e '/^\s*\/\/.*$/d' -e 's|//.*$||' "$file"
        ;;
    ex | exs)
        # Delete lines with only comments
        sed -i '' '/^\s*#.*$/d' "$file"
        ;;
    esac
done

echo "✅ Done removing comments"

# Run mix format if available
if command -v mix >/dev/null 2>&1 && [[ -f "mix.exs" ]]; then
    echo "🎨 Running mix format..."
    mix format
fi

# Run mix prettier if available
if command -v mix >/dev/null 2>&1 && mix help prettier >/dev/null 2>&1; then
    echo "💅 Running mix prettier..."
    mix prettier
fi

echo "✨ All done!"
