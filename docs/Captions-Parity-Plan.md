# Captions parity: template library, filler cuts, gaze, and the rest

Date: November 4, 2026. Status: approved November 4, 2026, all phases kept; phase 1 implemented by Codex and verified by Claude on November 4, 2026 (build, caption suites, library and Express picker driven live), committed since (checked 2026-11-24); phase 2 respecified 2026-11-24 (the cut needs a real removal step in the engine) 2a implemented by Codex with review fixes by Claude the same day (Debug build, 222 tests in 17 suites pass; driven live in Express, uncommitted), 2b not started; phases 3 to 5 not started.

## Why

Captions (captions.ai, by Mirage) only exposes burned-in captioning,
avatars and ad generation through its API, so none of its app features can
be bridged. This plan lists what we can build ourselves with the AI tools
already routed through `AITask` (text and vision models, image generation,
on-device Vision, transcription, translation, ElevenLabs and Mac voices),
in the order worth doing. Nothing here needs a new provider.

What we already match or beat, so it is not planned again: finding clips
(scenes, Q&A, highlights, soundbites, critic), word-level captions with
reveal, highlight and emphasis, per-speaker colours and positions,
translation, dubbing (Siri, Mac, ElevenLabs), noise reduction and loudness
(Speech polish), silence trims, framing, zoom and camera motion, B-roll
from the profile's own footage and image search, brand assets, Instagram
publishing and reports.

## Phase 1: caption template library

Captions sells "100+ caption styles" in three families: animated
word-by-word, highlights, and bold stacks. The twenty shown on its site are
named after stars and places: Cove, Energy, M81, Arion Pink, Quintessence,
Bellatrix, Prism, Freshly, Thuban, Mars, Runway, Grace, Copernicus,
Aldebaran, Nova, Alcyone Blue, Travel, Andromeda, Cassiopeia, Citadelle.
Only thumbnails are public, so the looks below are our own designs under
those names, plus the creator names every caption tool uses (Beast, Iman,
Ali, alongside our Hormozi and Karaoke).

Everything renders from `CaptionStyle` fields that exist today
(`wordsPerPage`, `weight`, `uppercase`, `highlight` colour/box/scale,
`emphasis`, `animation` pop/slide-up/fade, `reveal`, `bgOn`/`bgRadius`,
`decor` shadows, `position`, `emoji`, per-state `CaptionWordDecor`). Four
presets need small renderer additions, marked below.

