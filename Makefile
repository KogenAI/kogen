.PHONY: check live

# Offline surface. No provider request is ever made here. When invoked from
# inside the fake lifecycle test's nested clone, KOGEN_INNER_CHECK=1 skips
# the lifecycle test itself so the nested hook's own `make check` cannot
# recurse into another lifecycle run.
check:
	mix format --check-formatted
	mix compile --warnings-as-errors --force
	mix credo --strict
	@if [ -n "$$KOGEN_INNER_CHECK" ]; then \
		mix test --exclude live --exclude lifecycle ; \
	else \
		mix test --exclude live ; \
	fi

# The identical lifecycle assertions against real Codex CLI. Not part of
# `make check`; run explicitly, from a trusted checkout.
live:
	mix test --only live
