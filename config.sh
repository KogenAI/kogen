#!/bin/bash

# Simple configuration - use current working directory as target repository
# If ORIGINAL_WORKING_DIR is set (from ocg command), use that instead
WORK_DIR="${ORIGINAL_WORKING_DIR:-$(pwd)}"

# Save current directory to restore later
_SAVED_PWD="$(pwd)"

# Change to the working directory to get the git repository root
cd "$WORK_DIR" || {
    echo "❌ Error: cannot cd to WORK_DIR: $WORK_DIR" >&2
    exit 1
}
if ! TARGET_REPO_PATH="$(git rev-parse --show-toplevel)"; then
    echo "❌ Error: git rev-parse --show-toplevel failed in $WORK_DIR (not a git repository?)" >&2
    exit 1
fi
export TARGET_REPO_PATH

# Restore original directory
cd "$_SAVED_PWD" || {
    echo "❌ Error: cannot cd back to original directory: $_SAVED_PWD" >&2
    exit 1
}

# Database name prefix based on repository name
REPO_NAME="$(basename "$TARGET_REPO_PATH")"
export DB_NAME_PREFIX="$REPO_NAME"

# Validate we're in a git repository
if [ ! -d "$TARGET_REPO_PATH/.git" ]; then
    echo "❌ Error: Not in a git repository"
    exit 1
fi

# Docker configuration (mandatory) - use project-specific image
export DOCKER_IMAGE="${DOCKER_IMAGE:-ocg/phoenix:${REPO_NAME}}"
# DOCKER_COMPOSE_TEMPLATE will be set by the calling script
