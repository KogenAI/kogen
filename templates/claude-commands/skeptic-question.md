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

**STEP 3: Question Refinement**

Each question should be:

- **SHORT AND PUNCHY**: 3-8 words maximum - direct and memorable
- **Twitter-friendly**: Under 240 characters to leave room for hashtags
- **Engaging**: Prompts curiosity and skeptical thinking
- **Authentic**: Sounds like genuine skeptical inquiry, not academic debunking
- **Timely**: References current events people are discussing
- **Platform-optimized**: Works across TikTok, Twitter, Instagram, and podcasts

**CRITICAL: QUESTION LENGTH GUIDELINES**

**GOOD Examples (Short & Direct):**

- "Is Sabrina Carpenter an industry plant?"
- "Who's on both Diddy's and Epstein's lists?"
- "Why couldn't Joe Rogan talk about Hunter Biden's laptop?"
- "What did Hillary's inner circle witness?"
- "Who's censoring Jewish comedians criticizing Israel?"

**BAD Examples (Too Long):**

- "What's the real story behind Hunter Biden's laptop and why did Joe Rogan get banned from certain platforms for discussing it?"
- "Is Sabrina Carpenter's rapid rise organic or is she an industry-manufactured MK-Ultra asset - what's behind the pattern of pop star creation?"

**Platform Optimization**:

- **TikTok**: Questions that work as video hooks (5-10 seconds) - MUST be under 8 words
- **Twitter**: Short questions with engaging hooks - leave room for hashtags
- **Instagram**: Visual conspiracy questions (photos/graphics needed) - punchy text overlay
- **Podcast**: Can be slightly longer for detailed analysis, but still keep core question short

**STEP 4: Output Format**

Present 5-10 questions in this format:

**Topic**: [Brief description of news event or podcast episode]
**Conspiracy Angle**: [What theories might emerge around this]
**Question**: "[Specific SHORT question for Skeptic.bot - 3-8 words max]"
**Twitter Hook**: [Suggested tweet text with question]

**IMPORTANT**: Always prioritize podcast-connected questions first, then supplement with trending news questions. If user provides podcast episode descriptions, create questions that directly connect to those episodes.

**Example Question Formats (Keep Short!):**

- "What's really behind [event]?"
- "Who's controlling [topic]?"
- "Why can't we discuss [topic]?"
- "Is [person] an industry plant?"
- "Who's on [person]'s client list?"
- "What's [organization] hiding?"

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

- Questions must be answerable using podcast transcription data (especially from Sam Tripoli, Eddie Bravo, and user-provided episodes)
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
