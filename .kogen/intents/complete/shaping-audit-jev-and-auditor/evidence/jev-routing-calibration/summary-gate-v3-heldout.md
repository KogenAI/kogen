| # | label | choice | P(prod) | P(settled) | by | by_p |
|---|---|---|---|---|---|---|
| 0 | P | product_ux | 0.97 | 0.01 | none | 1.00 |
| 1 | P | product_ux | 0.69 | 0.30 | shp-wait-only-product | 0.43 |
| 2 | P | product_ux | 0.90 | 0.07 | none | 0.96 |
| 3 | P | product_ux | 0.87 | 0.09 | none | 0.80 |
| 4 | P | already_settled | 0.09 | 0.85 | shp-auditor-profile | 0.96 |
| 5 | P | product_ux | 0.94 | 0.05 | none | 0.83 |
| 6 | P | already_settled | 0.30 | 0.69 | dir-1.17 | 0.98 |
| 7 | P | already_settled | 0.42 | 0.43 | shp-one-build | 0.65 |
| 8 | T | technical | 0.02 | 0.24 | none | 0.44 |
| 9 | T | technical | 0.01 | 0.01 | none | 0.99 |
| 10 | T | technical | 0.01 | 0.03 | none | 0.98 |
| 11 | T | technical | 0.05 | 0.03 | none | 1.00 |
| 12 | T | technical | 0.01 | 0.21 | shp-one-build | 0.57 |
| 13 | T | technical | 0.02 | 0.01 | none | 1.00 |
| 14 | T | technical | 0.07 | 0.08 | none | 0.97 |
| 15 | T | technical | 0.03 | 0.04 | none | 0.98 |
| 16 | S:dir-1.16 | already_settled | 0.00 | 0.96 | dir-1.16 | 0.99 |
| 17 | S:dir-1.13 | already_settled | 0.13 | 0.87 | dir-1.13 | 0.75 |
| 18 | S:dir-1.17 | already_settled | 0.16 | 0.84 | shp-one-build | 0.73 |
| 19 | S:shp-auditor-profile | already_settled | 0.03 | 0.96 | shp-auditor-profile | 0.97 |
| 20 | S:dir-1.15 | technical | 0.15 | 0.23 | none | 0.56 |
| 21 | S:shp-wait-only-product | already_settled | 0.03 | 0.96 | shp-wait-only-product | 0.93 |

product>=0.5 settled>=0.6 by>=0.6: {'P->shaper': 5, 'P': 8, 'T->shaper': 0, 'T': 8, 'S->cited_ok': 4, 'S->shaper': 0, 'S': 6, 'wrong_cite': 3}

product>=0.5 settled>=0.6 by>=0.8: {'P->shaper': 5, 'P': 8, 'T->shaper': 0, 'T': 8, 'S->cited_ok': 3, 'S->shaper': 0, 'S': 6, 'wrong_cite': 2}

product>=0.5 settled>=0.8 by>=0.6: {'P->shaper': 5, 'P': 8, 'T->shaper': 0, 'T': 8, 'S->cited_ok': 4, 'S->shaper': 0, 'S': 6, 'wrong_cite': 2}

product>=0.5 settled>=0.8 by>=0.8: {'P->shaper': 5, 'P': 8, 'T->shaper': 0, 'T': 8, 'S->cited_ok': 3, 'S->shaper': 0, 'S': 6, 'wrong_cite': 1}

product>=0.6 settled>=0.6 by>=0.6: {'P->shaper': 5, 'P': 8, 'T->shaper': 0, 'T': 8, 'S->cited_ok': 4, 'S->shaper': 0, 'S': 6, 'wrong_cite': 3}

product>=0.6 settled>=0.6 by>=0.8: {'P->shaper': 5, 'P': 8, 'T->shaper': 0, 'T': 8, 'S->cited_ok': 3, 'S->shaper': 0, 'S': 6, 'wrong_cite': 2}

product>=0.6 settled>=0.8 by>=0.6: {'P->shaper': 5, 'P': 8, 'T->shaper': 0, 'T': 8, 'S->cited_ok': 4, 'S->shaper': 0, 'S': 6, 'wrong_cite': 2}

product>=0.6 settled>=0.8 by>=0.8: {'P->shaper': 5, 'P': 8, 'T->shaper': 0, 'T': 8, 'S->cited_ok': 3, 'S->shaper': 0, 'S': 6, 'wrong_cite': 1}
