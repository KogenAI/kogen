# Optimum Codegen
# Usage: make [command]

SCRIPT_DIR := $(shell dirname $(realpath $(firstword $(MAKEFILE_LIST))))

# Helper functions for command restrictions
define check_ocg_only
	@if [ "$$OCG_CLI" != "true" ]; then \
		echo "❌ The $(1) command only works with 'ocg $(1)'"; \
		echo "   Please use 'ocg $(1)' instead of 'make $(1)'"; \
		exit 1; \
	fi
endef

define check_make_only
	@if [ "$$OCG_CLI" = "true" ]; then \
		echo "❌ The $(1) command only works with 'make $(1)'"; \
		echo "   Please use 'make $(1)' instead of 'ocg $(1)'"; \
		exit 1; \
	fi
endef

init:
	$(call check_ocg_only,init)
	@cd "$(ORIGINAL_WORKING_DIR)" && "$(SCRIPT_DIR)/init_project.sh" $(filter-out $@,$(MAKECMDGOALS))

setup:
	$(call check_ocg_only,setup)
	@cd "$(ORIGINAL_WORKING_DIR)" && "$(SCRIPT_DIR)/setup_project.sh"

new:
	$(call check_ocg_only,new)
	@if [ -z "$(filter-out $@,$(MAKECMDGOALS))" ]; then \
		. ./utils.sh; \
		echo "Usage: $$OCG_CMD new <feature-name> [options]"; \
		echo "Options:"; \
		echo "  --model, -m <model>      AI model to use (default: sonnet)"; \
		echo "  --agent, -a <name>   AI agent to use (default: from config)"; \
		echo "  --container              Run in Docker container"; \
		echo ""; \
		echo "Examples:"; \
		echo "  $$OCG_CMD new dashboard-redesign"; \
		echo "  $$OCG_CMD new dashboard-redesign --model opus"; \
		echo "  $$OCG_CMD new dashboard-redesign --agent opencode"; \
		echo "  $$OCG_CMD new dashboard-redesign -m opus -a opencode --container"; \
		exit 1; \
	fi
	@args="$(filter-out $@,$(MAKECMDGOALS))"; \
	if echo "$$args" | grep -q -- "--container"; then \
		clean_args=$$(echo "$$args" | sed 's/--container//g' | xargs); \
		./create_workspace.sh $$clean_args --container; \
	else \
		./create_workspace.sh $$args; \
	fi

clean:
	$(call check_ocg_only,clean)
	@echo "🧹 Removing all feature workspaces..."
	@cd "$(ORIGINAL_WORKING_DIR)"; \
	WORKSPACES=$$("$(SCRIPT_DIR)/list_workspaces.sh" 2>/dev/null | grep "^📁" | grep -v "Main Repository" | sed 's/^📁 //'); \
	if [ -z "$$WORKSPACES" ]; then \
		echo "ℹ️  No feature workspaces found to remove"; \
	else \
		echo "📋 Found workspaces to remove:"; \
		echo "$$WORKSPACES" | sed 's/^/      - /'; \
		echo "⚠️  This will remove ALL feature workspaces. Continue? [y/N]"; \
		read -r confirm; \
		if [ "$$confirm" != "y" ] && [ "$$confirm" != "Y" ]; then \
			echo "❌ Operation cancelled"; \
			exit 1; \
		fi; \
		echo ""; \
		. "$(SCRIPT_DIR)/config.sh"; \
		for workspace in $$WORKSPACES; do \
			WORKSPACE_PATH="$$TARGET_REPO_PATH/codegen/workspaces/$$workspace"; \
			"$(SCRIPT_DIR)/cleanup_servers.sh" "$$WORKSPACE_PATH" --quiet; \
			echo "🗑️  Removing workspace: $$workspace"; \
			$(MAKE) rm "$$workspace" || echo "⚠️  Failed to remove workspace: $$workspace"; \
		done; \
		echo "✅ Finished removing all workspaces"; \
	fi; \
	echo ""; \
	echo "💡 Tip: Feature branches are preserved by default"; \
	. "$(SCRIPT_DIR)/utils.sh"; \
	echo "   To also remove orphaned feature branches, run: $$OCG_CMD clean-branches"

clean-branches:
	$(call check_ocg_only,clean-branches)
	@cd "$(ORIGINAL_WORKING_DIR)" && "$(SCRIPT_DIR)/clean_branches.sh"

