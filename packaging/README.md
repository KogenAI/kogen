# Kogen

Kogen takes one requested feature through shaping, building, verifying, reviewing and committing, in your own Git repository, with your ChatGPT plan.

## Install

```sh
sh install.sh                 # installs into ~/.local
sh install.sh --prefix <dir>  # or elsewhere
export PATH="$HOME/.local/bin:$PATH"   # if install.sh says ~/.local/bin is not on your PATH
```

The installer needs no administrator rights and edits no shell files. It needs `git`. If no Node 22 or newer is on `PATH`, it downloads the current Node LTS into Kogen's own folder, for Quint and the acceptance bridge.

Supported platforms: macOS on Apple Silicon and Linux x86-64 with glibc, at the versions release acceptance ran on (macOS 26 on Apple Silicon, Ubuntu 24.04 on x86-64).

## Use

In a Git repository with at least one commit (a Build needs a clean working tree, so keep the request file outside the repository, or commit it):

```sh
kogen provider login chatgpt
cd my-project && kogen init        # finds and checks the project's commands, commits the configuration
kogen intent shape my-feature ../request.md
kogen intent refine my-feature <full-sha256-from-review-card> ../correction.md  # unapproved ready drafts; existing owned files only
kogen intent approve my-feature    # read the card, then approve with its hash
kogen intent build my-feature
```

Run `kogen help` for every command. `kogen uninstall` removes the program and keeps `~/.kogen` (your login) and your projects.

## License

Kogen is licensed under the Apache License 2.0: see `LICENSE` and `NOTICE`. It bundles third-party software under their own licences: see `licenses/`.
