#!/bin/bash

# Colors for terminal output
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Helper function to get coverage information
get_coverage_info() {
    local coverage_percentage=""
    local minimum_coverage=""
    local coverage_status=""
    local coverage_color=""

    # Try to get coverage from last test run output
    if [ -f "codegen/.ci_status" ]; then
        # Look for coverage in CI output - matches pattern [TOTAL] XX.X%
        coverage_percentage=$(grep "\[TOTAL\]" "codegen/.ci_status" 2>/dev/null | tail -1 | grep -o '[0-9]\+\.[0-9]\+%' | head -1)
    fi

    # Get minimum coverage requirement from coveralls.json
    if [ -f "coveralls.json" ]; then
        minimum_coverage=$(grep -o '"minimum_coverage":[[:space:]]*[0-9]\+\.[0-9]\+' coveralls.json | grep -o '[0-9]\+\.[0-9]\+')
    fi

    if [ -n "$coverage_percentage" ] && [ -n "$minimum_coverage" ]; then
        # Extract numeric values for comparison
        current_num=$(echo "$coverage_percentage" | sed 's/%//')
        minimum_num="$minimum_coverage"

        # Compare coverage (using awk for floating point comparison)
        if awk "BEGIN {exit !($current_num >= $minimum_num)}"; then
            if awk "BEGIN {exit !($current_num > $minimum_num)}"; then
                coverage_status="🎯 ABOVE TARGET"
                coverage_color="${GREEN}"
            else
                coverage_status="✅ MEETS TARGET"
                coverage_color="${GREEN}"
            fi
        else
            coverage_status="⚠️  BELOW TARGET"
            coverage_color="${RED}"
        fi

        echo -e "${BOLD}${PURPLE}📊 Coverage:${NC} ${coverage_color}${coverage_percentage}${NC} / ${YELLOW}${minimum_coverage}%${NC} ${coverage_color}${coverage_status}${NC}"
    elif [ -n "$coverage_percentage" ]; then
        echo -e "${BOLD}${PURPLE}📊 Coverage:${NC} ${YELLOW}${coverage_percentage}${NC}"
    else
        echo -e "${BOLD}${PURPLE}📊 Coverage:${NC} ${YELLOW}Not available${NC}"
    fi
}

