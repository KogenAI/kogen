#!/bin/bash

# Global Resource Manager for OCG
# Manages port allocation across all OCG projects system-wide

# Global registry file path
GLOBAL_REGISTRY_FILE="$HOME/.ocg/resources.json"
GLOBAL_REGISTRY_LOCK="$HOME/.ocg/resources.lock"

# Ensure ~/.ocg directory exists
ensure_global_registry() {
    local ocg_dir="$HOME/.ocg"
    if [ ! -d "$ocg_dir" ]; then
        mkdir -p "$ocg_dir"
    fi

    # Create registry if it doesn't exist
    if [ ! -f "$GLOBAL_REGISTRY_FILE" ]; then
        cat >"$GLOBAL_REGISTRY_FILE" <<'EOF'
{
  "phoenix_ports": {},
  "playwright_ports": {},
  "metadata": {
    "last_updated": ""
  }
}
EOF
    fi

    # Validate registry JSON structure
    if ! jq . "$GLOBAL_REGISTRY_FILE" >/dev/null 2>&1; then
        echo "⚠️  Warning: Global registry corrupted, recreating..." >&2
        # Backup corrupted file
        if [ -f "$GLOBAL_REGISTRY_FILE" ]; then
            cp "$GLOBAL_REGISTRY_FILE" "${GLOBAL_REGISTRY_FILE}.backup.$(date +%s)"
        fi
        # Recreate clean registry
        cat >"$GLOBAL_REGISTRY_FILE" <<'EOF'
{
  "phoenix_ports": {},
  "playwright_ports": {},
  "metadata": {
    "last_updated": ""
  }
}
EOF
    fi
}

# Acquire file lock for atomic operations
acquire_lock() {
    local timeout=10
    local count=0

    while [ $count -lt $timeout ]; do
        if mkdir "$GLOBAL_REGISTRY_LOCK" 2>/dev/null; then
            return 0
        fi
        sleep 0.1
        ((count++))
    done

    echo "❌ Error: Could not acquire registry lock after ${timeout}s" >&2
    return 1
}

# Release file lock
release_lock() {
    rmdir "$GLOBAL_REGISTRY_LOCK" 2>/dev/null || true
}

# Update the metadata timestamp
update_timestamp() {
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    jq ".metadata.last_updated = \"$timestamp\"" "$GLOBAL_REGISTRY_FILE" >"${GLOBAL_REGISTRY_FILE}.tmp" &&
        mv "${GLOBAL_REGISTRY_FILE}.tmp" "$GLOBAL_REGISTRY_FILE"
}

# Check if a port is already allocated globally
is_port_allocated() {
    local port="$1"
    local port_type="$2" # phoenix_ports or playwright_ports

    ensure_global_registry

    if jq -e ".${port_type}.\"${port}\"" "$GLOBAL_REGISTRY_FILE" >/dev/null 2>&1; then
        return 0 # Port is allocated
    else
        return 1 # Port is not allocated
    fi
}

# Check if port is in use by system (not just OCG)
is_port_in_use() {
    local port="$1"
    lsof -i ":$port" >/dev/null 2>&1
}

# Allocate a Phoenix port for a project/workspace
allocate_phoenix_port() {
    local project="$1"
    local workspace="$2"

    if [ -z "$project" ] || [ -z "$workspace" ]; then
        echo "❌ Error: Project and workspace name required" >&2
        return 1
    fi

    ensure_global_registry

    if ! acquire_lock; then
        return 1
    fi

    # Find next available port starting from 4001
    local base_port=4001
    local current_port=$base_port
    local max_port=4100

    while [ $current_port -le $max_port ]; do
        if ! is_port_allocated "$current_port" "phoenix_ports" && ! is_port_in_use "$current_port"; then
            # Allocate the port
            local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
            jq ".phoenix_ports.\"${current_port}\" = {\"project\": \"$project\", \"workspace\": \"$workspace\", \"allocated_at\": \"$timestamp\"}" \
                "$GLOBAL_REGISTRY_FILE" >"${GLOBAL_REGISTRY_FILE}.tmp" &&
                mv "${GLOBAL_REGISTRY_FILE}.tmp" "$GLOBAL_REGISTRY_FILE"

            update_timestamp
            release_lock
            echo "$current_port"
            return 0
        fi
        ((current_port++))
    done

    release_lock
    echo "❌ Error: Could not find available Phoenix port (checked up to $max_port)" >&2
    return 1
}

