# Peace Grappler gap closure — implementation plan

Source: `docs/PG-System-Overview-Gap-Analysis.pdf` (September 4, 2026).
Scope: every item marked Missing or Partial there, **except** third-party
integrations (Windsor, HypeAuditor, OpusClip) and other platforms (TikTok,
YouTube publishing and metrics, "where to post"). Those are listed at the
end as deferred so nothing is lost.

How to use this file: the numbered list is the build order. Move items up
or down freely; each item says what it depends on so a reorder is safe if
the dependency still comes first. Answer the questions under an item by
editing it in place; anything unanswered will be built on the stated
assumption.

Effort: S = a day or two, M = about a week, L = two weeks or more.
Items sharing a phase can be built in parallel.

---

## Phase A — Foundations everything else builds on

### 1. Output sizes and aspect ratios  (L)
Parameterize the fixed 1080×1920 canvas: render presets for 9:16, 1:1,
4:5, 16:9 at 1080p and 4K (2160-wide / 2160-tall), plus a custom size.
Touches both renderers, screen-crop layouts (stored as fractions already,
so mostly canvas math), overlays, area framing, captions, cover frames,
and the Builder preview. The Wizard picks the preset from the profile
default; the Builder exposes it per timeline.
- Depends on: nothing. Blocks: 4, 11, 13, 16.
- Assumption: layouts, overlays, and framing keep working in fractional
  coordinates, so existing templates carry over to new sizes unchanged.
- **Q1.** Which presets matter on day one? Proposed: 9:16 1080p (current),
  9:16 4K, 16:9 1080p, 16:9 4K, 1:1 1080p. Anything else?
  No
- **Q2.** Should encode quality be a user setting (bitrate / CRF), or fixed
  per preset?
  user setting

### 2. Transcript pipeline upgrades  (M)
Make the transcript the backbone for the podcast features: speaker
diarization (who is talking, using the existing person identities),
silence and filler detection, and a shared "transcript segments with
speaker + energy" model that items 6, 7, 8, and 12 read. On-device only,
no network.
- Depends on: nothing. Blocks: 6, 7, 8, 12.
- **Q3.** Is on-device Apple speech good enough for podcast audio quality,
  or do you want an option to send audio to a cloud transcriber later?
  (Assumption: on-device only for now.)
  on-device for now

### 3. Cut cadence control and pace curve  (S)
An explicit "scene change every N seconds" control (2 s, 3 s, or a mix
range like 2–4 s) on the Wizard and in the format presets, replacing the
indirect cuts-per-minute steering. Add an optional pace curve: accelerate,
steady, decelerate, or build-then-drop, applied when the planner places
clips. The Builder shows the resulting cadence on the timeline ruler.
- Depends on: nothing.
- **Q4.** Should a chosen cadence override what the account benchmarks and
  reference templates suggest, or only apply when nothing else set it?
  (Assumption: an explicit choice always wins.)
  overrides win

---

## Phase B — Editing features the document asks for

### 4. Lower thirds as a first-class overlay  (S)
A "Lower third" overlay template type: name line, role line, optional
logo, enters and exits with a slide, anchored bottom-left or bottom-right.
The Wizard places one automatically for the first appearance of each
named person in interview and podcast footage; the Builder offers it in
the Add menu.
- Depends on: 1 (position math), people names already exist.
- **Q5.** Do you have an existing lower-third design to match, or should
  the first version be a clean default styled from the brand profile?
  create one. but just made an out of the box overlay option. no need to make it first-class

### 5. Proposed cuts with per-cut accept, reject, and edit  (M)
A review step between planning and rendering: the planner's clips appear
as a list with thumbnails, in/out times, and reason; each can be accepted,
rejected, or trimmed, and the plan re-validates before rendering. The same
review UI serves the podcast dead-air cuts (item 7) and the topic split
(item 6).
- Depends on: nothing for short-form; 2 for podcast use.
- **Q6.** Should this review be optional per run (a toggle, default on for
  podcast, off for fight clips)? (Assumption: yes.)
  yes optional

### 6. Topic separation for podcasts  (M)
Segment a transcript into topics with titles, using the diarized
segments: question-and-answer boundaries, subject shifts, and speaker
turns. Output is a list of titled ranges saved as scene-like rows so the
short-form Wizard can build one clip per topic and the long-form editor
can use them as chapters.
- Depends on: 2. Used by: 7, 12, 14.

### 7. Dead-air and garbage-cut suggestions  (M)
From item 2's silence and filler detection: propose cuts for long pauses,
filler runs, false starts, and off-mic noise, with per-cut accept, reject,
or shorten through item 5's review UI. Applies to both long-form and the
podcast short-form path.
- Depends on: 2, 5.
- **Q7.** What counts as dead air for you? Proposed default: silence over
  1.5 s, filler runs over 2 s, adjustable in Settings.
  default to suggested by allow user to adjust

### 8. Caption translation  (M)
Translate transcript segments into one or more target languages
(on-device Apple Translation where available, otherwise the routed AI
provider), store them as translation tracks (the schema flag already
exists), and burn in a chosen language or export as a sidecar subtitle
file. The profile gets a default subtitle language list.
- Depends on: 2.
- **Q8.** Which languages first? And burned-in only, or also SRT export?
  main languages are brazilian portuguese and english usa
---

## Phase C — Library and data bank

