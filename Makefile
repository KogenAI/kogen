# Optimum Codegen
# Usage: make [command]

SCRIPT_DIR := $(shell dirname $(realpath $(firstword $(MAKEFILE_LIST))))
SHELL := bash

# Helper functions for command restrictions
define check_ocg_only
	@if [ "$$OCG_CLI" != "true" ]; then \
		echo "❌ The $(1) command only works with 'ocg $(1)'"; \
		echo "   Please use 'ocg $(1)' instead of 'make $(1)'"; \
		exit 1; \
	fi
endef



.PHONY: hook-parity
hook-parity:
	@pf=$$(mktemp); \
	trap 'rm -f "$$pf"' EXIT; \
	out=$$(cd "$(SCRIPT_DIR)/templates" && python3 generator/hook_registrations.py \
		--hooks-dir ../harnesses/claude/hooks \
		--output-settings "$$pf" \
		--existing-settings "$(SCRIPT_DIR)/harnesses/claude/claude-code-settings.json" 2>&1); \
	rc=$$?; [ -n "$$VERBOSE" ] && printf '%s\n' "$$out"; \
	[ $$rc -eq 0 ] || { [ -z "$$VERBOSE" ] && printf '%s\n' "$$out"; exit $$rc; }; \
	diff -u "$(SCRIPT_DIR)/harnesses/claude/claude-code-settings.json" "$$pf" || exit 1; \
	[ -z "$$VERBOSE" ] || echo "hook-parity: PASS"

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
		--bash-out "$(SCRIPT_DIR)/harnesses/claude/hooks"
	@bash "$(SCRIPT_DIR)/templates/generator/orphan-hook-check.sh" \
		--hooks-dir "$(SCRIPT_DIR)/harnesses/claude/hooks" \
		--registry "$(SCRIPT_DIR)/shared/enforcement/registry.yaml" \
		--prune
	@python3 "$(SCRIPT_DIR)/templates/generator/hook_registrations.py" \
		--hooks-dir "$(SCRIPT_DIR)/harnesses/claude/hooks" \
		--registry "$(SCRIPT_DIR)/shared/enforcement/registry.yaml" \
		--emit-headers
	@$(MAKE) hook-parity
	@python3 "$(SCRIPT_DIR)/templates/generator/hook_registrations.py" \
		--hooks-dir "$(SCRIPT_DIR)/harnesses/claude/hooks" \
		--output-settings "$(SCRIPT_DIR)/harnesses/claude/claude-code-settings.json"
	@./install.sh

