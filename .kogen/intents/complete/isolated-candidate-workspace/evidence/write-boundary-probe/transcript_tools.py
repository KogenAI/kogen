import json,sys
for path in sys.argv[1:]:
    print("==",path.split('/')[-1])
    for line in open(path):
        try: e=json.loads(line)
        except: continue
        m=e.get("message") or {}
        c=m.get("content")
        if isinstance(c,list):
            for part in c:
                if part.get("type")=="tool_use":
                    print("USE", part.get("name"), json.dumps(part.get("input"))[:200])
                elif part.get("type")=="tool_result":
                    cc=part.get("content")
                    txt=cc if isinstance(cc,str) else " ".join(x.get("text","") for x in (cc or []) if isinstance(x,dict))
                    print("RES", ("ERR " if part.get("is_error") else "")+txt.replace("\n"," | ")[:240])
