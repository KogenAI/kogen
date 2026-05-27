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



COMBOBULATE_DIR ?= $(shell \
  if [ -f "$(SCRIPT_DIR)/../combobulate/CLAUDE.md" ] || [ -f "$(SCRIPT_DIR)/../combobulate/AGENTS.md" ]; then \
    echo "$(SCRIPT_DIR)/../combobulate"; \
  elif [ -f "$(HOME)/Projects/AppBuilder/combobulate/CLAUDE.md" ] || [ -f "$(HOME)/Projects/AppBuilder/combobulate/AGENTS.md" ]; then \
    echo "$(HOME)/Projects/AppBuilder/combobulate"; \
  else \
    echo "$(SCRIPT_DIR)/../combobulate"; \
  fi)
HOOKS_MD_PATH := $(COMBOBULATE_DIR)/context/hooks.md
HOOKS_MD_ARG := $(if $(wildcard $(HOOKS_MD_PATH)),--hooks-md-path "$(HOOKS_MD_PATH)",)
PI_EXTENSION_DIR ?= $(SCRIPT_DIR)/harnesses/pi/pi-extensions/enforcement

.PHONY: hook-parity
hook-parity:
	@cd "$(SCRIPT_DIR)/templates" && python3 generator/hook_registrations.py \
		--hooks-dir ../harnesses/claude/hooks \
		--output-settings /tmp/claude-code-settings-parity.json \
		--existing-settings "$(SCRIPT_DIR)/harnesses/claude/claude-code-settings.json" \
		--combobulate-dir /tmp/hook-parity-test \
		--subagents-dir "$(SCRIPT_DIR)/shared/subagents" \
		$(HOOKS_MD_ARG)
	@diff -u "$(SCRIPT_DIR)/harnesses/claude/claude-code-settings.json" /tmp/claude-code-settings-parity.json || exit 1
	@if [ -f "$(COMBOBULATE_DIR)/priv/claude_config/agent_manifest.json" ]; then \
		diff -u "$(COMBOBULATE_DIR)/priv/claude_config/agent_manifest.json" /tmp/hook-parity-test/priv/claude_config/agent_manifest.json || exit 1; \
	fi
	@if [ -f "$(COMBOBULATE_DIR)/priv/claude_config/hook_manifest.json" ]; then \
		diff -u "$(COMBOBULATE_DIR)/priv/claude_config/hook_manifest.json" /tmp/hook-parity-test/priv/claude_config/hook_manifest.json || exit 1; \
	fi
	@if [ -f "$(COMBOBULATE_DIR)/priv/claude_config/expected_hook_manifest_hash.txt" ]; then \
		diff -u "$(COMBOBULATE_DIR)/priv/claude_config/expected_hook_manifest_hash.txt" /tmp/hook-parity-test/priv/claude_config/expected_hook_manifest_hash.txt || exit 1; \
	fi
	@echo "hook-manifest-parity: PASS"
	@echo "hook-parity: PASS"

install: hook-parity
	@bash "$(SCRIPT_DIR)/templates/generator/generate-pi-extension.sh" "$(PI_EXTENSION_DIR)"
	@python3 "$(SCRIPT_DIR)/templates/generator/hook_registrations.py" \
		--hooks-dir "$(SCRIPT_DIR)/harnesses/claude/hooks" \
		--output-settings "$(SCRIPT_DIR)/harnesses/claude/claude-code-settings.json" \
		--combobulate-dir "$(COMBOBULATE_DIR)" \
		--subagents-dir "$(SCRIPT_DIR)/shared/subagents" \
		--pi-extension-dir "$(PI_EXTENSION_DIR)" \
		$(HOOKS_MD_ARG)
	@./install.sh

# harness-parity: verify codegen-build + dispatch.sh stubs are self-consistent.
# Runs the codegen-build_test.sh script in isolation.
.PHONY: harness-parity
harness-parity:
	@bash "$(SCRIPT_DIR)/harnesses/claude/hooks/codegen-build_test.sh"
	@bash "$(SCRIPT_DIR)/shared/scaffold/static/scaffold_test.sh"
	@echo "harness-parity: PASS"

