# Podcast footage — implementation plan

September 5, 2026. Same format as `docs/PG-Implementation-Plan.md`: numbered
build order, effort (S = a day or two, M = about a week, L = two weeks or
more), dependencies, and the decision each item rests on. Items in one phase
can be built in parallel.

## The use case

Feed a podcast recording (5 to 30 minutes, sometimes a Zoom recording with
two people side by side in one frame). The app transcribes it, breaks it into
scenes that never cut a question or an answer in the middle, names who is
talking, flags the moments that would make a good short reel, and shows who
is speaking on screen — either by following the talker or by splitting the
two feeds into their own crop areas. From there the Wizard builds reels from
the flagged moments and the Builder works as it does for fight footage.

## Decisions (settled)

- **D1.** Videos run 5–30 minutes. Podcasts are analyzed transcript-first;
  frames are only sampled for speaker identification and thumbnails, never
  at the fight pipeline's per-interval rate.
- **D2.** Zoom recordings are usually two equal halves in one frame. The
  half-and-half layout is the first-class case; anything else falls back to
  the single-camera path.
- **D3.** Who-is-talking uses both signals: on-device audio speaker
  separation, and per-half mouth-motion detection in the picture. Picture is
  the tie-breaker when they disagree.
- **D4.** Transcription auto-detects the language, trying English and
  Brazilian Portuguese first; other languages only when neither fits.
- **D5.** Scenes are kept whole: one complete question-and-answer exchange
  per scene, however long. No maximum length; the Wizard trims.
- **D6.** Reel-worthy sections get both a highlight score on the scene card
  and an automatic favorite.
- **D7.** Speaker recognition matches faces against every person in the
  profile, including people first seen in other projects.
- **D8.** Transcripts are always generated for podcast videos.

## What already exists

- On-device transcription with word timestamps (`TranscriptionService`).
- Transcript features (speech, silence, filler) and speaker hints derived
  from visual person tags (`TranscriptFeatureAnalyzer`).
- Heuristic topic segmentation into titled ranges (`TopicSegmenter`,
  `TopicRange`).
- Cleanup proposals with accept/reject, and the Wizard's cut review.
- Center Stage tracking camera and screen-crop layouts (a 50/50 layout ships).
- Profile-wide people identities with portraits, markers, and merge.
- Video types: fight, training, interview, recap, other.

---

## Phase A — Podcast analysis pipeline

### 1. Podcast video type and pipeline switch  (S)
Add `podcast` to `VideoType`. Analysis dispatch checks the type: podcast
runs the transcript-first pipeline below; everything else keeps the current
visual pass. The type is inferred by the existing classifier (long, two
faces, mostly talking) and editable in the Sources detail pane as today.
- Decisions: D1, D8.
- Depends on: nothing. Blocks: 2–6.

### 2. Language auto-detection  (S)
Before transcribing a podcast, sample the first minute of audio with the
English and Brazilian Portuguese recognizers and keep the one with the
higher confidence; try other installed locales only when both score low.
Store the detected language on the transcript (the column exists).
- Decisions: D4.
- Depends on: 1.

### 3. Speaker separation from audio  (M)
An on-device pass that clusters the transcript's words by voice using audio
embeddings, yielding "speaker A / speaker B" turns with times. Output is a
`speaker_turns` table (video, start, end, cluster, confidence). No names
yet; that is item 5.
- Decisions: D3 (audio half).
- Depends on: 2.

### 4. Zoom half-and-half detection and mouth motion  (M)
Detect the side-by-side layout (two face regions with a vertical seam near
the middle, stable over time) and record it on the video. For each half,
measure mouth motion over time from sampled frames (face landmarks) and
produce the picture-side talker signal. Merge with item 3: where audio and
picture disagree, the picture wins; the merged result is the per-video
speaker timeline.
- Decisions: D2, D3 (picture half and tie-break).
- Depends on: 3.

### 5. Speaker identification against People  (M)
Match each speaker cluster to a person: sample a few clear frames from that
speaker's half (or the full frame for single-camera), run the existing
person recognition against the profile's whole People list, and assign the
person key with the best portrait match. Unknown speakers become new
people through the existing review sheet. Speaker turns then carry a person
key, which also feeds the transcript's speaker hints.
- Decisions: D7.
- Depends on: 4.

### 6. Whole-exchange scene segmentation  (M)
Replace the heuristic topic segmenter for podcasts with a two-stage split:
first, deterministic boundaries at speaker turns and sentence ends (word
timestamps, punctuation, pauses); second, one AI pass over the transcript
in chunks that groups turns into complete question-and-answer exchanges,
titles each, and writes a one-line summary. A scene is one exchange, kept
whole. Scenes land in the normal scenes table with tags (`podcast`,
`person:<key>` for each speaker, `question`, `answer`) so the grid, the
Wizard, and the Builder treat them like any other scene.
- Decisions: D5.
- Depends on: 2, 5.

