exec(open("map.py").read().split("W={u")[0])
def run(focus, variant):
  ww = {k:(1 if variant=="unweighted" else v) for k,v in w.items()}
  W={u:sum(v for (a,b),v in ww.items() if a==u) for u in files}
  p={f:(1/len(focus) if f in focus else 0.0) for f in files}
  r={f:1/len(files) for f in files} if variant=="uniform_start" else dict(p)
  for _ in range(100):
    dang=sum(r[d] for d in files if W[d]==0)
    tele = {v:(1/len(files)) for v in files} if variant=="uniform_dangling" else p
    if variant=="no_dangling": dang=0
    r={v:0.15*p[v]+0.85*(sum(r[u]*ww.get((u,v),0)/W[u] for u in files if W[u]>0)+tele[v]*dang) for v in files}
  if variant=="refcount":
    r={v:sum(c for (a,b),c in w.items() if b==v) for v in files}
  return [f.split("/")[-1] for f in sorted(files,key=lambda f:(-r[f],f))]
focuses={"all":files,"test":["test/shop_test.exs"],"lib/shop/":[f for f in files if f.startswith("lib/shop/")],"shop.ex":["lib/shop.ex"]}
for v in ["right","unweighted","uniform_start","uniform_dangling","no_dangling","refcount"]:
  print(v,{k:run(f,v) for k,f in focuses.items()})