prepare:
	$(call check_ocg_only,prepare)
	@cd "$(ORIGINAL_WORKING_DIR)" && "$(SCRIPT_DIR)/prepare_environment.sh" $(filter-out $@,$(MAKECMDGOALS))

extract-figma-screenshots:
	$(call check_ocg_only,extract-figma-screenshots)
	@cd "$(ORIGINAL_WORKING_DIR)" && "$(SCRIPT_DIR)/extract_figma_screenshots.sh" $(filter-out $@,$(MAKECMDGOALS))

extract-figma-metadata:
	$(call check_ocg_only,extract-figma-metadata)
	@cd "$(ORIGINAL_WORKING_DIR)" && "$(SCRIPT_DIR)/extract_figma_metadata.sh" $(filter-out $@,$(MAKECMDGOALS))

extract-figma-variables:
	$(call check_ocg_only,extract-figma-variables)
	@cd "$(ORIGINAL_WORKING_DIR)" && "$(SCRIPT_DIR)/extract_figma_variables.sh" $(filter-out $@,$(MAKECMDGOALS))

extract-figma-implementation-specs:
	$(call check_ocg_only,extract-figma-implementation-specs)
	@cd "$(ORIGINAL_WORKING_DIR)" && "$(SCRIPT_DIR)/extract_figma_implementation_specs.sh" $(filter-out $@,$(MAKECMDGOALS))

clean-servers:
	$(call check_ocg_only,clean-servers)
	@cd "$(ORIGINAL_WORKING_DIR)"; \
	case "$$MAKEFLAGS" in \
		*s*|*--silent*|*--quiet*) QUIET=true ;; \
		*) QUIET=false ;; \
	esac; \
	if [ "$$QUIET" = "false" ]; then \
		echo "🧹 Cleaning up servers for all workspaces..."; \
	fi; \
	. "$(SCRIPT_DIR)/config.sh"; \
	WORKSPACES=$$("$(SCRIPT_DIR)/list_workspaces.sh" 2>/dev/null | grep "^📁" | grep -v "Main Repository" | sed 's/^📁 //'); \
	if [ -z "$$WORKSPACES" ]; then \
		if [ "$$QUIET" = "false" ]; then \
			echo "ℹ️  No workspaces found"; \
		fi; \
	else \
		for workspace in $$WORKSPACES; do \
			WORKSPACE_PATH="$$TARGET_REPO_PATH/codegen/workspaces/$$workspace"; \
			"$(SCRIPT_DIR)/cleanup_servers.sh" "$$WORKSPACE_PATH" --quiet; \
		done; \
		if [ "$$QUIET" = "false" ]; then \
			echo "✅ Server cleanup complete"; \
		fi; \
	fi

rm:
	$(call check_ocg_only,rm)
	@if [ -z "$(filter-out $@,$(MAKECMDGOALS))" ]; then \
		. ./utils.sh; \
		echo "Usage: $$OCG_CMD rm <feature-name>"; \
		echo "Example: $$OCG_CMD rm dashboard-redesign"; \
		exit 1; \
	fi
	@cd "$(ORIGINAL_WORKING_DIR)"; \
	. "$(SCRIPT_DIR)/config.sh"; \
	WORKSPACE_PATH="$$TARGET_REPO_PATH/codegen/workspaces/$(filter-out $@,$(MAKECMDGOALS))"; \
	if [ -d "$$WORKSPACE_PATH" ]; then \
		"$(SCRIPT_DIR)/cleanup_servers.sh" "$$WORKSPACE_PATH" --quiet; \
	fi; \
	"$(SCRIPT_DIR)/remove_workspace.sh" $(filter-out $@,$(MAKECMDGOALS))

resume:
	$(call check_ocg_only,resume)
	@if [ -z "$(filter-out $@,$(MAKECMDGOALS))" ]; then \
		. ./utils.sh; \
		echo "Usage: $$OCG_CMD resume <feature-name> [options]"; \
		echo "Options:"; \
		echo "  --model, -m <model>      AI model to use (default: from workspace)"; \
		echo "  --agent, -a <name>   AI agent to use (default: from workspace)"; \
		echo "  --container              Run in Docker container"; \
		echo ""; \
		echo "Examples:"; \
		echo "  $$OCG_CMD resume dashboard-redesign"; \
		echo "  $$OCG_CMD resume dashboard-redesign --model opus"; \
		echo "  $$OCG_CMD resume dashboard-redesign --agent opencode"; \
		echo "  $$OCG_CMD resume dashboard-redesign -m opus -a opencode --container"; \
		exit 1; \
	fi
	@args="$(filter-out $@,$(MAKECMDGOALS))"; \
	if echo "$$args" | grep -q -- "--container"; then \
		clean_args=$$(echo "$$args" | sed 's/--container//g' | xargs); \
		./resume_workspace.sh $$clean_args --container; \
	else \
		./resume_workspace.sh $$args; \
	fi

