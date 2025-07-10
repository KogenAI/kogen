# Optimum Codegen
# Usage: make [command]

SCRIPT_DIR := $(shell dirname $(realpath $(firstword $(MAKEFILE_LIST))))

setup:
	@cd "$(ORIGINAL_WORKING_DIR)" && "$(SCRIPT_DIR)/setup_project.sh"

new:
	@if [ -z "$(filter-out $@,$(MAKECMDGOALS))" ]; then \
		. ./utils.sh; \
		echo "Usage: $$OCG_CMD new <feature-name> [options]"; \
		echo "Options:"; \
		echo "  --model, -m <model>      AI model to use (default: sonnet)"; \
		echo "  --assistant, -a <name>   AI assistant to use (default: from config)"; \
		echo "  --container              Run in Docker container"; \
		echo ""; \
		echo "Examples:"; \
		echo "  $$OCG_CMD new dashboard-redesign"; \
		echo "  $$OCG_CMD new dashboard-redesign --model opus"; \
		echo "  $$OCG_CMD new dashboard-redesign --assistant opencode"; \
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
	@cd "$(ORIGINAL_WORKING_DIR)" && "$(SCRIPT_DIR)/clean_branches.sh"

prepare:
	@cd "$(ORIGINAL_WORKING_DIR)" && "$(SCRIPT_DIR)/prepare_environment.sh" $(filter-out $@,$(MAKECMDGOALS))

clean-servers:
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
	@if [ -z "$(filter-out $@,$(MAKECMDGOALS))" ]; then \
		. ./utils.sh; \
		echo "Usage: $$OCG_CMD resume <feature-name> [options]"; \
		echo "Options:"; \
		echo "  --model, -m <model>      AI model to use (default: from workspace)"; \
		echo "  --assistant, -a <name>   AI assistant to use (default: from workspace)"; \
		echo "  --container              Run in Docker container"; \
		echo ""; \
		echo "Examples:"; \
		echo "  $$OCG_CMD resume dashboard-redesign"; \
		echo "  $$OCG_CMD resume dashboard-redesign --model opus"; \
		echo "  $$OCG_CMD resume dashboard-redesign --assistant opencode"; \
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
	@if [ -z "$(filter-out $@,$(MAKECMDGOALS))" ]; then \
		. ./utils.sh; \
		echo "Usage: $$OCG_CMD update-context <feature-name>"; \
		echo "Example: $$OCG_CMD update-context dashboard-redesign"; \
		exit 1; \
	fi
	@./update_context.sh $(filter-out $@,$(MAKECMDGOALS))

consolidate-context:
	@./consolidate_context.sh

ls:
	@./list_workspaces.sh

bird-eye:
	@./modes/bird_eye_session.sh $(filter-out $@,$(MAKECMDGOALS))

plan:
	@./modes/plan_session.sh $(filter-out $@,$(MAKECMDGOALS))

install:
	@./install.sh

uninstall:
	@./uninstall.sh

format:
	@echo "🎨 Formatting all files..."
	@shfmt -w -i 4 .
	@npx prettier -w --log-level error .
	@echo "✅ All files formatted"

remove-comments:
	@if [ -z "$(ORIGINAL_WORKING_DIR)" ]; then \
		./remove_comments.sh $(filter-out $@,$(MAKECMDGOALS)); \
	else \
		cd "$(ORIGINAL_WORKING_DIR)" && "$(SCRIPT_DIR)/remove_comments.sh" $(filter-out $@,$(MAKECMDGOALS)); \
	fi

ai-config:
	@if [ -z "$(filter-out $@,$(MAKECMDGOALS))" ]; then \
		echo "Usage: ocg ai-config <action> [options]"; \
		echo "Actions:"; \
		echo "  set default <assistant>  Set default AI assistant (claude|opencode)"; \
		echo "  get default              Show current default assistant"; \
		echo "  status                   Show full configuration"; \
		echo ""; \
		echo "Examples:"; \
		echo "  ocg ai-config set default opencode"; \
		echo "  ocg ai-config get default"; \
		echo "  ocg ai-config status"; \
		exit 1; \
	fi
	@./ai_config.sh $(filter-out $@,$(MAKECMDGOALS))


help:
	@echo "🚀 Optimum Codegen"
	@echo "================="
	@echo ""
	@. ./utils.sh; \
	if [ "$$OCG_CLI" = "true" ]; then \
		echo "🚀 Project Management:"; \
		echo "  $$OCG_CMD setup                       🚀 Initialize codegen in the project (requires OCG_RULES_DIR environment variable)"; \
		echo "  $$OCG_CMD prepare                     🔧 Install Elixir/Erlang versions from .tool-versions (native mode)"; \
		echo "  $$OCG_CMD update-context <name>       🔄 Update project context and extract reusable recipes"; \
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
		echo ""; \
		echo "🧹 Code Maintenance:"; \
		echo "  $$OCG_CMD remove-comments             🗑️  Remove comments from git diff changes"; \
		echo ""; \
		echo "🤖 AI Assistant Configuration:"; \
		echo "  $$OCG_CMD ai-config set default       🔧 Set default AI assistant (claude|opencode)"; \
		echo "  $$OCG_CMD ai-config status            📊 Show AI assistant configuration"; \
		echo ""; \
		echo "📋 Recommended Workflow:"; \
		echo "  1. Run: $$OCG_CMD setup (one-time project initialization)"; \
		echo "  2. Run: $$OCG_CMD prepare [--container] (install Elixir/Erlang or build Docker image)"; \
		echo "  3. Plan: $$OCG_CMD bird-eye <name> (high-level planning)"; \
		echo "  4. Plan: $$OCG_CMD plan <name> (detailed technical planning)"; \
		echo "  5. Implement: $$OCG_CMD new <name> (create workspace and start development)"; \
		echo "  6. Work on your feature in the workspace"; \
		echo "  7. Finish: $$OCG_CMD rm <name> (archives feature context to codegen/contexts/)"; \
		echo "  8. Learn: $$OCG_CMD update-context <name> (update PROJECT_CONTEXT.md + extract recipes)"; \
		echo "  9. Cleanup: $$OCG_CMD clean-branches to remove orphaned feature branches when done"; \
	else \
		echo "📦 Available Commands:"; \
		echo "  make install    📦 Install CLI globally (enables 'ocg' commands)"; \
		echo "  make format     🎨 Format all shell scripts and files"; \
		echo ""; \
		echo "💡 Install globally with 'make install' to use 'ocg' commands from anywhere!"; \
		echo "   After installation, run 'ocg' to see all workspace management features"; \
	fi

# Default target shows help
.DEFAULT_GOAL := help

# Prevent make from treating arguments as targets
%:
	@:
