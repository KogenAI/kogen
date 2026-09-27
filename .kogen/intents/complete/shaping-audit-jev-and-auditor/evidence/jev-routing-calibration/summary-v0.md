| # | label | source | choice | P(product_ux) | ok@argmax |
|---|---|---|---|---|---|
| 0 | P | named-routes | product_ux | 0.85 | yes |
| 1 | P | named-routes | technical | 0.28 | NO |
| 2 | P | claude-code-harness | technical | 0.19 | NO |
| 3 | P | claude-code-harness | product_ux | 0.55 | yes |
| 4 | P | claude-code-harness | product_ux | 0.86 | yes |
| 5 | P | claude-code-harness | product_ux | 0.58 | yes |
| 6 | P | shaping-preflight-audit Q1 | product_ux | 0.70 | yes |
| 7 | P | shaping-preflight-audit Q2 | product_ux | 0.99 | yes |
| 8 | P | DIRECTION D1 | product_ux | 1.00 | yes |
| 9 | P | written | product_ux | 0.91 | yes |
| 10 | P | written | product_ux | 0.73 | yes |
| 11 | P | written | product_ux | 1.00 | yes |
| 12 | P | written | product_ux | 1.00 | yes |
| 13 | P | written | product_ux | 0.97 | yes |
| 14 | P | written | product_ux | 0.93 | yes |
| 15 | T | named-routes | technical | 0.05 | yes |
| 16 | T | named-routes | technical | 0.46 | yes |
| 17 | T | shaping-preflight-audit Q6 | technical | 0.01 | yes |
| 18 | T | shaping-preflight-audit Q7 | technical | 0.03 | yes |
| 19 | T | shaping-preflight-audit Q8 | product_ux | 0.55 | NO |
| 20 | T | adversarial-shaping-auditor Q6 | product_ux | 0.57 | NO |
| 21 | T | adversarial-shaping-auditor Q5 | technical | 0.12 | yes |
| 22 | T | shaping-audit-jev | technical | 0.01 | yes |
| 23 | T | sol 3b #2 | technical | 0.20 | yes |
| 24 | T | sol 3b #5 | technical | 0.03 | yes |
| 25 | T | sol 3b #6 | technical | 0.07 | yes |
| 26 | T | sol 3b #7 | technical | 0.03 | yes |
| 27 | T | sol 3b #9 | product_ux | 0.79 | NO |
| 28 | T | sol 3b #1 | product_ux | 0.97 | NO |
| 29 | T | sol 3a | technical | 0.00 | yes |
| 30 | T | sol 3a | technical | 0.00 | yes |
| 31 | T | astra 3a #2 | product_ux | 0.88 | NO |
| 32 | T | written | technical | 0.13 | yes |
| 33 | T | written | technical | 0.01 | yes |
| 34 | T | written | technical | 0.13 | yes |

gate product_ux >= 0.5: product recall 13/15, technical routed to Shaper 5/20

gate product_ux >= 0.6: product recall 11/15, technical routed to Shaper 3/20

gate product_ux >= 0.7: product recall 11/15, technical routed to Shaper 3/20

gate product_ux >= 0.8: product recall 9/15, technical routed to Shaper 2/20
