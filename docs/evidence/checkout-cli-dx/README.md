# Installed CLI evidence

`installed-observations.json` retains attachments from the independent approved
checkout CLI acceptance driver, run on the local supported macOS arm64 host.
All ten scenarios passed through a freshly packaged disposable installation.
The fast-read observation contains the platform, 20-sample measurements before
and after accumulated history and with the installed core removed and the run
history path replaced by a FIFO. Preparation is outside measured reads.

Command (repository root):

```
NODE_PATH=test/acceptance/node_modules node test/acceptance/node_modules/@cucumber/cucumber/bin/cucumber.js --strict --require features/steps/checkout_cli_dx_steps.js .kogen/intents/checkout-cli-dx/acceptance.feature
```

The deterministic Go suite additionally evaluates real Zsh dynamic completion
wiring for commands, options, directories and a project-selected positional.
These observations are development evidence, not Root's installed release
qualification, publication or default-adoption authorization. No active frozen
prefix or default Studio store was changed.
