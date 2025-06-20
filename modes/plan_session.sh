#!/bin/bash

# Start detailed planning session
# Usage: plan_session.sh [feature_name] [model]

set -e

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Start planning session with detailed-planning mode
exec "$SCRIPT_DIR/start_planning_session.sh" "detailed-planning" "$1" "$2"