# test: run every PreToolUse/SubagentStop/Stop hook unit-test script in parallel.
# Each *_test.sh is hermetic — own tmp dirs, no shared state — so xargs -P is safe.
# Job count caps at 8 to avoid thrashing on smaller machines.
test: hook-parity harness-parity test-generator
	@./harnesses/claude/hooks/run-tests.sh
	@./shared/scaffold/phoenix/run-tests.sh
	@./test_harness/install/run-tests.sh
	@for ext in enforcement askuserquestion subagents web-utils; do \
		ext_dir="$(SCRIPT_DIR)/harnesses/pi/pi-extensions/$$ext"; \
		if [ -f "$$ext_dir/package.json" ] && grep -q '"test"[[:space:]]*:' "$$ext_dir/package.json"; then \
			echo "▶ Test: $$ext"; \
			(cd "$$ext_dir" && mise exec -- npm test) || exit 1; \
		fi; \
	done
	@ext_dir="$(SCRIPT_DIR)/harnesses/pi/pi-extensions/subagents"; \
	if [ -d "$$ext_dir/test/integration" ] && [ -n "$$(ls "$$ext_dir/test/integration/"*.test.ts 2>/dev/null)" ]; then \
		echo "▶ Test:integration: subagents"; \
		(cd "$$ext_dir" && mise exec -- npm run test:integration) || exit 1; \
	fi

.PHONY: test-generator test-generator-python
test-generator: test-generator-python
	@bash "$(SCRIPT_DIR)/templates/generator/run-tests.sh"
test-generator-python:
	@cd "$(SCRIPT_DIR)/templates/generator" && python3 -m unittest discover -s tests -v

.PHONY: test-coverage test-coverage-elixir test-coverage-typescript test-coverage-shell test-coverage-python test-coverage-summary

# test-coverage: run coverage instrumentation per language. Slower than `make test`.
# Output: coverage/<language>/ at repo root.
test-coverage: test-coverage-elixir test-coverage-typescript test-coverage-shell test-coverage-python test-coverage-summary

test-coverage-elixir:
	@mkdir -p "$(SCRIPT_DIR)/coverage/elixir"
	cd "$(SCRIPT_DIR)/test_harness" && mix coveralls.json --include slow
	@cp "$(SCRIPT_DIR)/test_harness/cover/excoveralls.json" "$(SCRIPT_DIR)/coverage/elixir/excoveralls.json"

test-coverage-typescript:
	@mkdir -p "$(SCRIPT_DIR)/coverage/typescript"
	@for ext in enforcement subagents askuserquestion; do \
		ext_dir="$(SCRIPT_DIR)/harnesses/pi/pi-extensions/$$ext"; \
		if [ -f "$$ext_dir/package.json" ] && grep -q '"test:coverage"' "$$ext_dir/package.json"; then \
			echo "▶ Coverage: $$ext"; \
			(cd "$$ext_dir" && mise exec -- npm run test:coverage) || echo "⚠  $$ext: test:coverage exited $$? (no test files or error — continuing)"; \
			mkdir -p "$(SCRIPT_DIR)/coverage/typescript/$$ext"; \
			[ -d "$$ext_dir/coverage" ] && cp -R "$$ext_dir/coverage/." "$(SCRIPT_DIR)/coverage/typescript/$$ext/"; \
		else \
			echo "⏭  Skip $$ext (no test:coverage script)"; \
		fi \
	done

test-coverage-shell:
	@{ command -v kcov >/dev/null 2>&1 || { echo "⚠  kcov not installed — shell coverage skipped (brew install kcov)"; exit 0; }; } && \
		mkdir -p "$(SCRIPT_DIR)/coverage/shell" && \
		kcov --include-path="$(SCRIPT_DIR)/harnesses/claude/hooks","$(SCRIPT_DIR)/shared/scaffold" \
			--exclude-pattern=_test.sh \
			"$(SCRIPT_DIR)/coverage/shell" \
			"$(SCRIPT_DIR)/harnesses/claude/hooks/run-tests.sh"

test-coverage-python:
	@mkdir -p "$(SCRIPT_DIR)/coverage/python"
	@cd "$(SCRIPT_DIR)/templates/generator" && \
		PYTHONPATH=. python3 -m coverage run --source=process_template,hook_registrations -m unittest discover -s tests && \
		python3 -m coverage xml -o "$(SCRIPT_DIR)/coverage/python/coverage.xml" && \
		python3 -m coverage html -d "$(SCRIPT_DIR)/coverage/python/htmlcov"