### 7. Highlight scoring  (M)
In the same AI pass, score each exchange for reel potential: hook strength
in the first sentence, self-contained meaning, quotability, emotional or
surprising content, and a duration sweet spot of 20–60 seconds. Store the
score as the scene's score and excitement, and favorite scenes above the
threshold (default 7 of 10, adjustable in Settings). The scene card shows
the score badge it already has plus a "Reel" highlight chip.
- Decisions: D6.
- Depends on: 6.

---

## Phase B — Showing the speaker

### 8. Follow-the-talker framing  (M)
A Center Stage mode that uses the speaker timeline instead of motion
tracking: the crop sits on the speaker's half (Zoom) or on the speaker's
face (single camera), holds for at least 1.5 seconds before switching, and
cuts rather than pans between halves. Stored as a camera path like today,
so the Builder and Wizard replay it without re-tracking.
- Decisions: D3.
- Depends on: 4, 5.

### 9. Split feeds into two crop areas  (S)
For half-and-half recordings, a one-click "Split Zoom feeds" that applies the
50/50 horizontal layout with each area's source rectangle pinned to its
half and labeled with the person. Available per timeline in the Builder
and as a Wizard option; both this and item 8 are optional per timeline.
- Decisions: D2.
- Depends on: 4, 5; uses the existing layout system.

---

## Phase C — Making reels

### 10. Podcast highlight Wizard recipe  (S)
A recipe that plans only from highlighted podcast scenes, prefers
self-contained exchanges, keeps each exchange whole unless it exceeds the
target length (then trims at a sentence end), chooses follow-the-talker or
split framing from the timeline option, and adds the speaker's lower third
on their first appearance. Uses the existing cut review by default.
- Depends on: 7, 8, 9.

### 11. Builder parity  (S)
Podcast scenes appear in the Builder's scene browser with their score and
speaker chips; dropping one keeps the whole exchange; the framing option
applies per clip. No new Builder concepts.
- Depends on: 6, 8, 9.

---

## Phase D — Verification

### 12. Tests and a real recording  (M)
Unit: language pick from confidences; turn boundaries never split inside a
word; exchange grouping keeps question and answer together; highlight
threshold favorites; speaker tie-break prefers picture. Integration: a
synthetic two-speaker file (two tones panned left/right with a face
cutout each half) through items 3–5. Manual: one real Zoom podcast and one
single-camera interview end to end, checking scene boundaries by ear.
- Depends on: 1–11.

## Open points to confirm while building

- The people review sheet is used for unknown speakers as-is; if a podcast
  regularly has guests you never want stored, a "don't remember" choice may
  be worth adding.
- Highlight threshold and hold time are Settings entries with the defaults
  above; move them into the profile if they should differ per brand.

## Implementation and verification notes — September 5, 2026

The working tree now contains the podcast type and sparse pre-classification,
mandatory EN/pt-BR-first transcription, word-aligned voice windows with local
spectral embeddings, persisted speaker turns, sparse face-landmark motion and
center-seam checks, profile-wide portrait references, whole-exchange grouping
and scoring, saved speaker camera paths, split feeds, and the highlight Wizard
recipe. Camera hold affects framing only, not transcript speaker attribution.
Wizard introductions are timed to each named speaker's first turn; generated
timelines retain those introductions and labeled split tracks.

Exchange requests are batched at whole candidate boundaries. If AI grouping
fails, deterministic exchanges remain available with score zero; duration
alone does not auto-favorite a scene. No maximum scene duration is imposed.

Automated coverage includes language selection, multipart questions, sentence
and voice-window boundaries, picture tie-breaking, camera hold, sparse identity
sampling, speaker persistence and People merge/delete, Wizard trimming, and
split rendering with audio. The generated fixture uses alternating stereo
tones and colored halves; its identity test supplies picture signals and a
known roster. It does **not** establish recognition accuracy on real faces.

Still required for Phase D: a face-cutout fixture exercising positive Vision
detection and portrait recognition, plus an end-to-end real Zoom recording and
a single-camera interview, with boundaries checked by ear. No such recordings
were supplied in this workspace. Voice clustering currently supports up to two
voices using acoustic features, not a pretrained neural speaker model; accuracy
with similar voices, crosstalk, changing camera positions, and quiet speech
needs those recording checks. Language model downloads and live AI analysis
also require end-to-end validation.
