import csv,datetime,io,json,re,sys
from pathlib import Path
def read(path):
 raw=Path(path).read_bytes()
 if len(raw)>1024:raise ValueError("input too large")
 rows=list(csv.reader(io.StringIO(raw.decode("utf-8-sig"),newline="")))
 if not rows or rows[0]!=["date","value"]:raise ValueError("header")
 if not 1<=len(rows)-1<=10:raise ValueError("row count")
 for row in rows[1:]:
  if len(row)!=2:raise ValueError("width")
  if not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}",row[0]):raise ValueError("date syntax")
  datetime.date.fromisoformat(row[0])
  if not re.fullmatch(r"-?[0-9]+",row[1]):raise ValueError("integer")
 return rows
if __name__=="__main__":
 try:print(json.dumps(read(sys.argv[1])))
 except (OSError,ValueError,csv.Error) as e:print(str(e),file=sys.stderr);raise SystemExit(2)
