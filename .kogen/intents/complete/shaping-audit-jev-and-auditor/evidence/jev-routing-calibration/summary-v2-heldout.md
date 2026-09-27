| # | label | source | choice | P(product_ux) | ok@argmax |
|---|---|---|---|---|---|
| 0 | P | held-out | product_ux | 1.00 | yes |
| 1 | P | held-out | product_ux | 1.00 | yes |
| 2 | P | held-out | product_ux | 1.00 | yes |
| 3 | P | held-out | product_ux | 0.99 | yes |
| 4 | P | held-out | technical | 0.17 | NO |
| 5 | P | held-out | product_ux | 1.00 | yes |
| 6 | T | held-out | technical | 0.01 | yes |
| 7 | T | held-out | technical | 0.06 | yes |
| 8 | T | held-out | technical | 0.00 | yes |
| 9 | T | held-out | technical | 0.01 | yes |
| 10 | T | held-out | technical | 0.01 | yes |
| 11 | T | held-out | technical | 0.01 | yes |

gate product_ux >= 0.5: product recall 5/6, technical routed to Shaper 0/6

gate product_ux >= 0.6: product recall 5/6, technical routed to Shaper 0/6

gate product_ux >= 0.7: product recall 5/6, technical routed to Shaper 0/6

gate product_ux >= 0.8: product recall 5/6, technical routed to Shaper 0/6
