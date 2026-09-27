exec(open("map.py").read().split("def block")[0].replace("for name,focus in","for name,focus in []:#"))
def rank2(focus, it=100, dang_on=True):
  p={f:(1/len(focus) if f in focus else 0.0) for f in files}; r=dict(p)
  for _ in range(it):
    dang=sum(r[d] for d in files if W[d]==0) if dang_on else 0
    r={v:0.15*p[v]+0.85*(sum(r[u]*w.get((u,v),0)/W[u] for u in files if W[u]>0)+p[v]*dang) for v in files}
  return r
for name,focus in [("uniform",files),("focus test/shop_test.exs",["test/shop_test.exs"])]:
  r=rank2(focus); print(name); [print("  %-24s %.15f"%(f,r[f])) for f in files]; print("  sum %.15f"%sum(r.values()))
  nd=rank2(focus,dang_on=False); print("  no-dangling tax %.15f"%nd["lib/shop/tax.ex"])
  c=rank2(focus,it=200); print("  200-iter max diff %.3e"%max(abs(c[f]-r[f]) for f in files))
