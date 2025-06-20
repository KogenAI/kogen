#!/bin/bash

# Start bird-eye planning session
# Usage: bird_eye_session.sh [feature_name] [model]

set -e

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Start planning session with bird-eye mode
exec "$SCRIPT_DIR/start_planning_session.sh" "bird-eye" "$1" "$2"