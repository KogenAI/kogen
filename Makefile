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



PI_EXTENSION_DIR ?= $(SCRIPT_DIR)/harnesses/pi/pi-extensions/enforcement

.PHONY: hook-parity
hook-parity:
	@out=$$(cd "$(SCRIPT_DIR)/templates" && python3 generator/hook_registrations.py \
		--hooks-dir ../harnesses/claude/hooks \
		--output-settings /tmp/claude-code-settings-parity.json \
		--existing-settings "$(SCRIPT_DIR)/harnesses/claude/claude-code-settings.json" 2>&1); \
	rc=$$?; [ -n "$$VERBOSE" ] && printf '%s\n' "$$out"; \
	[ $$rc -eq 0 ] || { [ -z "$$VERBOSE" ] && printf '%s\n' "$$out"; exit $$rc; }
	@diff -u "$(SCRIPT_DIR)/harnesses/claude/claude-code-settings.json" /tmp/claude-code-settings-parity.json || exit 1
	@diff -u "$(SCRIPT_DIR)/harnesses/claude/claude-code-loop-settings.json" /tmp/claude-code-loop-settings.json || exit 1
	@[ -z "$$VERBOSE" ] || echo "hook-parity: PASS"

.PHONY: hook-header-parity
hook-header-parity:
	@out=$$(python3 "$(SCRIPT_DIR)/templates/generator/hook_registrations.py" \
		--hooks-dir "$(SCRIPT_DIR)/harnesses/claude/hooks" \
		--registry "$(SCRIPT_DIR)/shared/enforcement/registry.yaml" \
		--check-headers 2>&1); \
	rc=$$?; [ -n "$$VERBOSE" ] && printf '%s\n' "$$out"; \
	[ $$rc -eq 0 ] || { [ -z "$$VERBOSE" ] && printf '%s\n' "$$out"; exit $$rc; }
	@[ -z "$$VERBOSE" ] || echo "hook-header-parity: PASS"

install:
	@if ! command -v python3 >/dev/null 2>&1; then \
		echo "❌ python3 required but not found — install python3 first"; \
		exit 1; \
	fi
	@if ! command -v node >/dev/null 2>&1; then \
		echo "❌ node required but not found — install via mise: mise install node"; \
		exit 1; \
	fi
	@if ! command -v yq >/dev/null 2>&1; then \
		echo "❌ yq required but not found — install mikefarah/yq: brew install yq (macOS) | https://github.com/mikefarah/yq"; \
		exit 1; \
	fi
	@if ! yq --version 2>&1 | grep -qi mikefarah; then \
		echo "❌ installed yq is not mikefarah/yq (apt python-yq is incompatible) — install from https://github.com/mikefarah/yq"; \
		exit 1; \
	fi
	@python3 "$(SCRIPT_DIR)/templates/generator/enforcement_compiler.py" \
		--registry "$(SCRIPT_DIR)/shared/enforcement/registry.yaml" \
		--bash-out "$(SCRIPT_DIR)/harnesses/claude/hooks" \
		--ts-out "$(SCRIPT_DIR)/harnesses/pi/pi-extensions/enforcement/src/hooks" \
		--pi-hooks-dir "$(SCRIPT_DIR)/harnesses/pi/pi-extensions/enforcement/src/hooks" \
		--index "$(SCRIPT_DIR)/harnesses/pi/pi-extensions/enforcement/src/index.ts"
	@python3 "$(SCRIPT_DIR)/templates/generator/hook_registrations.py" \
		--hooks-dir "$(SCRIPT_DIR)/harnesses/claude/hooks" \
		--registry "$(SCRIPT_DIR)/shared/enforcement/registry.yaml" \
		--emit-headers
	@$(MAKE) hook-parity
	@bash "$(SCRIPT_DIR)/templates/generator/generate-pi-extension.sh" "$(PI_EXTENSION_DIR)"
	@python3 "$(SCRIPT_DIR)/templates/generator/hook_registrations.py" \
		--hooks-dir "$(SCRIPT_DIR)/harnesses/claude/hooks" \
		--output-settings "$(SCRIPT_DIR)/harnesses/claude/claude-code-settings.json" \
		--pi-extension-dir "$(PI_EXTENSION_DIR)"
	@./install.sh

