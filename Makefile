SHELL := /bin/sh
.SHELLFLAGS := -eu -c
MAKEFLAGS += -j
M := mise exec --
KOGEN_PLT_DIR ?= $(HOME)/.kogen/plt
export KOGEN_PLT_DIR

TEST_ENV = GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME='Kogen Test' GIT_AUTHOR_EMAIL=test@kogen.invalid GIT_COMMITTER_NAME='Kogen Test' GIT_COMMITTER_EMAIL=test@kogen.invalid TZ=Europe/Sarajevo LC_ALL=C

.PHONY: check check-fast fix guard fmt compile-dev compile-test xref credo test kogen-checks-test dialyzer

check:
	+$(MAKE) --no-print-directory guard fmt compile-dev compile-test xref credo test dialyzer
	@echo "check OK"

guard:
	$(M) mix kogen.guard

fmt:
	$(M) mix format --check-formatted

compile-dev:
	$(M) mix compile --force --warnings-as-errors

compile-test:
	$(M) mix compile --force --warnings-as-errors

compile-test test: export MIX_ENV = test
compile-test test: export GIT_CONFIG_GLOBAL = /dev/null
compile-test test: export GIT_CONFIG_NOSYSTEM = 1
compile-test test: export GIT_AUTHOR_NAME = Kogen Test
compile-test test: export GIT_AUTHOR_EMAIL = test@kogen.invalid
compile-test test: export GIT_COMMITTER_NAME = Kogen Test
compile-test test: export GIT_COMMITTER_EMAIL = test@kogen.invalid
compile-test test: export TZ = Europe/Sarajevo
compile-test test: export LC_ALL = C

xref: compile-dev
	$(M) mix xref graph --format cycles --label compile-connected --fail-above 0

credo: compile-dev
	$(M) mix credo --strict

test: compile-test kogen-checks-test
	$(TEST_ENV) MIX_ENV=test $(M) mix test --warnings-as-errors --no-compile

kogen-checks-test: compile-test
	$(TEST_ENV) MIX_ENV=test $(M) mix test --warnings-as-errors --no-compile tools/kogen_checks/test

dialyzer: compile-dev
	mkdir -p "$(KOGEN_PLT_DIR)"
	$(M) mix dialyzer --quiet-with-result

check-fast:
	@if [ -z "$(D)" ]; then echo "usage: make check-fast D=<domain>" >&2; exit 2; fi
	+$(MAKE) --no-print-directory fmt compile-dev compile-test
	$(M) mix credo --strict lib/kogen/$(D).ex
	$(M) mix credo --strict lib/kogen/$(D)
	@test_files=$$(find "test/$(D)" -type f -name '*_test.exs' -print -quit 2>/dev/null); if [ -n "$$test_files" ]; then $(M) mix credo --strict test/$(D); else echo "No tests for $(D) yet"; fi
	@test_files=$$(find "test/$(D)" -type f -name '*_test.exs' -print -quit 2>/dev/null); if [ -n "$$test_files" ]; then $(TEST_ENV) MIX_ENV=test $(M) mix test --warnings-as-errors --no-compile test/$(D); else echo "No tests for $(D) yet"; fi

fix:
	$(M) mix format --force
