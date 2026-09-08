# Deterministic-first AI tasks — implementation plan

September 7, 2026, revised the same day after a Codex review (see
"Review log" at the end). Same format as `docs/Podcast-Implementation-Plan.md`:
numbered build order, effort (S = a day or two, M = about a week, L = two
weeks or more), dependencies, and the decision each item rests on. Items in
one phase can be built in parallel.

## The goal

An audit of the 27 `ai.call` sites found about a third doing mechanical
work: matching strings the database already holds, parsing numbers and
names out of text against closed vocabularies, detecting cuts and dead air
that ffmpeg measures directly, or classifying into a handful of labels. Each
call costs money, takes seconds, needs a network, and can return an invented
id or a hallucinated number. This plan moves that work into plain code and
Apple frameworks and keeps the model only for semantic or aesthetic judgement.

The pattern already exists in two places and is the template for everything
below:

- `TranscriptToolsSheet.swift` tries Apple's Translation framework first and
  calls the model only when it fails.
- `FramingService.swift` uses Vision (`VNDetectHumanRectanglesRequest`) with
  no model at all.
- `InstagramService.swift` overwrites the model's cut count with ffmpeg's
  `sceneChangeTimestamps` because "the model occasionally echoes rounded or
  hallucinated numbers."

## Decisions (settled)

- **D1. Code first, model second.** Where a deterministic path exists it
  runs first. The model is a fallback for the cases code marks as unsure,
  never a parallel second opinion.
- **D2. Same outputs, same call sites.** Every change keeps the function
  signature, return type, provenance record, and UI unchanged. Callers must
  not know which path answered. Where the code path answers, the provenance
  is recorded with provider `"local"` and the model name of the technique
  (for example `"keyword-match"`, `"ffmpeg-blackdetect"`, `"vision-classify"`).
- **D3. No new dependencies.** Apple frameworks (Vision, NaturalLanguage,
  Speech, Translation), Foundation, and the existing ffmpeg binary only.
  No Swift packages.
- **D4. Behavior is provable.** Each item ships with unit tests that run
  without a network, an API key, or ffmpeg where possible. Frame-based items
  use the fixture video in `ClipBuilderTests/Support/FixtureVideo.swift`.
- **D5. A setting keeps the old path reachable.** One toggle in Settings ›
  AI, "Prefer on-device processing" (default on). It is a preference only:
  off means every site calls the model as today; on means the local path
  runs first and the model is still called whenever the local path is
  unsure. It never blocks network use. The value is read once at the start
  of each operation and held for that operation; changing it mid-run
  affects the next operation only.
