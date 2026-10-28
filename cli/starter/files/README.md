# Kogen starter project

A tiny Node project to try Kogen on. `lib/text.js` has `titleCase`; `request.md` asks Kogen to add `slugify`. Tests run with `node --test`; the project's `test` check is `"$KOGEN_NODE" --test test/*.test.js`.

Commands (the ones `kogen starter` printed):

```sh
cd <dir>
kogen doctor
kogen intent shape slugify request.md
kogen intent approve slugify   # shows the card; run the approve command it prints
kogen intent build slugify
```

Known result: after shape, approve and build, the build lands one commit, the project's `test` check passes, and `slugify("Hello, World!")` returns `"hello-world"`.
