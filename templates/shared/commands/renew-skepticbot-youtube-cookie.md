---
description: Renew skeptic_bot YouTube cookies for yt-dlp and deploy to production
---

Renew the YouTube cookies used by skeptic_bot for channel scraping. Fully automated via CDP — no user interaction needed.

**What needs cookies**: channel scraping only (age-restricted videos). Downloads work without cookies.
**What does NOT need cookies**: video downloads, bgutil (bgutil is not required at all).

**YouTube account**: skeptic.bot.optimum@gmail.com / hYhrop-rarty4-juncew

## How it works

1. Launch Chrome with remote debugging (background, capture PID) — **non-headless, non-incognito** so Google doesn't reject the login
2. Log in to YouTube via CDP (click-based, not raw key events)
3. Extract all cookies via `Network.getAllCookies`
4. Base64-encode and update server `.env`
5. Rebuild release + restart skeptic_bot
6. Verify cookies work
7. Insert a new scraping job so it runs immediately
8. Kill Chrome

## Full automated script

Run everything in one go:

```bash
# Step 1: Launch Chrome with remote debugging
# IMPORTANT: non-headless (Google rejects HeadlessChrome logins)
# IMPORTANT: NOT incognito (Google blocks CDP logins in incognito)
# IMPORTANT: no --no-sandbox (macOS flag, causes Chrome warning and breaks behaviour)
# Use a fresh temp profile so no stale state
pkill -f "chrome-debug-skepticbot" 2>/dev/null
pkill -f "Google Chrome.*9222" 2>/dev/null
sleep 1
rm -rf /tmp/chrome-debug-skepticbot
/Applications/Google\ Chrome.app/Contents/MacOS/Google\ Chrome \
  --remote-debugging-port=9222 \
  --user-data-dir=/tmp/chrome-debug-skepticbot &
CHROME_PID=$!
sleep 5

# Step 2: Get the tab Chrome opened (it starts with chrome://intro/ — navigate away from it)
# Do NOT open a new tab. Reuse the existing one to avoid Chrome sign-in prompts.
INTRO_TAB_ID=$(curl -s http://localhost:9222/json | python3 -c "
import json,sys
tabs = json.load(sys.stdin)
tab = next(t for t in tabs if t.get('type') == 'page')
print(tab['id'])
")
echo "Tab ID: $INTRO_TAB_ID"

# Step 3: Log in via CDP
# - Navigate into the existing tab (bypasses Chrome's 'Sign in to Chrome' intro dialog)
# - Uses Input.insertText for typing (most reliable with Google's React forms)
# - Clicks the 'Next' button by exact text match (not by Enter key — unreliable)
# - Verifies login succeeded before extracting cookies
pip3 install websockets --break-system-packages -q 2>/dev/null
python3 - <<PYEOF
import asyncio, json, websockets

TAB_ID = "$INTRO_TAB_ID"
_msg_id = 0

async def cdp(ws, method, params=None):
    global _msg_id
    _msg_id += 1
    mid = _msg_id
    msg = {"id": mid, "method": method}
    if params:
        msg["params"] = params
    await ws.send(json.dumps(msg))
    while True:
        raw = await asyncio.wait_for(ws.recv(), timeout=15)
        resp = json.loads(raw)
        if resp.get("id") == mid:
            return resp

async def eval_js(ws, expr):
    r = await cdp(ws, "Runtime.evaluate", {"expression": expr, "awaitPromise": True})
    return r['result'].get('result', {}).get('value')

async def click_next(ws):
    await eval_js(ws, "Array.from(document.querySelectorAll('button')).find(b => b.textContent.trim() === 'Next').click()")

async def login():
    ws_url = f"ws://127.0.0.1:9222/devtools/page/{TAB_ID}"
    async with websockets.connect(ws_url) as ws:
        await cdp(ws, "Network.enable")

        # Navigate into the existing tab — this dismisses the Chrome intro dialog automatically
        print("Navigating to Google login...")
        await cdp(ws, "Page.navigate", {"url": "https://accounts.google.com/ServiceLogin?service=youtube"})
        await asyncio.sleep(6)
        print("URL:", await eval_js(ws, "document.location.href"))

        # Type email and click Next
        await eval_js(ws, "document.querySelector('input[name=identifier]').focus()")
        await asyncio.sleep(0.3)
        await cdp(ws, "Input.insertText", {"text": "skeptic.bot.optimum@gmail.com"})
        await asyncio.sleep(0.3)
        await click_next(ws)
        await asyncio.sleep(6)

        print("After email:", await eval_js(ws, "document.location.href"))

        # Type password and click Next
        await eval_js(ws, "document.querySelector('input[type=password]').focus()")
        await asyncio.sleep(0.3)
        await cdp(ws, "Input.insertText", {"text": "hYhrop-rarty4-juncew"})
        await asyncio.sleep(0.3)
        await click_next(ws)
        await asyncio.sleep(10)

        print("After login:", await eval_js(ws, "document.location.href"))

        # Verify signed into YouTube before extracting
        await cdp(ws, "Page.navigate", {"url": "https://www.youtube.com"})
        await asyncio.sleep(6)
        signed_in = await eval_js(ws, "document.querySelector('button[aria-label*=\"Account\"]') ? 'yes' : 'no'")
        print(f"Signed into YouTube: {signed_in}")
        if signed_in != 'yes':
            print("ERROR: Not signed in — aborting cookie export")
            exit(1)

        # Navigate to robots.txt for clean single-tab cookie state
        await cdp(ws, "Page.navigate", {"url": "https://www.youtube.com/robots.txt"})
        await asyncio.sleep(3)

        # Extract all cookies — Network.getAllCookies gets HttpOnly cookies too
        r = await cdp(ws, "Network.getAllCookies")
        cookies = r["result"]["cookies"]
        yt_cookies = [c for c in cookies if "youtube.com" in c.get("domain", "") or "google.com" in c.get("domain", "")]

        has_datasync = any(c['name'] == 'DATASYNC_ID' for c in yt_cookies)
        print(f"Total cookies: {len(yt_cookies)}, DATASYNC_ID: {has_datasync}")

        with open("/tmp/youtube_cookies.txt", "w") as f:
            f.write("# Netscape HTTP Cookie File\n")
            for c in yt_cookies:
                domain = c["domain"]
                flag = "TRUE" if domain.startswith(".") else "FALSE"
                secure = "TRUE" if c.get("secure") else "FALSE"
                expires = max(0, int(c.get("expires", 0)))  # -1 = session cookie, yt-dlp needs >= 0
                name = c["name"]
                value = c["value"]
                path = c.get("path", "/")
                f.write(f"{domain}\t{flag}\t{path}\t{secure}\t{expires}\t{name}\t{value}\n")

        print(f"Exported {len(yt_cookies)} cookies to /tmp/youtube_cookies.txt")

asyncio.run(login())
PYEOF

# Step 4: Update server .env
NEW_B64=$(base64 -i /tmp/youtube_cookies.txt | tr -d '\n')
ssh root@46.225.1.182 "sed -i 's|^YOUTUBE_COOKIE_FILE=.*|YOUTUBE_COOKIE_FILE=$NEW_B64|' /home/combobulate/apps/skeptic_bot/.env && echo 'Updated .env'"

# Step 5: Rebuild release
ssh root@46.225.1.182 'su - combobulate -s /bin/bash -c "cd /home/combobulate/apps/skeptic_bot && git rev-parse HEAD > priv/REVISION && mise exec -- bash -c \"MIX_ENV=prod mix release --overwrite\" 2>&1 | tail -5"'

# Step 6: Restart skeptic_bot
ssh root@46.225.1.182 '/home/combobulate/platform/_build/prod/rel/combobulate/bin/combobulate rpc "app = Combobulate.Apps.get_app_by_slug(\"skeptic-bot\"); Combobulate.Apps.ProcessManager.restart_app(app)"'
sleep 8

# Step 7: Verify cookies work — test channel scraping (the actual use case for cookies)
# Must return episode data, not a "Sign in" error
ssh root@46.225.1.182 'su - combobulate -s /bin/bash -c "COOKIE_FILE=\$(find /home/combobulate/apps/skeptic_bot/_build/prod/rel/skeptic_bot/lib -name '"'"'youtube_cookies.txt'"'"') && PYTHONUTF8=1 mise exec -- yt-dlp --retries 0 --cache-dir /tmp --proxy http://e3zl57o17o97mhND:sBYLaaVRJ9oRMcXz@geo.iproyal.com:12321 --cookies \"\$COOKIE_FILE\" --date $(date -v-1d +%Y%m%d) --print \"%(title)s\" '"'"'https://www.youtube.com/@SamTripoli/videos'"'"' 2>&1 | head -5"'

# Step 8: Insert a new scraping job to run immediately
ssh root@46.225.1.182 "su - combobulate -s /bin/bash -c \"psql postgresql://combobulate:postgres@localhost/skeptic_bot -c \\\"INSERT INTO oban_jobs (queue, worker, args, max_attempts, state, inserted_at, scheduled_at) VALUES ('scraping', 'SkepticBot.Podcasts.ScrapingWorker', '{}', 1, 'available', NOW(), NOW()) RETURNING id;\\\"\""

# Step 9: Kill Chrome
kill $CHROME_PID 2>/dev/null
pkill -f "chrome-debug-skepticbot" 2>/dev/null
pkill -f "Google Chrome.*9222" 2>/dev/null
echo "Done — cookies renewed, skeptic_bot restarted, scraping job queued."
```