### 9. B-roll tagging and photo library by subject  (M)
Mark footage or scenes as B-roll (manual toggle plus an AI pass that
detects cutaways: crowd, walkouts, training, establishing shots). Run the
existing people and subject tagging over the Images library so photos are
named and searchable by fighter and event, the same as videos. "Ask the
Library" covers photos too.
- Depends on: nothing.

### 10. Photo and B-roll suggestions inside an edit  (M)
When the planner or the Builder has a clip on a subject, suggest owned
photos and B-roll for that subject ("use a photo here — here are the ones
you have"), placed as image overlays or cutaway clips the user accepts
through item 5's review. Suggestions also surface in the gap report.
- Depends on: 5, 9.

### 11. Instagram formats beyond reels: carousel, feed post, story  (M)
Render presets for a 1:1 or 4:5 feed video, a carousel of stills or short
clips pulled from a reel's best frames, and a 9:16 story cut. Creation and
export only; publishing them stays with the existing Instagram
connection.
- Depends on: 1.
- **Q9.** Is publishing carousels and stories through the existing
  Instagram connection in scope for this plan, or export-only for now?
  (Assumption: export-only; publishing is an integration task.)
  export-only

---

## Phase D — Long-form podcast
DELAY THIS feature. do not implement

### 12. Long-form podcast editor  (L)
Multi-source ingest for one episode: up to three host cameras plus a
separate Zoom recording, synced by audio waveform, with a horizontal
16:9 long-form render. Automatic camera switching follows the diarized
speaker (wide shot on cross-talk), chapters come from item 6, cuts from
item 7, both reviewed through item 5. Output is a long-form file in the
Library with chapter markers.
- Depends on: 1, 2, 5, 6, 7.
- **Q10.** What do the raw recordings look like today? Separate files per
  camera with a clap or common start? Zoom's cloud recording with separate
  speaker tracks, or one combined file?
- **Q11.** Should the long-form editor live in the Builder (new project
  type) or as its own screen? (Assumption: a new "Episode" project type in
  the Builder.)

---

## Phase E — Intelligence layer, using data the app already has

### 13. Record edit traits on every published reel  (S)
Store the traits the analysis needs on each generated video: screen
types used and for how long, cut cadence, hook type and length, people
featured, cut targets (fighter, B-roll, photo, text, graphic), output
size. Most already exist in the plan JSON; this makes them queryable.
- Depends on: 1, 3, 9. Blocks: 14, 15, 16.

### 14. Athlete return report  (M)
Per-person performance from published reels: followers gained in the
window, views, reach, watch time, shares, saves, and comments, normalized
per appearance, with a ranking by whichever metric you pick. Feeds the
planner as "who to feature" and the gap report.
- Depends on: 13, existing Instagram insights.

### 15. Hook and screen-type performance, with suggestions  (M)
Rank hooks by average watch time and reach (the closest proxies the
Instagram API exposes, since per-second retention is not available), by
hook type, length, athlete, and subject. Compare screen types (full,
split, diagonal), cadence, and cut targets against the same metrics.
Produce "suggested hook" and "suggested layout and cadence" for a new
clip, fed into the planner's benchmarks block and shown in the Wizard.
- Depends on: 13.
- Comment: true drop-off analysis ("where people stop watching") needs
  retention curves that Instagram does not provide by API. If you can
  export them from the app manually, an import path can be added later.

### 16. Feed winning timing and screen type back into the standard setup  (S)
Close the loop: item 15's winners become the profile's default cadence,
layout preference, and hook style, with a per-profile toggle and a visible
"learned from your results" note so the change is never silent.
- Depends on: 15, 3.

### 17. Spreadsheet export  (S)
Export the Reports data and the per-reel traits and results as CSV (and
optionally XLSX): per-reel rows with traits, metrics, and scores; per-week
account rows; athlete and hook rankings. File export only, no Sheets sync.
- Depends on: 13 for the traits columns; metrics already exist.
- **Q12.** CSV enough, or do you need XLSX with multiple sheets?
  csv is fine

---

## Phase F — Automation

### 18. Posting schedule with approval  (M)
DELAY THIS FEATURE DO NOT implement

A queue: rendered reels get a proposed slot from the best-posting-times
data, appear in a calendar view, and publish through the existing
Instagram connection when their time comes, only if approved ("say OK").
Unapproved items wait; a daily digest lists what is due. Runs while the
app is open.
- Depends on: existing Instagram publishing; 11 if formats other than
  reels should queue.
- **Q13.** Must this post while the app is closed (needs a background
  helper or a server), or is "app must be running" acceptable for now?
  (Assumption: app running.)


---

## Deferred (out of scope for this plan)

- Windsor, HypeAuditor, OpusClip connections.
- TikTok output, publishing, and metrics.
- YouTube publishing and metrics (the long-form 16:9 render in item 12 is
  in scope; uploading is not).
- "Where to post" recommendations across platforms.
- Per-second retention and drop-off analysis (no data source without a
  platform export).

## Open questions summary

Q1 output presets · Q2 encode quality setting · Q3 on-device vs cloud
transcription · Q4 cadence override rules · Q5 lower-third design · Q6
optional cut review · Q7 dead-air thresholds · Q8 translation languages and
SRT · Q9 publishing non-reel formats · Q10 raw podcast recordings · Q11
long-form editor placement · Q12 CSV vs XLSX · Q13 posting while closed