- **D6. Log which path answered.** Every site emits one activity-log line
  naming the path ("Matched 4 images by keyword" / "Keyword match found
  nothing — asking the model").
- **D7. Acceptance bar before default-on.** Each item ships default-off
  behind its own key in `AIConfig.onDeviceOverrides: [String: Bool]` until
  the local path agrees with the model on a saved sample set at least 90
  percent of the time (item 14's compare action records the numbers). The
  global toggle in D5 only applies to items that have passed the bar.
- **D8. Mixed provenance.** When both paths contributed (local narrowing
  then a model call, or local groups plus model groups), the recorded
  provenance is the model's, with `technique` set to the local step's name
  so the AI details popup shows both. `AIProvenance` gains an optional
  `technique: String?` for this; `AIProvenance.local(technique:)` is the
  all-local case with provider `"local"`.
- **D9. Filenames.** Generated names are `<people> - <fight date>.<ext>`:
  people in roster order joined with " vs " for fights and " & " otherwise,
  and the fight date from `FightResearchRecord.fightDate` as `yyyy-MM-dd`.
  No type, outcome, or import date in the name.

## What already exists

- `FFmpeg.sceneChangeTimestamps(of:threshold:)` and `FFmpeg.duration(of:)`
  in `Services/FFmpeg.swift`; `FFmpeg.run(_:timeout:)` for new filters.
- `ThumbnailService.jpegFrames(url:at:)` for sampled frames.
- `PodcastExchangeSegmenter.candidateExchanges(segments:turns:)` in
  `PodcastAnalysisService.swift` (~line 506): a rule-based exchange splitter
  that already runs before the model to build chunks and boundary hints; its
  output is used as the final answer only when the model fails.
  `heuristicScore(duration:)` (~line 782) deliberately returns 0, so the
  fallback ships unscored scenes.
- `FFmpeg.sceneChangeTimestamps` reads ffmpeg's stderr directly (~line 202);
  `FFmpeg.run` returns stdout, so new detector wrappers need a stderr-capturing
  runner.
- `AppStore.shortDate` (~line 2365) formats `MM/dd/yy` and falls back to
  today; it is for the rename review sheet, not for filenames.
- `SceneFinder` caps scene search input at the 800 most recent scenes;
  `CoverFramePicker.sampleTimes/parse` pair the model's answer with the
  sampled timestamps; `DuplicateFinder.maxVideos` is 30 and groups carry a
  `keepID`.
- `AssetBrowserView.tagImage` (~line 449) defines subjects as
  person/event/topic and b-roll as cutaway, atmosphere, training, walkout,
  crowd, or establishing visual.
- `FightResearchService` builds a deterministic `QueryPlan` fallback
  (line ~133) before asking the model.
- `WizardEngine.parseRequest` validates the model's tags and template
  names against the real vocabulary and drops anything unknown.
- `AIResponseParser.jsonObject(from:)` and `AIProvenance` for recording who
  answered.
- Vision is imported in `RenderEngine`, `Analyzer`, `FramingService`,
  `PodcastAnalysisService`, `CenterStageService`. NaturalLanguage and
  SoundAnalysis are not used anywhere yet.

---

## Phase A — Pure string and number work (no frames)

### 1. Preference toggle and local provenance  (S)
Add `preferOnDevice: Bool = true` and `onDeviceOverrides: [String: Bool]`
to `AIConfig` in `AppSettings.swift` (Codable with defaults so old settings
files still load) and a toggle in Settings › AI with the caption "Use
on-device matching and detection before asking a model." Add
`AIProvenance.technique: String?` and `AIProvenance.local(technique:)`.
Add one helper, `OnDevicePolicy.isEnabled(item:config:)`, that combines the
global toggle with the per-item override and default-off state (D7); every
site calls it once at the start of the operation and passes the Bool down
into the service actor as a plain parameter, so actors never read settings
themselves. The AI details popup shows the technique line when present.
- Decisions: D2, D5, D7, D8.
- Tests: settings round-trip with and without the keys; policy table
  (global off, item passed, item default-off, override on/off); provenance
  encoding with and without technique.

### 2. Image library search without the model  (S)
`Views/ImageLibrarySearchSheet.swift` `run()` sends the model a list of
images with their stored `subjects` and `tags` and asks for matching ids.
Replace with a `LocalImageMatcher` (new file under `Services/`) that:
- Normalizes with `String.folding(options: [.diacriticInsensitive,
  .caseInsensitive])` so "Jiu-Jitsu", "jiu jitsu", and "jiu-jítsu" match,
  then tokenizes (split on whitespace and hyphens, strip punctuation, drop
  English and Portuguese stop words). Negations ("no", "sem", "without")
  exclude the following token.
- Scores each image: exact token hits weigh 3, prefix hits 2, and
  `NLEmbedding.sentenceEmbedding(for: .english)` cosine similarity between
  the query and the joined tag text adds up to 1 when the embedding is
  available (it is optional and must not be required).
- Returns images with score ≥ 3 (one exact hit), best first, capped at 60
  (the sheet has no cap today; 60 keeps the results grid usable). Ties
  break on newer file date.
When the local matcher returns nothing, or the query has three or more
content words and fewer than two exact hits (a paraphrase like "someone
getting swept"), fall back to the existing model call unchanged. The sheet
shows the same results list either way.
- Depends on: 1.
- Tests: a fixed inventory of six images; queries for a subject name, a
  tag, a two-word phrase, and a nonsense word (expects empty). Tests must
  pass with the embedding unavailable.

### 3. Wizard request parsing without the model  (M)
`WizardEngine.parseRequest(description:profile:emit:)` asks the model for a
JSON object whose fields are almost all closed-vocabulary. Add
`WizardRequestParser` (new file under `Services/`) producing a
`ParsedWizardRequest` deterministically:
- **Duration:** regex over `(\d+)\s*(s|sec|seconds?|m|min|minutes?)` plus
  spelled-out numbers up to twenty and forms like "one minute", "90-second",
  "1:30". Clamp to the existing 3…180 range.
- **Overlay text:** first quoted phrase (straight or curly quotes) following
  words like caption, title, text, overlay, saying, that says. Copy verbatim.
- **Overlay template:** best fuzzy match of any quoted or capitalized phrase
  against `OverlayTemplateStore.list()` names, using normalized Levenshtein
  distance with a 0.8 acceptance threshold; else nil.
- **Content tags:** every vocabulary tag whose normalized form appears as a
  token or phrase in the description ("fight footage only" matches `fight`
  and any tag containing it). Apply the same synonyms the prompt lists.
- **Flags:** `addCaptions` true only on "subtitles", "closed captions",
  "spoken captions", or "legendas"; a bare "caption" followed by a quoted
  phrase is overlay text, as the prompt already distinguishes. `useMusic`
  true/false on "music"/"no music"/"without music"/"sem música";
  `enableTextOverlays` true when overlay text or template was found or the
  text mentions "on-screen text"/"overlay".
- **Language:** all keyword lists carry English and Brazilian Portuguese
  forms; matching is diacritic- and case-insensitive.
- **Residual instructions:** the description with every matched span
  removed, whitespace collapsed.
Mark the result `confident` only when at least one structured field was
filled and the residual is under eight words after removal. Anything else
(residual-only requests, long creative briefs) goes to the model as today,
and the local parse's structured fields are merged in where the model
returned null. Keep the existing post-validation of tags and template
names for the model path.
- Depends on: 1.
- Tests: build a table of fifteen phrasings covering the rules in
  `parseRequestPrompt` (~line 405): duration forms, quoted overlay text
  after "caption"/"title"/"saying", loose template references, "fight
  footage only", subtitles versus caption, music on/off, and Portuguese
  equivalents ("um vídeo de 30 segundos com a legenda "Porrada day!" sem
  música"). "quick recap, punchy, dark mood" must be residual-only and not
  confident. Existing `WizardEngineTests` stay green.

### 4. Fight research query planning without the model  (S)
`FightResearchService` (~line 133) builds a deterministic `QueryPlan`
fallback that hardcodes MMA subreddits; the model spell-corrects fighter
names, adds nicknames, and picks subreddits per discipline. Keep the model
for the subreddit and nickname choice, but pre-resolve names locally:
fuzzy-match each fighter name against the profile's people names and names
already stored in `FightResearchRecord` rows (Levenshtein, accept at 0.85)
and pass the corrected names into the prompt. Skip the model entirely only
when every name resolved locally and a previous research row for the same
fighters already holds subreddits and nicknames to reuse.
- Depends on: 1.
- Tests: a misspelled known name resolves; an unknown name is passed
  through unchanged; a repeat lookup reuses the stored plan without a call.

### 5. File naming from metadata first  (S)
`AppStore.suggestFileNames(for:provider:model:)` sends the model people,
type, outcome, narratives, and transcript to compose a filename. Add a
template path per D9: `<people> - <fight date>.<ext>`, people in roster
order joined with " vs " when the video has a fight research row and " & "
otherwise, and the date from `FightResearchRecord.fightDate` reformatted
to `yyyy-MM-dd` (the field is free text; parse the common forms and omit
the date when it does not parse). Run the result through
`Analyzer.sanitizedFilenameSuggestion`. Use the template when the video has
at least one named person; otherwise call the model as today. The rename
review sheet is unchanged.
- Depends on: 1.
- Tests: two people with a fight date; one person without research (no
  date suffix); unparseable date omitted; no named people requests the
  model path.

### 6. Scene search: narrow before asking  (S)
`AppStore.findScenes(matching:in:provider:model:)` already caps input at
the 800 most recent scenes (`SceneFinder`). Build `LocalTextMatcher` as one
service shared with item 2 (rows of `(id, fields)`; item 2 is its first
client). Answer locally only when the query is made entirely of tag names
and people names (after normalization). Otherwise narrow to the top 200
locally-scored candidates plus every scene from the last 30 days, and send
those to the model. Never narrow below 100 when more exist, so a paraphrase
query cannot lose the right scene to an empty keyword score.
- Depends on: 2.
- Tests: tag-only query answered locally; "someone getting swept" is
  narrowed but keeps at least 100 candidates; the recent-scene guarantee.

### 7. Hashtags from tags  (S)
`WizardEngine` caption calls (~lines 2136 and 2216) return one combined
string of caption text plus hashtags, and `BrandProfile` has no hashtag
field. This item is an input reduction, not a removed call: build a
candidate hashtag list in code from the plan's content tags and people
names (deduplicated, `#`-prefixed, camel-cased multiword tags, capped at
the count the prompt specifies), pass it into the prompt as "use these
hashtags, add at most three more", and keep the combined-string return.
Add `hashtags: [String]` to `BrandProfile` (Codable, default empty) with a
Settings field so a profile can pin its fixed ones.
- Depends on: 1.
- Tests: hashtag list from a fixed plan; no duplicates; cap honored;
  profile pins come first.

---

## Phase B — Frame and audio work with ffmpeg and Vision

### 8. Trim suggestion from ffmpeg detectors  (M)
`Analyzer.suggestTrim(video:provider:model:log:)` sends 24 sparse frames
so the model can find where content starts and stops. Add
`FFmpeg.blackSegments(of:)` (filter `blackdetect=d=1.0:pic_th=0.98`) and
`FFmpeg.frozenSegments(of:)` (filter `freezedetect=n=-50dB:d=2`), parsing
the `lavfi` log lines into `[ClosedRange<Double>]`, plus the existing
`sceneChangeTimestamps`. Local rule: the content window starts after the
last leading black or frozen segment and ends before the first trailing
one. Return it locally only when the trimmed-off portion is at least 3
seconds and at most 40 percent of the duration; a single-take video with
no cuts is fine. When nothing was trimmed, answer locally with the full
range and reason "no static or black sections found" instead of calling
the model, since the model's job here is only to skip chrome and dead air;
the existing `Analyzer.suggestTrim` prompt (~line 768) also asks it to
skip replays and menus, which the detectors cannot see, so when the
per-item override is off or the video is a screen recording (filename
starts with "Screen Recording"/"ScreenRecording") keep the model path.
Run both filters in one ffmpeg invocation with a stderr-capturing runner
(`FFmpeg.runCapturingStderr`), 120 s timeout, cancellable through the
existing `ProcessRunner`. Cache the parsed segments in a new
`video_detectors` table (`video_id`, `algorithm_version`, `black_json`,
`frozen_json`, `cuts_json`, `computed_at`) via the migration list and a
`Database.schemaVersion` bump; invalidate when the file's size or
modification date changes.
- Depends on: 1.
- Tests: fixture video padded with two seconds of black at each end via
  ffmpeg in the test (skip when ffmpeg is missing); expect the window to
  exclude the padding. Parsing tests for the two log formats with fixed
  sample stderr text.

### 9. Long recording classification with signals first  (M)
`Analyzer.classifyLongRecording(video:provider:model:log:)` sends five
frames for a single label. Compute, for the same five frames plus
detector output from item 8:
- cut rate per minute from `sceneChangeTimestamps`;
- face count per frame from `VNDetectFaceRectanglesRequest`, and whether
  the same count holds across frames;
- aspect ratio and whether the picture is split in two halves: one face
  in each horizontal half on most frames (the split-feed render in
  `PodcastAnalysisService` ~line 806 shows the crop geometry; no detector
  exists yet, so write one).
Rules, applied only when a rule fires on all five frames: two faces whose
boxes stay within 10 percent of their position across frames and a cut
rate under 3 per minute → `podcast`; the same with one face → `interview`;
cut rate above 12 per minute and `VNRecognizeTextRequest` finding text in
at least three frames → `recap`. Anything else, including all fight versus
training decisions, calls the model as today. The rules are conservative
on purpose: a demonstration with a stable instructor looks like an
interview, so `interview` additionally requires speech on at least 80
percent of the duration from the transcript features when a transcript
exists, and is otherwise left to the model.
- Depends on: 8.
- Tests: rule table with synthetic signal inputs (no video needed); the
  fixture video reaches the model path.

### 10. Duplicate detection by hash first  (M)
`AppStore.findDuplicateVideos(provider:model:log:)` sends one mid-frame
per video and an inventory line to the model. Add `DuplicateFinder.local`:
- byte-identical groups when file size and a SHA-256 of the first and
  last megabyte match (no decode needed);
- same-export groups when duration (±0.5 s), resolution, and the 64-bit
  difference hash of five frames (at 10, 30, 50, 70, 90 percent) are all
  within Hamming distance 4;
- everything else, including crops, re-exports with intros, and different
  lengths, goes to the model as today with the local groups excluded from
  the inventory.
`keepID` for a local group is the earliest `createdDate`, then the largest
file. Local and model groups are merged by video id before display, with
provenance per D8. Implement dHash in Swift on a 9×8 grayscale downsample
with Core Graphics; no library. Frame hashing runs off the main actor
through the existing `BoundedConcurrency` with the ffmpeg job limit.
- Depends on: 1.
- Tests: dHash of an image versus its re-encoded copy is within 2; versus
  a different image is above 20; grouping logic on synthetic hash sets;
  keep-id choice.

### 11. Cover frame candidates pre-filtered  (S)
`AppStore.proposeCoverFrames(for:provider:model:log:)` sends the model a
grid of frames. This is an input reduction, not a removed call. Before the call, drop
frames that are near-black or near-white (mean luminance under 0.08 or over
0.95) or whose Laplacian variance is below 25 percent of the median across
the sampled set (relative, so a soft-focus video still keeps frames).
Saliency is not used: it would discard readable title cards. Keep at least
four frames, and when fewer than four survive send the original set.
`CoverFramePicker.parse(_:sampledTimes:)` must receive the surviving
timestamps, not the original list, so the model's indices line up.
- Depends on: 1.
- Tests: a black frame and a blurred frame are dropped; at least four
  survive from a mixed set; parse receives the filtered timestamps.

### 12. Image tagging with Vision first  (M)
`AssetBrowserView.tagImage(_:)` (~line 449) sends every owned image to a
multimodal model for subjects (person, event, or topic), one of eight fixed
tags, and a b-roll flag whose definition includes training, walkouts, and
crowds. Vision cannot name events or topics, so this item is a pre-pass
that reduces model calls rather than replacing them. Add
`VisionImageTagger`: `VNClassifyImageRequest` labels mapped to the eight
tags (`crowd`, `establishing-shot`, `graphic`, `portrait` map directly
from Vision's taxonomy; `walkout`, `training`, `action` do not and stay
with the model), `VNDetectFaceRectanglesRequest` for a face count, and
`VNRecognizeTextRequest` to flag graphics. Answer locally only for the
clear cases: a graphic (text covers over 20 percent of the area, no
faces) or a crowd/establishing shot (Vision label ≥ 0.6, no face larger
than 5 percent of the frame), with `isBroll` true and subjects empty.
Every other image calls the model as today with Vision's labels added to
the prompt as hints. Vision requests run off the main actor with bounded
concurrency; the grid shows the existing per-item spinner either way.
- Depends on: 1.
- Tests: a fixture graphic and a fixture crowd photo answer locally with
  no model call; a fixture with a large face requests the model with hints.

### 13. Podcast exchanges: lock the unambiguous ones  (M)
`PodcastExchangeSegmenter.segment` (~line 518) already runs
`candidateExchanges` first and gives the model chunks with boundary hints;
the model repairs question-and-answer units and scores them, and the
heuristic fallback ships zero scores on purpose. Fixed heuristic boundaries
would lose that repair, so this item keeps the model for boundaries and
scores and instead reduces what it is asked to do:
- Exchanges whose candidate boundaries are unambiguous (a question sentence
  followed by one speaker turn ending in a pause over 1.5 s, under 90 s
  total) are marked `locked` in the prompt; the model may score and title
  them but not move them.
- Only ambiguous stretches (overlapping turns, no question mark, runs over
  180 s) are sent as open chunks for repair.
- Replace the zero `heuristicScore` with a transcript-feature score for the
  fallback only (speech density, filler ratio, and a question-mark bonus
  from `TranscriptFeatureAnalyzer`), capped at 0.5 so fallback scenes are
  ranked but never auto-favorited.
Boundary rules covered by `PodcastAnalysisTests` stay green.
- Depends on: 1.
- Tests: locked exchanges keep their boundaries after a stubbed model
  response that tries to move them; fallback scores are in (0, 0.5].

---

## Phase C — Verification

### 14. Agreement measurement and the acceptance bar  (M)
- Run the full suite via xcodebuild (the release gate in `TESTING-PLAN.md`).
- One "Compare on-device with model" action in Settings › AI (debug builds
  and a hidden defaults key in release) that, for every item with a local
  path, runs both on the current library, writes a JSON report to
  `.cache/on-device-agreement/<item>-<date>.json` with per-case agreement,
  and shows the percentage per item. This is the number D7 gates on.
- A per-item row in Settings › AI showing "on-device: passed 94%" or
  "model only (68%)" with the override switch.

### 15. Batch the translation fallback  (S)
`TranscriptToolsSheet.swift` (~line 210) already tries Apple's Translation
framework first and falls back to the model per row. Batch the fallback:
collect every row Apple could not translate and send them in one call
with numbered lines, then split the answer back. Same UI, one call instead
of N.
- Depends on: none.
- Tests: three failed rows produce one prompt with three numbered lines
  and map back in order; a short answer leaves the missing rows untouched.

---

## Open points to confirm while building

- Whether `NLEmbedding` is available for the user's system language; the
  matcher must degrade to token scoring only.
- The dHash thresholds in item 10 against real re-exports from Instagram
  versus originals.
- Whether `freezedetect` is compiled into the Homebrew ffmpeg the installer
  fetches; if not, use `mpdecimate` counts as the frozen-segment signal.

## Order for a single engineer

1, 15, 2, 5, 7, 3 (string work) → 8, 11 (ffmpeg and frame filtering) →
10, 12, 9 (Vision) → 4, 6, 13 → 14. Item 14 can start as soon as item 2
exists and grow with each item, since D7 needs its numbers before any item
goes default-on.

## Review log

- **September 7, 2026, Codex review.** Corrected: podcast helper ownership
  and the zero heuristic score, the date helper's format, the combined
  caption string and missing hashtag field, the b-roll definition, the
  wizard prompt's caption-versus-subtitles rule, fight planning's subreddit
  and nickname role, search caps, and `FFmpeg.run` returning stdout.
  Added: D5 toggle semantics, D7 acceptance bar with per-item default-off,
  D8 mixed provenance, D9 filename fields, detector cache schema and
  invalidation, concurrency placement, language-aware normalization,
  narrowing floors, item 15. Reframed items 7, 11, 12 as input reductions
  and item 13 as locked boundaries. Scope kept in full per the author.
