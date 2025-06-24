# Optimum Codegen
# Usage: make [command]

SCRIPT_DIR := $(shell dirname $(realpath $(firstword $(MAKEFILE_LIST))))

setup:
	@cd "$(ORIGINAL_WORKING_DIR)" && "$(SCRIPT_DIR)/setup_project.sh"

new:
	@if [ -z "$(filter-out $@,$(MAKECMDGOALS))" ]; then \
		echo "Usage: make new <feature-name>"; \
		echo "Example: make new dashboard-redesign"; \
		exit 1; \
	fi
	@./create_workspace.sh $(filter-out $@,$(MAKECMDGOALS))

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
	echo "   To also remove orphaned feature branches, run: make clean-branches"

clean-branches:
	@cd "$(ORIGINAL_WORKING_DIR)" && "$(SCRIPT_DIR)/clean_branches.sh"

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
		echo "Usage: make rm <feature-name>"; \
		echo "Example: make rm dashboard-redesign"; \
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
		echo "Usage: make resume <feature-name>"; \
		echo "Example: make resume dashboard-redesign"; \
		exit 1; \
	fi
	@./resume_workspace.sh $(filter-out $@,$(MAKECMDGOALS))

update-context:
	@if [ -z "$(filter-out $@,$(MAKECMDGOALS))" ]; then \
		echo "Usage: make update-context <feature-name>"; \
		echo "Example: make update-context dashboard-redesign"; \
		exit 1; \
	fi
	@./update_context.sh $(filter-out $@,$(MAKECMDGOALS))

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

help:
	@echo "🚀 Optimum Codegen"
	@echo "================="
	@echo ""
	@. ./utils.sh; \
	if [ "$$OCG_CLI" = "true" ]; then \
		EXTRA_CMD="  $$OCG_CMD uninstall                   🗑️  Remove global CLI installation"; \
		TIP=""; \
	else \
		EXTRA_CMD="  $$OCG_CMD install                     📦 Install CLI globally (ocg/optimum_codegen commands)"; \
		TIP="💡 Install globally with 'make install' to use 'ocg' commands from anywhere!"; \
	fi; \
	echo "🚀 Project Management:"; \
	echo "  $$OCG_CMD setup                       🚀 Initialize codegen in the project (requires OCG_RULES_DIR environment variable)"; \
	echo "  $$OCG_CMD update-context <name>       🔄 Update project context for a specific feature"; \
	echo ""; \
	echo "📋 Planning Sessions:"; \
	echo "  $$OCG_CMD bird-eye [name] [model]     🦅 Start bird-eye planning session (default model: sonnet)"; \
	echo "  $$OCG_CMD plan [name] [model]         📝 Start detailed planning session (default model: sonnet)"; \
	echo ""; \
	echo "🎨 Workspaces:"; \
	echo "  $$OCG_CMD new <name>                  🎨 Create new feature workspace"; \
	echo "  $$OCG_CMD rm <name>                   🗑️  Remove feature workspace"; \
	echo "  $$OCG_CMD clean                       🧹 Remove ALL feature workspaces (with confirmation)"; \
	echo "  $$OCG_CMD clean-branches              🌿 Remove all orphaned feature branches (with confirmation)"; \
	echo "  $$OCG_CMD clean-servers               🔧 Kill servers for all workspace ports"; \
	echo "  $$OCG_CMD resume <name>               🔄 Resume feature workspace"; \
	echo "  $$OCG_CMD ls                          📋 List all feature workspaces"; \
	echo "$$EXTRA_CMD"; \
	echo ""; \
	echo "📋 Recommended Workflow:"; \
	echo "  1. Run: $$OCG_CMD setup (one-time project initialization)"; \
	echo "  2. Plan: $$OCG_CMD bird-eye <name> (high-level planning)"; \
	echo "  3. Plan: $$OCG_CMD plan <name> (detailed technical planning)"; \
	echo "  4. Implement: $$OCG_CMD new <name> (create workspace and start development)"; \
	echo "  5. Work on your feature in the workspace"; \
	echo "  6. Finish: $$OCG_CMD rm <name> (archives feature context to codegen/contexts/)"; \
	echo "  7. Learn: $$OCG_CMD update-context <name> (update main PROJECT_CONTEXT.md with learnings)"; \
	echo "  8. Cleanup: $$OCG_CMD clean-branches to remove orphaned feature branches when done"; \
	echo ""; \
	echo "📝 Examples:"; \
	echo "  $$OCG_CMD setup"; \
	echo "  $$OCG_CMD bird-eye dashboard-redesign"; \
	echo "  $$OCG_CMD bird-eye complex-feature opus"; \
	echo "  $$OCG_CMD plan dashboard-redesign"; \
	echo "  $$OCG_CMD plan complex-feature opus"; \
	echo "  $$OCG_CMD new dashboard-redesign"; \
	echo "  $$OCG_CMD resume dashboard-redesign"; \
	echo "  $$OCG_CMD rm dashboard-redesign"; \
	echo "  $$OCG_CMD update-context dashboard-redesign"; \
	echo "  $$OCG_CMD clean"; \
	echo "  $$OCG_CMD clean-branches"; \
	echo "  $$OCG_CMD ls"; \
	if [ "$$OCG_CLI" = "true" ]; then \
		echo "  $$OCG_CMD uninstall"; \
	else \
		echo "  $$OCG_CMD install                     # Then use: ocg new dashboard-redesign"; \
	fi; \
	if [ -n "$$TIP" ]; then \
		echo ""; \
		echo "$$TIP"; \
	fi

# Default target shows help
.DEFAULT_GOAL := help

# Prevent make from treating arguments as targets
%:
	@:
