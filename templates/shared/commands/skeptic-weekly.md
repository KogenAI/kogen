---
description: Generate weekly Substack digest from latest podcast episodes
---

Generate a comprehensive weekly roundup article for Skeptic.bot's Substack, summarizing the latest podcast episodes added to the database in the past 7 days.

## Process

**STEP 1: Get Current Date and Calculate Date Range**

Use the Bash `date` command to get the current date, then calculate the date range for "last 7 days":

```bash
date
```

Determine the week's date range (e.g., "Nov 1-7, 2025").

**STEP 2: Provide SQL Query to User**

**IMPORTANT:** You cannot access the database directly. Output the following SQL query for the user to run in production, then **WAIT** for them to provide the results:

```sql
-- Get episodes from last 7 days, showing ALL versions if duplicates exist
-- This allows manual verification of which URL works
WITH recent_episodes AS (
  SELECT
    p.id as podcast_id,
    p.name as podcast_name,
    pe.title as episode_title,
    pe.summary as episode_summary,
    pe.teaser as episode_teaser,
    pe.external_id,
    pe.inserted_at
  FROM podcast_episodes pe
  JOIN podcasts p ON pe.podcast_id = p.id
  WHERE pe.inserted_at >= NOW() - INTERVAL '7 days'
),
all_versions AS (
  SELECT
    p.name as podcast_name,
    pe.title as episode_title,
    pe.summary as episode_summary,
    pe.teaser as episode_teaser,
    pe.external_id,
    pe.inserted_at,
    COUNT(*) OVER (PARTITION BY p.id, pe.title) as version_count,
    ROW_NUMBER() OVER (PARTITION BY p.id, pe.title ORDER BY pe.inserted_at DESC) as version_rank
  FROM podcast_episodes pe
  JOIN podcasts p ON pe.podcast_id = p.id
  WHERE EXISTS (
    SELECT 1 FROM recent_episodes re
    WHERE re.podcast_id = p.id AND re.episode_title = pe.title
  )
)
SELECT
  podcast_name,
  episode_title,
  episode_summary,
  episode_teaser,
  external_id,
  inserted_at,
  version_count,
  version_rank,
  CASE
    WHEN podcast_name IN ('Tin Foil Hat', 'Cash Daddies', 'Doom Scrollin', 'Union of the Unwanted', 'Zero with Sam Tripoli')
    THEN 'https://vid.samtripoli.com/w/' || external_id
    WHEN podcast_name IN ('Candace', 'Deep Waters', 'Nephilim Death Squad', 'Broken Simulation')
    THEN 'https://www.youtube.com/watch?v=' || external_id
    ELSE external_id
  END as test_url
FROM all_versions
ORDER BY podcast_name, episode_title, inserted_at DESC;
```

**Note:** This query returns ALL versions of each episode (including old duplicates), with:

- `version_count`: How many versions exist
- `version_rank`: 1 = newest, 2 = second newest, etc.
- `test_url`: Full URL to manually test in browser

**Usage:** For episodes with `version_count > 1`, manually test each `test_url` to find which works, then use that `external_id` in the article.

**STEP 3: Detect and Exclude Backfilled Episodes**

Since `inserted_at` shows scrape time (not publish time), detect obvious backfills by checking episode numbers:

For each podcast:

1. Find the highest episode number in the results
2. Exclude episodes where: `(highest_episode_number - episode_number) > 10`

Example: If Candace Ep 260 is the highest, exclude anything below Ep 250 (like Ep 233).

**Note:** Some podcasts don't use episode numbers (Deep Waters, Nephilim Death Squad, Look Into It) - for these, include all episodes from the last 7 days based on `inserted_at`.

**STEP 4: Test Sam Tripoli URLs**

Test all Sam Tripoli URLs to determine which episodes are accessible:

```bash
# Extract unique Sam Tripoli URLs from the query results
urls=(
  # List all vid.samtripoli.com URLs here
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

Once you've confirmed which episodes are accessible and recently published:

Review all accessible episode summaries and identify:

- Common themes across multiple podcasts
- Major breaking news topics covered
- Controversial claims or investigations
- Connections between different episodes
- Standout guests or revelations

**STEP 6: Generate Article Structure**

Create a Substack-formatted Markdown article with the following structure (only including accessible, recently published episodes).

**IMPORTANT: Podcast Grouping & Ordering**

- Each podcast gets its own section with `## Podcast Name` header
- "Doom Scrollin" is a SEPARATE podcast from "Tin Foil Hat" (both are Sam Tripoli shows)
- Other Sam Tripoli podcasts: Cash Daddies, Union of the Unwanted, Zero with Sam Tripoli
- Group episodes by podcast name, NOT by host
- **Order episodes chronologically (oldest to newest)** - this creates a natural narrative flow as the week unfolds
- Episodes from the same day should be grouped by podcast, then ordered by podcast name alphabetically

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

🎧 [Watch/Listen]([episode_url based on podcast - see URL Logic below])

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

**STEP 7: Write to File with Timestamp**

Save the article to a markdown file:

```bash
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_FILE="skeptic_weekly_${TIMESTAMP}.md"

# Write article content to file
cat > "$OUTPUT_FILE" << 'EOF'
[Generated article content]
EOF

echo "Weekly roundup saved to: $OUTPUT_FILE"
```

**STEP 8: Output Short Summary**

After writing the file, output a brief summary to the terminal (3-5 sentences) covering:

- Total number of episodes covered (accessible episodes only)
- Which podcasts were active this week
- The top 2-3 themes/topics
- Any particularly explosive revelations
- File path where article was saved
- Number of Sam Tripoli episodes excluded due to broken URLs

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

**Episode URL Logic:**

Construct URLs based on the podcast name and external_id:

- **YouTube podcasts** (Candace, Deep Waters, Nephilim Death Squad, Broken Simulation):

  - `https://www.youtube.com/watch?v=[external_id]`
  - external_id format: YouTube video ID (e.g., `vwG1juDCQZQ`)
  - These URLs are stable and reliable

- **Sam Tripoli podcasts** (Tin Foil Hat, Cash Daddies, Doom Scrollin, Union of the Unwanted, Zero with Sam Tripoli):

  - `https://vid.samtripoli.com/w/[external_id]`
  - external_id format: UUID (e.g., `d3f5d9e4-4669-4c4f-a706-174d79f02c76`)
  - **⚠️ CRITICAL WARNING:** Approximately **60% of these URLs will 404**
    - Episodes are frequently removed/replaced on vid.samtripoli.com
    - Even the "latest" duplicate may be broken
    - Re-uploads get new UUIDs, making old links invalid
  - **MANDATORY:** Test EVERY Sam Tripoli URL with curl before including in article
  - **Strategy:** Exclude all 404 episodes entirely from the article

- **Look Into It**:
  - If external_id is all numeric: `https://rokfin.com/post/[external_id]`
  - Otherwise: `https://rumble.com/[external_id]`

## Quality Criteria

- Article must be ready to copy/paste directly into Substack
- Only include episodes with verified working URLs (all YouTube + tested Sam Tripoli)
- Group by podcast, then chronological within each podcast
- No speculation beyond what's in the episode summaries
- All links must be tested and confirmed working before inclusion
- Keep total article length reasonable (aim for 1500-2500 words)

## Output Format

1. **Full markdown article** saved to file
2. **Terminal summary** (short, 3-5 sentences) including:
   - "Generated weekly roundup for [date range]"
   - "Covered X accessible episodes across Y podcasts"
   - "Excluded Z Sam Tripoli episodes with broken URLs"
   - "Top themes: [theme 1], [theme 2], [theme 3]"
   - "Saved to: [filename]"
   - "All links verified and working"

## Publishing to Substack

Once the article is generated:

1. **Copy the markdown content** from the generated file
2. **Paste directly into Substack's editor** - Substack will automatically convert markdown to formatted text
3. **Select "News" as the primary category** for best positioning
4. **Add relevant tags** (select 3-5 based on week's content):
   - **Always include:** conspiracy theories, alternative media
   - **Common tags:** 9/11, AI, surveillance, politics, media criticism, government, technology
   - **Topic-specific:** Use tags matching the week's major themes
5. **The article is ready to publish:**
   - All links have been tested and verified working
   - Headers, bold text, bullet points will render correctly
   - No manual URL verification needed
   - No manual formatting needed
