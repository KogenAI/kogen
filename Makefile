# Optimum Codegen
# Usage: make [command]

new:
	@if [ -z "$(filter-out $@,$(MAKECMDGOALS))" ]; then \
		echo "Usage: make new <feature-name>"; \
		echo "Example: make new dashboard-redesign"; \
		exit 1; \
	fi
	@./create_workspace.sh $(filter-out $@,$(MAKECMDGOALS))

clean:
	@echo "🧹 Removing all feature workspaces..."
	@WORKSPACES=$$(./list_workspaces.sh 2>/dev/null | grep "^📁" | grep -v "Main Repository" | sed 's/^📁 //'); \
	if [ -z "$$WORKSPACES" ]; then \
		echo "   ℹ️  No feature workspaces found to remove"; \
		exit 0; \
	fi; \
	echo "   📋 Found workspaces to remove:"; \
	echo "$$WORKSPACES" | sed 's/^/      - /'; \
	echo "   ⚠️  This will remove ALL feature workspaces. Continue? [y/N]"; \
	read -r confirm; \
	if [ "$$confirm" != "y" ] && [ "$$confirm" != "Y" ]; then \
		echo "   ❌ Operation cancelled"; \
		exit 1; \
	fi; \
	for workspace in $$WORKSPACES; do \
		echo "   🗑️  Removing workspace: $$workspace"; \
		$(MAKE) rm "$$workspace" || echo "   ⚠️  Failed to remove workspace: $$workspace"; \
	done; \
	echo "   ✅ Finished removing all workspaces"; \
	echo ""; \
	echo "💡 Tip: Feature branches are preserved by default"; \
	echo "   To also remove orphaned feature branches, run: make clean-branches"

clean-branches:
	@./clean_branches.sh

rm:
	@if [ -z "$(filter-out $@,$(MAKECMDGOALS))" ]; then \
		echo "Usage: make rm <feature-name>"; \
		echo "Example: make rm dashboard-redesign"; \
		exit 1; \
	fi
	@./remove_workspace.sh $(filter-out $@,$(MAKECMDGOALS))

resume:
	@if [ -z "$(filter-out $@,$(MAKECMDGOALS))" ]; then \
		echo "Usage: make resume <feature-name>"; \
		echo "Example: make resume dashboard-redesign"; \
		exit 1; \
	fi
	@./resume_workspace.sh $(filter-out $@,$(MAKECMDGOALS))

ls:
	@./list_workspaces.sh

install:
	@./install.sh

uninstall:
	@./uninstall.sh

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
	echo "⚡ Commands:"; \
	echo "  $$OCG_CMD new <name>                  🎨 Create new feature workspace"; \
	echo "  $$OCG_CMD rm <name>                   🗑️  Remove feature workspace"; \
	echo "  $$OCG_CMD clean                       🧹 Remove ALL feature workspaces (with confirmation)"; \
	echo "  $$OCG_CMD clean-branches              🌿 Remove all orphaned feature branches (with confirmation)"; \
	echo "  $$OCG_CMD resume <name>               🔄 Resume feature workspace"; \
	echo "  $$OCG_CMD ls                          📋 List all feature workspaces"; \
	echo "$$EXTRA_CMD"; \
	echo ""; \
	echo "📋 Recommended Workflow:"; \
	echo "  1. Ask Cursor to create a plan in codegen/plans/<name>.md in your target repo"; \
	echo "  2. Run: $$OCG_CMD new <name> (automatically starts Playwright and includes the plan)"; \
	echo "  3. Use: $$OCG_CMD clean to remove all workspaces when done"; \
	echo "  4. Use: $$OCG_CMD clean-branches to remove orphaned feature branches"; \
	echo ""; \
	echo "📝 Examples:"; \
	echo "  $$OCG_CMD new dashboard-redesign"; \
	echo "  $$OCG_CMD rm dashboard-redesign"; \
	echo "  $$OCG_CMD clean"; \
	echo "  $$OCG_CMD clean-branches"; \
	echo "  $$OCG_CMD resume dashboard-redesign"; \
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
