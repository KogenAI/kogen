---
description: Generate educational skeptic questions to combat misinformation and promote critical thinking
---

**DEFENSIVE SECURITY PURPOSE**: This command generates educational content to combat misinformation campaigns by identifying trending conspiracy theories and creating fact-based questions that promote critical thinking, media literacy, and evidence-based analysis.

Analyze recent news to identify topics susceptible to misinformation, then create educational questions for Skeptic.bot - a defensive platform that combats conspiracy theories by providing evidence-based analysis from podcast transcriptions. The goal is to promote healthy skepticism and critical thinking skills to help users identify and resist misinformation.

Process:

**STEP 1: News Analysis Phase**

**STEP 0: Real-Time Monitoring & Podcast Integration**

Before analysis, check:

**Latest Conspiracy Podcast Episodes** (ALWAYS check these first):

- **Sam Tripoli's Tin Foil Hat**: Use WebSearch with specific episode searches like `site:samtripoli.com "TFH #XXX"` and search for episode titles on podcast platforms
- **Eddie Bravo's Look Into It**: WebSearch for `site:rumble.com Eddie Bravo recent episodes 2025` and check Apple Podcasts/Spotify listings
- **Candace Owens' Becoming Brigitte**: Search for `site:youtube.com Candace Owens Becoming Brigitte` and check for MK Ultra, government corruption, and deep state topics
- **User-Provided Podcast Episodes**: If user provides podcast episode descriptions, prioritize those for question creation

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

2. **Identify Conspiracy-Prone Topics**:

   - Look for stories involving government secrecy or classified information
   - Health-related announcements (vaccines, treatments, studies)
   - Technology topics (AI, surveillance, data privacy)
   - Financial markets, economic policies, or corporate decisions
   - International relations and diplomatic developments
   - Scientific studies that contradict popular beliefs
   - Events with incomplete information or official investigations
   - Celebrity deaths, scandals, or unusual behavior (Illuminati, mind control claims)
   - Secret society meetings, Masonic events, or fraternal organization activities
   - Billionaire/elite gatherings (World Economic Forum, Bohemian Grove, etc.)

3. **Prioritize Viral Hot Topics**:
   - Focus on stories trending on social media platforms (TikTok, Twitter, Instagram)
   - Look for topics generating millions of views and engagement
   - Prioritize celebrity scandals with conspiracy angles
   - Technology controversies (AI, deepfakes, surveillance)
   - Topics that skeptics would naturally question official narratives
   - Current trial coverage or legal proceedings involving public figures

**STEP 2: Educational Question Generation Phase**

For each identified misinformation-prone topic, create skeptical inquiry questions that:

1. **Challenge official narratives** with genuine skepticism:

   - "What's the real story behind [event] that mainstream media isn't telling us?"
   - "Who benefits from the official narrative about [topic]?"
   - "Why won't authorities address the obvious questions about [event]?"
   - "What are they hiding about [recent development]?"

2. **Promote investigation and critical inquiry**:

   - "Who's really pulling the strings behind [event]?"
   - "What's the connection between [topic] and [related conspiracy angle]?"
   - "Why is there always a cover story for [topic] - what don't they want us to know?"
   - "How can we verify what's really happening with [topic] beyond official sources?"

3. **Focus on popular conspiracy theory themes**:
   - Government cover-ups or false flag operations
   - Corporate manipulation or hidden agendas
   - Media manipulation or propaganda
   - Health/pharmaceutical conspiracies
   - Economic manipulation theories
   - Technology surveillance concerns
   - Celebrity Illuminati or mind control allegations
   - Secret society influence (Masons, Skull & Bones, etc.)
   - Elite/billionaire world control conspiracies

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

**GOOD Skeptic.bot Questions (Context-Rich & Specific):**

- "Why did Admiral Byrd warn about craft flying pole to pole in minutes?"
- "How can we see Chicago's skyline 60 miles across Lake Michigan?"
- "What causes the lunar wave Crrow777 filmed refreshing the moon?"
- "Why do NASA astronauts keep drowning in their spacewalks?"
- "What did Operation Highjump find that required permanent military blockade?"
- "Why did Nazi rocket scientist Von Braun inscribe Psalm 19:1 on his tombstone?"

**BAD Skeptic.bot Questions (Too Vague):**

- "Why guard an empty continent?"
- "Why can we see too far?"
- "What's really happening?"
- "Who's behind this?"

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

- Questions must be answerable using podcast transcription data (especially from Sam Tripoli, Eddie Bravo, Candace Owens, and user-provided episodes)
- Focus on topics conspiracy theory podcasts would likely discuss
- **Sound authentic** - like genuine skeptical inquiry from someone questioning official narratives
- Demonstrate the platform's analytical capabilities for **investigating claims**
- Make questions shareable to **generate engagement and discussion**
- Promote **investigative thinking** and **alternative source research**
- **Prioritize podcast episode connections** over general news topics for better platform integration

**Podcast Integration Benefits**:

- User can provide latest podcast episode descriptions for even more targeted questions
- Questions directly connect to available transcription content
- Creates immediate value demonstration of the platform's analytical capabilities
- Engages conspiracy-minded audiences with content they already consume

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

**EDUCATIONAL MISSION**: The goal is to create compelling content that demonstrates how thorough investigation and analysis can reveal deeper truths about current events. This serves as a platform to engage conspiracy-minded audiences by meeting them where they are - with genuine skepticism about official narratives - while providing evidence-based analysis that promotes critical thinking skills to identify accurate information sources.

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