update-context:
	$(call check_ocg_only,update-context)
	@if [ -z "$(filter-out $@,$(MAKECMDGOALS))" ]; then \
		. ./utils.sh; \
		echo "Usage: $$OCG_CMD update-context <feature-name>"; \
		echo "Example: $$OCG_CMD update-context dashboard-redesign"; \
		exit 1; \
	fi
	@./update_context.sh $(filter-out $@,$(MAKECMDGOALS))

consolidate-context:
	$(call check_ocg_only,consolidate-context)
	@./consolidate_context.sh

ls:
	$(call check_ocg_only,ls)
	@./list_workspaces.sh

resources:
	$(call check_ocg_only,resources)
	@./show_global_resources.sh $(filter-out $@,$(MAKECMDGOALS))

bird-eye:
	$(call check_ocg_only,bird-eye)
	@./modes/bird_eye_session.sh $(filter-out $@,$(MAKECMDGOALS))

plan:
	$(call check_ocg_only,plan)
	@./modes/plan_session.sh $(filter-out $@,$(MAKECMDGOALS))

install:
	$(call check_make_only,install)
	@./install.sh

uninstall:
	$(call check_ocg_only,uninstall)
	@./uninstall.sh

update:
	$(call check_ocg_only,update)
	@./update_ai_tools.sh

format:
	$(call check_make_only,format)
	@echo "🎨 Formatting all files..."
	@if ! command -v mise >/dev/null 2>&1; then \
		echo "❌ mise not found. Please install mise first."; \
		echo "   curl https://mise.run | sh"; \
		exit 1; \
	fi
	@if ! command -v shfmt >/dev/null 2>&1; then \
		echo "❌ shfmt not found. Installing with mise..."; \
		mise install shfmt; \
		hash -r 2>/dev/null || true; \
	fi
	@if ! command -v npx >/dev/null 2>&1; then \
		echo "❌ npx not found. Installing Node.js with mise..."; \
		mise install node; \
		hash -r 2>/dev/null || true; \
	fi
	@shfmt -w -i 4 .
	@npx prettier -w --log-level error .
	@echo "✅ All files formatted"

remove-comments:
	$(call check_ocg_only,remove-comments)
	@if [ -z "$(ORIGINAL_WORKING_DIR)" ]; then \
		./remove_comments.sh $(filter-out $@,$(MAKECMDGOALS)); \
	else \
		cd "$(ORIGINAL_WORKING_DIR)" && "$(SCRIPT_DIR)/remove_comments.sh" $(filter-out $@,$(MAKECMDGOALS)); \
	fi

ai-config:
	$(call check_ocg_only,ai-config)
	@if [ -z "$(filter-out $@,$(MAKECMDGOALS))" ]; then \
		echo "Usage: ocg ai-config <action> [options]"; \
		echo "Actions:"; \
		echo "  set default <agent>      Set default AI agent (claude|opencode|cursor)"; \
		echo "  get default              Show current default agent"; \
		echo "  status                   Show full configuration"; \
		echo ""; \
		echo "Examples:"; \
		echo "  ocg ai-config set default opencode"; \
		echo "  ocg ai-config get default"; \
		echo "  ocg ai-config status"; \
		exit 1; \
	fi
	@./ai_config.sh $(filter-out $@,$(MAKECMDGOALS))

usage-rules:
	$(call check_ocg_only,usage-rules)
	@./usage_rules.sh $(filter-out $@,$(MAKECMDGOALS))