## Notes

- **Non-headless, non-incognito, no `--no-sandbox`** — Google rejects `HeadlessChrome` UA. Incognito + CDP also causes login failures. `--no-sandbox` is a Linux flag that causes a warning banner on macOS and breaks behaviour. Use a fresh `--user-data-dir` temp profile, no extra flags.
- **Chrome may not open a page tab** — if `curl http://localhost:9222/json` shows no `type: page` tab (only service workers), create one with `curl -X PUT http://localhost:9222/json/new` before running the Python script.
- **`Input.insertText` for typing** — more reliable than `Input.dispatchKeyEvent` with Google's React-based forms. Raw key events don't trigger React's synthetic event handlers properly.
- **Click "Next" button by exact text, not Enter key** — `Array.from(document.querySelectorAll('button')).find(b => b.textContent.trim() === 'Next').click()`. Enter key dispatched via CDP doesn't reliably submit Google's login form.
- **Unique CDP message IDs required** — all `id` values must be unique per message. Reusing the same ID causes response matching to break (events from the server share the same stream).
- **Verify login before extracting cookies** — check `button[aria-label*="Account"]` exists on YouTube. If login failed silently, you'd extract only 3 unauthenticated cookies instead of ~40 auth cookies.
- **`Network.getAllCookies` via CDP** — required to get HttpOnly cookies. `document.cookie` only returns ~3 non-HttpOnly cookies.
- **`DATASYNC_ID` cookie** — not always present in a fresh session (Google doesn't always set it). yt-dlp will warn if missing but the bgutil plugin handles PO tokens regardless. ~40 cookies with `SAPISID`, `LOGIN_INFO`, `__Secure-1PSID` etc. is a valid auth session.
- **`expires = max(0, ...)` fix** — CDP returns `-1` for session cookies (no expiry). yt-dlp rejects negative expires values, so clamp to `0`.
- **RPC into skeptic_bot's own node fails** (`:noconnection`) — insert Oban jobs directly via psql instead.
- **bgutil is NOT required** — tested: scraping and downloads both work without it. Ignore any bgutil warnings.
- **pip-installed yt-dlp** — always use `mise exec -- yt-dlp`, not `/usr/local/bin/yt-dlp` (zipapp, outdated).
- **Kill Chrome with both methods** — `kill $CHROME_PID` may not catch all child processes. Also run `pkill -f "chrome-debug-skepticbot"` and `pkill -f "Google Chrome.*9222"` to be thorough.
