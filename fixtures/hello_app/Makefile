M := mise exec --


.PHONY: check

check:
	$(M) mix format --check-formatted
	$(M) mix compile --warnings-as-errors
	$(M) mix test --warnings-as-errors
