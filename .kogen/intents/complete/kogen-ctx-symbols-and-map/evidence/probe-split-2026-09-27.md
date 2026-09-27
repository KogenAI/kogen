# Split probes for kogen-ctx-symbols-and-map (2026-09-27, Mac Studio, shaping)

These probes ran outside the repository, in the shaping scratchpad (`probe/split/`), with the pinned crate set:
`evidence/cargo` of kogen-ctx-index-and-search, `mise exec rust@1.97.1 -- cargo build --release --locked --offline
--target-dir <scratch>`. No global mise, rustup or cargo state was changed, and CARGO_HOME was never set.

## S1. Reference extractor (`probe/reference-extractor.rs`)

This is a ~120-line tree-sitter walk that implements INTENT.md's symbol, ref and alias rules literally:

- qualified nested modules;
- a `when` head unwrapped;
- arity as written;
- the first clause per `{kind, name}`;
- alias, import, use and require refs, `A.{B, C}` expanded;
- the pipe right operand +1;
- `&M.f/N` as a capture;
- `__MODULE__`;
- aliases collected anywhere in a module body except nested modules' bodies, plus nested `defmodule` first
  segments;
- inner scopes shadow outer ones;
- there is no table of names.

Its output sorts symbols by (path, line, name) and refs by (path, line, kind, target):

- `probe/reference-extractor-shop.txt`: the seven `evidence/fixture/` files. **Every symbols/refs expected output of
  kogen-ctx-tool's scenario 4 (which Opus hand-verified) is reproduced**, including the counts behind
  `Shop --limit 1` → `... 25 more` (26 symbols contain `Shop`) and `Shop.Cart --limit 2` → `... 3 more` (5 refs).
- `probe/reference-extractor-alias.txt`: the three `evidence/alias-fixture/` files, which use names that appear
  nowhere in the shop fixture. They cover:
  - an alias used before it is written (line 2 of billing.ex);
  - `as:`;
  - `A.{B, C}`;
  - a nested module's first segment used in the parent (`Invoice.build`);
  - an enclosing module's alias used in a nested module (`Row.new` in `Invoice`);
  - a two-step pipe;
  - a capture;
  - an unaliased reference in another module that stays as written (`Row.new/1` in `Acme.Report`);
  - a default-argument call in a head;
  - a function-level alias applying to the whole module (the documented approximation, line 11);
  - an inner module's `as:` shadowing it.

  These outputs are the expected outputs of scenario `aliases-resolve-by-scope-not-by-name`.
- `probe/tree-sitter-sexp-alias.txt`: all three alias-fixture files parse with `has_error=false`.
- The rule change made while probing: the first version skipped function heads and collected only top-level
  aliases. The final version walks heads and collects function-level aliases, and its output on the shop fixture is
  byte-identical to the first version's.

## S2. PageRank (`probe/map.py`, `probe/variants.py`, `probe/ranks.py`)

- `map.py` implements INTENT.md's formula (start at p, exactly 100 iterations, dangling mass redistributed by p,
  ties by path) over the shop fixture's edges. It reproduces kogen-ctx-tool's scenario 5 orders for `map`,
  `--focus test/shop_test.exs` and `--focus lib/shop/`. It also gives the block byte sizes: tax 80, cart 135,
  inventory 137, pricing 165, format 69, lib/shop.ex 123, test 40; 749 in total (188 tokens).
  `probe/map-default-expected.txt` is the complete expected stdout of `map`.
- `--tokens 25` → the tax block (20 tokens), then `... 6 more files`. `--tokens 64` → tax + cart (215 bytes,
  54 tokens), then `... 5 more files`: adding inventory would make 88 tokens. A skip-and-continue implementation
  would wrongly add `test/shop_test.exs` (255 bytes, 64 tokens). `--tokens 10` → no block, then `... 7 more files`.
- `variants.py`: the file order alone does not detect every wrong formula on this fixture:
  - dropping the dangling mass and starting from uniform give the same orders;
  - unweighted edges change the `map` order (format before inventory), so H1 catches them;
  - uniform dangling redistribution changes the `--focus test/shop_test.exs` order, so H3 catches it;
  - reference-count order changes every order.

  So the scenario adds a Rust unit test on the rank values.
- `ranks.py` (output `probe/ranks-output.txt`), the rank values after exactly 100 iterations:
  - uniform: lib/shop.ex 0.102980719720808, cart 0.209966245208536, format 0.112706676583328, inventory
    0.122432633445849, pricing 0.122432633445849, tax 0.226500371874821, test 0.102980719720808;
  - focus test/shop_test.exs: cart 0.459459419267445, test 0.540540580732555, all others 0.

  Without dangling redistribution, the uniform tax value is 0.047130952380952. After 200 iterations, the focus case
  moves by 4.0e-8 (it converges to 17/37 and 20/37), so a 1e-12 tolerance pins the iteration count.