# test-coverage-summary: parse each tool's output and print one line per language.
test-coverage-summary:
	@echo ""
	@echo "═══ Coverage Summary ═══"
	@if [ -f "$(SCRIPT_DIR)/coverage/elixir/excoveralls.json" ]; then \
		pct=$$(jq -r '([.source_files[] | .coverage[] | select(. != null)] | length) as $$all | ([.source_files[] | .coverage[] | select(. != null and . > 0)] | length) as $$hit | if $$all > 0 then (($$hit * 100 / $$all) | floor | tostring) else "0" end' "$(SCRIPT_DIR)/coverage/elixir/excoveralls.json" 2>/dev/null || echo "—"); \
		echo "Elixir:     $$pct%"; \
	else echo "Elixir:     (no data)"; fi
	@for ext in enforcement subagents askuserquestion; do \
		f="$(SCRIPT_DIR)/coverage/typescript/$$ext/coverage-summary.json"; \
		if [ -f "$$f" ]; then \
			pct=$$(jq -r '.total.lines.pct' "$$f" 2>/dev/null || echo "—"); \
			printf "TS %-15s %s%%\n" "$$ext:" "$$pct"; \
		else printf "TS %-15s (no data)\n" "$$ext:"; fi \
	done
	@if [ -d "$(SCRIPT_DIR)/coverage/shell" ] && [ -f "$(SCRIPT_DIR)/coverage/shell/index.html" ]; then \
		echo "Shell:      see coverage/shell/index.html"; \
	else echo "Shell:      (no data)"; fi
	@if [ -f "$(SCRIPT_DIR)/coverage/python/coverage.xml" ]; then \
		pct=$$(python3 -c "import xml.etree.ElementTree as ET; t=ET.parse('$(SCRIPT_DIR)/coverage/python/coverage.xml').getroot(); print(int(float(t.get('line-rate','0'))*100))" 2>/dev/null || echo "—"); \
		echo "Python:     $$pct%"; \
	else echo "Python:     (no data — run make test-coverage-python)"; fi
	@echo "════════════════════════"

# test-stacks: run ExUnit stack scaffold tests under test_harness/ for both
# harnesses in parallel. Real LLM calls — slow + costs tokens. Pre-deploy gate.
.PHONY: test-stacks test-stacks-claude test-stacks-pi test-stacks-claude-compile test-stacks-pi-compile test-stacks-claude-p1 test-stacks-claude-p2 test-stacks-claude-p3 test-stacks-claude-p4 test-stacks-pi-p1 test-stacks-pi-p2 test-stacks-pi-p3 test-stacks-pi-p4 test-all record-green
test-stacks:
	$(MAKE) test-stacks-claude
	$(MAKE) test-stacks-pi

# test-stacks-claude: precompile once into _build/claude_test, then fan out
# 7 partition processes via `$(MAKE) -j7`. Each partition is its own BEAM/OS
# process running `mix test --partitions 4 --no-compile --only slow` with a
# distinct `MIX_TEST_PARTITION` value. Mix sorts test files round-robin into
# partitions; with 7 slow test files we get 1 file per partition. Tests
# within a partition use the module's `async: true` for intra-file parallelism
# (only meaningful for `test/stacks/static/iteration_test.exs` which has 5
# tests; the other 6 files have 1 test each).
test-stacks-claude: test-stacks-claude-compile
	$(MAKE) -j4 test-stacks-claude-p1 test-stacks-claude-p2 test-stacks-claude-p3 test-stacks-claude-p4

test-stacks-claude-compile:
	cd "$(SCRIPT_DIR)/test_harness" && \
		MIX_BUILD_PATH=_build/claude_test mix compile

test-stacks-claude-p1:
	cd "$(SCRIPT_DIR)/test_harness" && \
		HARNESS=claude MIX_BUILD_PATH=_build/claude_test MIX_TEST_PARTITION=1 \
		mix test --partitions 4 --no-compile --only slow

test-stacks-claude-p2:
	cd "$(SCRIPT_DIR)/test_harness" && \
		HARNESS=claude MIX_BUILD_PATH=_build/claude_test MIX_TEST_PARTITION=2 \
		mix test --partitions 4 --no-compile --only slow

test-stacks-claude-p3:
	cd "$(SCRIPT_DIR)/test_harness" && \
		HARNESS=claude MIX_BUILD_PATH=_build/claude_test MIX_TEST_PARTITION=3 \
		mix test --partitions 4 --no-compile --only slow

test-stacks-claude-p4:
	cd "$(SCRIPT_DIR)/test_harness" && \
		HARNESS=claude MIX_BUILD_PATH=_build/claude_test MIX_TEST_PARTITION=4 \
		mix test --partitions 4 --no-compile --only slow

test-stacks-pi: test-stacks-pi-compile
	$(MAKE) -j4 test-stacks-pi-p1 test-stacks-pi-p2 test-stacks-pi-p3 test-stacks-pi-p4