| Name | Family | Settings |
| --- | --- | --- |
| Cove | word-by-word | 3 words, bold, reveal word, highlight colour (teal), soft shadow, bottom |
| Energy | word-by-word | 1 word, black, uppercase, highlight scale, pop, yellow emphasis, middle |
| M81 | highlights | 4 words, bold, highlight box (rounded, white on dark), no stroke |
| Arion Pink | highlights | 3 words, bold, highlight colour pink, emphasis colour, fade |
| Quintessence | bold stacks | 2 words, black, uppercase, two-line stack, slide-up, hard shadow |
| Bellatrix | word-by-word | 2 words, reveal word, highlight scale, glow shadow |
| Prism | highlights | 3 words, highlight colour cycling per page (renderer: colour list) |
| Freshly | bold stacks | 3 words, bold, boxed page, green bg, white text, radius 12 |
| Thuban | word-by-word | 1 word, black, uppercase, bounce animation (renderer: spring frames) |
| Mars | highlights | 3 words, bold, highlight box red, uppercase, pop |
| Runway | bold stacks | 4 words, serif bold, middle, letter spacing 0.05 |
| Grace | word-by-word | 3 words, serif, reveal word, italic emphasis (Interview Serif's cousin) |
| Copernicus | highlights | 3 words, mono, highlight underline (renderer: underline on highlight decor exists per state) |
| Aldebaran | bold stacks | 2 words, black, orange bg box, uppercase, hard shadow |
| Nova | word-by-word | 1 word, black, highlight scale, emoji on |
| Alcyone Blue | highlights | 3 words, bold, highlight colour blue, blue stroke |
| Travel | bold stacks | 3 words, bold, white bg, dark text, bottom |
| Andromeda | word-by-word | 2 words, reveal word, highlight colour purple, glow |
| Cassiopeia | highlights | 4 words, bold, highlight box yellow on black text |
| Citadelle | bold stacks | 2 words, black, uppercase, stroke 2, no bg, top |
| Beast | creator | 1 word, black, uppercase, highlight colour cycling (renderer: colour list), pop, emoji on |
| Iman | creator | 3 words, lowercase, light weight, highlight weight bold only |
| Ali | creator | 3 words, bold rounded sans, highlight colour, fade, bottom |

Renderer additions (two small ones): `highlightColors: [String]?` cycled per
page for Prism and Beast, and a `bounce` entry in `CaptionAnimation.frames`.
Glow and underline already exist through decor and `CaptionWordDecor`.

Library UI: the existing style library inserts a fresh copy of a preset;
add the family as a section header and a `CaptionPreviewImage` thumbnail
per preset so the list reads like Captions' gallery. Picker on the Express
Overlays tab lists the same groups.

Tests: every preset decodes and round-trips, no two presets are equal,
highlight, emphasis and speaker-colour defaults never collide (the
October 20 review rule), one preview render per family.

Effort: two days. Files: `Services/CaptionPresets.swift`,
`Services/CaptionAnimation.swift`, `Services/CaptionRenderer.swift`
(colour cycling), `Views/CaptionLibrary*.swift`, tests next to them.

## Phase 2: filler-word removal as a one-click option

Revised 2026-11-24 after reading the code. The first version of this
section said the engine could "feed the proposals as `cleanupCuts`". That
does nothing: `cleanupCuts` is only a block of text in the AI planning
prompt (`WizardEngine.swift`, "ACCEPTED PODCAST CLEANUP CUTS"), skipped for
the podcast preset, and Express has no planner to read it. The only code
that removes a span from inside a clip is the Builder's
`TimelineDocument.applyingCuts`. So this phase adds a real removal step.
Status: 2a implemented and driven live in Express 2026-11-24 (a 26 s clip:
3 cuts, −4.7 s, hard cuts, captions without the fillers; not yet heard by
ear, full wizard not driven); 2b implemented 2026-11-24 (marks and count
on the results card and the rough cut; the count is not on the pre-Generate
summary chip, where the cuts are not yet known). Codex review of 2a: four of
five findings fixed; translated captions still keep the filler.

As built, beyond the text below: the cut is skipped on a dubbed reel (the
toggle is hidden there); the applied spans are saved on the plan and the
timeline document (`appliedFillerSpans`) so a re-render and the Editor keep
the captions filtered; translated captions are not filtered (no word
timings). On the Peace Grappler transcripts (429 minutes) the rules find
about 1.5 cuts a minute, nine in ten of them repeated words.

What exists and is reused: `TranscriptCleanupProposer` (filler, repeated
word, false start, retake over timed words, English filler set) with its
tests; `Database.fetchTranscripts(videoID:)` for the active set's rows with
`language` and word timings.

### 2a: the option, the cut, the captions

**Where the cut happens.** Express and the AI Wizard both render through
`makeReel` → `renderSelection` (`WizardEngine.swift`). The plan is final
there after `applyPacing`, `renderTransitions` and `snapCutsToBeats`. Right
after the `snapCutsToBeats` block (for the podcast preset too) and before
`WizardStrikePauses.Eligibility(plan:)`, when
`options.removeFillerWords == true`, each plan clip is replaced by its
pieces around the filler spans. Pieces are ordinary `WizardPlanClip`s, so
extraction, pauses, drawings, voice-over and captions keep working per clip
and by source second. The rough cut and Open in Editor go through the same
function and get the cuts too. Not split at document level in
`prepareAssembly`: extraction is one contiguous file per plan clip and the
podcast merge assumes contiguous source per `originKey`.

**Pure rules** in a new `Services/Wizard/FillerCutRules.swift`
(`nonisolated enum`, no database), tests next to it:

- `spans(rows:)`: runs the proposer over the original-language rows (not
  translations) with the filler sets for the rows' language and returns the
  `.filler` and `.repeatWord` proposals as source-time ranges. False starts
  and retakes are not cut here (they stay a Transcript Tools review).
- `split(_ plan:, spans: [Int64: [ClosedRange<Double>]], sceneVideo:)`
  returns the new plan, the number of cuts applied and the seconds removed.
  Rules:
  - A clip is split only when `speed == 1`, `replay == false`,
    `areaClips.isEmpty` and `layout == nil`. Others pass through.
  - A span is clamped to the clip. A span at a clip edge trims that edge.
  - A cut that would leave a piece shorter than 0.5 s is skipped (the
    filler stays) rather than dropping real words.
  - `textOverlay`, `overlayKicker` and `speakerIntroductions` stay on the
    first piece only (introductions that start after the first piece ends
    are dropped). `brollCuts` are partitioned with
    `MiniBRollRules.retained(_:in:)`. `miniPickID`, crop and speaker names
    are copied to every piece.
  - Later pieces carry a new `continuesPrevious: Bool?` on
    `WizardPlanClip` (Optional, nil elsewhere). `WizardNameTags` shows no
    name tag on a clip that continues the previous one.
  - `plan.transitions` gets a `"cut"` at every new join; the transitions at
    the original clip boundaries keep their places. The same expansion is
    applied to `roughTransitions` in `renderSelection`.
  - Idempotent: splitting an already split plan changes nothing (Highlight
    history re-renders the recorded plan through the same function).
- The engine logs one line: `Filler words: cut N (−S.S s)`, or
  `Filler words: none found`.

**Captions.** A removed word must not be shown. `CaptionOverlayPlan.pages`
pages whole segments and keeps any page overlapping the clip window, so
without a change the filler stays in the page text. When the option is on,
words whose middle lies in an applied filler span are removed from the
`TranscriptSegment`s (and the segment text rebuilt from the remaining
words) before paging, for every clip of that video. A page that straddles a
join shows without the filler and keeps its word timing on both sides.

**Filler sets per language**, chosen by the two-letter prefix of
`TranscriptRow.language`, English when unknown. "Always" tokens are cut
wherever they occur; "between pauses" tokens only with a pause of
`conditionalPause` on both sides, as `like` is today, because they are real
words mid-sentence. Conditional matching is extended to bigrams.

| Language | Always | Between pauses |
| --- | --- | --- |
| en | um, umm, uh, uhh, uhm, erm, hmm, you know, i mean | like |
| pt | hã, hãm, ahn, hum | né, tipo, assim |
| es | eh, ehm, em, mmm | este, pues, bueno, o sea |
| fr | euh, heu, hum | bah, ben, genre |
| de | äh, ähm, hm | halt, also |
| ar | اه, امم | يعني |

`normalize` must keep accented and Arabic letters. Repeated-word detection
is language independent; a run of three or more of the same word is
deliberate ("whoa, whoa, whoa") and is left alone. `então` and `é` were
dropped from the Portuguese list and triple repeats spared on 2026-11-24,
at the user's request, after a count on real transcripts.

**Option.** `removeFillerWords: Bool?` on `WizardOptions` and
`MiniWizardSettings`, nil = off. Plumbed the way `drawnPauses` is: the
`WizardOptions` stored property, init and neutralizing in
`WizardEngine.swift`; `WizardOptionsSteps.swift` (step 2 field, CodingKeys,
split and merge); `WizardOptionsDecoding.swift`; the key lists in
`AIRunSettings.swift` and `AISettingsPreferences.swift` (`wizardKeys`);
`WizardPresetStore.nullableFields`; and for Express the hand-written
Codable, `step2Options`, `remembered` / `remember` with a
`MiniWizardMemory.Field`, `WizardPresetBridge`, and the rough-cut carriers
(`RoughCutOverlays`, `WizardRoughCut`).

**Controls.** Express: Audio tab in `MiniSettingsCard.audioRows`, outside
the `flow.showsAudioOptions` gate, shown only for flows that work from a
transcript (hidden otherwise, per the settings rule). Full wizard:
`audioFields` in `WizardView+Look.swift` with an `@AppStorage` key. Label
"Remove filler words" ("Cut fillers" in Express, where the label column is
96 pt), detail "Cuts um, uh and repeated words from the kept
footage. Check the result in the rough cut." Run summary: a "Filler words
cut" chip in the Audio section (`MiniWizardFlow.runSummaryCard` and the full
wizard's summary) when the option is on.

**Not covered in 2a.** The critic-loop proxy (`renderProxy`) does not go
through `renderSelection` and plays the fillers. Reel panel and Footage
list rows keep showing the saved clips, not the pieces. Camera focus is
planned per piece, so a podcast cut may reframe at a join.

**Tests.** Proposer: one case per language, conditional bigram, accents and
Arabic survive `normalize`. `FillerCutRules`: pieces never overlap a
removed span and never cut into a kept word; edge spans trim; a cut leaving
a piece under 0.5 s is skipped; ineligible clips pass through; overlay and
introductions on the first piece only; B-roll partitioned; transitions are
`"cut"` at new joins and unchanged elsewhere; idempotent. Options: round
trip through `WizardOptions`, step split/merge, `MiniWizardSettings` and a
preset, and old JSON without the key decodes. Engine: through the
`renderPlan` hook of `renderSelection`, a plan with the option on comes out
split and with the option off comes out unchanged. Captions: a page
straddling a join has no filler word.

Files: `Services/Wizard/FillerCutRules.swift` (new),
`Services/TranscriptCleanupProposer.swift`, `Services/WizardEngine.swift`,
`Services/Wizard/WizardPlanRules.swift` or `WizardNameTags.swift`,
`Data/WizardOptionsSteps.swift`, `Data/WizardOptionsDecoding.swift`,
`Data/AIRunSettings.swift`, `Services/Wizard/MiniWizardSettings.swift`,
`Services/Wizard/MiniWizardFlow.swift`, `Views/MiniSettingsCard.swift`,
`Views/WizardView+Look.swift`, tests next to them. Effort: two to three
days, not the one first estimated.

### 2b: showing the cuts

Cut spans as markers on the rough-cut and preview scrubber, through the
`scrubLane` slot of `ScrubbingPlayerView` that `VoiceOverLane` already
uses, and the count of cuts on the run summary chip. After 2a is verified.

## Phase 3: eye contact

Honest answer: real gaze redirection repaints the eyes in every frame with a
generative model. Captions runs its own model for that; macOS ships no
such model, and none of our providers (text and vision LLMs, still image
generation) can re-synthesize video at frame rate. We cannot add the
Captions feature itself without their API, and the API does not expose it
either.

What we can add with Vision on device, as "Gaze-aware framing":

- `GazeMeter`: Vision face landmarks (pupil and eye contour points) and
  head pose yaw per sampled frame, through the same sampling the
  `InterviewFaceSampling` and `VisualSpeechActivity` passes use. Produces
  looking-away spans per person per recording, stored like camera motion.
- Framing planner: inside a looking-away span, prefer the other speaker's
  tile, a B-roll cut, or a punch-in, so the viewer sees the reading glance
  less. An option "Hide glances" on the Picture tab, off by default.
- Critic: a note when a reel's talking head looks away more than a third of
  the time, with the spans, so the user can reshoot or cut.
- If a CoreML gaze-redirection model becomes available, it plugs in as a
  clip effect through `EffectCatalog` without changing the above.

Effort: two days for the meter and planner rule, half a day for the critic
note. Files: new `Services/GazeMeter.swift` with a synthetic-frame test (the
camera motion meter's pattern), `Services/Framing/*`, `Services/ReelCritic.swift`.

### Phase 3 respecified (2026-11-24, Claude)

Status: 3a (meter) built and committed 2026-11-24; 3a2 (stored, synced,
"Measure gaze", report line) built and driven live on one single-camera
clip the same day, server migration written and not applied; 3b and 3c
specified, waiting on the user's read of the numbers on their own footage.

**What the sketch above got wrong** (checked against the code and two real
recordings):

- "Stored like camera motion": camera motion is not stored. `CameraMotionMeter`
  output lives in a `Mutex` inside `CenterStageService.trackPeople` and is
  thrown away. There is no table, analysis pass or per-frame face data to
  extend, and nothing in the app reads head pose.
- "Looking away" cannot mean "not looking at the lens". In the Johnny Walker
  interview (side by side, 832x464) both people sit in near profile for the
  whole recording: median head yaw 66 and -37 degrees. A glance is a
  departure from that person's own usual pose in that stretch.
- No pass to ride on: `VisualSpeechActivity` refreshes faces every 2 s and
  only runs for two or more tiles; `InterviewFaceSampling` takes six frames.
- One person on one camera has no other shot to cut to. A punch-in does not
  hide a glance, it enlarges it. Only B-roll can cover it there.
- The critic knows nothing about who is on screen; deterministic notes are
  appended after `parse` today only as `learnedLines`.
- Effort: about a week and a half, not two and a half days.

**Probe** (scratch tool, not in the repo; `VNDetectFaceRectanglesRequest`
revision 3 then `VNDetectFaceLandmarksRequest` on its faces, frames at most
960 px): head yaw / pitch / roll come back in whole degrees, continuous
(the landmarks request alone quantizes yaw to 45 degree steps, do not use its
pose). Pupil position inside the eye contour box (0 centred, +-1 at a corner)
moves smoothly between -0.3 and +0.3 horizontally on a 400 px face. Six
frames of the Dana White clip checked by eye: vertical pupil offset -0.57 and
-0.74 = eyes cast down; yaw -23 and -28 = head turned to a reporter;
horizontal offset -0.25 and +0.29 = side glances with the head still. On the
66 px faces of the side-by-side interview the pupil reading is noise; pose
still holds. Cost: 517 frames in 7.7 s through `AVAssetImageGenerator`.

**Decisions** (Claude's recommendations, the user can overrule):

1. No database table and no sync. Gaze is derived from the footage and cheap,
   so it is measured for the clip ranges a reel uses and cached as a small
   JSON record in `RenderSegmentCache`, the way `FeedPathCache` caches camera
   paths (key: source fingerprint, range, region, meter version). Nothing to
   migrate, nothing to push to Supabase.
2. Order: 3a measures and reports (no change to any reel), so the user can
   judge the numbers on real footage before 3b lets them move a cut.
3. Single camera, one person: "Hide glances" only raises B-roll priority
   over a glance, and says so in the option's caption. No punch-in.

#### 3a: the meter, its cache, and the report line (Codex)

New `Services/GazeMeter.swift`, `nonisolated enum GazeMeter`, with the pure
rules separate from the Vision sampler so they are tested without footage:

- `struct Sample: Codable, Sendable, Equatable { time: Double; yaw: Double;
  pitch: Double; pupilX: Double?; pupilY: Double?; faceWidth: Double }`
  (degrees; `time` in source seconds; `faceWidth` in pixels of the analysed
  frame; pupils nil when the landmarks are missing or the eye box is empty).
- `struct Span: Codable, Sendable, Equatable { start, end: Double; kind: Kind }`
  with `enum Kind: String, Codable { case down, aside, turned }`.
- `static func spans(_ samples: [Sample], tuning: Tuning = .init()) -> [Span]`,
  pure:
  - Baseline per call = the median of yaw, of pitch, and of each pupil
    offset over the samples (the person's usual pose in this stretch).
    Fewer than `tuning.minimumSamples` (8) samples: no spans.
  - A sample is away as `turned` when `abs(yaw - medianYaw) >= 18` degrees
    or `abs(pitch - medianPitch) >= 14`; else as `down` when pupils are
    usable and `pupilY - medianPupilY <= -0.35`; else as `aside` when
    usable and `abs(pupilX - medianPupilX) >= 0.22`. Pupils are usable
    only when `faceWidth >= 120`. All thresholds live in `Tuning`.
  - Consecutive away samples form a span from the first sample's time to
    the last one's plus one sample interval; a gap of one sample inside a
    span is bridged; the span takes the kind most of its samples have.
    Spans shorter than `tuning.minimumSpan` (0.6 s) are dropped: a blink or
    a saccade is not a glance.
- `static func share(_ spans: [Span], of range: ClosedRange<Double>) -> Double`
  (0...1, spans clipped to the range).
- `static func pupilOffset(eye: [CGPoint], pupil: [CGPoint]) -> CGPoint?`,
  pure: the pupil centroid inside the eye points' bounding box, 0 centred,
  +-1 at the edges; nil for empty input or a degenerate box.
- Sampler: `static func measure(url: URL, range: ClosedRange<Double>,
  region: FreeCropRect? = nil, fps: Double = 5) async throws -> [Sample]`.
  `AVAssetImageGenerator` with zero tolerance, `maximumSize` 960, preferred
  transform applied; crop to `region` (a tile, in source fractions) before
  Vision; `DetectFaceRectanglesRequest(.revision3)` (the Swift API
  `PodcastAnalysisService` already uses at line 1181 for landmarks) then
  landmarks for the largest face only; a frame without a face yields no
  sample. Checks `Task.checkCancellation()` per frame. Never on the main
  actor.

New `Services/GazeCache.swift`, `actor GazeCache`, modelled line for line on
`FeedPathCache`: `Identity { fingerprint, region, start, duration, fps,
version }`, `Record { identity, samples }`, `samples(for:) / store(_:for:)`
through `RenderSegmentCache.key`. `GazeMeter.version = "1"`.

Report line, no option, no change to the reel: in `WizardEngine` after a
reel's clips are final (beside the existing "Filler words:" emit), for each
plan clip of an `interview` or `podcast` recording whose source is a single
camera or whose framing shows one full tile, measure the clip range (cache
first), and when `share >= 1/3` emit one line per reel:
`Gaze: looks away 38% of clip 2 (down 2.1 s, turned 1.4 s)`. Under a third,
or no face, emit nothing. Wrap in `WizardTiming.measure("gaze", ...)`. A
failure is logged once (`Gaze: not measured (<reason>)`) and never fails the
render. Separate-feed recordings with several tiles are left to 3b (they
need the tile regions).

Tests (`ClipBuilderTests/Services/GazeMeterTests.swift`, Swift Testing, no
footage): baseline relativity (a constant yaw of 60 gives no spans; a
departure of 20 from it does); each kind and each threshold just under and
just over; pupils ignored below 120 px; minimum span; one-sample gap
bridged, two not; majority kind; `share` with clipping; `pupilOffset`
centre, edges, empty and degenerate; fewer than eight samples. One
synthetic-frame sampler test only if a face can be drawn that Vision
detects reliably; otherwise leave the sampler to the live check and say so.
`GazeCacheTests`: store then read, a different range or version misses.

Out of scope for 3a: any option, any view, any planner change, the
database, Team Sync, the critic.

#### 3a2: measured once, stored, synced (user, 2026-11-24: "i want to avoid re-measured on another mac")

Replaces decision 1 above and 3a's `GazeCache` and per-clip measuring. The
meter and its pure rules from 3a stay.

- Measured once per recording, not per reel: analysis pass `gaze`
  (`AnalysisPassRecord.Pass`, version 1), run as an `AppJobs` job like the
  other missing passes (`AppStore+AnalysisMissingPasses.swift`), for
  `interview` and `podcast` recordings; one region per tile for separate
  feeds (`PodcastTile`), the whole frame otherwise. 5 fps. A 40 minute
  recording is about 12,000 frames per tile, a few minutes in the
  background (the probe ran about 67 frames a second).
- Baseline becomes a rolling one, since a whole recording has no single
  usual pose: the median over the samples within 30 s either side
  (`Tuning.baselineWindow`). `GazeMeter.spans` takes it as a parameter; the
  whole-stretch median stays for tests of short input.
- Stored as spans, not samples (small, and what every consumer wants):
  table `gaze_spans (id, video_id REFERENCES videos ON DELETE CASCADE, tile
  INTEGER NOT NULL DEFAULT 0, person_key TEXT, start_time REAL, end_time
  REAL, kind TEXT, meter_version INTEGER)`, index on `(video_id,
  start_time)`; queries in a new `Data/Database+Gaze.swift`
  (`replaceGazeSpans(videoID:tile:...)`, `fetchGazeSpans(videoID:)`).
  A measured tile with no glance stores one row of kind `none` with
  `start_time = end_time = 0`, so "measured, nothing found" travels too and
  the other Mac does not measure again.
- Team Sync: a `SyncTable(name: "gaze_spans", ... naturalKey: ["video_id",
  "tile", "start_time", "kind"], references: ["video_id": "videos"])`, a
  Supabase migration creating the table with the same columns and RLS as
  `speaker_turns`, and `SyncEngine.understoodSchemaVersion` 15 -> 16. The
  gate is exact: the migration is applied to the server only together with
  the release that ships this client, never before.
- A Mac that receives spans by sync and has no completed local `gaze` pass
  for that video treats the recording as measured when any `gaze_spans` row
  of the current `meter_version` exists (check whether `analysis_passes`
  itself syncs before adding anything else).
- The report line and everything in 3b and 3c read `fetchGazeSpans`, clipped
  to the clip's range; nothing measures during a render. A recording not
  yet measured reports nothing and "Hide glances" says "Measure gaze first"
  with the button that starts the job.
- A visible control (project rule): "Measure gaze" among the recording's
  analysis actions on the Sources card, with the pass's state.
- Tests: rolling baseline (a slow drift of 40 degrees over two minutes
  gives no span, a 20 degree turn for 1 s inside it does); database round
  trip and replace; the `none` row; sync column list equals the table's
  columns (the existing SyncTable schema test pattern).

#### 3b: "Hide glances" (after the user has seen 3a's lines)

- Option `hideGlances: Bool?` on `WizardOptions` / `MiniWizardSettings`
  (default off), Picture tab row "Hide glances" with a caption that says
  what it can do for this footage (several tiles: "Cuts to the listener
  while the speaker looks away."; one camera: "Covers glances with B-roll
  when B-roll is on."). Hidden where it can do nothing (one camera and
  B-roll off). Plumbing: the same sixteen places `removeFillerWords` went
  through (list in the 2a section), plus `FramingContext`.
- Several tiles: gaze per tile (region = the tile) for each clip range,
  handed to `CropRecipePlanner.plan` through `FramingContext`.
  `TalkerShotPlanning.events` treats a talker's glance span of at least
  `minShot` as a reason to show the listener for that span, inside the
  existing `maxShot` / `minShot` / `recent` rules; `VIPFocusPlanning`'s
  `cutawayTarget` does the same for VIP focus. Needs `PodcastTile.personKey`
  to place the span; a tile without one is skipped.
- B-roll: `PodcastHighlightBRollPlanner.plan` gives a window that overlaps
  a glance priority 0 (with pauses) instead of 2.
- Preview and render must agree: `WizardPreviewFraming` passes the same
  cached samples.

#### 3c: the critic note

After `ReelCritic.parse`, append to `critique.notes` the 3a line when a
clip's share is a third or more, with reel times from the plan's clip
offsets ("0:04-0:07"). Deterministic, no prompt change.

## Phase 4: the rest of their app, feature by feature

| Captions feature | Where we stand | Plan |
| --- | --- | --- |
| AI Edit (describe the edit in words) | Ask AI on Express and the Builder agent already map text to settings and timeline edits | Nothing new; add two example prompts to the Ask AI placeholder |
| Auto zooms from the script | Interview zoom, punch-in and camera moves exist, keyed to speakers | Add an "Emphasis zoom" option: a short punch-in on `CaptionEmphasis` words (numbers, names), rate-limited to one per 6 s. Half a day |
| Sound effects | None; music and beat detection exist | A Sound effects resource (whoosh, pop, riser, bundled royalty-free set plus user files) and a plan rule that places one on transitions and emphasis zooms, mixed under the dub and music ducking. One day |
| AI B-roll generator | Image generation produces stills; B-roll comes from footage and image search | "Generate B-roll" in the B-roll panel: keywords from the transcript segment become image prompts, each still becomes a Ken Burns clip through the existing image overlay path. One day |
| Auto emojis | Exists (`emoji` on the style) | Make it visible: an Emoji toggle on the Overlays tab next to the template picker |
| AI Denoise | Exists as Speech polish | Rename the chip to "Denoise and level" so it is recognisable |
| Eye contact | Phase 3 | |
| Caption templates | Phase 1 | |
| Filler removal | Phase 2 | |
| Lipdub (lip sync to the dub) | Not possible with our tools; needs a video generative model | Out of scope |
| AI Twin, AI actors, text-to-video, AI ads | Not possible without their API; also outside the product's purpose (real footage) | Out of scope |
| Translate captions, 100+ languages | Exists through the translate task | Nothing new |

## Order and estimate

1. Phase 1 templates (two days). Visible, no risk.
2. Phase 2 filler option (two to three days; see the revised section).
3. Emphasis zoom and sound effects (one and a half days).
4. Generated B-roll (one day).
5. Phase 3 gaze-aware framing (two and a half days). Needs the meter first.

About eight working days in total, each phase shippable on its own.
