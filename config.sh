#!/bin/bash

# Simple configuration - use current working directory as target repository
# If ORIGINAL_WORKING_DIR is set (from ocg command), use that instead
WORK_DIR="${ORIGINAL_WORKING_DIR:-$(pwd)}"

# Save current directory to restore later
_SAVED_PWD="$(pwd)"

# Change to the working directory to get the git repository root
cd "$WORK_DIR"
export TARGET_REPO_PATH="$(git rev-parse --show-toplevel)"

# Restore original directory
cd "$_SAVED_PWD"

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
