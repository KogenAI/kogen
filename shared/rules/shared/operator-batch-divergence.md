# Operator vs Batch Divergence Intentional

Different exec modes (interactive vs CI, operator vs batch) → different output format, persistence, hardening flags. Don't unify these.

Unify _shared config_ only: model, tools, base prompt.

❌ Force single launcher path
✅ Two launchers, one config block
