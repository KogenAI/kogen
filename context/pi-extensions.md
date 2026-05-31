# Pi Extensions Domain — Pi TypeScript Extensions

The pi-extensions domain covers the TypeScript npm packages that extend the Pi harness with custom tool implementations. Each extension is an independent npm package under `harnesses/pi/pi-extensions/<name>/` with its own `package.json`, `src/`, and compiled output. `generate-pi-extension.sh` scaffolds new extensions from a template in `templates/shared/pi-extensions/`.

Current extensions: `askuserquestion` (interactive user prompts), `enforcement` (rule enforcement at runtime), `subagents` (agent delegation bridge), `web-utils` (HTTP/web helpers).

## Components

| File / Dir                                        | Purpose                                                        |
| ------------------------------------------------- | -------------------------------------------------------------- |
| `harnesses/pi/pi-extensions/askuserquestion/`     | Implements `AskUserQuestion` tool for Pi harness               |
| `harnesses/pi/pi-extensions/askuserquestion/src/` | TypeScript source                                              |
| `harnesses/pi/pi-extensions/enforcement/`         | Rule enforcement extension (blocks disallowed patterns)        |
| `harnesses/pi/pi-extensions/subagents/`           | Subagent delegation bridge for Pi                              |
| `harnesses/pi/pi-extensions/web-utils/`           | HTTP fetch, web search helpers                                 |
| `harnesses/pi/pi-extensions/web-utils/src/`       | TypeScript source                                              |
| `templates/generator/generate-pi-extension.sh`    | Scaffolds a new extension from template                        |
| `templates/shared/pi-extensions/`                 | Extension scaffold template (package.json, tsconfig, src stub) |

## Key Paths

```
harnesses/pi/pi-extensions/
  askuserquestion/
    index.ts, package.json, src/
  enforcement/
    package.json, src/          ← no root-level index.ts; entry is under src/
  subagents/
    index.ts, package.json, src/
  web-utils/
    index.ts, package.json, src/
templates/generator/generate-pi-extension.sh
templates/shared/pi-extensions/
```

## Integration Points

- **harnesses**: Pi launchers (`pi-build.sh`, etc.) reference compiled extensions; extension changes require rebuild (`npm run build` inside extension dir)
- **core**: `install.sh` pi install steps include extension compilation and installation
- **development**: `make test` may include pi extension type-checks; `npm install` required in each extension dir after dep changes

## Dev Workflow

Adding a new extension:

1. `generate-pi-extension.sh <name>` — scaffolds from template
2. Implement in `src/`
3. `npm install && npm run build` in extension dir
4. Register in `harnesses/pi/manifest.yaml` install_steps if needed

## Pitfalls

- **Each extension is an independent npm package** — `npm install` must be run per-extension, not at repo root
- **`package-lock.json` files are per-extension** — commit them; they are the reproducibility guarantee
- **`package-lock.json` churn is normal** — `subagents/package-lock.json` and `web-utils/package-lock.json` may appear dirty when different npm versions resolve deps differently; do not panic-commit these changes without intentional npm updates
- **TypeScript compile errors block Pi harness** — extension build failures prevent Pi from loading the tool
- **Extension structure varies** — `enforcement` has no root-level `index.ts` (entry is under `src/`); all four extensions have a `src/` subdirectory; do not assume a uniform layout at root level across all four extensions