help:
	@echo "🚀 Optimum Codegen"
	@echo "================="
	@echo ""
	@. ./utils.sh; \
	if [ "$$OCG_CLI" = "true" ]; then \
		echo "🚀 Project Initialization:"; \
		echo "  $$OCG_CMD init <name> [options]       🎯 Create new Phoenix/Ash project with OCG"; \
		echo ""; \
		echo "🚀 Project Management:"; \
		echo "  $$OCG_CMD setup                       🚀 Initialize codegen in existing project (requires OCG_CONTEXT_DIR environment variable)"; \
		echo "  $$OCG_CMD prepare                     🔧 Install Elixir/Erlang versions from .tool-versions (native mode)"; \
		echo "  $$OCG_CMD update-context <name>       🔄 Update project context, extract recipes & rules, update Figma files"; \
		echo "  $$OCG_CMD consolidate-context         📋 Consolidate PROJECT_CONTEXT.md by removing redundancies"; \
		echo ""; \
		echo "📋 Planning Sessions:"; \
		echo "  $$OCG_CMD bird-eye [name] [model]     🦅 Start bird-eye planning session (default model: opus)"; \
		echo "  $$OCG_CMD plan [name] [model]         📝 Start detailed planning session (default model: opus)"; \
		echo ""; \
		echo "🎨 Workspaces:"; \
		echo "  $$OCG_CMD prepare --container         📦 Build Docker image and prepare base volumes"; \
		echo "  $$OCG_CMD new <name> [options]        🎨 Create new feature workspace"; \
		echo "  $$OCG_CMD new <name> --container      🐳 Create workspace in Docker container"; \
		echo "  $$OCG_CMD rm <name>                   🗑️  Remove feature workspace"; \
		echo "  $$OCG_CMD clean                       🧹 Remove ALL feature workspaces (with confirmation)"; \
		echo "  $$OCG_CMD clean-branches              🌿 Remove all orphaned feature branches (with confirmation)"; \
		echo "  $$OCG_CMD clean-servers               🔧 Kill servers for all workspace ports"; \
		echo "  $$OCG_CMD resume <name> [options]     🔄 Resume feature workspace"; \
		echo "  $$OCG_CMD resume <name> --container   🐳 Resume workspace in Docker container"; \
		echo "  $$OCG_CMD ls                          📋 List all feature workspaces"; \
		echo "  $$OCG_CMD resources [--cleanup-orphaned] 🌐 Show global resource allocation"; \
		echo ""; \
		echo "🧹 Code Maintenance:"; \
		echo "  $$OCG_CMD remove-comments             🗑️  Remove comments from git diff changes"; \
		echo "  $$OCG_CMD usage-rules                 📚 Generate usage rules for Elixir dependencies from mix.exs"; \
		echo ""; \
		echo "🗑️  Uninstallation:"; \
		echo "  $$OCG_CMD uninstall                   🗑️  Remove global CLI installation"; \
		echo ""; \
		echo "🔄 Updates:"; \
		echo "  $$OCG_CMD update                      🔄 Update all AI agents (Claude Code, OpenCode, Cursor CLI)"; \
		echo ""; \
		echo "🤖 AI Agent Configuration:"; \
		echo "  $$OCG_CMD ai-config set default       🔧 Set default AI agent (claude|opencode|cursor)"; \
		echo "  $$OCG_CMD ai-config status            📊 Show AI agent configuration"; \
		echo ""; \
		echo "📋 Recommended Workflow:"; \
		echo "  1. Run: $$OCG_CMD setup (one-time project initialization)"; \
		echo "  2. Run: $$OCG_CMD prepare [--container] (install Elixir/Erlang or build Docker image)"; \
		echo "  3. Plan: $$OCG_CMD bird-eye <name> (high-level planning)"; \
		echo "  4. Plan: $$OCG_CMD plan <name> (detailed technical planning)"; \
		echo "  5. Implement: $$OCG_CMD new <name> (create workspace and start development)"; \
		echo "  6. Work on your feature in the workspace"; \
		echo "  7. Finish: $$OCG_CMD rm <name> (archives feature context to codegen/contexts/)"; \
		echo "  8. Learn: $$OCG_CMD update-context <name> (update PROJECT_CONTEXT.md + extract recipes & rules + update Figma files)"; \
		echo "  9. Cleanup: $$OCG_CMD clean-branches to remove orphaned feature branches when done"; \
	else \
		echo "📦 Available Commands:"; \
		echo "  make install    📦 Install CLI globally (enables 'ocg' commands)"; \
		echo "  make format     🎨 Format all shell scripts and files"; \
		echo ""; \
		echo "💡 Install globally with 'make install' to use 'ocg' commands from anywhere!"; \
		echo "   After installation, run 'ocg' to see all workspace management features"; \
		echo ""; \
		echo "⚠️  Note: Commands like 'status' and 'resources' are only available via 'ocg'"; \
		echo "   from your project repositories, not from this codegen repository."; \
	fi

# Default target shows help
.DEFAULT_GOAL := help

# Prevent make from treating arguments as targets
%:
	@:
