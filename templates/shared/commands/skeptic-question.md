---
description: Generate balanced skeptic questions analyzing evidence from multiple perspectives
---

Analyze recent news and podcast content to create investigative questions for Skeptic.bot — platform examining claims and evidence from mainstream media, government statements, and alternative perspectives from podcasters and researchers.

Process:

**STEP 0: Database & Real-Time Monitoring**

FIRST — check podcasts available in Skeptic.bot DB:

```sql
SELECT p.name, MAX(pe.inserted_at)
FROM podcasts p
JOIN podcast_episodes pe ON p.id = pe.podcast_id
GROUP BY p.name
```

Shows which podcasts have episodes, when last added, what content can be referenced.

**Available Podcasts in DB** (as of Nov 2025):

- Tin Foil Hat (Nov 7, 2025)
- Nephilim Death Squad (Nov 7, 2025)
- Candace (Nov 7, 2025)
- Cash Daddies (Nov 4, 2025)
- Deep Waters / Conspiracy Social Club (Nov 3, 2025)
- Doom Scrollin (Oct 26, 2025)
- Look Into It (Oct 8, 2025)
- Broken Simulation (Oct 4, 2025)
- Zero with Sam Tripoli (Mar 30, 2025)
- Union of the Unwanted (Mar 30, 2025)

Questions MUST connect to episodes in DB. Users search against actual transcripts. Generic questions → no relevant content. Goal: drive users to EXISTING podcast content.

**Then do real-time monitoring** — search for specific episode details:

- **Sam Tripoli's Tin Foil Hat**: `site:samtripoli.com "TFH #XXX"` and episode title searches on podcast platforms
- **Eddie Bravo's Look Into It**: `site:rumble.com Eddie Bravo recent episodes 2025` + Apple Podcasts/Spotify
- **Candace Owens**: Search recent episodes challenging mainstream narratives
- **User-Provided Episodes**: If user provides episode descriptions, prioritize those

**Podcast research method**:

- DO NOT rely on homepage fetches — no detailed episode content
- USE PARALLEL SEARCHES — all podcast episode searches simultaneously in single message
- TARGET SPECIFIC EPISODES — titles and descriptions, not just show pages
- CROSS-PLATFORM — check Rumble, Apple Podcasts, Spotify, website listings simultaneously

**Social Media & News Monitoring**:

- Social media trending topics (last 24-48 hours)
- Viral conspiracy content on TikTok/Twitter
- Celebrity news and entertainment scandals
- Technology/AI development announcements
- Political developments generating skepticism
- Breaking news with incomplete official explanations

**STEP 1: News Analysis Phase**

1. **Gather Recent News (Last 30-60 Days)**:
   - First use Bash tool with `date` to get ACTUAL current date — don't assume
   - Use exact date from terminal in all WebSearch queries (e.g. `date` shows "Mon Aug 4 2025" → search "August 2025")

   **Parallel research** (run ALL searches simultaneously):
   - Find trending news from major sources (Reuters, AP, BBC, CNN, etc.)
   - Search podcast episodes and news in SINGLE message with multiple WebSearch calls
   - NEVER run searches sequentially — batch 8-10 per message
   - Prioritize viral hot topics over historical events

   Example parallel batch:

   ```
   WebSearch: "Sam Tripoli TFH #910 episode description"
   WebSearch: "Eddie Bravo Look Into It Rumble August 2025"
   WebSearch: "viral conspiracy theories TikTok August 2025"
   WebSearch: "celebrity scandals conspiracy August 2025"
   WebSearch: "AI deepfakes government news August 2025"
   WebSearch: "UFO disclosure whistleblowers August 2025"
   WebSearch: "Project 2025 shadow government August 2025"
   WebSearch: "government classified leaks August 2025"
   ```

   Focus topics: government announcements, health/medical developments, tech breakthroughs, economic events, scientific discoveries, international conflicts, celebrity controversies, environmental events, secret society activities.

2. **Identify Topics With Multiple Perspectives**:
   - Government secrecy where podcasters have different interpretations
   - Health announcements with alternative viewpoints (vaccines, treatments)
   - Tech topics where privacy concerns conflict with official assurances
   - Financial markets where different analysts have varying conclusions
   - Events with incomplete info where investigators offer different theories
   - Historical events where new evidence has emerged

3. **Prioritize Viral Hot Topics**:
   - Stories trending on TikTok, Twitter, Instagram
   - Topics generating millions of views
   - Celebrity scandals with conspiracy angles
   - Technology controversies (AI, deepfakes, surveillance)
   - Current trial coverage involving public figures

**STEP 2: Question Generation**

For each topic with multiple perspectives, create investigative questions that:

1. **Ask direct questions about events**:
   - "Who killed [person] and why won't they investigate [specific angle]?"
   - "What really happened at [event] that officials aren't telling us?"
   - "Why did [person] die right before [related event]?"
   - "Who benefits from [event] happening when it did?"

2. **Focus on specific claims and connections**:
   - "What was [person] about to expose before they died?"
   - "Why are [officials/media] covering up [specific detail] about [event]?"
   - "Who ordered [action] and what are they hiding?"
   - "What connects [event A] to [event B] that happened [timeframe]?"

3. **Question official narratives directly**:
   - "Why did [official response] happen so quickly after [event]?"
   - "What are they not telling us about [current situation]?"
   - "Who's really behind [policy/decision] and what's their agenda?"
   - "Why is [person/organization] pushing [narrative] so hard right now?"
   - "What's the real reason [event] happened when it did?"
   - "Who profits from [situation] and how are they connected?"
   - "What did [person] know that got them [consequence]?"
   - "Why are [authorities] ignoring [obvious evidence/connection]?"

**STEP 3: Question Refinement Strategy**

**Two-tier approach:**

1. **Skeptic.bot Question** (10-25 words):
   - Descriptive — include specific details, names, context
   - Reference sources, episodes, researchers by name
   - Promote investigation and critical thinking

2. **Twitter Hook** (3-6 words max):
   - Timeline-based — connect past events to current developments
   - Quote researchers, podcasters, officials
   - Optimized for social media engagement

**Good Skeptic.bot Questions (Direct & Event-Focused):**

- "Who killed Charlie Kirk and why won't they investigate the coordination angle?"
- "What was Anne Heche about to expose before her fiery car crash?"
- "Why did all Tesla attacks happen simultaneously if they weren't coordinated?"
- "Who ordered the classified document raids and what are they really looking for?"
- "What connects Diddy's arrest to the other celebrity investigations?"
- "Why did Meta end fact-checking right before the election?"

**Bad Skeptic.bot Questions (Too Academic/Vague):**

- "What evidence do different sources present about the assassination?"
- "How do researchers interpret the same data?"
- "What methodologies do investigators use?"
- "Which aspects have been independently verified?"

**Question Phrasing for RAG Retrieval**

Question MUST be semantically similar to episode titles/summaries for embeddings.

How embeddings work:

```
Episode embedding = "passage: {title} {summary}"
Example: "passage: BlackBalled With Arthur Kwon Lee Arthur Kwon Lee discusses his journey..."
```

**Bad Question Phrasing (High Semantic Distance):**