# Allocate a Playwright port for a project/workspace
allocate_playwright_port() {
    local project="$1"
    local workspace="$2"

    if [ -z "$project" ] || [ -z "$workspace" ]; then
        echo "❌ Error: Project and workspace name required" >&2
        return 1
    fi

    ensure_global_registry

    if ! acquire_lock; then
        return 1
    fi

    # Find next available port starting from 8901
    local base_port=8901
    local current_port=$base_port
    local max_port=9000

    while [ $current_port -le $max_port ]; do
        if ! is_port_allocated "$current_port" "playwright_ports" && ! is_port_in_use "$current_port"; then
            # Allocate the port
            local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
            jq ".playwright_ports.\"${current_port}\" = {\"project\": \"$project\", \"workspace\": \"$workspace\", \"allocated_at\": \"$timestamp\"}" \
                "$GLOBAL_REGISTRY_FILE" >"${GLOBAL_REGISTRY_FILE}.tmp" &&
                mv "${GLOBAL_REGISTRY_FILE}.tmp" "$GLOBAL_REGISTRY_FILE"

            update_timestamp
            release_lock
            echo "$current_port"
            return 0
        fi
        ((current_port++))
    done

    release_lock
    echo "❌ Error: Could not find available Playwright port (checked up to $max_port)" >&2
    return 1
}

# Deallocate all resources for a project/workspace
deallocate_resources() {
    local project="$1"
    local workspace="$2"

    if [ -z "$project" ] || [ -z "$workspace" ]; then
        echo "❌ Error: Project and workspace name required" >&2
        return 1
    fi

    ensure_global_registry

    if ! acquire_lock; then
        return 1
    fi

    # Find and remove allocations for this project/workspace
    local phoenix_removed=0
    local playwright_removed=0

    # Remove Phoenix port allocations
    while IFS= read -r port; do
        if [ -n "$port" ]; then
            jq "del(.phoenix_ports.\"$port\")" "$GLOBAL_REGISTRY_FILE" >"${GLOBAL_REGISTRY_FILE}.tmp" &&
                mv "${GLOBAL_REGISTRY_FILE}.tmp" "$GLOBAL_REGISTRY_FILE"
            ((phoenix_removed++))
        fi
    done < <(jq -r ".phoenix_ports | to_entries[] | select(.value.project == \"$project\" and .value.workspace == \"$workspace\") | .key" "$GLOBAL_REGISTRY_FILE" 2>/dev/null || true)

    # Remove Playwright port allocations
    while IFS= read -r port; do
        if [ -n "$port" ]; then
            jq "del(.playwright_ports.\"$port\")" "$GLOBAL_REGISTRY_FILE" >"${GLOBAL_REGISTRY_FILE}.tmp" &&
                mv "${GLOBAL_REGISTRY_FILE}.tmp" "$GLOBAL_REGISTRY_FILE"
            ((playwright_removed++))
        fi
    done < <(jq -r ".playwright_ports | to_entries[] | select(.value.project == \"$project\" and .value.workspace == \"$workspace\") | .key" "$GLOBAL_REGISTRY_FILE" 2>/dev/null || true)

    if [ $phoenix_removed -gt 0 ] || [ $playwright_removed -gt 0 ]; then
        update_timestamp
        echo "✅ Deallocated $phoenix_removed Phoenix port(s) and $playwright_removed Playwright port(s) for $project/$workspace" >&2
    fi

    release_lock
    return 0
}

# List all global resources
list_global_resources() {
    ensure_global_registry

    echo "🌐 GLOBAL RESOURCE ALLOCATION"
    echo ""

    # Partition-based view
    echo "📋 Resource Partitions:"
    local phoenix_count=0
    while IFS=$'\t' read -r port project workspace allocated_at; do
        if [ -n "$port" ]; then
            local partition=$((port - 4000))
            # Calculate time since allocation
            local time_ago=""
            if command -v date >/dev/null 2>&1 && [ -n "$allocated_at" ]; then
                if [[ "$OSTYPE" == "darwin"* ]]; then
                    # macOS date command
                    local allocated_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$allocated_at" "+%s" 2>/dev/null || echo "")
                else
                    # Linux date command
                    local allocated_epoch=$(date -d "$allocated_at" "+%s" 2>/dev/null || echo "")
                fi
                if [ -n "$allocated_epoch" ]; then
                    local current_epoch=$(date "+%s")
                    local diff=$((current_epoch - allocated_epoch))
                    if [ $diff -lt 3600 ]; then
                        time_ago="$(($diff / 60))m ago"
                    elif [ $diff -lt 86400 ]; then
                        time_ago="$(($diff / 3600))h ago"
                    else
                        time_ago="$(($diff / 86400))d ago"
                    fi
                fi
            fi
            echo "  $partition → $project/$workspace${time_ago:+ (allocated $time_ago)}"
            ((phoenix_count++))
        fi
    done < <(jq -r '.phoenix_ports | to_entries[] | "\(.key)\t\(.value.project)\t\(.value.workspace)\t\(.value.allocated_at)"' "$GLOBAL_REGISTRY_FILE" 2>/dev/null | sort -n)

    if [ $phoenix_count -eq 0 ]; then
        echo "  (none allocated)"
    fi

    echo ""

    # Summary
    echo "📊 Resource Summary:"
    echo "  📋 Partitions: $phoenix_count/100 allocated (1-100)"

    # List unique projects
    local projects=$(jq -r '.phoenix_ports, .playwright_ports | to_entries[].value.project' "$GLOBAL_REGISTRY_FILE" 2>/dev/null | sort -u | tr '\n' ', ' | sed 's/,$//')
    if [ -n "$projects" ]; then
        echo "  Projects: $projects"
    else
        echo "  Projects: (none)"
    fi
    echo ""
    echo "💡 Each partition provides: Phoenix (400X), Test (410X), Playwright (890X), Databases (_dev_X, _test_X)"
}

