.PHONY: check live

# Complete offline gate. The normal Stop hook owns invoking this target.
check:
	/usr/bin/time -p python3 scripts/check/offline.py

# Outer-owned real-provider lifecycle and cold-cache offline acceptance.
live:
	mix test --only live
