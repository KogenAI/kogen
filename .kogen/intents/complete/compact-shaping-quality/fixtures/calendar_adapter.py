import json,sys
from pathlib import Path
def slots(path):
 data=json.loads(Path(path).read_text())
 if not isinstance(data,dict) or not isinstance(data.get("scopes"),list) or not all(isinstance(x,str) for x in data["scopes"]):raise ValueError("malformed connection")
 if data.get("organizer")!="org-1" or "availability.read" not in data.get("scopes",[]):raise ValueError("unavailable: reconnect or contact operator")
 result=data.get("slots")
 if not isinstance(result,list) or any(not isinstance(x,list) or len(x)!=2 or not all(isinstance(y,str) for y in x) for x in result):raise ValueError("malformed slots")
 return result
if __name__=="__main__":
 try:print(json.dumps(slots(sys.argv[1])))
 except (OSError,ValueError,TypeError,AttributeError) as e:print("unavailable: reconnect or contact operator: "+str(e),file=sys.stderr);raise SystemExit(2)