show_workspace_info() {
    local FEATURE_NAME="$(basename "$(pwd)")"
    local CURRENT_DIR="$(pwd)"

    # Check if we're in container mode
    local CURRENT_BRANCH
    if [ -f "docker-compose.yml" ]; then
        # Get branch from inside container
        local PROJECT_NAME="$(basename "$(cd ../../.. && pwd)")"
        local CONTAINER_NAME="ocg-${PROJECT_NAME}-${FEATURE_NAME}"
        if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
            CURRENT_BRANCH="$(docker exec "${CONTAINER_NAME}" git branch --show-current 2>/dev/null || echo "unknown")"
        else
            CURRENT_BRANCH="unknown (container not running)"
        fi
    else
        # Native mode - get branch directly
        CURRENT_BRANCH="$(git branch --show-current 2>/dev/null || echo "unknown")"
    fi

    # Read ports from .env file
    local PORT="4000"
    local DEV_PARTITION=""
    local TEST_PARTITION=""

    if [ -f ".env" ]; then
        # Use tail -1 to get last occurrence (workspace overrides template defaults)
        PORT=$(grep "^PORT=" ".env" 2>/dev/null | tail -1 | cut -d'=' -f2 || echo "4000")
        DEV_PARTITION=$(grep "^MIX_DEV_PARTITION=" ".env" 2>/dev/null | tail -1 | cut -d'=' -f2 || echo "")
        TEST_PARTITION=$(grep "^MIX_TEST_PARTITION=" ".env" 2>/dev/null | tail -1 | cut -d'=' -f2 || echo "")
    fi

    # Check server status
    local PHOENIX_STATUS="🔴 Stopped"

    # For container mode, check if services are accessible
    if [ -f "docker-compose.yml" ]; then
        # Check Phoenix by trying to connect
        if nc -z localhost $PORT 2>/dev/null; then
            PHOENIX_STATUS="🟢 Running"
        fi
    else
        # Native mode - use lsof
        if lsof -i :$PORT >/dev/null 2>&1; then
            PHOENIX_STATUS="🟢 Running"
        fi
    fi

    clear
    echo -e "${BOLD}${CYAN}WORKSPACE INFO${NC}"
    echo -e "${BOLD}${PURPLE}🎯 Feature:${NC} ${YELLOW}$FEATURE_NAME${NC}"
    echo -e "${BOLD}${PURPLE}📁 Directory:${NC} ${YELLOW}$CURRENT_DIR${NC}"
    echo -e "${BOLD}${PURPLE}🌿 Branch:${NC} ${YELLOW}$CURRENT_BRANCH${NC}"
    echo -e "${BOLD}${PURPLE}🕐 Updated:${NC} $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""

    echo -e "${BOLD}${CYAN}SERVER INFORMATION${NC}"
    echo -e "${BOLD}${GREEN}🌐 Phoenix Server${NC} $PHOENIX_STATUS"
    echo -e "   URL: ${CYAN}http://localhost:$PORT${NC}"
    echo -e "   Port: ${YELLOW}$PORT${NC}"
    echo ""

    # CI Status Section
    echo -e "${BOLD}${CYAN}CI STATUS${NC}"
    # CI status file is in codegen directory (same path pattern as Phoenix log)
    local ci_status_file="codegen/.ci_status"
    if [ -f "$ci_status_file" ]; then
        local ci_timestamp=$(head -1 "$ci_status_file")
        local overall_status=$(grep "Overall Status:" "$ci_status_file" | cut -d':' -f2 | tr -d ' ')

        if [ "$overall_status" = "PASSED" ]; then
            echo -e "${BOLD}${GREEN}🎉 Status: PASSED${NC}"
        elif [ "$overall_status" = "FAILED" ]; then
            echo -e "${BOLD}${RED}💥 Status: FAILED${NC}"
        elif [ "$overall_status" = "IN_PROGRESS" ]; then
            echo -e "${BOLD}${CYAN}🔄 Status: IN PROGRESS${NC}"
        else
            echo -e "${BOLD}${YELLOW}⚠️  Status: UNKNOWN${NC}"
        fi

        echo -e "   Last run: ${YELLOW}$ci_timestamp${NC}"

        # Add coverage information
        get_coverage_info
    else
        echo -e "${BOLD}${YELLOW}⚠️  No CI status available${NC}"
        echo -e "   Run ${CYAN}./codegen/ci.sh${NC} to check code quality"
    fi
    echo ""

    echo -e "${BOLD}${CYAN}DATABASE INFORMATION${NC}"

    # Get project name from mix.exs or use directory name as fallback
    local PROJECT_NAME
    if [ -f "mix.exs" ]; then
        PROJECT_NAME=$(grep -E "app:|:app" mix.exs | head -1 | sed 's/.*:\([a-zA-Z_][a-zA-Z0-9_]*\).*/\1/')
    fi
    if [ -z "$PROJECT_NAME" ]; then
        PROJECT_NAME=$(basename "$(pwd)" | tr '[:upper:]' '[:lower:]' | tr '-' '_')
    fi

    if [ -n "$DEV_PARTITION" ]; then
        echo -e "${BOLD}${GREEN}🗄️  Dev:${NC} ${YELLOW}${PROJECT_NAME}_dev_${DEV_PARTITION}${NC}"
    else
        echo -e "${BOLD}${GREEN}🗄️  Dev:${NC} ${YELLOW}${PROJECT_NAME}_dev${NC}"
    fi

    if [ -n "$TEST_PARTITION" ]; then
        echo -e "${BOLD}${GREEN}🧪 Test:${NC} ${YELLOW}${PROJECT_NAME}_test_${TEST_PARTITION}${NC}"
    else
        echo -e "${BOLD}${GREEN}🧪 Test:${NC} ${YELLOW}${PROJECT_NAME}_test${NC}"
    fi

}

# Auto-refresh loop (like Phoenix logs)
while true; do
    show_workspace_info
    sleep 3
done
