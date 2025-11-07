---
description: Generate balanced skeptic questions analyzing evidence from multiple perspectives
---

**INVESTIGATIVE PURPOSE**: This command generates questions that analyze evidence from multiple perspectives, including alternative viewpoints presented in podcasts. Rather than dismissing claims, we examine evidence objectively to help users evaluate information critically and form their own conclusions based on available data.

Analyze recent news and podcast content to create investigative questions for Skeptic.bot - a platform that examines claims and evidence from various sources including mainstream media, government statements, and alternative perspectives from podcasters and researchers. The goal is to promote evidence-based investigation and critical analysis skills.

Process:

**STEP 1: News Analysis Phase**

**STEP 0: Database & Real-Time Monitoring**

**CRITICAL FIRST STEP - CHECK THE DATABASE:**

Before any web searches, ALWAYS check what podcasts are available in the Skeptic.bot database:

```sql
SELECT p.name, MAX(pe.inserted_at)
FROM podcasts p
JOIN podcast_episodes pe ON p.id = pe.podcast_id
GROUP BY p.name
```

This shows you:

- Which podcasts have episodes in the system
- When their most recent episode was added
- What content you can actually reference and link to

**Available Podcasts in Database** (as of Nov 2025):

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

**WHY THIS MATTERS:**

- Questions MUST connect to episodes that exist in the database
- Users will search these questions against actual transcripts
- Generic questions about topics not in podcasts won't find relevant content
- Your goal is to drive users to explore EXISTING podcast content

**THEN Do Real-Time Monitoring:**

After checking the database, search for specific episode details:

- **Sam Tripoli's Tin Foil Hat**: Use WebSearch with specific episode searches like `site:samtripoli.com "TFH #XXX"` and search for episode titles on podcast platforms
- **Eddie Bravo's Look Into It**: WebSearch for `site:rumble.com Eddie Bravo recent episodes 2025` and check Apple Podcasts/Spotify listings
- **Candace Owens' Show**: Search for recent episodes and topics being discussed that challenge mainstream narratives
- **User-Provided Podcast Episodes**: If user provides podcast episode descriptions, prioritize those for question creation

**Purpose**: These podcasts often present alternative perspectives and raise questions about official narratives. Rather than dismissing their viewpoints, we analyze the evidence they present alongside mainstream sources to help users evaluate all available information.

**CRITICAL PODCAST RESEARCH METHOD**:

- **DO NOT rely on homepage fetches** - they don't provide detailed episode content
- **USE PARALLEL SEARCHES** - run all podcast episode searches simultaneously using multiple WebSearch calls in a single message
- **TARGET SPECIFIC EPISODES** - search for individual episode titles and descriptions, not just general show pages
- **CROSS-PLATFORM SEARCH** - check Rumble, Apple Podcasts, Spotify, and website listings simultaneously

**Social Media & News Monitoring**:

- Social media trending topics (last 24-48 hours)
- Viral conspiracy content on TikTok/Twitter
- Celebrity news and entertainment scandals
- Technology/AI development announcements
- Political developments generating skepticism
- Breaking news with incomplete official explanations

1. **Gather Recent News (Last 30-60 Days)**:

   - **CRITICAL**: First use Bash tool with `date` command to get the ACTUAL current date
   - **IMPORTANT**: The AI assistant does NOT know the current date - it MUST use the terminal output from `date` command
   - **Use the exact date from terminal output** in all WebSearch queries (e.g. if `date` shows "Mon Aug 4 2025", search for "August 2025" not "January 2025")

   **PARALLEL RESEARCH STRATEGY** (Run ALL searches simultaneously):

   - Use WebSearch to find trending news from major sources (Reuters, AP, BBC, CNN, etc.)
   - Search podcast episodes and news topics in a SINGLE message with multiple WebSearch tool calls
   - **NEVER run searches sequentially** - always batch 8-10 searches per message for maximum efficiency
   - **Prioritize viral hot topics** over historical events

   **EXAMPLE PARALLEL SEARCH BATCH**:

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

   - Focus on topics that typically attract conspiracy theories:
     - Government announcements or policy changes
     - Health/medical developments
     - Technology breakthroughs or concerns
     - Economic events or market movements
     - Scientific discoveries or studies
     - International conflicts or tensions
     - Celebrity/public figure controversies
     - Environmental/climate events
     - Secret society activities or allegations
     - Masonic or fraternal organization events

2. **Identify Topics With Multiple Perspectives**:

   - Stories involving government secrecy or classified information where podcasters may have different interpretations
   - Health-related announcements where alternative viewpoints exist (vaccines, treatments, studies)
   - Technology topics where privacy concerns and official assurances may conflict
   - Financial markets, economic policies where different analysts have varying conclusions
   - International relations where multiple interpretations of events are possible
   - Scientific studies where researchers may have differing methodologies or conclusions
   - Events with incomplete information where various investigators offer different theories
   - Historical events where new evidence or interpretations have emerged
   - Corporate or institutional actions where motives and impacts are debated

3. **Prioritize Viral Hot Topics**:
   - Focus on stories trending on social media platforms (TikTok, Twitter, Instagram)
   - Look for topics generating millions of views and engagement
   - Prioritize celebrity scandals with conspiracy angles
   - Technology controversies (AI, deepfakes, surveillance)
   - Topics that skeptics would naturally question official narratives
   - Current trial coverage or legal proceedings involving public figures

**STEP 2: Balanced Evidence Analysis Question Generation**

For each identified topic with multiple perspectives, create investigative questions that:

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

**TWO-TIER APPROACH:**

**1. Skeptic.bot Question (Detailed & Analytical):**

- **CAN BE LONGER**: 10-25 words for comprehensive analysis
- **Descriptive**: Include specific details, names, and context
- **Research-focused**: Reference sources, episodes, researchers by name
- **Educational**: Promote investigation and critical thinking

**2. Twitter Hook (Short & Viral):**

- **MUST BE SHORT**: 3-6 words maximum for the question portion
- **Timeline-based**: Connect past events to current developments
- **Authority-referenced**: Quote researchers, podcasters, officials
- **Shareable**: Optimized for social media engagement

**QUESTION LENGTH EXAMPLES:**

**GOOD Skeptic.bot Questions (Direct & Event-Focused):**

- "Who killed Charlie Kirk and why won't they investigate the coordination angle?"
- "What was Anne Heche about to expose before her fiery car crash?"
- "Why did all Tesla attacks happen simultaneously if they weren't coordinated?"
- "Who ordered the classified document raids and what are they really looking for?"
- "What connects Diddy's arrest to the other celebrity investigations?"
- "Why did Meta end fact-checking right before the election?"

**BAD Skeptic.bot Questions (Too Academic/Vague):**

- "What evidence do different sources present about the assassination?"
- "How do researchers interpret the same data?"
- "What methodologies do investigators use?"
- "Which aspects have been independently verified?"

**CRITICAL: Question Phrasing for RAG Retrieval**

Your question must be **semantically similar** to episode titles/summaries to work with embeddings.

**How Episode Embeddings Work:**

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

**Best Practice: Dual Question Format**

Store TWO versions of each question:

1. **Display Title** (user-facing, can be interrogative/conspiratorial):

   - "Why Was Arthur Kwon Lee Blackballed From The Art World?"

2. **Search Query** (for embedding, declarative, keyword-focused):
   - "Arthur Kwon Lee blackballed art world establishment"

**Pattern Templates:**

- Person-focused: "{Person} {action/topic} {context}"
  - Example: "Arthur Kwon Lee blackballed art world"
- Event-focused: "{Event} {key detail} {context}"
  - Example: "Tucker Carlson cancellation Fox News"
- Investigative: "{Subject} {investigation} {revelation}"
  - Example: "Brigitte MK Ultra French Gold Rush"

**Question Testing Checklist:**

1. ✅ Uses words from episode title?
2. ✅ Declarative rather than interrogative?
3. ✅ Avoids conspiracy framing not in episode?
4. ✅ Matches semantic style of episode summaries?

**Platform Optimization**:

- **TikTok**: Questions that work as video hooks (5-10 seconds) - MUST be under 8 words
- **Twitter**: Short questions with engaging hooks - leave room for hashtags
- **Instagram**: Visual conspiracy questions (photos/graphics needed) - punchy text overlay
- **Podcast**: Can be slightly longer for detailed analysis, but still keep core question short

**STEP 4: Twitter Hook Strategy**

Create compelling Twitter hooks that follow this proven format:

**🔥 HIGH-ENGAGEMENT HOOK FORMULA:**
"[Person/Event 1] [action/connection]. [Person/Event 2] [related action/timing]. [Skeptical researcher quote or connection]. [SHORT QUESTION - 3-6 words max]? #Hashtag"

**PROVEN HOOK EXAMPLES:**

**Timeline + Authority Pattern:**

- "Anne Heche dies in fiery crash 2022. Ellen flees to England after Trump wins 2024. Christopher Knowles says there's 'still more to unearth.' What really killed Anne Heche? #EllenFled"

**Expert Quote + Connection Pattern:**

- "Sam Tripoli's guest Christopher Knowles calls Anne Heche's death 'ritualistic murder.' Ellen's rise to power, shadowy lesbian mobsters, and Hollywood occult symbolism. What really killed Anne Heche? #TinFoilHat"

**Official vs. Reality Pattern:**

- "FBI says Tesla attacks are lone wolves, but officials scream 'coordination.' Why fake Tesla attack coordination? #TeslaPsyop"

**Research Discovery Pattern:**

- "Researchers found Ellen's connection to New Orleans 'lesbian mobster' who died in car crash. Anne Heche knew Ellen's secrets, then fiery death. What really killed Anne Heche? #Research"

**HOOK STRUCTURE REQUIREMENTS:**