- ❌ "Why did the art world blackball Arthur Kwon Lee?" (interrogative, doesn't match title style)
- ❌ "What are they hiding about Arthur Kwon Lee?" (conspiracy angle not in title)
- ❌ "Who ordered Arthur Kwon Lee's cancellation?" (too specific)

**Good Question Phrasing (Low Semantic Distance):**

- ✅ "Arthur Kwon Lee blackballed art world" (matches title keywords)
- ✅ "Tucker Carlson canceled again" (matches title directly)
- ✅ "Brigitte MK Ultra French Gold Rush" (uses exact title words)

**Dual Question Format**

Store TWO versions:

1. **Display Title** (user-facing, interrogative): "Why Was Arthur Kwon Lee Blackballed From The Art World?"
2. **Search Query** (for embedding, declarative): "Arthur Kwon Lee blackballed art world establishment"

**Pattern Templates:**

- Person-focused: "{Person} {action/topic} {context}"
  - Example: "Arthur Kwon Lee blackballed art world"
- Event-focused: "{Event} {key detail} {context}"
  - Example: "Tucker Carlson cancellation Fox News"
- Investigative: "{Subject} {investigation} {revelation}"
  - Example: "Brigitte MK Ultra French Gold Rush"

**Question Testing Checklist:**

1. Uses words from episode title?
2. Declarative rather than interrogative?
3. Avoids conspiracy framing not in episode?
4. Matches semantic style of episode summaries?

**Platform Optimization**:

- **TikTok**: Under 8 words (5-10 second hook)
- **Twitter**: Short with engaging hooks — leave room for hashtags
- **Instagram**: Punchy text overlay for visual content
- **Podcast**: Slightly longer OK but keep core question short

**STEP 4: Twitter Hook Strategy**

High-engagement hook formula:
"[Person/Event 1] [action/connection]. [Person/Event 2] [related action/timing]. [Skeptical researcher quote]. [SHORT QUESTION - 3-6 words max]? #Hashtag"

**Proven Hook Examples:**

**Timeline + Authority Pattern:**

- "Anne Heche dies in fiery crash 2022. Ellen flees to England after Trump wins 2024. Christopher Knowles says there's 'still more to unearth.' What really killed Anne Heche? #EllenFled"

**Expert Quote + Connection Pattern:**

- "Sam Tripoli's guest Christopher Knowles calls Anne Heche's death 'ritualistic murder.' Ellen's rise to power, shadowy lesbian mobsters, and Hollywood occult symbolism. What really killed Anne Heche? #TinFoilHat"

**Official vs. Reality Pattern:**

- "FBI says Tesla attacks are lone wolves, but officials scream 'coordination.' Why fake Tesla attack coordination? #TeslaPsyop"

**Research Discovery Pattern:**

- "Researchers found Ellen's connection to New Orleans 'lesbian mobster' who died in car crash. Anne Heche knew Ellen's secrets, then fiery death. What really killed Anne Heche? #Research"

**Hook Structure:**

1. Timeline Connection (2022 event → 2024/2025 development)
2. Authority Reference (podcast guest, researcher, official)
3. Conspiracy Angle (what doesn't add up)
4. SHORT QUESTION (3-6 words max)
5. Strategic Hashtag (platform-specific)

**Output Format**

When user asks to create content:

1. **Skeptic.bot Question** (10-20 words, specific):
   - Include names, dates, measurable claims, or quotes
   - Avoid vague questions like "What's really happening?"
   - Use exact terms from episode titles/descriptions for embedding search
   - Test multiple variations if initial question doesn't find podcast content

2. **Twitter Thread** (exactly 3 tweets):

**Tweet 1 (Hook — MUST BE UNDER 280 CHARS):**
[Specific historical fact/date]. [Connected modern event]. [Authority figure quote]. [Context-rich question]?

Shortening techniques: "docs:" not "documents", "Intel" not "Intelligence Committee", "govt"/"admin"/"classified info"

**Tweet 2 (Explanation — under 280 chars):**
[Authority source] reveals [key insight]. [Modern parallel]. [Supporting detail].

**Tweet 3 (Link — MUST BE UNDER 280 CHARS INCLUDING LINK):**
[Warning/consequence]. [Thought-provoking conclusion].

Skeptic.bot links ~85 chars → Tweet 3 text MUST be under 195 chars (280 - 85 = 195).

3. **File Output** (MANDATORY):
   - Write all questions and Twitter threads to: `skeptic_questions_[date].txt`
   - Timestamp via: `date +%Y%m%d_%H%M%S`

**Twitter thread rules:**

- NO hashtags in first tweet
- NO podcast names in first tweet
- Every tweet under 280 chars — test character count
- Third tweet ends naturally — link card handles CTA
- Authentic conspiratorial language, not marketing speak

Prioritize podcast-connected questions first, then supplement with trending news. If user provides episode descriptions, connect questions directly to those episodes.

**Question Format Examples:**

- "Why did [specific person] warn about [specific claim with details]?"
- "What causes [specific phenomenon] that [researcher] filmed?"
- "What did [specific operation/event] find that required [specific response]?"

**High-Engagement Examples:**

Classic (short & punchy):

- "What's behind Kubrick's Eyes Wide Shut?"
- "Who's on Epstein's guest list?"
- "What really happened at Bohemian Grove?"

Current hot topics (update regularly):

- "Is TikTok using AI clones?"
- "Who's controlling deepfake technology?"
- "What's SpaceX really doing on ISS?"

**Quality Criteria:**

- Answerable using podcast transcription data
- Sound balanced — genuine investigative inquiry
- Encourage evidence evaluation, not dismissal of alternative viewpoints
- Prioritize podcast episode connections

**Research Success Criteria:**

Good output:

- TFH #910: Dom the Hypnotist's client witnessed Hillary Clinton's "shady behind-the-scenes actions"
- Eddie Bravo: "Season of Psyops" episode connected Tesla explosions to coordinated operations
- Candace Owens: "Becoming Brigitte" explores MK Ultra, Stanford Prison Experiment, prisoner 2093

Quality indicators:

- Episode-specific details (not just show titles)
- Current month breaking news with conspiracy angles
- Platform-optimized questions (3-6 words)
- Authentic skeptical language (not academic debunking)
- Direct connection to available transcript content

Research failures to avoid:

- Generic homepage content without episode details
- Sequential searches (slow and inefficient)
- Questions longer than 8 words
- Academic or dismissive tone
- Historical topics not trending currently

## File Output

After generating questions, write to file for easy copying:

```bash
# Create output file with timestamp
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_FILE="skeptic_questions_${TIMESTAMP}.txt"

# Write all questions and Twitter threads to file
cat > "$OUTPUT_FILE" << 'EOF'
[Generated questions and Twitter threads go here]
EOF

echo "Questions saved to: $OUTPUT_FILE"
```

**File Format Example**:

```
===========================================
SKEPTIC.BOT QUESTIONS - [DATE]
===========================================

QUESTION 1: [Topic Name]
-------------------------
Skeptic.bot: Why did Admiral Byrd warn about craft flying pole to pole in minutes?

Twitter Thread:
Tweet 1: Admiral Byrd 1947: "Craft that can fly from pole to pole at incredible speeds." Eddie Bravo connects Operation Highjump to Antarctica Treaty. No commercial flights cross Antarctica today. Why did Admiral Byrd warn about craft flying pole to pole in minutes?

Tweet 2: Eddie reveals NASA's missing moon tapes prove deception pathway. First you question moon landings, then you discover the ice wall truth.

Tweet 3: Every nation at war suddenly cooperates at 60° South. What discovery united sworn enemies in permanent treaty?

===========================================
```