# Cleanup orphaned resources (where workspace directories no longer exist)
cleanup_orphaned_resources() {
    ensure_global_registry

    if ! acquire_lock; then
        return 1
    fi

    local phoenix_cleaned=0
    local playwright_cleaned=0

    echo "🧹 Checking for orphaned resources..."

    # Check Phoenix port allocations
    while IFS=$'\t' read -r port project workspace; do
        if [ -n "$port" ] && [ -n "$project" ] && [ -n "$workspace" ]; then
            # Try to find a workspace directory for this allocation
            # Look in common OCG workspace locations
            local found_workspace=false

            # Check current project if it matches
            if [ -n "$TARGET_REPO_PATH" ]; then
                local current_project=$(basename "$TARGET_REPO_PATH")
                if [ "$project" = "$current_project" ]; then
                    if [ -d "$TARGET_REPO_PATH/codegen/workspaces/$workspace" ]; then
                        found_workspace=true
                    fi
                fi
            fi

            # If workspace not found, mark for cleanup
            if [ "$found_workspace" = false ]; then
                echo "  Removing orphaned Phoenix port $port for $project/$workspace"
                jq "del(.phoenix_ports.\"$port\")" "$GLOBAL_REGISTRY_FILE" >"${GLOBAL_REGISTRY_FILE}.tmp" &&
                    mv "${GLOBAL_REGISTRY_FILE}.tmp" "$GLOBAL_REGISTRY_FILE"
                ((phoenix_cleaned++))
            fi
        fi
    done < <(jq -r '.phoenix_ports | to_entries[] | "\(.key)\t\(.value.project)\t\(.value.workspace)"' "$GLOBAL_REGISTRY_FILE" 2>/dev/null)

    # Check Playwright port allocations
    while IFS=$'\t' read -r port project workspace; do
        if [ -n "$port" ] && [ -n "$project" ] && [ -n "$workspace" ]; then
            # Try to find a workspace directory for this allocation
            local found_workspace=false

            # Check current project if it matches
            if [ -n "$TARGET_REPO_PATH" ]; then
                local current_project=$(basename "$TARGET_REPO_PATH")
                if [ "$project" = "$current_project" ]; then
                    if [ -d "$TARGET_REPO_PATH/codegen/workspaces/$workspace" ]; then
                        found_workspace=true
                    fi
                fi
            fi

            # If workspace not found, mark for cleanup
            if [ "$found_workspace" = false ]; then
                echo "  Removing orphaned Playwright port $port for $project/$workspace"
                jq "del(.playwright_ports.\"$port\")" "$GLOBAL_REGISTRY_FILE" >"${GLOBAL_REGISTRY_FILE}.tmp" &&
                    mv "${GLOBAL_REGISTRY_FILE}.tmp" "$GLOBAL_REGISTRY_FILE"
                ((playwright_cleaned++))
            fi
        fi
    done < <(jq -r '.playwright_ports | to_entries[] | "\(.key)\t\(.value.project)\t\(.value.workspace)"' "$GLOBAL_REGISTRY_FILE" 2>/dev/null)

    if [ $phoenix_cleaned -gt 0 ] || [ $playwright_cleaned -gt 0 ]; then
        update_timestamp
        echo "✅ Cleaned up $phoenix_cleaned Phoenix port(s) and $playwright_cleaned Playwright port(s)"
    else
        echo "✅ No orphaned resources found"
    fi

    release_lock
    return 0
}

# Fallback to local port scanning if global registry fails
fallback_get_next_phoenix_port() {
    local base_port=4001
    local current_port=$base_port

    echo "⚠️  Using fallback port scanning..." >&2

    while true; do
        local port_in_use=false

        # Check if port is in use by system
        if lsof -i ":$current_port" >/dev/null 2>&1; then
            port_in_use=true
        fi

        # Check local workspace directories if TARGET_REPO_PATH is set
        if [ -n "$TARGET_REPO_PATH" ] && [ ! "$port_in_use" = true ]; then
            for workspace_dir in "$TARGET_REPO_PATH"/codegen/workspaces/*; do
                if [ -d "$workspace_dir" ] && [ -f "$workspace_dir/.env" ]; then
                    if grep -q "^PORT=$current_port" "$workspace_dir/.env" 2>/dev/null; then
                        port_in_use=true
                        break
                    fi
                fi
            done
        fi

        if [ ! "$port_in_use" = true ]; then
            echo "$current_port"
            return 0
        fi

        ((current_port++))

        if [ $current_port -gt 4100 ]; then
            echo "❌ Error: Could not find available port (checked up to 4100)" >&2
            return 1
        fi
    done
}