# harness-parity: verify codegen-build + dispatch.sh stubs are self-consistent.
# Runs the codegen-build_test.sh script in isolation.
# enforce-registry-parity: compile to /tmp and diff all generated files vs committed.
# Exits non-zero if any generated file differs from what is committed.
.PHONY: enforce-registry-parity
enforce-registry-parity:
	@cp "$(SCRIPT_DIR)/harnesses/pi/pi-extensions/enforcement/src/index.ts" /tmp/enforce-parity-index.ts.tmp
	@python3 "$(SCRIPT_DIR)/templates/generator/enforcement_compiler.py" \
		--registry "$(SCRIPT_DIR)/shared/enforcement/registry.yaml" \
		--bash-out /tmp/enforce-parity-bash \
		--ts-out /tmp/enforce-parity-ts \
		--pi-hooks-dir "$(SCRIPT_DIR)/harnesses/pi/pi-extensions/enforcement/src/hooks" \
		--index /tmp/enforce-parity-index.ts.tmp > /dev/null 2>&1
	@fail=0; \
	for f in /tmp/enforce-parity-bash/*.sh; do \
		name=$$(basename "$$f"); \
		committed="$(SCRIPT_DIR)/harnesses/claude/hooks/$$name"; \
		if [ ! -f "$$committed" ]; then \
			echo "enforce-registry-parity: MISSING committed $$committed"; \
			fail=1; \
		elif ! diff -q "$$committed" "$$f" > /dev/null 2>&1; then \
			echo "enforce-registry-parity: DRIFT in $$name (bash)"; \
			diff -u "$$committed" "$$f" || true; \
			fail=1; \
		fi; \
	done; \
	for f in /tmp/enforce-parity-ts/*.ts; do \
		name=$$(basename "$$f"); \
		committed="$(SCRIPT_DIR)/harnesses/pi/pi-extensions/enforcement/src/hooks/$$name"; \
		if [ ! -f "$$committed" ]; then \
			echo "enforce-registry-parity: MISSING committed $$committed"; \
			fail=1; \
		elif ! diff -q "$$committed" "$$f" > /dev/null 2>&1; then \
			echo "enforce-registry-parity: DRIFT in $$name (ts)"; \
			diff -u "$$committed" "$$f" || true; \
			fail=1; \
		fi; \
	done; \
	committed_index="$(SCRIPT_DIR)/harnesses/pi/pi-extensions/enforcement/src/index.ts"; \
	if [ ! -f "$$committed_index" ]; then \
		echo "enforce-registry-parity: MISSING committed $$committed_index"; \
		fail=1; \
	elif ! diff -q "$$committed_index" /tmp/enforce-parity-index.ts.tmp > /dev/null 2>&1; then \
		echo "enforce-registry-parity: DRIFT in index.ts"; \
		diff -u "$$committed_index" /tmp/enforce-parity-index.ts.tmp || true; \
		fail=1; \
	fi; \
	bash "$(SCRIPT_DIR)/templates/generator/orphan-hook-check.sh" \
		--hooks-dir "$(SCRIPT_DIR)/harnesses/claude/hooks" \
		--ts-dir "$(SCRIPT_DIR)/harnesses/pi/pi-extensions/enforcement/src/hooks" \
		--registry "$(SCRIPT_DIR)/shared/enforcement/registry.yaml" || fail=1; \
	if [ $$fail -eq 0 ] && [ -n "$$VERBOSE" ]; then echo "enforce-registry-parity: PASS"; fi; \
	exit $$fail

.PHONY: enforce-hook-rationale
enforce-hook-rationale:
	@out=$$(bash "$(SCRIPT_DIR)/templates/generator/enforce-hook-rationale.sh" 2>&1); rc=$$?; \
	if [ -n "$$VERBOSE" ]; then printf '%s\n' "$$out"; fi; \
	if [ $$rc -ne 0 ]; then \
		[ -z "$$VERBOSE" ] && printf '%s\n' "$$out"; \
		echo "enforce-hook-rationale: FAIL"; \
	elif [ -n "$$VERBOSE" ]; then \
		echo "enforce-hook-rationale: PASS"; \
	fi; \
	exit $$rc

.PHONY: harness-parity
harness-parity:
	@fail=0; \
	for t in \
		"$(SCRIPT_DIR)/harnesses/claude/hooks/codegen-build_test.sh" \
		"$(SCRIPT_DIR)/harnesses/pi/dispatch_test.sh" \
		"$(SCRIPT_DIR)/harnesses/claude/hooks/codegen-call_test.sh" \
		"$(SCRIPT_DIR)/harnesses/claude/hooks/codegen-propose_test.sh" \
		"$(SCRIPT_DIR)/shared/scaffold/static/scaffold_test.sh" \
		"$(SCRIPT_DIR)/harnesses/shared/experiment-prune_test.sh" \
		"$(SCRIPT_DIR)/harnesses/shared/build-queue-launcher_test.sh" \
		"$(SCRIPT_DIR)/harnesses/shared/claude-experiment-settings_test.sh" \
		"$(SCRIPT_DIR)/codegen-log_test.sh"; do \
		out=$$(bash "$$t" 2>&1); rc=$$?; \
		if [ -n "$$VERBOSE" ]; then printf '%s\n' "$$out"; fi; \
		if [ $$rc -ne 0 ]; then \
			[ -z "$$VERBOSE" ] && printf '%s\n' "$$out"; \
			echo "harness-parity: FAIL — $$(basename "$$t")"; \
			fail=1; \
		fi; \
	done; \
	[ $$fail -eq 0 ] && [ -n "$$VERBOSE" ] && echo "harness-parity: PASS" || true; \
	exit $$fail

.PHONY: prompt-content-parity
prompt-content-parity:
	@out=$$(bash "$(SCRIPT_DIR)/harnesses/claude/hooks/prompt-content-parity_test.sh" 2>&1); rc=$$?; \
	if [ -n "$$VERBOSE" ]; then printf '%s\n' "$$out"; fi; \
	if [ $$rc -ne 0 ]; then \
		[ -z "$$VERBOSE" ] && printf '%s\n' "$$out"; \
		echo "prompt-content-parity: FAIL"; \
	elif [ -n "$$VERBOSE" ]; then \
		echo "prompt-content-parity: PASS"; \
	fi; \
	exit $$rc

.PHONY: tools-header-no-dup
tools-header-no-dup:
	@out=$$(bash "$(SCRIPT_DIR)/harnesses/claude/hooks/tools-header-no-dup_test.sh" 2>&1); rc=$$?; \
	if [ -n "$$VERBOSE" ]; then printf '%s\n' "$$out"; fi; \
	if [ $$rc -ne 0 ]; then \
		[ -z "$$VERBOSE" ] && printf '%s\n' "$$out"; \
		echo "tools-header-no-dup: FAIL"; \
	elif [ -n "$$VERBOSE" ]; then \
		echo "tools-header-no-dup: PASS"; \
	fi; \
	exit $$rc

.PHONY: ci
ci: test

# test: run every PreToolUse/SubagentStop/Stop hook unit-test script in parallel.
# Each *_test.sh is hermetic — own tmp dirs, no shared state — so xargs -P is safe.
# Job count caps at 8 to avoid thrashing on smaller machines.
# Post-deps stages (hook-tests, phoenix scaffold, test_harness/install, npm) run
# concurrently via & + wait to reduce wall time.
test: hook-parity hook-header-parity harness-parity test-generator enforce-registry-parity enforce-hook-rationale test-hermetic prompt-content-parity tools-header-no-dup rule-render-freshness
	@set -e; \
	export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false; \
	subagents_ext_dir="$(SCRIPT_DIR)/harnesses/pi/pi-extensions/subagents"; \
	if [ -f "$$subagents_ext_dir/package.json" ] && grep -q '"build"[[:space:]]*:' "$$subagents_ext_dir/package.json"; then \
		(cd "$$subagents_ext_dir" && mise exec -- npm run build) || { echo "subagents pre-build failed"; exit 1; }; \
	fi; \
	enforcement_ext_dir="$(SCRIPT_DIR)/harnesses/pi/pi-extensions/enforcement"; \
	if [ -f "$$enforcement_ext_dir/package.json" ] && grep -q '"build"[[:space:]]*:' "$$enforcement_ext_dir/package.json"; then \
		(cd "$$enforcement_ext_dir" && mise exec -- npm run build) || { echo "enforcement pre-build failed"; exit 1; }; \
	fi; \
	tmp_hooks=$$(mktemp); tmp_scaffold=$$(mktemp); tmp_install=$$(mktemp); \
	tmp_npm=$$(mktemp); tmp_subagents=$$(mktemp); \
	pids=(); labels=(); tmps=(); \
	{ ./harnesses/claude/hooks/run-tests.sh; } > "$$tmp_hooks" 2>&1 & pids+=($$!); labels+=(hooks); tmps+=("$$tmp_hooks"); \
	{ ./shared/scaffold/phoenix/run-tests.sh; } > "$$tmp_scaffold" 2>&1 & pids+=($$!); labels+=(scaffold-phoenix); tmps+=("$$tmp_scaffold"); \
	{ ./test_harness/install/run-tests.sh; } > "$$tmp_install" 2>&1 & pids+=($$!); labels+=(install); tmps+=("$$tmp_install"); \
	{ \
		fail=0; \
		for ext in enforcement askuserquestion subagents web-utils; do \
			ext_dir="$(SCRIPT_DIR)/harnesses/pi/pi-extensions/$$ext"; \
			if [ -f "$$ext_dir/package.json" ] && grep -q '"test"[[:space:]]*:' "$$ext_dir/package.json"; then \
				if [ "$$ext" != "subagents" ] && [ "$$ext" != "enforcement" ] && grep -q '"build"[[:space:]]*:' "$$ext_dir/package.json"; then \
					(cd "$$ext_dir" && mise exec -- npm run build) || fail=1; \
				fi; \
				if [ -n "$$VERBOSE" ]; then \
					echo "▶ Test: $$ext"; \
					(cd "$$ext_dir" && mise exec -- npm test) || fail=1; \
				else \
					out=$$(cd "$$ext_dir" && mise exec -- npm test 2>&1); rc=$$?; \
					if [ $$rc -ne 0 ]; then \
						echo "▶ Test: $$ext — FAILED"; \
						printf '%s\n' "$$out"; \
						fail=1; \
					fi; \
				fi; \
			fi; \
		done; \
		exit "$$fail"; \
	} > "$$tmp_npm" 2>&1 & pids+=($$!); labels+=(npm-ext); tmps+=("$$tmp_npm"); \
	{ \
		ext_dir="$(SCRIPT_DIR)/harnesses/pi/pi-extensions/subagents"; \
		if [ -d "$$ext_dir/test/integration" ] && [ -n "$$(ls "$$ext_dir/test/integration/"*.test.ts 2>/dev/null)" ]; then \
			if [ -n "$$VERBOSE" ]; then \
				echo "▶ Test:integration: subagents"; \
				(cd "$$ext_dir" && mise exec -- npm run test:integration) || exit 1; \
			else \
				out=$$(cd "$$ext_dir" && mise exec -- npm run test:integration 2>&1); rc=$$?; \
				if [ $$rc -ne 0 ]; then \
					echo "▶ Test:integration: subagents — FAILED"; \
					printf '%s\n' "$$out"; \
					exit 1; \
				fi; \
			fi; \
		fi; \
	} > "$$tmp_subagents" 2>&1 & pids+=($$!); labels+=(subagents-integration); tmps+=("$$tmp_subagents"); \
	fail=0; failed_labels=(); \
	for i in "$${!pids[@]}"; do \
		if ! wait "$${pids[$$i]}"; then \
			fail=1; \
			failed_labels+=("$${labels[$$i]}"); \
		fi; \
		cat "$${tmps[$$i]}"; \
	done; \
	if [ "$$fail" -eq 0 ]; then \
		echo "ALL CLEAR ✅ make test"; \
	else \
		bash_fails=$$(cat "$$tmp_hooks" "$$tmp_scaffold" "$$tmp_install" 2>/dev/null | grep -oE 'FAIL: [^ —]+' | sed 's/FAIL: //' | tr '\n' ',' | sed 's/,$$//' || true); \
		npm_fails=$$(cat "$$tmp_npm" "$$tmp_subagents" 2>/dev/null | grep -oE '▶ Test: [^ —]+' | sed 's/▶ Test: //' | tr '\n' ',' | sed 's/,$$//' || true); \
		all_fails="$$bash_fails"; \
		[ -n "$$npm_fails" ] && [ -n "$$all_fails" ] && all_fails="$$all_fails,$$npm_fails" || all_fails="$$all_fails$$npm_fails"; \
		joined=$$(printf '%s, ' "$${failed_labels[@]}"); joined=$${joined%, }; \
		if [ -n "$$all_fails" ]; then \
			echo "FAILED ❌ make test — $$joined ($$all_fails)"; \
		else \
			echo "FAILED ❌ make test — $$joined"; \
		fi; \
	fi; \
	rm -f "$$tmp_hooks" "$$tmp_scaffold" "$$tmp_install" "$$tmp_npm" "$$tmp_subagents"; \
	exit "$$fail"

# test-hermetic: fast, deterministic ExUnit tests — no LLM, no Playwright, no real server.
# Runs only tests NOT tagged :slow (excludes LLM-dependent scaffold/gate/seed/iteration tests).
.PHONY: test-hermetic
test-hermetic:
	@cd "$(SCRIPT_DIR)/test_harness" && \
	out=$$(MIX_BUILD_PATH=_build/claude_test mix test --exclude slow 2>&1); rc=$$?; \
	printf '%s\n' "$$out"; \
	if [ $$rc -eq 0 ]; then echo "ALL CLEAR ✅ make test-hermetic"; else echo "FAILED ❌ make test-hermetic"; fi; \
	exit $$rc

.PHONY: test-generator test-generator-python
test-generator: test-generator-python
	@bash "$(SCRIPT_DIR)/templates/generator/run-tests.sh"
test-generator-python:
	@fail=0; \
	out=$$(cd "$(SCRIPT_DIR)/templates/generator" && python3 -m unittest discover -s tests 2>&1); rc=$$?; [ $$rc -eq 0 ] || { printf '%s\n' "$$out"; fail=1; }; \
	out=$$(cd "$(SCRIPT_DIR)" && python3 -m unittest discover -s analysis/tests 2>&1); rc=$$?; [ $$rc -eq 0 ] || { printf '%s\n' "$$out"; fail=1; }; \
	exit $$fail

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
	@fail=0; \
	for ext in enforcement subagents askuserquestion web-utils; do \
		ext_dir="$(SCRIPT_DIR)/harnesses/pi/pi-extensions/$$ext"; \
		if [ -f "$$ext_dir/package.json" ] && grep -q '"test:coverage"' "$$ext_dir/package.json"; then \
			echo "▶ Coverage: $$ext"; \
			(cd "$$ext_dir" && mise exec -- npm run test:coverage) || { echo "⚠  $$ext: test:coverage failed"; fail=1; }; \
			mkdir -p "$(SCRIPT_DIR)/coverage/typescript/$$ext"; \
			[ -d "$$ext_dir/coverage" ] && cp -R "$$ext_dir/coverage/." "$(SCRIPT_DIR)/coverage/typescript/$$ext/"; \
		else \
			echo "⏭  Skip $$ext (no test:coverage script)"; \
		fi; \
	done; \
	exit "$$fail"

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
	@for ext in enforcement subagents askuserquestion web-utils; do \
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
# All 18 async modules run within a single BEAM via ExUnit's :max_cases default
# (System.schedulers_online * 2). No partition fanout needed.
#
# Benchmarking mode: set BENCH=1 REASON="<reason>" to capture per-test
# stream-json telemetry into codegen/benchmarks/<UTC-ts>/. BENCH unset
# (default) is byte-identical to pre-bench behaviour.
.PHONY: test-stacks test-stacks-claude test-stacks-pi test-stacks-claude-compile test-stacks-pi-compile test-all record-green test-harness-parity test-harness-parity-compile check-green-staleness
ifeq ($(BENCH),1)
test-stacks:
	$(MAKE) test-harness-parity
	$(eval BENCH_RUN_DIR := $(shell BENCH=1 REASON="$(REASON)" "$(SCRIPT_DIR)/test_harness/bench-prepare.sh"))
	$(MAKE) -j2 \
		BENCH_RUN_DIR="$(BENCH_RUN_DIR)" \
		test-stacks-claude \
		test-stacks-pi
else
test-stacks:
	$(MAKE) test-harness-parity
	$(MAKE) -j2 test-stacks-claude test-stacks-pi
endif

test-harness-parity-compile:
	cd "$(SCRIPT_DIR)/test_harness" && \
		MIX_BUILD_PATH=_build/parity_test mix compile

test-harness-parity: test-harness-parity-compile
	cd "$(SCRIPT_DIR)/test_harness" && \
		MIX_BUILD_PATH=_build/parity_test mix test --no-compile --only harness_parity

check-green-staleness:
	@JSON="$(SCRIPT_DIR)/test_harness/last_green.json"; \
	if [ ! -f "$$JSON" ]; then echo "check-green-staleness: last_green.json not found"; exit 1; fi; \
	TS="$$(jq -r '.test_passed_at' "$$JSON")"; \
	if [ -z "$$TS" ] || [ "$$TS" = "null" ]; then echo "check-green-staleness: test_passed_at missing in last_green.json"; exit 1; fi; \
	NOW_S="$$(date -u +%s 2>/dev/null)"; \
	THEN_S="$$(date -d "$$TS" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$$TS" +%s 2>/dev/null || echo "")"; \
	if [ -z "$$THEN_S" ]; then echo "check-green-staleness: could not parse timestamp $$TS"; exit 1; fi; \
	AGE_DAYS="$$(( (NOW_S - THEN_S) / 86400 ))"; \
	if [ "$$AGE_DAYS" -gt 7 ]; then \
		echo "check-green-staleness: last green is $$AGE_DAYS days old (>7) — run make test-stacks && make record-green"; \
		exit 1; \
	else \
		echo "check-green-staleness: OK — last green $$AGE_DAYS day(s) old ($$TS)"; \
	fi

test-stacks-claude: test-stacks-claude-compile
	cd "$(SCRIPT_DIR)/test_harness" && \
	  HARNESS=claude MIX_BUILD_PATH=_build/claude_test \
	  $(if $(BENCH_RUN_DIR),BENCH_RUN_DIR="$(BENCH_RUN_DIR)") \
	  mix test --no-compile --only slow

test-stacks-claude-compile:
	cd "$(SCRIPT_DIR)/test_harness" && \
		MIX_BUILD_PATH=_build/claude_test mix compile

test-stacks-pi: test-stacks-pi-compile
	cd "$(SCRIPT_DIR)/test_harness" && \
	  HARNESS=pi MIX_BUILD_PATH=_build/pi_test \
	  $(if $(BENCH_RUN_DIR),BENCH_RUN_DIR="$(BENCH_RUN_DIR)") \
	  mix test --no-compile --only slow

test-stacks-pi-compile:
	cd "$(SCRIPT_DIR)/test_harness" && \
		MIX_BUILD_PATH=_build/pi_test mix compile

# bench: full benchmarking run + markdown summary.
# Requires REASON. Creates codegen/benchmarks/<UTC-ts>/, runs both harness
# stack suites under that dir (real LLM, slow, costs tokens), then writes
# <run-dir>/summary.md aggregating all per-test harness_summary JSONL records.
.PHONY: bench
bench:
	@if [ -z "$(REASON)" ]; then \
		echo "❌ REASON is required. Usage: make bench REASON=\"your reason\""; \
		exit 1; \
	fi
	$(eval BENCH_RUN_DIR := $(shell BENCH=1 REASON="$(REASON)" "$(SCRIPT_DIR)/test_harness/bench-prepare.sh"))
	@if [ -z "$(BENCH_RUN_DIR)" ] || [ ! -d "$(BENCH_RUN_DIR)" ]; then \
		echo "❌ bench-prepare.sh did not produce a run dir"; \
		exit 1; \
	fi
	@echo "▶ bench run dir: $(BENCH_RUN_DIR)"
	$(MAKE) -j2 \
		BENCH_RUN_DIR="$(BENCH_RUN_DIR)" \
		test-stacks-claude \
		test-stacks-pi; \
	BENCH_EXIT=$$?; \
	node "$(SCRIPT_DIR)/test_harness/bench/summarize.js" "$(BENCH_RUN_DIR)" > /dev/null; \
	cat "$(BENCH_RUN_DIR)/summary-short.txt"; \
	echo ""; \
	echo "✅ summary: $(BENCH_RUN_DIR)/summary.md"; \
	-cd "$(SCRIPT_DIR)/test_harness" && mix codegen.bench.check-regression --run "$(BENCH_RUN_DIR)" || true; \
	exit $$BENCH_EXIT

# test-all: full pre-deploy gate. Chains hook tests + stack tests, then
# writes last_green.json. Only the all-green path overwrites last_green.json.
test-all: test test-stacks record-green

record-green:
	@"$(SCRIPT_DIR)/test_harness/record-green.sh"

# harness-path-check: post-install agent path sanity check, NOT a content-parity gate.
# Verifies baked agent files do not reference stale harness paths (grep-only; does not
# re-render or diff template content — that is covered by `make rule-render-freshness`).
harness-path-check:
	@AGENTS_DIR="$(HOME)/.claude/agents"; \
	if [ -d "$$AGENTS_DIR" ]; then \
		if grep -rl "templates/shared/claude-\|templates/shared/pi-" "$$AGENTS_DIR" 2>/dev/null | grep -q .; then \
			echo "harness-path-check: ERROR — generated agent files reference old templates/shared/claude-* or pi-* paths"; \
			grep -rl "templates/shared/claude-\|templates/shared/pi-" "$$AGENTS_DIR" 2>/dev/null; \
			exit 1; \
		fi; \
		echo "harness-path-check: OK — no stale harness paths in baked agents [checked: $$AGENTS_DIR]"; \
	else \
		echo "harness-path-check: FAIL — $$AGENTS_DIR not found (run make install first)"; \
		exit 1; \
	fi

# rule-render-freshness: verify committed shared/apps/*.md match a fresh render.
# Catches the case where a rule file or template was edited without re-running make install.
.PHONY: rule-render-freshness
rule-render-freshness:
	@echo "--- rule-render-freshness: checking committed apps docs match fresh render ---"; \
	tmp=$$(mktemp -d); \
	trap 'rm -rf "$$tmp"' EXIT; \
	cp -R shared "$$tmp/shared"; \
	for base in AGENTS-phoenix AGENTS-static; do \
		variant=$${base#AGENTS-}; \
		CODEGEN_DIR="$$PWD" python3 templates/generator/process_template.py "shared/apps/$$base.md.j2" pi false > "$$tmp/shared/apps/$$base.md"; \
		CODEGEN_DIR="$$PWD" python3 templates/generator/process_template.py "shared/apps/$$base.md.j2" claude false > "$$tmp/shared/apps/CLAUDE-$$variant.md"; \
	done; \
	node node_modules/prettier/bin/prettier.cjs -w --log-level error "$$tmp/shared"; \
	fail=0; \
	for f in CLAUDE-phoenix CLAUDE-static AGENTS-phoenix AGENTS-static; do \
		if ! diff -q "$$tmp/shared/apps/$$f.md" "shared/apps/$$f.md" >/dev/null 2>&1; then \
			echo "rule-render-freshness: STALE — shared/apps/$$f.md does not match a fresh render. A rule or template changed without re-render. Run 'make install' and commit the regenerated shared/apps/*.md."; \
			fail=1; \
		fi; \
	done; \
	if [ "$$fail" = "0" ]; then echo "rule-render-freshness: OK — all apps docs match fresh render"; fi; \
	exit "$$fail"

# show-failures: pretty-print the durable agent tool-failure store.
.PHONY: show-failures
show-failures:
	@bash -c 'source "$(SCRIPT_DIR)/harnesses/claude/hooks/lib/hooks-lib.sh"; read_tool_failures "$(SCRIPT_DIR)"'

# show-verdicts: pretty-print the durable gate-verdict history.
.PHONY: show-verdicts
show-verdicts:
	@bash -c 'source "$(SCRIPT_DIR)/harnesses/claude/hooks/lib/hooks-lib.sh"; read_gate_verdicts "$(SCRIPT_DIR)"'

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
	if command -v yq >/dev/null 2>&1; then \
		if yq --version 2>&1 | grep -qi mikefarah; then \
			echo "OK: yq on PATH (mikefarah/yq)"; \
		else \
			echo "FAIL: yq on PATH but is NOT mikefarah/yq (apt python-yq is incompatible) — install from https://github.com/mikefarah/yq"; \
			fails=$$((fails + 1)); \
		fi; \
	else \
		echo "FAIL: yq not on PATH (brew install yq / https://github.com/mikefarah/yq)"; \
		fails=$$((fails + 1)); \
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
	if command -v node >/dev/null 2>&1 && node --version >/dev/null 2>&1; then \
		echo "OK: node on PATH"; \
	else \
		echo "FAIL: node not on PATH (install via mise: mise install node)"; fails=$$((fails + 1)); \
	fi; \
	if command -v pi >/dev/null 2>&1; then \
		echo "OK: pi on PATH"; \
	else \
		echo "FAIL: pi not on PATH (npm install -g @earendil-works/pi-coding-agent)"; fails=$$((fails + 1)); \
	fi; \
	if command -v git >/dev/null 2>&1; then \
		echo "OK: git on PATH"; \
	else \
		echo "FAIL: git not on PATH (install git)"; fails=$$((fails + 1)); \
	fi; \
	case ":$$PATH:" in \
		*":$$HOME/.local/bin:"*) echo "OK: ~/.local/bin on PATH" ;; \
		*) echo "FAIL: ~/.local/bin not on PATH (add to shell profile: export PATH=\"\$$HOME/.local/bin:\$$PATH\")"; fails=$$((fails + 1)) ;; \
	esac; \
	if [ -d "$(SCRIPT_DIR)/node_modules/ajv" ]; then \
		echo "OK: ajv node_modules present"; \
	else \
		echo "FAIL: ajv not in codegen node_modules (run: npm install in codegen root)"; fails=$$((fails + 1)); \
	fi; \
	if node -e "const pw = require('$(SCRIPT_DIR)/node_modules/playwright'); const p = pw.chromium.executablePath(); const fs = require('fs'); if (!fs.existsSync(p)) { process.exit(1); }" >/dev/null 2>&1; then \
		echo "OK: Chromium binary present (playwright)"; \
	else \
		echo "FAIL: Chromium binary not found — run: cd $(SCRIPT_DIR) && npx playwright install chromium"; fails=$$((fails + 1)); \
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
	@echo "  make bench REASON=  Run benchmark stacks + write summary.md (real LLM, slow)"
	@echo "  make test-all       Full pre-deploy gate: test + test-stacks + record-green"
	@echo "  make record-green   Write test_harness/last_green.json with current sha + versions"
	@echo "  make hook-parity    Verify hook registrations match claude-code-settings.json"
	@echo "  make harness-path-check     Grep baked agents for stale harness-relative paths"
	@echo "  make rule-render-freshness  Verify committed apps docs match a fresh render"
	@echo "  make show-failures  Pretty-print durable agent tool-failure store"
	@echo "  make show-verdicts  Pretty-print durable gate-verdict history"
	@echo "  make format         Format all shell scripts and files"
	@echo "  make doctor         Check required tools and config"
	@echo "  make uninstall      Remove global CLI installation (via ocg)"
	@echo "  make update         Update all AI agents (via ocg)"
	@echo "  make help           Show this help"
	@echo ""
	@echo "PATH binaries (no make target):"
	@echo "  codegen-analyze     Scan Claude sessions for agent turn-waste; ranked report (--since, --json, --window, --threshold-reread, --project-dir)"
	@echo "  codegen-propose     Turn codegen-analyze clusters into human-gated proposed-change records (--since, --max, --min-wasted-turns, --model)"

.PHONY: diagnose-pi-all diagnose-pi-phoenix-scaffold diagnose-pi-phoenix-gate diagnose-pi-phoenix-committer diagnose-pi-phoenix-iteration diagnose-pi-phoenix-seed diagnose-pi-static-iteration-vanilla diagnose-pi-static-iteration-react diagnose-pi-static-iteration-vue diagnose-pi-static-iteration-multilingual

diagnose-pi-phoenix-scaffold:
	mkdir -p test_harness/_diagnostics
	cd test_harness && \
	  HARNESS=pi KEEP_TMP=1 \
	  DIAGNOSTICS_FILE="$(SCRIPT_DIR)/test_harness/_diagnostics/phoenix-scaffold-pi-{N}.jsonl" \
	  mix test test/stacks/phoenix/scaffold_test.exs --only slow || true

diagnose-pi-phoenix-gate:
	mkdir -p test_harness/_diagnostics
	cd test_harness && \
	  HARNESS=pi KEEP_TMP=1 \
	  DIAGNOSTICS_FILE="$(SCRIPT_DIR)/test_harness/_diagnostics/phoenix-gate-pi-{N}.jsonl" \
	  mix test test/stacks/phoenix/gate_test.exs --only slow || true

diagnose-pi-phoenix-committer:
	mkdir -p test_harness/_diagnostics
	cd test_harness && \
	  HARNESS=pi KEEP_TMP=1 \
	  DIAGNOSTICS_FILE="$(SCRIPT_DIR)/test_harness/_diagnostics/phoenix-committer-pi-{N}.jsonl" \
	  mix test test/stacks/phoenix/committer_test.exs --only slow || true

diagnose-pi-phoenix-iteration:
	mkdir -p test_harness/_diagnostics
	cd test_harness && \
	  HARNESS=pi KEEP_TMP=1 \
	  DIAGNOSTICS_FILE="$(SCRIPT_DIR)/test_harness/_diagnostics/phoenix-iteration-pi-{N}.jsonl" \
	  mix test test/stacks/phoenix/iteration_test.exs --only slow || true

diagnose-pi-phoenix-seed:
	mkdir -p test_harness/_diagnostics
	cd test_harness && \
	  HARNESS=pi KEEP_TMP=1 \
	  DIAGNOSTICS_FILE="$(SCRIPT_DIR)/test_harness/_diagnostics/phoenix-seed-pi-{N}.jsonl" \
	  mix test test/stacks/phoenix/seed_test.exs --only slow || true

diagnose-pi-static-iteration-vanilla:
	mkdir -p test_harness/_diagnostics
	cd test_harness && \
	  HARNESS=pi KEEP_TMP=1 \
	  DIAGNOSTICS_FILE="$(SCRIPT_DIR)/test_harness/_diagnostics/static-iteration-vanilla-pi-{N}.jsonl" \
	  mix test test/stacks/static/iteration_test.exs --only slow || true

diagnose-pi-static-iteration-react:
	mkdir -p test_harness/_diagnostics
	cd test_harness && \
	  HARNESS=pi KEEP_TMP=1 \
	  DIAGNOSTICS_FILE="$(SCRIPT_DIR)/test_harness/_diagnostics/static-iteration-react-pi-{N}.jsonl" \
	  mix test test/stacks/static/iteration_test.exs --only slow || true

diagnose-pi-static-iteration-vue:
	mkdir -p test_harness/_diagnostics
	cd test_harness && \
	  HARNESS=pi KEEP_TMP=1 \
	  DIAGNOSTICS_FILE="$(SCRIPT_DIR)/test_harness/_diagnostics/static-iteration-vue-pi-{N}.jsonl" \
	  mix test test/stacks/static/iteration_test.exs --only slow || true

diagnose-pi-static-iteration-multilingual:
	mkdir -p test_harness/_diagnostics
	cd test_harness && \
	  HARNESS=pi KEEP_TMP=1 \
	  DIAGNOSTICS_FILE="$(SCRIPT_DIR)/test_harness/_diagnostics/static-iteration-multilingual-pi-{N}.jsonl" \
	  mix test test/stacks/static/iteration_test.exs --only slow || true

diagnose-pi-all: diagnose-pi-phoenix-scaffold diagnose-pi-phoenix-gate diagnose-pi-phoenix-committer diagnose-pi-phoenix-iteration diagnose-pi-phoenix-seed diagnose-pi-static-iteration-vanilla diagnose-pi-static-iteration-react diagnose-pi-static-iteration-vue diagnose-pi-static-iteration-multilingual

# Default target shows help
.DEFAULT_GOAL := help

# Prevent make from treating arguments as targets
%:
	@:
