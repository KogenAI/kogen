---
description: Generate weekly Substack digest from latest podcast episodes
---

Generate a comprehensive weekly roundup article for Skeptic.bot's Substack, summarizing the latest podcast episodes added to the database in the past 7 days. Then generate Reddit posts when the user provides the Substack link.

## Arguments

This command takes an optional path to a PostgreSQL database dump file:

```
/skeptic-weekly [path-to-dump]
```

If no dump path is provided, one will be created automatically from the production server.

Example with existing dump: `/skeptic-weekly /Users/almirsarajcic/skeptic_bot_20251219.dump`

## Two-Phase Process

**PHASE 1:** Generate Substack article (Steps 1-8)
**PHASE 2:** When user replies with Substack URL, generate Reddit posts (Step 9)

---

# PHASE 1: Substack Article

**STEP 0: Create Dump (skip if dump path was provided)**

If no dump path was provided, fetch a fresh dump from the production server:

```bash
export DB=skeptic_bot
export datetime=$(date +'%Y%m%d%H%M%S')
export DUMP_PATH="${HOME}/${DB}_${datetime}.dump"

ssh root@46.225.1.182 "su - combobulate -c \"pg_dump -U combobulate -d $DB --format custom --exclude-table-data=podcast_episode_transcriptions\"" > "$DUMP_PATH"

echo "Dump saved to: $DUMP_PATH"
```

Use `$DUMP_PATH` as the dump path for the rest of the steps.

**STEP 1: Restore Database Dump**

Restore the provided dump file to a temporary PostgreSQL database:

```bash
# Create temp database and restore dump
dropdb -U postgres --if-exists skeptic_weekly_temp
createdb -U postgres skeptic_weekly_temp
pg_restore -U postgres -d skeptic_weekly_temp --no-owner --no-privileges <DUMP_PATH> 2>&1 | tail -5
```

Verify data was restored:

```bash
psql -U postgres -d skeptic_weekly_temp -c "SELECT COUNT(*) FROM podcast_episodes;"
```

**STEP 2: Determine Date Range Based on Previous Weekly**

The date range should continue from where the last weekly ended. Check existing weekly files to find the previous week's end date:

```bash
# List existing weekly files to find the last one
ls -la skeptic_weekly_*.md | tail -5
```

Then determine the start date for this week:

- If the previous weekly was "December 12-19", this week should be "December 19-26"
- The start date of the new weekly = end date of the previous weekly

Get the MAX(inserted_at) from the dump to determine the end date:

```bash
psql -U postgres -d skeptic_weekly_temp -c "SELECT MAX(inserted_at)::date as dump_date FROM podcast_episodes;"
```

**IMPORTANT:** The date range should be calculated as:

- **End date:** The dump date (MAX(inserted_at)::date) or current date, whichever makes sense
- **Start date:** End date minus 7 days, BUT adjusted to be the day AFTER the previous weekly's end date

For example, if:

- Previous weekly ended on Dec 19
- Dump date is Dec 26
- This weekly should cover Dec 19-26 (starting from the 19th to include episodes from that day forward)

Query episodes using the correct start date:

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

**Alternative:** If no previous weekly exists, use the 7-day window from dump date:

```sql
WHERE pe.inserted_at >= (SELECT MAX(inserted_at) FROM podcast_episodes)::date - INTERVAL '7 days'
```

**STEP 3: Detect and Exclude Backfilled Episodes**

Since `inserted_at` shows scrape time (not publish time), detect obvious backfills by checking episode numbers:

For each podcast with numbered episodes (Candace, Tin Foil Hat):

1. Find the highest episode number in the results
2. Exclude episodes where: `(highest_episode_number - episode_number) > 10`

Example: If Candace Ep 282 is the highest, exclude anything below Ep 272.

**Note:** Some podcasts don't use episode numbers (Deep Waters, Nephilim Death Squad, Look Into It, Broken Simulation) - for these, include all episodes from the last 7 days.

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

**IMPORTANT:** Only include episodes that:

1. Are NOT backfills (episode number check for numbered podcasts)
2. Have working URLs (200 status for Sam Tripoli URLs)

**STEP 5: Analyze Episodes and Identify Themes**

