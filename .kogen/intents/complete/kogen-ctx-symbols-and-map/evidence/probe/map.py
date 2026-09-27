import math
files=["lib/shop.ex","lib/shop/cart.ex","lib/shop/format.ex","lib/shop/inventory.ex","lib/shop/pricing.ex","lib/shop/tax.ex","test/shop_test.exs"]
w={("lib/shop.ex","lib/shop/cart.ex"):2,("lib/shop.ex","lib/shop/pricing.ex"):2,("lib/shop.ex","lib/shop/tax.ex"):2,("lib/shop.ex","lib/shop/inventory.ex"):2,("lib/shop.ex","lib/shop/format.ex"):1,("lib/shop/inventory.ex","lib/shop/tax.ex"):1,("test/shop_test.exs","lib/shop/cart.ex"):2}
syms={
"lib/shop/tax.ex":["defmodule Shop.Tax","def Shop.Tax.add/1","def Shop.Tax.rate/0"],
"lib/shop/cart.ex":["defmodule Shop.Cart","def Shop.Cart.total/1","def Shop.Cart.total/2","def Shop.Cart.empty/0","def Shop.Cart.merge/2"],
"lib/shop/inventory.ex":["defmodule Shop.Inventory","def Shop.Inventory.put/2","def Shop.Inventory.lookup/1","def Shop.Inventory.fetcher/0"],
"lib/shop/pricing.ex":["defmodule Shop.Pricing","def Shop.Pricing.apply/2","defmodule Shop.Pricing.Rules","def Shop.Pricing.Rules.default/0","def Shop.Pricing.rules/0"],
"lib/shop/format.ex":["defmodule Shop.Format","def Shop.Format.money/1"],
"lib/shop.ex":["defmodule Shop","def Shop.checkout/2","def Shop.restock/1","defmacro Shop.trace/1","defguard Shop.positive/1"],
"test/shop_test.exs":["defmodule ShopTest"]}
W={u:sum(v for (a,b),v in w.items() if a==u) for u in files}
def rank(focus):
  p={f:(1/len(focus) if f in focus else 0.0) for f in files}
  r=dict(p)
  for _ in range(100):
    dang=sum(r[d] for d in files if W[d]==0)
    r={v:0.15*p[v]+0.85*(sum(r[u]*w.get((u,v),0)/W[u] for u in files if W[u]>0)+p[v]*dang) for v in files}
  return sorted(files,key=lambda f:(-r[f],f)),r
def block(f): return f+"\n"+"".join("  "+s+"\n" for s in syms[f])
for name,focus in [("all",files),("test",["test/shop_test.exs"]),("lib/shop/",[f for f in files if f.startswith("lib/shop/")])]:
  order,r=rank(focus); print(name,[(f,repr(r[f])) for f in order])
order,_=rank(files)
out="";tot=0
for f in order:
  b=block(f); print(f,len(b.encode()),math.ceil(len(b.encode())/4)); tot+=len(b.encode())
print("total bytes",tot,math.ceil(tot/4))
open("map-all.txt","w").write("".join(block(f) for f in order))
