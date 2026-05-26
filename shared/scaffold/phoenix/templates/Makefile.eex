ci:
	MIX_ENV=test mix compile
	mix ci
	MIX_ENV=test mix ecto.rollback --all --quiet
