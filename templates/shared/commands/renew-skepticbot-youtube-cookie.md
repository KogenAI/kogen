---
description: Renew skeptic_bot YouTube cookies for yt-dlp and deploy to production
---

Renew the YouTube cookies used by skeptic_bot for yt-dlp downloads. Fully automated via CDP — no extensions needed.

**YouTube account**: skeptic.bot.optimum@gmail.com / hYhrop-rarty4-juncew

## Steps

1. **Launch Chrome with remote debugging** — run this in a terminal (keep it open):

   ```bash
   /Applications/Google\ Chrome.app/Contents/MacOS/Google\ Chrome \
     --remote-debugging-port=9222 \
     --user-data-dir=/tmp/chrome-debug-skepticbot \
     --incognito
   ```

2. **Log into YouTube** — navigate to `https://www.youtube.com` in that Chrome window and log in as skeptic.bot.optimum@gmail.com / hYhrop-rarty4-juncew. Confirm when done.

3. **Navigate to robots.txt** — go to `https://www.youtube.com/robots.txt` in that same tab (ensures clean single-tab session with cookies set).

4. **Extract cookies via CDP** — run:

   ```bash
   # Get the WebSocket debugger URL for the active tab
   TAB_WS=$(curl -s http://localhost:9222/json | python3 -c "
   import json, sys
   tabs = json.load(sys.stdin)
   tab = next(t for t in tabs if 'youtube.com' in t.get('url', ''))
   print(tab['webSocketDebuggerUrl'])
   ")

   # Use CDP Network.getAllCookies to extract all cookies
   python3 - <<'PYEOF'
   import asyncio, json, websockets, sys

   async def get_cookies():
       tab_ws = "$(echo $TAB_WS)"
       async with websockets.connect(tab_ws) as ws:
           await ws.send(json.dumps({"id": 1, "method": "Network.getAllCookies"}))
           response = json.loads(await ws.recv())
           cookies = response["result"]["cookies"]
           # Filter youtube.com cookies
           yt_cookies = [c for c in cookies if "youtube.com" in c.get("domain", "") or "google.com" in c.get("domain", "")]

           # Write Netscape format
           with open("/tmp/youtube_cookies.txt", "w") as f:
               f.write("# Netscape HTTP Cookie File\n")
               for c in yt_cookies:
                   domain = c["domain"]
                   flag = "TRUE" if domain.startswith(".") else "FALSE"
                   secure = "TRUE" if c.get("secure") else "FALSE"
                   expires = int(c.get("expires", 0))
                   name = c["name"]
                   value = c["value"]
                   path = c.get("path", "/")
                   f.write(f"{domain}\t{flag}\t{path}\t{secure}\t{expires}\t{name}\t{value}\n")
           print(f"Exported {len(yt_cookies)} cookies to /tmp/youtube_cookies.txt")

   asyncio.run(get_cookies())
   PYEOF
   ```

   If `websockets` is not installed: `pip3 install websockets`

5. **Verify the file** — check it looks valid:

   ```bash
   head -5 /tmp/youtube_cookies.txt
   grep -c "youtube.com" /tmp/youtube_cookies.txt
   ```

6. **Base64 encode**:

   ```bash
   base64 -i /tmp/youtube_cookies.txt | tr -d '\n' > /tmp/youtube_cookies_b64.txt
   cat /tmp/youtube_cookies_b64.txt
   ```

7. **Update server .env** — SSH to production and replace the value:

   ```bash
   NEW_B64=$(cat /tmp/youtube_cookies_b64.txt)
   ssh root@46.225.1.182 "sed -i 's|^YOUTUBE_COOKIE_FILE=.*|YOUTUBE_COOKIE_FILE=$NEW_B64|' /home/combobulate/apps/skeptic_bot/.env && echo 'Updated'"
   ```

8. **Rebuild and restart** skeptic_bot on the server:

   ```bash
   ssh root@46.225.1.182 "su - combobulate -s /bin/bash -c 'cd /home/combobulate/apps/skeptic_bot && git rev-parse HEAD > priv/REVISION && mise exec -- bash -c \"MIX_ENV=prod mix release --overwrite\" 2>&1 | tail -5'"
   ```

   Then restart via RPC:

   ```bash
   ssh root@46.225.1.182 "su - combobulate -s /bin/bash -c '/home/combobulate/platform/_build/prod/rel/combobulate/bin/combobulate rpc \"app = Combobulate.Apps.get_app_by_slug(\\\"skeptic-bot\\\"); Combobulate.Apps.ProcessManager.restart_app(app)\"'"
   ```

9. **Verify** — test the cookie file directly on server:

   ```bash
   ssh root@46.225.1.182 "COOKIE_FILE=/home/combobulate/apps/skeptic_bot/_build/prod/rel/skeptic_bot/lib/skeptic_bot-0.1.0/priv/youtube_cookies.txt && PYTHONUTF8=1 yt-dlp --cache-dir /tmp --cookies \$COOKIE_FILE 'https://www.youtube.com/watch?v=dQw4w9WgXcQ' --simulate 2>&1 | tail -5"
   ```

   Success = no cookie errors (warnings about JS runtime are expected and unrelated).

10. **Retry failed jobs** — reschedule jobs that were discarded due to cookie/utf-8 errors, spaced 1 hour apart to avoid rate limiting. Skips private/404 videos:

    ```bash
    ssh root@46.225.1.182 "su - combobulate -s /bin/bash -c 'psql postgresql://combobulate:postgres@localhost/skeptic_bot -c \"
    WITH retryable AS (
      SELECT id, ROW_NUMBER() OVER (ORDER BY id) AS rn
      FROM oban_jobs
      WHERE state = '\''discarded'\''
        AND queue = '\''downloading'\''
        AND (errors[array_length(errors,1)]->>'\''error'\'' LIKE '\''%utf-8%'\''
          OR errors[array_length(errors,1)]->>'\''error'\'' LIKE '\''%cookie%'\''
          OR errors[array_length(errors,1)]->>'\''error'\'' LIKE '\''%Sign in%'\'')
        AND errors[array_length(errors,1)]->>'\''error'\'' NOT LIKE '\''%private%'\''
        AND errors[array_length(errors,1)]->>'\''error'\'' NOT LIKE '\''%404%'\''
    )
    UPDATE oban_jobs SET state = '\''available'\'', max_attempts = attempt + 3,
      scheduled_at = NOW() + (retryable.rn * INTERVAL '\''1 hour'\'')
    FROM retryable WHERE oban_jobs.id = retryable.id;
    \"'"
    ```

11. **Close the Chrome debug window** after successful verification.
