import csv,json,sys
from pathlib import Path
with Path(sys.argv[1]).open(encoding="utf-8",newline="") as f: rows=list(csv.reader(f))
print(json.dumps(rows))
