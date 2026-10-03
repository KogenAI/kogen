---
title: Project environment block
domains: [project, kernel, contracts]
size: small
---
Some projects need fixed environment values for every command Kogen runs, such as a test database port. Today the only way is to wrap each check's argv in `env`, which does not reach acceptance tests. Add an `env:` map to project.yaml and give its entries to every command a Build runs in a workspace.

## Acceptance
- A1: A project.yaml `env:` map loads as the project's `env` field, and a project.yaml without `env:` loads with an empty `env` map.
- A2: An `env:` entry with an invalid variable name or a non-string value is a load error naming its key.
- A3: `Kogen.Kernel.candidate_environment/3` returns the workdir's toolchain environment plus every project `env:` entry, with project entries winning.

## Verify
- A1: test domain=project
- A2: test domain=project
- A3: test domain=kernel

## Notes
A valid name matches `^[A-Za-z_][A-Za-z0-9_]*$`. The signature is `candidate_environment(workdir, runtime, project)`, returning `{:ok, env}` or the same errors as `project_environment/2`. The Build engine must use it wherever it now uses `project_environment/2` for a workspace, so setup commands, project checks, fixers, diagnostics, harness shell commands and acceptance tests all see the entries, on both the candidate and the red-on-base checkout.
