# Kogen Bare Loop

Kogen Bare Loop is a small prompt-to-file baseline: send one prompt through the
installed ChatGPT subscription login and save one completed assistant response
to a new file. It does not shape the prompt or run generated code.

## Start here

Run it from this directory with Elixir 1.20.2 and Erlang/OTP 29:

```sh
elixir loop.exs 'Write the requested text.' /existing/parent/response.txt
```

The parent directory must already exist, and the output path must be unused.
The prompt is sent verbatim. The request uses `gpt-6-luna`, maximum reasoning,
and the instruction `Return only the requested output.` The received assistant
text is written exactly as returned, with no added newline.
If the response contains cached login material, saving it is refused.

The command reads the private `~/.codex/auth.json` created and maintained by
the installed Codex login. If the login is missing, expired, rejected, or not
private, use `codex login` (or `codex login --device-auth`) and rerun. The
command makes one bounded HTTPS subscription request; it does not use a paid
API key. Errors go to standard error, and response text is never printed.

## Check

Run `make check` to run the offline tests through `mix test`. The tiny Mix
project exists for these tests; the user entrypoint is `loop.exs`.

## Files

- `loop.exs` — command-line entrypoint.
- `lib/kogen/bare_loop.ex` — authentication, subscription request, response
  parsing, output preflight, and exclusive file creation.
- `test/` — offline tests using a fake transport and local temporary files.
- `Makefile` and `mix.exs` — the single `make check` test command.
