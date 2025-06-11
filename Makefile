# Optimum Codegen
# Usage: make [command]

new:
	@if [ -z "$(filter-out $@,$(MAKECMDGOALS))" ]; then \
		echo "Usage: make new <feature-name>"; \
		echo "Example: make new dashboard-redesign"; \
		exit 1; \
	fi
	@./create_workspace.sh $(filter-out $@,$(MAKECMDGOALS))

batch:
	@echo "🚀 Creating codegen features from all available plans..."
	@. ./config.sh; \
	PLANS_DIR="$$TARGET_REPO_PATH/codegen/plans"; \
	if [ ! -d "$$PLANS_DIR" ] && [ ! -d "plans" ]; then \
		echo "   ❌ No plans directory found in target repo ($$PLANS_DIR) or codegen repo (plans/)"; \
		exit 1; \
	fi; \
	if [ -d "$$PLANS_DIR" ]; then \
		PLANS_PATH="$$PLANS_DIR"; \
	else \
		PLANS_PATH="plans"; \
	fi; \
	plan_count=$$(ls $$PLANS_PATH/*.md 2>/dev/null | wc -l | xargs); \
	if [ $$plan_count -eq 0 ]; then \
		echo "   ❌ No plan files found in $$PLANS_PATH directory"; \
		exit 1; \
	fi; \
	echo "   📋 Found $$plan_count plan(s) to process in $$PLANS_PATH"; \
	sleep_duration=$$((5 + plan_count)); \
	echo "   ⏱️  Using $$sleep_duration second delay between workspaces"; \
	window_pos=1; \
	for plan in $$PLANS_PATH/*.md; do \
		if [ -f "$$plan" ]; then \
			name=$$(basename "$$plan" .md); \
			echo "   🎨 Creating codegen feature: $$name (window $$window_pos of $$plan_count)"; \
			./create_workspace.sh "$$name" "$$window_pos" "$$plan_count" || echo "   ⚠️  Failed to create workspace for $$name"; \
			window_pos=$$((window_pos + 1)); \
			if [ $$window_pos -le $$plan_count ]; then \
				echo "   ⏳ Waiting $$sleep_duration seconds for workspace to initialize..."; \
				sleep $$sleep_duration; \
			fi; \
		fi; \
	done; \
	echo "   ✅ Finished creating all workspaces"

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
	echo "  $$OCG_CMD batch                       🎯 Create feature workspaces from all available plans"; \
	echo "  $$OCG_CMD rm <name>                   🗑️  Remove feature workspace"; \
	echo "  $$OCG_CMD clean                       🧹 Remove ALL feature workspaces (with confirmation)"; \
	echo "  $$OCG_CMD clean-branches              🌿 Remove all orphaned feature branches (with confirmation)"; \
	echo "  $$OCG_CMD resume <name>               🔄 Resume feature workspace"; \
	echo "  $$OCG_CMD ls                          📋 List all feature workspaces"; \
	echo "$$EXTRA_CMD"; \
	echo ""; \
	echo "📋 Recommended Workflow:"; \
	echo "  1. (Optional) Ask Cursor to create a plan in codegen/plans/<name>.md in your target repo"; \
	echo "  2. Run: $$OCG_CMD new <name> (automatically starts Playwright and includes the plan if it exists)"; \
	echo "  3. Or run: $$OCG_CMD batch to create feature workspaces from all available plans"; \
	echo "  4. Use: $$OCG_CMD clean to remove all workspaces when done"; \
	echo "  5. Use: $$OCG_CMD clean-branches to remove orphaned feature branches"; \
	echo ""; \
	echo "📝 Examples:"; \
	echo "  $$OCG_CMD new dashboard-redesign"; \
	echo "  $$OCG_CMD batch"; \
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