1. **Timeline Connection** (2022 event → 2024/2025 development)
2. **Authority Reference** (podcast guest, researcher, official)
3. **Conspiracy Angle** (what doesn't add up)
4. **SHORT QUESTION** (3-6 words maximum)
5. **Strategic Hashtag** (platform-specific)

**Output Format**

When user asks to create content, provide:

1. **Skeptic.bot Question** (context-rich, specific, 10-20 words):

   - Example: "Why did Admiral Byrd warn about craft flying pole to pole in minutes?"
   - Must include specific details: names, dates, measurable claims, or quotes
   - Avoid vague questions like "What's really happening?" or "Who's behind this?"
   - **CRITICAL**: Use exact terms from podcast episode titles/descriptions for embedding search
   - Test multiple variations if initial question doesn't find podcast content

2. **Twitter Thread** (exactly 3 tweets following hook-explanation-link format):

**Tweet 1 (Hook - MUST BE UNDER 280 CHARS):**
[Specific historical fact/date]. [Connected modern event]. [Authority figure quote or measurable claim]. [Context-rich question]?

**CRITICAL SHORTENING TECHNIQUES FOR TWEET 1:**

- Use "docs:" instead of "documents"
- Use "Intel" instead of "Intelligence Committee"
- Remove "FBI" if context is clear
- Use abbreviations: "govt" "admin" "classified info" "bombshell" not "bombshell documents"
- Cut redundant phrases

**Tweet 2 (Explanation - Under 280 chars):**
[Authority source] reveals [key insight]. [Modern parallel/connection]. [Supporting detail].

**Tweet 3 (Link - MUST BE UNDER 280 CHARS INCLUDING LINK):**
[Warning/consequence]. [Thought-provoking conclusion that maintains conspiratorial tone].

**CRITICAL: Tweet 3 + Skeptic.bot link must total under 280 chars**

- Skeptic.bot links are ~85 chars: https://skeptic.bot/questions/bd3c529e-97f4-416e-862b-e99feb053593
- **Tweet 3 text MUST be under 195 characters** (280 - 85 = 195)
- Keep conclusions short and punchy

3. **File Output** (MANDATORY):
   - Write all questions and Twitter threads to: `skeptic_questions_[date].txt`
   - Use bash command: `date +%Y%m%d_%H%M%S` for timestamp
   - Format file for easy copy/paste to Skeptic.bot and Twitter

**TWITTER THREAD REQUIREMENTS:**

- NO hashtags in first tweet (hook must be clean)
- NO mention of podcast names in first tweet
- **CRITICAL: Keep each tweet under 280 characters** - Test character count and shorten if needed
- **Tweet 1 MUST be under 280 chars** - Remove redundant words, use abbreviations (e.g. "Intel" not "Intelligence Committee", "docs:" not "documents")
- Follow proven engagement patterns from examples
- Third tweet should end naturally without forced "call to action" - the link card handles that
- Focus on authentic conspiratorial language over marketing speak

**IMPORTANT**: Always prioritize podcast-connected questions first, then supplement with trending news questions. If user provides podcast episode descriptions, create questions that directly connect to those episodes.

**Example Question Formats (Context-Rich & Specific!):**

- "Why did [specific person] warn about [specific claim with details]?"
- "How can we see [specific location] from [distance] if Earth curves?"
- "What causes [specific phenomenon] that [researcher] filmed?"
- "Why do [specific group] keep [specific pattern] in their [activity]?"
- "What did [specific operation/event] find that required [specific response]?"
- "Why did [person] inscribe [specific text] on their [location]?"

**High-Engagement Question Examples**:

**Classic High-Engagement (Short & Punchy):**

- "What's behind Kubrick's Eyes Wide Shut?"
- "Who's Trump's handler?"
- "Who's on Epstein's guest list?"
- "What is the cosmic egg?"
- "What really happened at Bohemian Grove?"
- "Are the Masons controlling world events?"
- "What's behind the Denver Airport murals?"

**Current Hot Topics (Update Regularly - Keep Short!):**

- "Is TikTok using AI clones?"
- "What's really happening at Diddy's parties?"
- "Why create babies with three parents?"
- "Who's controlling deepfake technology?"
- "What connects celebrity deaths to industry contracts?"
- "What's SpaceX really doing on ISS?"

**Quality Criteria**:

- Questions must be answerable using podcast transcription data alongside other available sources
- Focus on topics where podcasters and mainstream sources offer different perspectives
- **Sound balanced** - like genuine investigative inquiry examining evidence from multiple viewpoints
- Demonstrate the platform's analytical capabilities for **cross-referencing claims**
- Make questions that encourage **evidence evaluation** rather than dismissal of alternative viewpoints
- Promote **comparative analysis** between different sources and methodologies
- **Prioritize podcast episode connections** to show how alternative perspectives can be analyzed alongside official sources

**Podcast Integration Benefits**:

- User can provide latest podcast episode descriptions for even more targeted questions
- Questions directly connect to available transcription content for evidence analysis
- Creates immediate value demonstration of the platform's cross-referencing capabilities
- Engages audiences interested in alternative perspectives by treating their viewpoints seriously
- Allows for objective comparison between different sources and methodologies

**RESEARCH SUCCESS CRITERIA**:

✅ **Successful Research Output Example**:

- **TFH #910**: Dom the Hypnotist's client witnessed Hillary Clinton's "shady behind-the-scenes actions"
- **TFH #909**: Jewish anti-Zionist comedian Michael Schirter faced walkouts and censorship
- **Eddie Bravo**: "Season of Psyops" episode connected Tesla explosions to coordinated operations
- **Candace Owens**: "Becoming Brigitte" explores MK Ultra, Stanford Prison Experiment, prisoner 2093
- **Breaking News**: Marco Rubio/Susie Wiles deepfake impersonations by foreign actors
- **Viral Topics**: Project 2025 authors now holding federal positions, "Fogvid-24" chemical fog events

✅ **Quality Indicators**:

- Episode-specific details (not just show titles)
- Current month breaking news with conspiracy angles
- Platform-optimized questions (3-6 words each)
- Authentic skeptical language (not academic debunking tone)
- Direct connection to available transcript content

❌ **Research Failures to Avoid**:

- Generic homepage content without episode details
- Sequential searches (slow and inefficient)
- Questions longer than 8 words
- Academic or dismissive tone
- Historical topics not trending currently

**INVESTIGATIVE MISSION**: The goal is to create compelling content that demonstrates how thorough investigation and analysis can examine claims from multiple perspectives. This serves as a platform to engage audiences interested in alternative viewpoints by providing balanced evidence-based analysis that allows users to evaluate information from various sources - including podcasters, researchers, and official sources - and draw their own informed conclusions.

## File Output Instructions

**MANDATORY**: After generating questions, write them to a file for easy copying:

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
