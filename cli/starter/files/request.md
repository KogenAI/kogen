# Add slugify to the text library

Add `slugify(text)` to `lib/text.js`, exported next to `titleCase`, with tests in `test/text.test.js`.

Examples:

- "Hello, World!" → "hello-world"
- "  Node.js   &   Kogen  " → "node-js-kogen"
- "---Rock'n'Roll 101---" → "rock-n-roll-101"

Rules:

1. The result is lower-case.
2. Every run of non-alphanumeric characters (anything other than ASCII letters and digits) becomes a single hyphen, and hyphens are trimmed at both ends.
