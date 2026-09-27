| # | label | source | choice | P(product_ux) | ok@argmax |
|---|---|---|---|---|---|
| 0 | P | named-routes | product_ux | 0.94 | yes |
| 1 | P | named-routes | technical | 0.46 | NO |
| 2 | P | claude-code-harness | product_ux | 0.86 | yes |
| 3 | P | claude-code-harness | product_ux | 0.59 | yes |
| 4 | P | claude-code-harness | product_ux | 0.89 | yes |
| 5 | P | claude-code-harness | product_ux | 0.99 | yes |
| 6 | P | shaping-preflight-audit Q1 | product_ux | 0.95 | yes |
| 7 | P | shaping-preflight-audit Q2 | product_ux | 0.91 | yes |
| 8 | P | DIRECTION D1 | product_ux | 1.00 | yes |
| 9 | P | written | product_ux | 0.98 | yes |
| 10 | P | written | product_ux | 0.94 | yes |
| 11 | P | written | product_ux | 1.00 | yes |
| 12 | P | written | product_ux | 1.00 | yes |
| 13 | P | written | product_ux | 0.99 | yes |
| 14 | P | written | product_ux | 0.99 | yes |
| 15 | T | named-routes | technical | 0.22 | yes |
| 16 | T | named-routes | technical | 0.46 | yes |
| 17 | T | shaping-preflight-audit Q6 | technical | 0.01 | yes |
| 18 | T | shaping-preflight-audit Q7 | technical | 0.09 | yes |
| 19 | T | shaping-preflight-audit Q8 | technical | 0.41 | yes |
| 20 | T | adversarial-shaping-auditor Q6 | product_ux | 0.51 | NO |
| 21 | T | adversarial-shaping-auditor Q5 | technical | 0.35 | yes |
| 22 | T | shaping-audit-jev | technical | 0.00 | yes |
| 23 | T | sol 3b #2 | technical | 0.14 | yes |
| 24 | T | sol 3b #5 | technical | 0.03 | yes |
| 25 | T | sol 3b #6 | technical | 0.02 | yes |
| 26 | T | sol 3b #7 | technical | 0.02 | yes |
| 27 | T | sol 3b #9 | product_ux | 0.59 | NO |
| 28 | T | sol 3b #1 | technical | 0.15 | yes |
| 29 | T | sol 3a | technical | 0.00 | yes |
| 30 | T | sol 3a | technical | 0.00 | yes |
| 31 | T | astra 3a #2 | technical | 0.30 | yes |
| 32 | T | written | technical | 0.14 | yes |
| 33 | T | written | technical | 0.01 | yes |
| 34 | T | written | technical | 0.22 | yes |

gate product_ux >= 0.5: product recall 14/15, technical routed to Shaper 2/20

gate product_ux >= 0.6: product recall 13/15, technical routed to Shaper 0/20

gate product_ux >= 0.7: product recall 13/15, technical routed to Shaper 0/20

gate product_ux >= 0.8: product recall 13/15, technical routed to Shaper 0/20
