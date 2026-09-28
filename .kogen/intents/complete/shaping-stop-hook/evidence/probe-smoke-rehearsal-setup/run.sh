#!/bin/sh
# Rebuilds four variants of test/support/shaping_evaluation from a HEAD (dece3e84) extract in ./head and runs
# driver_smoke_rehearsal_test.py in each, with KOGEN_ROLE and KOGEN_HARNESS_HOME unset. ./new holds the final
# variant (driver.diff + rehearsal.diff applied); the two intermediate variants are derived from it.
set -u
P=$(cd "$(dirname "$0")" && pwd)
T=test/support/shaping_evaluation
run() { (cd "$1" && env -u KOGEN_ROLE -u KOGEN_HARNESS_HOME python3 -B $T/driver_smoke_rehearsal_test.py -v 2>&1 |
  grep -E '\.\.\. |^Ran |^OK|^FAILED|^RuntimeError|AssertionError: 0 != 1'); }
rm -rf "$P/v-oldsetup" "$P/v-noignore"
mkdir -p "$P/v-oldsetup/$T" "$P/v-noignore/$T" "$P/v-oldsetup/.kogen" "$P/v-noignore/.kogen"
for v in v-oldsetup v-noignore; do cp "$P/head/.kogen/config.yaml" "$P/$v/.kogen/"; cp "$P/new/$T"/* "$P/$v/$T/" 2>/dev/null; cp -R "$P/head/$T/replay" "$P/head/$T/compact-fixtures-v2" "$P/$v/$T/"; done
# v-oldsetup: new driver.py + new tests, but HEAD's setUp (codex-fake without auditor/helpers, no runtime ignore)
python3 - "$P/v-oldsetup/$T/driver_smoke_rehearsal_test.py" <<'PY'
import sys; p=sys.argv[1]; s=open(p).read()
for line in ['            "    auditor:   {model: fake-model, effort: high}\\n"\n','            "    helpers:\\n"\n',
             '            "      scout:  {model: fake-model, effort: low}\\n"\n','            "      worker: {model: fake-model, effort: high}\\n"\n']:
    assert s.count(line)==1; s=s.replace(line,'')
a='            "      expert: {model: fake-model, effort: high}\\n")'; assert s.count(a)==1
s=s.replace('{model: fake-model, effort: medium}\\n"\n'+a, '{model: fake-model, effort: medium}\\n")')
a='.kogen/intents/drafts/\\n.kogen/runtime/\\n'; assert s.count(a)==1; s=s.replace(a,'.kogen/intents/drafts/\\n')
open(p,'w').write(s)
PY
# v-noignore: new setUp route lines, but .gitignore without .kogen/runtime/
python3 - "$P/v-noignore/$T/driver_smoke_rehearsal_test.py" <<'PY'
import sys; p=sys.argv[1]; s=open(p).read()
a='.kogen/intents/drafts/\\n.kogen/runtime/\\n'; assert s.count(a)==1; s=s.replace(a,'.kogen/intents/drafts/\\n')
open(p,'w').write(s)
PY
echo "== 1. HEAD dece3e84 as is"; run "$P/head"
echo "== 2. new pinned_smoke_config + K1/K3, HEAD's setUp"; run "$P/v-oldsetup"
echo "== 3. new pinned_smoke_config + K1/K3 + setUp route lines, no .kogen/runtime/ ignore"; run "$P/v-noignore"
echo "== 4. new pinned_smoke_config + K1/K3 + setUp route lines + .kogen/runtime/ ignore (the Draft)"; run "$P/new"
echo "== 4, three more runs"; for i in 1 2 3; do run "$P/new" | tail -1; done