Review all accessible episode summaries and identify:

- Common themes across multiple podcasts
- Major breaking news topics covered
- Controversial claims or investigations
- Connections between different episodes
- Standout guests or revelations

**STEP 6: Generate Article**

Create a Substack-formatted Markdown article with this structure:

**Podcast Grouping & Ordering:**

- Each podcast gets its own **single** `## Podcast Name` section — never split a podcast into multiple sections
- "Doom Scrollin" is a SEPARATE podcast from "Tin Foil Hat" (both are Sam Tripoli shows)
- Other Sam Tripoli podcasts: Cash Daddies, Union of the Unwanted, Zero with Sam Tripoli
- Group episodes by podcast name, NOT by host
- **Order episodes chronologically (oldest to newest)** within each podcast section
- Order podcast sections by the date of their **earliest** episode in the week (all episodes from that podcast go in one block, regardless of when later episodes aired)

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

Output ONLY a brief summary (under 10 lines):

```
## Weekly Roundup: [Date Range]

**File:** `skeptic_weekly_YYYYMMDD_HHMMSS.md`
**Episodes:** X episodes across Y podcasts (Z Sam Tripoli URLs broken)
**Themes:** [theme 1], [theme 2], [theme 3]

### Substack Settings
- **Category:** News
- **Tags:** `conspiracy theories`, `alternative media`, `[topic tag 1]`, `[topic tag 2]`, `[topic tag 3]`
```

Do NOT output the full article content to the terminal.

## Content Guidelines

**Opening Paragraph:**

- Hook the reader with the most compelling theme or revelation
- Reference specific episodes or claims that tie the week together
- Keep it under 4 sentences

**Episode Summaries:**

- Focus on what was actually discussed, not speculation
- Highlight specific claims, guests, or evidence presented
- Use the episode's teaser for quick context if summary is too long
- Include guest names when mentioned in titles

**Questions to Generate:**

- Make them specific to the episode content
- Keep them short (6-10 words ideal)
- Use declarative phrasing for better RAG retrieval (e.g., "Military presence Provo before 9/11" vs "Why was military in Provo?")
- Connect to actual claims made in the episode

**Key Topics:**

- Pull from episode summaries
- Focus on concrete subjects discussed
- Use specific names, events, dates when possible
- Aim for 3-5 topics per episode

**Tone:**

- Neutral, journalistic
- Present claims without endorsing or dismissing
- Let the content speak for itself
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

- Article must be ready to copy/paste directly into Substack
- Only include episodes with verified working URLs
- Group by podcast, then chronological within each podcast
- No speculation beyond what's in the episode summaries
- All links must be tested and confirmed working before inclusion
- Keep total article length reasonable (aim for 1500-2500 words)

---

# PHASE 2: Reddit Posts

**STEP 9: Generate Reddit Posts (triggered when user provides Substack URL)**

When the user replies with their Substack URL (e.g., `https://skepticbot.substack.com/p/skepticbot-weekly-december-12-19`), generate a markdown file with Reddit posts.

**IMPORTANT Reddit Guidelines:**

1. **No links in post body** - Reddit filters new accounts posting external links. Put content only in the body.
2. **Link goes in comments** - After posting, add the Substack link as a comment.
3. **Space posts out** - One subreddit per day maximum to avoid spam detection.
4. **r/conspiracy requires account age** - Use r/conspiracy_commons for new accounts.

**Generate file:** `reddit_posts_YYYYMMDD.md` with this structure:

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

**Post Content Guidelines:**

- Each post should be tailored to the subreddit's focus
- r/conspiracy_commons: General weekly overview
- r/HighStrangeness: Focus on paranormal/strange content (use "Podcast" flair)
- r/conspiracytheories: Frame as question to encourage discussion
- r/podcasts: Focus on podcast discovery angle
- r/TinFoilHatPod: Episode-specific summaries in order

**URL Encoding:**

Use proper URL encoding for the submit links:

- Space: `%20`
- Colon: `%3A`
- Slash: `%2F`
- Hash: `%23`
- Comma: `%2C`
- Apostrophe: `%27`
- Quote: `%22`
- Parentheses: `%28` and `%29`
