---
description: Generate weekly Substack digest from latest podcast episodes
---

Generate weekly roundup for Skeptic.bot's Substack from podcast episodes added in past 7 days. Then generate Reddit posts when user provides Substack link.

## Arguments

Optional path to PostgreSQL dump file:

```
/skeptic-weekly [path-to-dump]
```

If no dump path, create automatically from production server.

Example: `/skeptic-weekly /Users/almirsarajcic/skeptic_bot_20251219.dump`

## Two-Phase Process

**PHASE 1:** Generate Substack article (Steps 1-8)
**PHASE 2:** When user replies with Substack URL, generate Reddit posts (Step 9)

---

# PHASE 1: Substack Article

**STEP 0: Create Dump (skip if dump path provided)**

Fetch fresh dump from production server:

```bash
export DB=skeptic_bot
export datetime=$(date +'%Y%m%d%H%M%S')
export DUMP_PATH="${HOME}/${DB}_${datetime}.dump"

ssh root@46.225.1.182 "su - combobulate -c \"pg_dump -U combobulate -d $DB --format custom --exclude-table-data=podcast_episode_transcriptions\"" > "$DUMP_PATH"

echo "Dump saved to: $DUMP_PATH"
```

Use `$DUMP_PATH` as the dump path for the rest of the steps.

**STEP 1: Restore DB Dump**

Restore dump file to temp PostgreSQL DB:

```bash
# Create temp database and restore dump
dropdb -U postgres --if-exists skeptic_weekly_temp
createdb -U postgres skeptic_weekly_temp
pg_restore -U postgres -d skeptic_weekly_temp --no-owner --no-privileges <DUMP_PATH> 2>&1 | tail -5
```

Verify restore:

```bash
psql -U postgres -d skeptic_weekly_temp -c "SELECT COUNT(*) FROM podcast_episodes;"
```

**STEP 2: Determine Date Range**

Continue from where last weekly ended. Check existing files for previous end date:

```bash
# List existing weekly files to find the last one
ls -la skeptic_weekly_*.md | tail -5
```

Start date of new weekly = end date of previous weekly. Get MAX(inserted_at) for end date:

```bash
psql -U postgres -d skeptic_weekly_temp -c "SELECT MAX(inserted_at)::date as dump_date FROM podcast_episodes;"
```

Date range:

- End date: dump date (MAX(inserted_at)::date) or current date
- Start date: end date minus 7 days, adjusted to day AFTER previous weekly's end date

Example: previous weekly ended Dec 19, dump date Dec 26 → cover Dec 19-26.

Query episodes using correct start date:

```sql
-- Replace START_DATE with the actual start date (e.g., '2025-12-19')
WITH recent_episodes AS (
  SELECT DISTINCT ON (p.id, pe.title)
    p.name as podcast_name,
    pe.title,
    pe.summary,
    pe.teaser,
    pe.external_id,
    pe.inserted_at
  FROM podcast_episodes pe
  JOIN podcasts p ON pe.podcast_id = p.id
  WHERE pe.inserted_at::date >= 'START_DATE'
  ORDER BY p.id, pe.title, pe.inserted_at DESC
)
SELECT
  podcast_name,
  title,
  teaser,
  summary,
  external_id,
  inserted_at::date as episode_date
FROM recent_episodes
ORDER BY inserted_at, podcast_name;
```

If no previous weekly exists, use 7-day window from dump date:

```sql
WHERE pe.inserted_at >= (SELECT MAX(inserted_at) FROM podcast_episodes)::date - INTERVAL '7 days'
```

**STEP 3: Detect and Exclude Backfilled Episodes**

`inserted_at` = scrape time, not publish time. Detect backfills by checking episode numbers.

For numbered podcasts (Candace, Tin Foil Hat):

1. Find highest episode number in results
2. Exclude: `(highest_episode_number - episode_number) > 10`

Example: Candace Ep 282 is highest → exclude anything below Ep 272.

Non-numbered podcasts (Deep Waters, Nephilim Death Squad, Look Into It, Broken Simulation) — include all from last 7 days.

**STEP 4: Test Sam Tripoli URLs**

Test all Sam Tripoli URLs (vid.samtripoli.com) to determine which episodes are accessible:

```bash
urls=(
  # List all vid.samtripoli.com URLs from query results
)

echo "Testing Sam Tripoli episode URLs..."
for url in "${urls[@]}"; do
  uuid=$(basename "$url")
  http_code=$(curl -s -o /dev/null -w "%{http_code}" "$url")

  if [ "$http_code" = "200" ]; then
    echo "✅ $uuid - WORKS"
  else
    echo "❌ $uuid - $http_code"
  fi
done
```

Only include episodes that:

1. Are NOT backfills (episode number check for numbered podcasts)
2. Have working URLs (200 status for Sam Tripoli URLs)

**STEP 5: Analyze Episodes and Identify Themes**

Review accessible episode summaries, identify:

- Common themes across podcasts
- Major breaking news topics
- Controversial claims or investigations
- Connections between episodes
- Standout guests or revelations

**STEP 6: Generate Article**

Create Substack-formatted Markdown:

**Podcast Grouping & Ordering:**

- Each podcast gets ONE `## Podcast Name` section — never split
- "Doom Scrollin" is SEPARATE podcast from "Tin Foil Hat" (both Sam Tripoli shows)
- Other Sam Tripoli podcasts: Cash Daddies, Union of the Unwanted, Zero with Sam Tripoli
- Group by podcast name, NOT host
- Order episodes chronologically (oldest → newest) within each podcast section
- Order podcast sections by earliest episode in the week

```markdown
# Skeptic.bot Weekly: [Date Range]

[Opening paragraph: 2-3 sentences about the week's main themes/patterns across all episodes]

---

## [Podcast Name 1]

### [Episode Title] ft. [Guest if mentioned]

[2-3 sentence episode summary highlighting key points]

**Key Topics:**

- [Topic 1]
- [Topic 2]
- [Topic 3]

**Questions This Raises:**

- [Skeptic question 1 - short, punchy, 6-10 words]
- [Skeptic question 2]

🎧 [Watch/Listen]([episode_url])

---

## [Podcast Name 2]

[Repeat structure for each podcast]

---

## Final Thoughts

[2-3 sentences connecting the dots between episodes, highlighting patterns, or noting significant revelations from the week]

**Want to investigate these claims?** Head to [Skeptic.bot](https://skeptic.bot) to ask questions and explore the evidence from these episodes.

---

_This is Skeptic.bot's weekly roundup of alternative media, examining claims and evidence from multiple perspectives. We analyze podcast content to help you think critically about narratives mainstream media won't touch._
```

**STEP 7: Write to File and Clean Up**

Save the article and clean up:

```bash
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_FILE="skeptic_weekly_${TIMESTAMP}.md"

cat > "$OUTPUT_FILE" << 'EOF'
[Generated article content]
EOF

echo "Weekly roundup saved to: $OUTPUT_FILE"

# Clean up temp database
dropdb -U postgres skeptic_weekly_temp

# Clean up dump file only if we created it in Step 0 (i.e. $DUMP_PATH is set)
if [ -n "${DUMP_PATH:-}" ]; then
  rm -f "$DUMP_PATH"
  echo "Removed temporary dump: $DUMP_PATH"
fi
```

**STEP 8: Output Short Summary**

Output brief summary (under 10 lines) only:

```
## Weekly Roundup: [Date Range]

**File:** `skeptic_weekly_YYYYMMDD_HHMMSS.md`
**Episodes:** X episodes across Y podcasts (Z Sam Tripoli URLs broken)
**Themes:** [theme 1], [theme 2], [theme 3]

### Substack Settings
- **Category:** News
- **Tags:** `conspiracy theories`, `alternative media`, `[topic tag 1]`, `[topic tag 2]`, `[topic tag 3]`
```

Do NOT output full article to terminal.

## Content Guidelines

**Opening Paragraph:**

- Hook with most compelling theme or revelation
- Reference specific episodes or claims tying the week together
- Under 4 sentences

**Episode Summaries:**

- What was actually discussed, not speculation
- Highlight specific claims, guests, or evidence
- Use episode teaser if summary too long
- Include guest names when mentioned in titles

**Questions to Generate:**

- Specific to episode content
- Short (6-10 words ideal)
- Declarative phrasing for better RAG (e.g., "Military presence Provo before 9/11" not "Why was military in Provo?")
- Connect to actual claims in episode

**Key Topics:**

- From episode summaries
- Concrete subjects — specific names, events, dates
- 3-5 topics per episode

**Tone:**

- Neutral, journalistic
- Present claims without endorsing or dismissing
- Emphasize investigation and evidence analysis

## Episode URL Logic

Construct URLs based on the podcast name and external_id:

- **YouTube podcasts** (Candace, Deep Waters, Nephilim Death Squad, Broken Simulation):
  - `https://www.youtube.com/watch?v=[external_id]`
  - external_id format: YouTube video ID (e.g., `vwG1juDCQZQ`)
  - These URLs are stable and reliable

- **Sam Tripoli podcasts** (Tin Foil Hat, Cash Daddies, Doom Scrollin, Union of the Unwanted, Zero with Sam Tripoli):
  - `https://vid.samtripoli.com/w/[external_id]`
  - external_id format: UUID (e.g., `d3f5d9e4-4669-4c4f-a706-174d79f02c76`)
  - **MANDATORY:** Test EVERY Sam Tripoli URL with curl before including
  - Exclude all 404 episodes from the article

- **Look Into It**:
  - If external_id is all numeric: `https://rokfin.com/post/[external_id]`
  - Otherwise: `https://rumble.com/[external_id]`

## Quality Criteria

- Ready to copy/paste directly into Substack
- Only episodes with verified working URLs
- Group by podcast, chronological within each
- No speculation beyond episode summaries
- All links tested before inclusion
- 1500-2500 words

---

# PHASE 2: Reddit Posts

**STEP 9: Generate Reddit Posts (when user provides Substack URL)**

Generate `reddit_posts_YYYYMMDD.md` when user replies with Substack URL.

**Reddit Guidelines:**

1. No links in post body — Reddit filters new accounts posting external links
2. Link goes in comments — add Substack link as comment after posting
3. Space posts out — one subreddit per day max
4. r/conspiracy requires account age — use r/conspiracy_commons for new accounts

File structure:

```markdown
# Reddit Posts for Skeptic.bot Weekly ([Date Range])

Substack URL: [USER_PROVIDED_URL]

---

## r/conspiracy_commons (TEXT)

Note: r/conspiracy requires account age of a few months. Use r/conspiracy_commons for new accounts.

**Click to submit:**
[URL-encoded link: https://www.reddit.com/r/conspiracy_commons/submit/?type=TEXT&title=...]

**Body:**
[Post content WITHOUT any links - save link for comments]

**Comment to add after posting:**
Full breakdown with working links: [SUBSTACK_URL]

---

## r/HighStrangeness (TEXT)

**Flair:** Podcast

**Click to submit:**
[URL-encoded link]

**Body:**
[Content focused on one specific episode/topic that fits the sub]

**Comment to add after posting:**
[SUBSTACK_URL]

---

## r/conspiracytheories (TEXT)

**Click to submit:**
[URL-encoded link]

**Body:**
[Content framed as a question to encourage discussion]

**Comment to add after posting:**
[SUBSTACK_URL]

---

## r/podcasts (TEXT - not LINK to avoid filters)

**Flair:** News & Current Affairs

**Click to submit:**
[URL-encoded link]

**Body:**
[Brief podcast roundup description, no links]

**Comment to add after posting:**
[SUBSTACK_URL]

---

## r/TinFoilHatPod (TEXT) - if TFH episodes exist

**Click to submit:**
[URL-encoded link with episode numbers in title, ordered correctly]

**Body:**
[Episode summaries in chronological order by episode number]

**Comment to add after posting:**
[SUBSTACK_URL]

---

## Posting Schedule

| Day   | Subreddit            | Flair                  |
| ----- | -------------------- | ---------------------- |
| Day 1 | r/conspiracy_commons | -                      |
| Day 2 | r/HighStrangeness    | Podcast                |
| Day 3 | r/conspiracytheories | -                      |
| Day 4 | r/podcasts           | News & Current Affairs |
| Day 5 | r/TinFoilHatPod      | -                      |

**Instructions:**

1. Click the submit URL
2. Paste the body text
3. Select flair if required
4. Post
5. Immediately add a comment with the Substack link
```

**Post Content per Subreddit:**

- r/conspiracy_commons: General weekly overview
- r/HighStrangeness: Paranormal/strange content (use "Podcast" flair)
- r/conspiracytheories: Frame as question to encourage discussion
- r/podcasts: Podcast discovery angle
- r/TinFoilHatPod: Episode-specific summaries in order

**URL Encoding:**

- Space: `%20`
- Colon: `%3A`
- Slash: `%2F`
- Hash: `%23`
- Comma: `%2C`
- Apostrophe: `%27`
- Quote: `%22`
- Parentheses: `%28` and `%29`
