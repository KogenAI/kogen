#!/bin/bash
set -e

# Position Cursor window using Rectangle shortcuts

echo "🖥️  Positioning window $WINDOW_POSITION of $TOTAL_WINDOWS ($LAYOUT_STRATEGY)"

check_rectangle_running() {
    if ! pgrep -f "Rectangle" >/dev/null 2>&1; then
        echo "❌ Rectangle not running"
        return 1
    fi
    return 0
}

check_cursor_running() {
    if ! pgrep -f "Cursor" >/dev/null 2>&1; then
        echo "❌ Cursor not running"
        return 1
    fi
    return 0
}

execute_shortcut() {
    local shortcut="$1"
    local move_to_monitor="$2"

    local applescript_result
    if [ -n "$move_to_monitor" ]; then
        # Script with monitor movement
        applescript_result=$(
            osascript <<EOF 2>&1
try
    tell application "Cursor" to activate
    delay 0.3
    tell application "System Events"
        tell process "Cursor"
            set frontmost to true
            delay 0.2
            -- Move to next display first
            key code 124 using {control down, option down, command down}
            delay 0.5
            -- Execute positioning shortcut
            $shortcut
            delay 0.2
        end tell
    end tell
    return "SUCCESS"
on error errMsg number errNum
    return "ERROR: " & errMsg & " (Code: " & errNum & ")"
end try
EOF
        )
    else
        # Script without monitor movement
        applescript_result=$(
            osascript <<EOF 2>&1
try
    tell application "Cursor" to activate
    delay 0.3
    tell application "System Events"
        tell process "Cursor"
            set frontmost to true
            delay 0.2
            -- Execute positioning shortcut
            $shortcut
            delay 0.5
        end tell
    end tell
    return "SUCCESS"
on error errMsg number errNum
    return "ERROR: " & errMsg & " (Code: " & errNum & ")"
end try
EOF
        )
    fi

    if [[ "$applescript_result" == *"ERROR"* ]] || [[ "$applescript_result" == *"syntax error"* ]]; then
        echo "❌ AppleScript execution failed: $applescript_result"
        return 1
    fi
    return 0
}

position_window() {
    local pos="$1"
    local total="$2"
    local strategy="$3"

    # Determine if this window should move to second monitor
    local move_to_second_monitor=""
    if [ "$total" -le 4 ]; then
        # 4 or fewer windows: all go to second monitor
        move_to_second_monitor="move"
    elif [ "$pos" -le 4 ]; then
        # More than 4 windows: first 4 go to second monitor
        move_to_second_monitor="move"
    fi

    case $strategy in
    "single_fullscreen")
        echo "🔧 Attempting to maximize window on second monitor..."
        execute_shortcut 'key code 36 using {control down, option down}' "$move_to_second_monitor" # ⌃⌥↩ (Return key for Maximize)
        ;;
    "dual_split")
        if [ "$pos" -eq 1 ]; then
            execute_shortcut 'key code 123 using {control down, option down}' "$move_to_second_monitor" # ⌃⌥← Left half
        else
            execute_shortcut 'key code 124 using {control down, option down}' "$move_to_second_monitor" # ⌃⌥→ Right half
        fi
        ;;
    "triple_mixed")
        if [ "$pos" -eq 1 ]; then
            execute_shortcut 'key code 123 using {control down, option down}' "$move_to_second_monitor" # ⌃⌥← Left half
        elif [ "$pos" -eq 2 ]; then
            execute_shortcut 'key code 34 using {control down, option down}' "$move_to_second_monitor" # ⌃⌥I Top right quarter
        else
            execute_shortcut 'key code 40 using {control down, option down}' "$move_to_second_monitor" # ⌃⌥K Bottom right quarter
        fi
        ;;
    "quad_quarters_second_monitor")
        local shortcuts=('key code 32' 'key code 34' 'key code 38' 'key code 40') # U, I, J, K key codes
        execute_shortcut "${shortcuts[$((pos - 1))]} using {control down, option down}" "$move_to_second_monitor"
        ;;
    "multi_quarters_both_monitors")
        local shortcuts=('key code 32' 'key code 34' 'key code 38' 'key code 40') # U, I, J, K key codes
        local quarter_pos=$(((pos - 1) % 4 + 1))
        execute_shortcut "${shortcuts[$((quarter_pos - 1))]} using {control down, option down}" "$move_to_second_monitor"
        ;;
    *)
        echo "❌ Unknown layout strategy: $strategy"
        return 1
        ;;
    esac
}

main() {
    if ! check_rectangle_running; then
        echo "⚠️  Skipping - Rectangle not available"
        return 1
    fi

    if ! check_cursor_running; then
        echo "⚠️  Skipping - Cursor not available"
        return 1
    fi

    if position_window "$WINDOW_POSITION" "$TOTAL_WINDOWS" "$LAYOUT_STRATEGY"; then
        echo "✅ Window positioned successfully"
    else
        echo "❌ Failed to position window"
        return 1
    fi
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main
fi