# harness-parity: verify codegen-build + dispatch.sh stubs are self-consistent.
# Runs the codegen-build_test.sh script in isolation.
# enforce-registry-parity: compile to /tmp and diff all generated files vs committed.
# Exits non-zero if any generated file differs from what is committed.
.PHONY: enforce-registry-parity
enforce-registry-parity:
	@t_bash=$$(mktemp -d); \
	trap 'rm -rf "$$t_bash"' EXIT; \
	python3 "$(SCRIPT_DIR)/templates/generator/enforcement_compiler.py" \
		--registry "$(SCRIPT_DIR)/shared/enforcement/registry.yaml" \
		--bash-out "$$t_bash" > /dev/null 2>&1; \
	fail=0; \
	for f in "$$t_bash"/*.sh; do \
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
	bash "$(SCRIPT_DIR)/templates/generator/orphan-hook-check.sh" \
		--hooks-dir "$(SCRIPT_DIR)/harnesses/claude/hooks" \
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
	@bad=""; \
	for s in "$(SCRIPT_DIR)/codegen-build" "$(SCRIPT_DIR)/codegen-call" \
		"$(SCRIPT_DIR)/codegen-propose" "$(SCRIPT_DIR)/codegen-log" \
		"$(SCRIPT_DIR)/codegen-commit" \
		"$(SCRIPT_DIR)/harnesses/claude/dispatch.sh" \
		"$(SCRIPT_DIR)/shared/scaffold/static/scaffold.sh"; do \
		[ -f "$$s" ] || continue; \
		bash -n "$$s" 2>/dev/null || bad="$$bad $$s"; \
	done; \
	if [ -n "$$bad" ]; then \
		echo "harness-parity: ABORTED — script(s) under test do not parse:$$bad"; \
		for s in $$bad; do bash -n "$$s" 2>&1 | sed 's/^/  /'; done; \
		echo "harness-parity: every assertion below would have failed for this one reason — fix the syntax error first (see also: make shell-syntax)."; \
		exit 1; \
	fi
	@t_out=$$(mktemp -d); \
	t_in=$$(mktemp); \
	trap 'rm -rf "$$t_out"; rm -f "$$t_in"' EXIT; \
	{ \
		printf '%s\0' \
			"$(SCRIPT_DIR)/harnesses/claude/hooks/codegen-build_test.sh" \
			"$(SCRIPT_DIR)/harnesses/claude/hooks/codegen-call_test.sh" \
			"$(SCRIPT_DIR)/harnesses/claude/hooks/codegen-propose_test.sh" \
			"$(SCRIPT_DIR)/harnesses/claude/hooks/codegen-commit_test.sh" \
			"$(SCRIPT_DIR)/shared/scaffold/static/scaffold_test.sh" \
			"$(SCRIPT_DIR)/codegen-log_test.sh"; \
		for st in "$(SCRIPT_DIR)/harnesses/shared/"*_test.sh; do \
			[ -e "$$st" ] && printf '%s\0' "$$st"; \
		done; \
	} >"$$t_in"; \
	if [ ! -s "$$t_in" ]; then \
		xargs_rc=0; \
	else \
		xargs -0 -n1 -P8 bash -c ' \
			t="$$0"; \
			name=$$(basename "$$t"); \
			out=$$(bash "$$t" 2>&1); rc=$$?; \
			printf "%s\n" "$$out" >"'"$$t_out"'/$$name.out"; \
			echo "$$rc" >"'"$$t_out"'/$$name.rc"; \
		' <"$$t_in"; \
		xargs_rc=$$?; \
	fi; \
	echo "$$xargs_rc" >"$$t_out/.xargs_rc"; \
	rm -f "$$t_in"; \
	fail=0; \
	xargs_rc=$$(cat "$$t_out/.xargs_rc" 2>/dev/null || echo 0); \
	if [ "$$xargs_rc" != "0" ]; then \
		echo "harness-parity: FAIL — xargs infrastructure exited $$xargs_rc"; \
		fail=1; \
	fi; \
	for rc_file in "$$t_out"/*.rc; do \
		[ -e "$$rc_file" ] || continue; \
		name=$${rc_file%.rc}; name=$$(basename "$$name"); \
		rc=$$(cat "$$rc_file"); \
		if [ -n "$$VERBOSE" ]; then cat "$$t_out/$$name.out"; fi; \
		if [ "$$rc" != "0" ]; then \
			[ -z "$$VERBOSE" ] && cat "$$t_out/$$name.out"; \
			echo "harness-parity: FAIL — $$name"; \
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

.PHONY: ci
ci: test

# test: run every PreToolUse/SubagentStop/Stop hook unit-test script in parallel,
# plus every gate check, in ONE pass — not fail-fast. All 11 former prereq
# checks (hook-parity, hook-header-parity, harness-parity, test-generator,
# enforce-registry-parity, enforce-hook-rationale, test-hermetic,
# prompt-content-parity, rule-render-freshness,
# usage-rules-index-parity) run as backgrounded `$(MAKE)` stages alongside the
# existing hooks/scaffold/install/npm stages, so a single `make test` surfaces
# every independent failure at once instead of stopping at the first failing
# prereq.
# Each *_test.sh is hermetic — own tmp dirs, no shared state — so xargs -P is safe.
# Job count caps at 8 to avoid thrashing on smaller machines.
# Post-deps stages (hook-tests, phoenix scaffold, test_harness/install, npm) run
# concurrently via & + wait to reduce wall time.
# One-owner execution: five hook tests owned by harness-parity/prompt-content-parity/
# are excluded from the backgrounded hooks-arm run (see
# run-all-tests.sh HOOK_DEDUP_EXCLUDE) so each discovered hook test runs exactly
# once per `make test`. Standalone `bash harnesses/claude/hooks/run-tests.sh`
# still runs the full population.
.PHONY: test
test:
	@bash "$(SCRIPT_DIR)/templates/generator/run-all-tests.sh"

# test-hermetic: fast, deterministic ExUnit tests — no LLM, no Playwright, no real server.
# Runs only tests NOT tagged :slow (excludes LLM-dependent scaffold/gate/seed/iteration tests).
.PHONY: test-hermetic
test-hermetic:
	@cd "$(SCRIPT_DIR)/test_harness" && \
	out=$$(MIX_BUILD_PATH=_build/claude_test mix test --exclude slow --max-cases $${EXUNIT_MAX_CASES:-24} 2>&1); rc=$$?; \
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
	@echo "test-coverage-typescript: no TypeScript packages in this repo — nothing to do"

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
	@for ext in enforcement subagents askuserquestion web-utils pitch-files; do \
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
.PHONY: test-stacks test-stacks-claude test-stacks-claude-compile test-all record-green check-green-staleness
ifeq ($(BENCH),1)
test-stacks:
	$(eval BENCH_RUN_DIR := $(shell BENCH=1 REASON="$(REASON)" "$(SCRIPT_DIR)/test_harness/bench-prepare.sh"))
	$(MAKE) \
		BENCH_RUN_DIR="$(BENCH_RUN_DIR)" \
		test-stacks-claude
else
test-stacks:
	$(MAKE) test-stacks-claude
endif

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

# MIX_ENV=test is load-bearing, not decoration. MIX_BUILD_PATH suppresses
# Mix's per-environment subdirectory, so `_build/claude_test` is ONE physical
# directory shared by every invocation that names it. Compiling it in dev
# (the default) made every alternation with `make test`/`mix test --only slow`
# a full 26-file purge-and-recompile of that root — and a purge landing under
# a concurrently running BEAM is exactly the `UndefinedFunctionError: module
# ... is not available` this repo already documents (context/development.md
# § Mix build-path assignment). It also meant `test-stacks-claude` below ran
# `mix test --no-compile` (test env) against dev-compiled beams.
# One build root, one MIX_ENV — enforced by `make mix-build-path-parity`.
test-stacks-claude-compile:
	cd "$(SCRIPT_DIR)/test_harness" && \
		MIX_ENV=test MIX_BUILD_PATH=_build/claude_test mix compile

# bench-preflight: spend-free bench-path validity gate. Runs ONLY offline,
# zero-model checks — never invoke mix codegen.loop, bare codegen-build (no
# --print-argv), make bench, or BENCH=1 in this recipe. The "no model turn"
# property is structural: every command below either reads Mix task metadata,
# dry-run-validates codegen-build flags (exits before exec, never mutates the
# target cwd), or reads git status. This is the zero-cost predictor for the
# turn-0 aborts a paid `make bench` would otherwise discover after spending:
# an unresolvable bench Mix task name, an invalid codegen-build flag for any
# harness×stack pair make bench drives, or a dirty tree.
.PHONY: bench-preflight
bench-preflight:
	@set +e; \
	fails=0; \
	echo "🚦 Running bench-preflight (spend-free, no LLM)..."; \
	echo ""; \
	echo "--- (a) bench Mix task name resolution ---"; \
	for t in codegen.bench.check_regression codegen.bench.view codegen.bench.list; do \
		if (cd "$(SCRIPT_DIR)/test_harness" && MIX_BUILD_PATH=_build/bench_preflight mix help "$$t" >/dev/null 2>&1); then \
			echo "OK: mix help $$t resolves"; \
		else \
			echo "FAIL: mix task $$t does not resolve (mix help $$t)"; fails=$$((fails + 1)); \
		fi; \
	done; \
	echo ""; \
	echo "--- (b) codegen-build --print-argv flag validation ---"; \
	_tmp=$$(mktemp -d); \
	for h in claude; do \
		for s in phoenix static; do \
			if "$(SCRIPT_DIR)/codegen-build" --print-argv --harness=$$h --stack=$$s --cwd="$$_tmp" >/dev/null 2>&1; then \
				echo "OK: codegen-build --print-argv --harness=$$h --stack=$$s"; \
			else \
				echo "FAIL: codegen-build --print-argv rejected --harness=$$h --stack=$$s"; fails=$$((fails + 1)); \
			fi; \
		done; \
	done; \
	rm -rf "$$_tmp"; \
	echo ""; \
	echo "--- (c) clean tree ---"; \
	dirty=$$(git -C "$(SCRIPT_DIR)" status --porcelain); \
	if [ -z "$$dirty" ]; then \
		echo "OK: working tree clean"; \
	else \
		echo "FAIL: working tree dirty — bench aborts at turn 0"; \
		echo "$$dirty"; fails=$$((fails + 1)); \
	fi; \
	echo ""; \
	if [ $$fails -eq 0 ]; then \
		echo "✅ bench-preflight: bench path is runnable"; \
		exit 0; \
	else \
		echo "❌ bench-preflight: $$fails check(s) failed"; \
		exit 1; \
	fi

# bench: full benchmarking run + markdown summary.
# Requires REASON. Creates codegen/benchmarks/<UTC-ts>/, runs both harness
# stack suites under that dir (real LLM, slow, costs tokens), then writes
# <run-dir>/summary.md aggregating all per-test harness_summary JSONL records.
#
# After the summary, runs `mix codegen.bench.check_regression` against
# perf_baseline.json — NOT a soft/informational-only check: a pass_rate drop
# below its declared min_abs is always a hard failure (`make bench` exits
# non-zero). max_regression_pct metrics (turns/cost/duration/tokens) stay
# informational-only unless BENCH_STRICT=1 is passed, since most of those
# baselines are still 0 (unpopulated) and skipped entirely regardless.
# `make bench BENCH_STRICT=1 REASON="..."` promotes every populated metric
# to a hard failure once you trust the baseline enough to gate on it.
.PHONY: bench
bench:
	@$(MAKE) --no-print-directory bench-preflight
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
	$(MAKE) \
		BENCH_RUN_DIR="$(BENCH_RUN_DIR)" \
		test-stacks-claude; \
	BENCH_EXIT=$$?; \
	node "$(SCRIPT_DIR)/test_harness/bench/summarize.js" "$(BENCH_RUN_DIR)" > /dev/null; \
	cat "$(BENCH_RUN_DIR)/summary-short.txt"; \
	echo ""; \
	echo "✅ summary: $(BENCH_RUN_DIR)/summary.md"; \
	cd "$(SCRIPT_DIR)/test_harness" && mix codegen.bench.check_regression --run "$(BENCH_RUN_DIR)" $(if $(BENCH_STRICT),--strict,); \
	CHECK_EXIT=$$?; \
	if [ $$BENCH_EXIT -ne 0 ]; then exit $$BENCH_EXIT; fi; \
	exit $$CHECK_EXIT

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
		if grep -rl "templates/shared/claude-" "$$AGENTS_DIR" 2>/dev/null | grep -q .; then \
			echo "harness-path-check: ERROR — generated agent files reference old templates/shared/claude-* paths"; \
			grep -rl "templates/shared/claude-" "$$AGENTS_DIR" 2>/dev/null; \
			exit 1; \
		fi; \
		echo "harness-path-check: OK — no stale harness paths in baked agents [checked: $$AGENTS_DIR]"; \
	else \
		echo "harness-path-check: FAIL — $$AGENTS_DIR not found (run make install first)"; \
		exit 1; \
	fi

# rule-render-freshness: verify committed shared/apps/*.md match a fresh render.
# Catches the case where a rule file or template was edited without re-running make install.
# --ignore-path /dev/null on the prettier pass below is required: mktemp's dir has no
# .gitignore of its own, and prettier's markdown printer silently stops backslash-escaping
# literal `*`/backtick-fence characters when it cannot resolve one starting from the target
# path — producing a false STALE verdict against committed content that used the (correct)
# escaped form. Forcing an empty ignore-path keeps prettier's output identical regardless of
# where the tmp copy lives.
# rule-render-freshness now runs alone in run-all-tests.sh's serial isolation
# tail (after the broad parallel fan-out fully joins), so the CPU-starved
# concurrency that motivated a retry-on-STALE no longer occurs. A first-pass
# mismatch is authoritative.
.PHONY: rule-render-freshness
rule-render-freshness:
	@echo "--- rule-render-freshness: checking committed apps docs match fresh render ---"; \
	tmp=$$(mktemp -d); \
	trap 'rm -rf "$$tmp"' EXIT; \
	cp -R shared "$$tmp/shared"; \
	for base in AGENTS-phoenix AGENTS-static; do \
		variant=$${base#AGENTS-}; \
		CODEGEN_DIR="$$PWD" python3 templates/generator/process_template.py "shared/apps/$$base.md.j2" agents false > "$$tmp/shared/apps/$$base.md"; \
		CODEGEN_DIR="$$PWD" python3 templates/generator/process_template.py "shared/apps/$$base.md.j2" claude false > "$$tmp/shared/apps/CLAUDE-$$variant.md"; \
	done; \
	node node_modules/prettier/bin/prettier.cjs -w --log-level error --ignore-path /dev/null "$$tmp/shared"; \
	fail=0; \
	for f in CLAUDE-phoenix CLAUDE-static AGENTS-phoenix AGENTS-static; do \
		if ! diff -q "$$tmp/shared/apps/$$f.md" "shared/apps/$$f.md" >/dev/null 2>&1; then \
			echo "rule-render-freshness: STALE — shared/apps/$$f.md does not match a fresh render. A rule or template changed without re-render. Run 'make install' and commit the regenerated shared/apps/*.md."; \
			fail=1; \
		fi; \
	done; \
	if [ "$$fail" = "0" ]; then echo "rule-render-freshness: OK — all apps docs match fresh render"; fi; \
	exit "$$fail"

# usage-rules-index-parity: verify shared/usage_rules/INDEX.md matches a fresh
# regeneration from the corpus on disk (max version per already-tracked dep).
# Fails loud, naming the stale dep(s), so INDEX.md can never silently drift
# behind the corpus again (see regenerate_usage_rules_index.py docstring).
.PHONY: usage-rules-index-parity
usage-rules-index-parity:
	@python3 "$(SCRIPT_DIR)/templates/generator/regenerate_usage_rules_index.py" \
		--usage-rules-dir "$(SCRIPT_DIR)/shared/usage_rules" --check; rc=$$?; \
	if [ $$rc -eq 0 ] && [ -n "$$VERBOSE" ]; then echo "usage-rules-index-parity: PASS"; fi; \
	exit $$rc

# pitch-scope-parity: fail-closed gate over codegen/pitches/ready/ — every
# pitch promoted to ready/ must declare a scope: frontmatter field. Reuses
# the mix codegen.pitches.scope report; --check exits non-zero when any
# ready/ pitch is UNROUTED (no scope: field), naming the slug(s). See
# context/pitch-writing-guide.md.
.PHONY: pitch-scope-parity
pitch-scope-parity:
	@cd "$(SCRIPT_DIR)/test_harness" && MIX_BUILD_PATH=_build/pitch_scope_parity mix codegen.pitches.scope --check --dir=ready --cwd=..; rc=$$?; \
	if [ $$rc -eq 0 ] && [ -n "$$VERBOSE" ]; then echo "pitch-scope-parity: PASS"; fi; \
	exit $$rc

# prompt-size-budget: fail-closed gate on the prompt attention surface — rule
# files under shared/rules/{_core,roles,stacks}/ and rendered agent system
# prompts must not exceed their committed ceiling in
# templates/generator/prompt-budgets.txt. Growth past the ceiling is a red
# gate, not silent drift; raising a budget is a reviewable diff (re-run with
# --write). See prompt_size_budget.py docstring.
.PHONY: prompt-size-budget
prompt-size-budget:
	@python3 "$(SCRIPT_DIR)/templates/generator/prompt_size_budget.py" --check; rc=$$?; \
	if [ $$rc -eq 0 ] && [ -n "$$VERBOSE" ]; then echo "prompt-size-budget: PASS"; fi; \
	exit $$rc

# context-index-parity: fail-closed gate over the repo's OWN context docs.
# Two legs, both run, both reported (never fail-fast on the first):
#   1. context_index_sync.py --check — the PROJECT_CONTEXT.md "Load when
#      prompt mentions..." column is GENERATED from each context/*.md
#      § Trigger Keywords section. Drift here is fixed by `make
#      context-index-sync`, never by hand-editing the index.
#   2. context-index-parity-scan.sh — the same scan the build-time curator
#      gate runs (coverage, phantom rows, missing Trigger Keywords sections,
#      non-.md clutter), pointed at THIS repo. It used to run only against
#      test fixtures, so repo-level drift blocked every build while `make ci`
#      stayed green. A gate that blocks builds must be visible to CI.
.PHONY: context-index-parity
context-index-parity:
	@fail=0; \
	out=$$(python3 "$(SCRIPT_DIR)/templates/generator/context_index_sync.py" \
		--repo-root "$(SCRIPT_DIR)" --check 2>&1) || fail=1; \
	[ -z "$$out" ] || printf '%s\n' "$$out"; \
	out=$$(bash "$(SCRIPT_DIR)/harnesses/claude/hooks/lib/context-index-parity-scan.sh" \
		"$(SCRIPT_DIR)" 2>&1) || fail=1; \
	[ -z "$$out" ] || printf '%s\n' "$$out"; \
	if [ $$fail -eq 0 ] && [ -n "$$VERBOSE" ]; then echo "context-index-parity: PASS"; fi; \
	exit $$fail

# context-index-sync: regenerate the index's trigger column from the context
# files. This is the remedy for a red context-index-parity — it needs no
# judgement, which is the whole point of deriving the column instead of
# maintaining a second copy of it by hand.
.PHONY: context-index-sync
context-index-sync:
	@python3 "$(SCRIPT_DIR)/templates/generator/context_index_sync.py" \
		--repo-root "$(SCRIPT_DIR)" --write

# shell-syntax: every tracked shell script parses (`bash -n`, `zsh -n` for
# zsh). Its own stage, deliberately: an unparseable script does not fail once
# — `codegen-build` with a missing `fi` produced thirteen red assertions in
# codegen-build_test.sh, none of which said "syntax error". Reported here, the
# cause is one line with the parser's own line number. See the script header.
.PHONY: shell-syntax
shell-syntax:
	@out=$$(bash "$(SCRIPT_DIR)/templates/generator/shell-syntax-check.sh" "$(SCRIPT_DIR)" 2>&1); rc=$$?; \
	if [ -n "$$VERBOSE" ] || [ $$rc -ne 0 ]; then [ -z "$$out" ] || printf '%s\n' "$$out"; fi; \
	exit $$rc

# mix-build-path-parity: one Mix build root, one MIX_ENV. MIX_BUILD_PATH has
# no per-environment subdirectory, so two invocations naming the same root
# under different environments purge and recompile each other — the documented
# `UndefinedFunctionError: module ... is not available` hazard. Derives the
# root -> env map from the sources instead of trusting the prose table in
# context/development.md § Mix build-path assignment.
.PHONY: mix-build-path-parity
mix-build-path-parity:
	@out=$$(bash "$(SCRIPT_DIR)/templates/generator/mix-build-path-parity.sh" "$(SCRIPT_DIR)" 2>&1); rc=$$?; \
	if [ -n "$$VERBOSE" ] || [ $$rc -ne 0 ]; then [ -z "$$out" ] || printf '%s\n' "$$out"; fi; \
	exit $$rc

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
	@bash "$(SCRIPT_DIR)/harnesses/shared/repo-format.sh"
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

.PHONY: build-ready
build-ready:
	@set +e; \
	fails=0; \
	echo "🚦 Running OCG build-ready preflight..."; \
	echo ""; \
	echo "--- (a) required binaries ---"; \
	$(MAKE) --no-print-directory doctor; \
	if [ $$? -ne 0 ]; then fails=$$((fails + 1)); fi; \
	echo ""; \
	echo "--- (b) installed harness currency ---"; \
	source "$(SCRIPT_DIR)/harnesses/shared/build-ready-currency.sh"; \
	check_install_currency "$(SCRIPT_DIR)" "$$HOME/.local/bin/.ocg-install-stamp"; \
	if [ $$? -ne 0 ]; then fails=$$((fails + 1)); fi; \
	echo ""; \
	echo "--- (c) make test (deterministic, no LLM) ---"; \
	$(MAKE) --no-print-directory test; \
	if [ $$? -ne 0 ]; then echo "FAIL: make test"; fails=$$((fails + 1)); fi; \
	echo ""; \
	if [ $$fails -eq 0 ]; then \
		echo "✅ build-ready: box is build-ready"; \
		exit 0; \
	else \
		echo "❌ build-ready: $$fails check(s) failed"; \
		echo "build-ready: RED — drain dispatch refused. Fix the above, re-run 'ocg build-ready'."; \
		exit 2; \
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
	@echo "  make test-stacks    Run ExUnit stack scaffold tests (real LLM, slow)"
	@echo "  make bench REASON=  Run benchmark stacks + write summary.md (real LLM, slow)"
	@echo "  make bench-preflight  Spend-free bench-path validity check (no LLM)"
	@echo "  make test-all       Full pre-deploy gate: test + test-stacks + record-green"
	@echo "  make record-green   Write test_harness/last_green.json with current sha + versions"
	@echo "  make hook-parity    Verify hook registrations match claude-code-settings.json"
	@echo "  make harness-path-check     Grep baked agents for stale harness-relative paths"
	@echo "  make rule-render-freshness  Verify committed apps docs match a fresh render"
	@echo "  make prompt-size-budget    Verify rule/agent-prompt sizes within committed ceiling"
	@echo "  make show-failures  Pretty-print durable agent tool-failure store"
	@echo "  make show-verdicts  Pretty-print durable gate-verdict history"
	@echo "  make format         Format all shell scripts and files"
	@echo "  make doctor         Check required tools and config"
	@echo "  make build-ready    Preflight gate: doctor + install currency + make test (refuses drain dispatch on red)"
	@echo "  make uninstall      Remove global CLI installation (via ocg)"
	@echo "  make update         Update all AI agents (via ocg)"
	@echo "  make help           Show this help"
	@echo ""
	@echo "PATH binaries (no make target):"
	@echo "  codegen-analyze     Scan Claude sessions for agent turn-waste; ranked report (--since, --json, --window, --threshold-reread, --project-dir)"
	@echo "  codegen-propose     Turn codegen-analyze clusters into human-gated proposed-change records (--since, --max, --min-wasted-turns, --model)"

# Default target shows help
.DEFAULT_GOAL := help

# Prevent make from treating arguments as targets
%:
	@:
