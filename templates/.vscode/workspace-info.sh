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
    
    # Extract users from seeds.exs if available
    if [ -f "priv/repo/seeds.exs" ]; then
        local users_found=$(grep -E "email:.*@" priv/repo/seeds.exs | head -5)
        if [ -n "$users_found" ]; then
            echo ""
            echo -e "${BOLD}${CYAN}SEED USERS${NC}"
            
            # Extract email and password pairs from anywhere in seeds
            grep -E "(email:|password:)" priv/repo/seeds.exs | \
            sed 's/.*email: *"\([^"]*\)".*/📧 \1/' | \
            sed 's/.*password: *"\([^"]*\)".*/🔑 \1/' | \
            grep -E "(📧|🔑)" | \
            paste - - | \
            sed 's/\t/ | /g' | \
            head -5
        fi
    fi
}

# Auto-refresh loop (like Phoenix logs)
while true; do
    show_workspace_info
    sleep 3
done