test-stacks-pi-compile:
	cd "$(SCRIPT_DIR)/test_harness" && \
		MIX_BUILD_PATH=_build/pi_test mix compile

test-stacks-pi-p1:
	cd "$(SCRIPT_DIR)/test_harness" && \
		HARNESS=pi MIX_BUILD_PATH=_build/pi_test MIX_TEST_PARTITION=1 \
		mix test --partitions 4 --no-compile --only slow

test-stacks-pi-p2:
	cd "$(SCRIPT_DIR)/test_harness" && \
		HARNESS=pi MIX_BUILD_PATH=_build/pi_test MIX_TEST_PARTITION=2 \
		mix test --partitions 4 --no-compile --only slow

test-stacks-pi-p3:
	cd "$(SCRIPT_DIR)/test_harness" && \
		HARNESS=pi MIX_BUILD_PATH=_build/pi_test MIX_TEST_PARTITION=3 \
		mix test --partitions 4 --no-compile --only slow

test-stacks-pi-p4:
	cd "$(SCRIPT_DIR)/test_harness" && \
		HARNESS=pi MIX_BUILD_PATH=_build/pi_test MIX_TEST_PARTITION=4 \
		mix test --partitions 4 --no-compile --only slow

# test-all: full pre-deploy gate. Chains hook tests + stack tests, then
# writes last_green.json. Only the all-green path overwrites last_green.json.
test-all: test test-stacks record-green

record-green:
	@"$(SCRIPT_DIR)/test_harness/record-green.sh"

# rule-parity: re-render AGENTS-HYBRID.md.j2 in both modes to temp files and
# diff against committed AGENTS.md / CLAUDE.md. Exits non-zero on drift.
rule-parity:
	@SCRIPT_DIR="$(SCRIPT_DIR)"; \
	TEMPLATE="$$SCRIPT_DIR/templates/AGENTS-HYBRID.md.j2"; \
	PYTHON="$$SCRIPT_DIR/templates/generator/process_template.py"; \
	COMBOBULATE_DIR="$(COMBOBULATE_DIR)"; \
	AGENTS_COMMITTED="$$COMBOBULATE_DIR/AGENTS.md"; \
	CLAUDE_COMMITTED="$$COMBOBULATE_DIR/CLAUDE.md"; \
	if [ ! -f "$$AGENTS_COMMITTED" ] && [ ! -f "$$CLAUDE_COMMITTED" ]; then \
		echo "rule-parity: ERROR — neither AGENTS.md nor CLAUDE.md found under $$COMBOBULATE_DIR"; \
		echo "rule-parity: set COMBOBULATE_DIR=/path/to/combobulate (current default assumes sibling of codegen)"; \
		exit 2; \
	fi; \
	TMPDIR_PARITY="$$(mktemp -d)"; \
	python3 "$$PYTHON" "$$TEMPLATE" pi false > "$$TMPDIR_PARITY/AGENTS.md"; \
	python3 "$$PYTHON" "$$TEMPLATE" claude false > "$$TMPDIR_PARITY/CLAUDE.md"; \
	FAIL=0; \
	if [ -f "$$AGENTS_COMMITTED" ] && ! diff -q "$$TMPDIR_PARITY/AGENTS.md" "$$AGENTS_COMMITTED" > /dev/null 2>&1; then \
		echo "DRIFT: AGENTS.md differs from AGENTS-HYBRID.md.j2 (pi render)"; \
		diff "$$TMPDIR_PARITY/AGENTS.md" "$$AGENTS_COMMITTED" || true; \
		FAIL=1; \
	fi; \
	if [ -f "$$CLAUDE_COMMITTED" ] && ! diff -q "$$TMPDIR_PARITY/CLAUDE.md" "$$CLAUDE_COMMITTED" > /dev/null 2>&1; then \
		echo "DRIFT: CLAUDE.md differs from AGENTS-HYBRID.md.j2 (claude render)"; \
		diff "$$TMPDIR_PARITY/CLAUDE.md" "$$CLAUDE_COMMITTED" || true; \
		FAIL=1; \
	fi; \
	rm -rf "$$TMPDIR_PARITY"; \
	if [ $$FAIL -eq 1 ]; then exit 1; fi; \
	echo "rule-parity: OK (no drift) [checked: $$COMBOBULATE_DIR]"; \
	echo "rule-parity: checking harness path isolation..."; \
	AGENTS_DIR="$(HOME)/.claude/agents"; \
	if [ -d "$$AGENTS_DIR" ]; then \
		if grep -rl "templates/shared/claude-\|templates/shared/pi-" "$$AGENTS_DIR" 2>/dev/null | grep -q .; then \
			echo "rule-parity: ERROR — generated agent files reference old templates/shared/claude-* or pi-* paths"; \
			grep -rl "templates/shared/claude-\|templates/shared/pi-" "$$AGENTS_DIR" 2>/dev/null; \
			exit 1; \
		fi; \
		echo "rule-parity: OK — no stale harness paths in baked agents [checked: $$AGENTS_DIR]"; \
	else \
		echo "rule-parity: SKIP harness path isolation — $$AGENTS_DIR not found (run make install first)"; \
	fi

