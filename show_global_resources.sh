#!/bin/bash

# Show Global Resources Script
# Displays global resource allocation across all OCG projects

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/resource_manager.sh"

# Parse command line arguments for different modes
CLEANUP_ORPHANED=false

while [[ $# -gt 0 ]]; do
    case $1 in
    --cleanup-orphaned | --orphaned)
        CLEANUP_ORPHANED=true
        shift
        ;;
    --help | -h)
        echo "Usage: $0 [options]"
        echo ""
        echo "Options:"
        echo "  --cleanup-orphaned    Clean up orphaned resources"
        echo "  --help, -h           Show this help message"
        echo ""
        echo "Examples:"
        echo "  $0                   Show all global resources"
        echo "  $0 --cleanup-orphaned  Clean up orphaned resources"
        exit 0
        ;;
    *)
        echo "Unknown option: $1"
        echo "Use --help for usage information"
        exit 1
        ;;
    esac
done

# Handle cleanup mode
if [ "$CLEANUP_ORPHANED" = true ]; then
    cleanup_orphaned_resources
    exit $?
fi

# Default mode: show global resources
list_global_resources
