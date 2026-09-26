# Do all test-reliability declarations resolve to a real `test "..."` in their file?
import json, re, sys, collections
from pathlib import Path
root = Path(sys.argv[1])
cat = json.loads((root/"priv/kogen/test-reliability.yaml").read_text())
rows = cat["declarations"]
names = {}
for p in root.glob("test/**/*_test.exs"):
    rel = str(p.relative_to(root))
    names[rel] = re.findall(r'\btest\s+"([^"]+)"', p.read_text())
kinds = collections.Counter(); unresolved = []
for r in rows:
    f = r["file"]
    if not f.endswith("_test.exs"):
        kinds["non-exunit file"] += 1; unresolved.append(("non-exunit", r["id"], f)); continue
    if f not in names:
        kinds["missing file"] += 1; unresolved.append(("missing", r["id"], f)); continue
    if r["declaration"] in names[f]: kinds["resolved"] += 1
    else: kinds["unresolved"] += 1; unresolved.append(("unresolved", r["id"], r["declaration"]))
dups = [k for k,v in collections.Counter((r["file"], r["declaration"]) for r in rows).items() if v>1]
print("rows", len(rows), dict(kinds), "duplicate (file,declaration):", len(dups))
for u in unresolved[:15]: print(u)
cataloged_files = {r["file"] for r in rows}
all_tests = sum(len(v) for v in names.values())
print("test files", len(names), "cataloged files", len(cataloged_files), "total tests", all_tests)