uninstall:
	$(call check_ocg_only,uninstall)
	@./uninstall.sh

update:
	$(call check_ocg_only,update)
	@./update_ai_tools.sh

format:
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

doctor:
	@set +e; \
	fails=0; \
	check() { \
		local label="$$1"; shift; \
		if "$$@" >/dev/null 2>&1; then \
			echo "OK: $$label"; \
		else \
			echo "FAIL: $$label"; \
			fails=$$((fails + 1)); \
		fi; \
	}; \
	echo "🩺 Running OCG codegen doctor..."; \
	echo ""; \
	if command -v claude >/dev/null 2>&1 && claude --version >/dev/null 2>&1; then \
		echo "OK: claude on PATH and --version exits 0"; \
	else \
		echo "FAIL: claude on PATH and --version exits 0"; fails=$$((fails + 1)); \
	fi; \
	if [ -f "$$HOME/.claude/settings.json" ]; then \
		echo "OK: ~/.claude/settings.json exists"; \
	else \
		echo "FAIL: ~/.claude/settings.json exists (run 'make install')"; fails=$$((fails + 1)); \
	fi; \
	if [ -d "$(SCRIPT_DIR)/shared" ]; then \
		echo "OK: codegen/shared/ exists"; \
	else \
		echo "FAIL: codegen/shared/ missing (run 'make install')"; fails=$$((fails + 1)); \
	fi; \
	if python3 -c "import yaml" >/dev/null 2>&1; then \
		echo "OK: python3 -c 'import yaml' (pyyaml available)"; \
	else \
		echo "FAIL: pyyaml not installed (pip3 install --user pyyaml)"; fails=$$((fails + 1)); \
	fi; \
	if command -v jq >/dev/null 2>&1; then \
		echo "OK: jq on PATH"; \
	else \
		echo "FAIL: jq not on PATH (brew install jq)"; fails=$$((fails + 1)); \
	fi; \
	if command -v rg >/dev/null 2>&1; then \
		echo "OK: rg (ripgrep) on PATH"; \
	else \
		echo "FAIL: rg not on PATH (brew install ripgrep)"; fails=$$((fails + 1)); \
	fi; \
	if command -v mise >/dev/null 2>&1; then \
		echo "OK: mise on PATH"; \
	else \
		echo "FAIL: mise not on PATH (curl https://mise.run | sh)"; fails=$$((fails + 1)); \
	fi; \
	echo ""; \
	if [ $$fails -eq 0 ]; then \
		echo "✅ All checks passed"; \
		exit 0; \
	else \
		echo "❌ $$fails check(s) failed"; \
		exit 1; \
	fi


help:
	@echo "Optimum Codegen"
	@echo "==============="
	@echo ""
	@echo "Available commands (make):"
	@echo "  make install        Install CLI globally — installs all subagents"
	@echo "  make test           Run hook unit tests"
	@echo "  make test-generator  Run Python unittest + bash unit tests for generator pipeline"
	@echo "  make test-coverage  Coverage report per language → coverage/<lang>/"
	@echo "  make test-stacks    Run ExUnit stack scaffold tests (claude+pi parallel, real LLM, slow)"
	@echo "  make test-all       Full pre-deploy gate: test + test-stacks + record-green"
	@echo "  make record-green   Write test_harness/last_green.json with current sha + versions"
	@echo "  make hook-parity    Verify hook registrations match claude-code-settings.json"
	@echo "  make rule-parity    Verify AGENTS.md / CLAUDE.md match template render"
	@echo "  make format         Format all shell scripts and files"
	@echo "  make doctor         Check required tools and config"
	@echo "  make uninstall      Remove global CLI installation (via ocg)"
	@echo "  make update         Update all AI agents (via ocg)"
	@echo "  make help           Show this help"

# Default target shows help
.DEFAULT_GOAL := help

# Prevent make from treating arguments as targets
%:
	@:
