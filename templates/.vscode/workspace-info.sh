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

# Helper function to format check status
format_check_status() {
    local status="$1"
    case "$status" in
        "PASSED") echo -e "${GREEN}✅ PASSED${NC}" ;;
        "FAILED") echo -e "${RED}❌ FAILED${NC}" ;;
        "SKIPPED"*) echo -e "${YELLOW}⚠️  SKIPPED${NC}" ;;
        *) echo -e "${YELLOW}⚠️  UNKNOWN${NC}" ;;
    esac
}

show_workspace_info() {
    local FEATURE_NAME="$(basename "$(pwd)")"
    local CURRENT_DIR="$(pwd)"
    local CURRENT_BRANCH="$(git branch --show-current 2>/dev/null || echo "unknown")"
    
    # Read ports from .env file
    local PORT="4000"
    local PLAYWRIGHT_MCP_PORT="9222"
    local DEV_PARTITION=""
    local TEST_PARTITION=""
    
    if [ -f ".env" ]; then
        PORT=$(grep "^PORT=" ".env" 2>/dev/null | cut -d'=' -f2 || echo "4000")
        PLAYWRIGHT_MCP_PORT=$(grep "^PLAYWRIGHT_MCP_PORT=" ".env" 2>/dev/null | cut -d'=' -f2 || echo "9222")
        DEV_PARTITION=$(grep "^MIX_DEV_PARTITION=" ".env" 2>/dev/null | cut -d'=' -f2 || echo "")
        TEST_PARTITION=$(grep "^MIX_TEST_PARTITION=" ".env" 2>/dev/null | cut -d'=' -f2 || echo "")
    fi
    
    # Check server status
    local PHOENIX_STATUS="🔴 Stopped"
    local PLAYWRIGHT_STATUS="🔴 Stopped"
    
    if lsof -i :$PORT >/dev/null 2>&1; then
        PHOENIX_STATUS="🟢 Running"
    fi
    
    if lsof -i :$PLAYWRIGHT_MCP_PORT >/dev/null 2>&1; then
        PLAYWRIGHT_STATUS="🟢 Running"
    fi
    
    clear
    echo -e "${BOLD}${CYAN}WORKSPACE INFO${NC}"
    echo -e "${BOLD}${PURPLE}🎯 Feature:${NC} ${YELLOW}$FEATURE_NAME${NC}"
    echo -e "${BOLD}${PURPLE}📁 Directory:${NC} ${YELLOW}$CURRENT_DIR${NC}"
    echo -e "${BOLD}${PURPLE}🌿 Branch:${NC} ${YELLOW}$CURRENT_BRANCH${NC}"
    echo -e "${BOLD}${PURPLE}🕐 Updated:${NC} $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
    
    echo -e "${BOLD}${CYAN}SERVER INFORMATION${NC}"
    echo -e "${BOLD}${GREEN}🌐 Phoenix Server${NC}"
    echo -e "   URL: ${CYAN}http://localhost:$PORT${NC}"
    echo -e "   Port: ${YELLOW}$PORT${NC}"
    echo -e "   Status: $PHOENIX_STATUS"
    echo ""
    echo -e "${BOLD}${GREEN}🎭 Playwright MCP${NC}"
    echo -e "   Port: ${YELLOW}$PLAYWRIGHT_MCP_PORT${NC}"
    echo -e "   Status: $PLAYWRIGHT_STATUS"
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
