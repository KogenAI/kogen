# CLAUDE.md

This file provides guidance to Claude Code when working in this feature workspace.

## Implementation Mode Instructions

When working in this workspace:
1. Implement the plan in codegen/PLAN.md
2. Use context from codegen/CONTEXT.md and codegen/PROJECT_CONTEXT.md
3. Track your current stage in codegen/CONTEXT.md
4. Follow the staged development workflow

## Workspace Configuration
- Feature: {{FEATURE_NAME}}
- Branch: feature/{{FEATURE_NAME}}
- Phoenix Port: {{PORT}}
- Playwright MCP Port: {{PLAYWRIGHT_MCP_PORT}}
- Database Partition: {{PARTITION}}

## Available Commands
- `/project:implement` - Re-invoke implementation mode instructions

## Server Management
Claude Code can start/stop servers as needed:
- `mix phx.server` - Start Phoenix server on port {{PORT}}
- `lsof -ti tcp:{{PORT}} | xargs kill` - Stop Phoenix server
- `npx @playwright/mcp@latest --port {{PLAYWRIGHT_MCP_PORT}} --headless &` - Start Playwright MCP

## Key Files
- `codegen/PLAN.md` - The feature implementation plan
- `codegen/CONTEXT.md` - Your working document to track progress
- `codegen/PROJECT_CONTEXT.md` - Project-wide knowledge and patterns
- `/CLAUDE.md` - Main repository guidance (parent directory)
