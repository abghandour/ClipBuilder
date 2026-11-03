# VIP focus: whoever talks, the VIP whenever the picture can return

Date: November 2, 2026. Status: implemented November 2, 2026 (Claude); replaces Interview focus (docs/Interview-Focus-Plan.md, superseded). Verified by unit tests and a Debug build; not yet driven live or rendered.

## Why

Interview focus kept the VIP in the picture at all times: tight on the VIP
while they answered, a two-shot or a pull-back toward the interviewer while
they asked. On most recordings the two people sit too far apart for one
9:16 frame, so the "two-shot" was a half-face or a slow pan that never quite
arrived, and on separate feeds the picture split in two. The user asked for
a framing that behaves like Speaker focus (full screen on whoever talks) but
with the VIP as the home position: a question shows the asker briefly and
returns to the VIP; a long answer cuts away to the asker for a moment; with
more than two people the picture rotates, favouring the VIPs.

## Rules

One person on screen at a time, full screen, on a single camera and on
separate feeds alike.

- Whoever talks is shown first. A turn shorter than 1 s (the planner's
  interjection limit) does not take the picture.
- A non-VIP who talks is shown for up to 2 s (`askerShow`), then the picture
  returns to the VIP who answers next (the next VIP turn), else to the VIPs
  in rotation. The return is skipped when it would leave the VIP on screen
  for less than 2 s (`minimumReturn`) before the next change: a short
  question stays on the asker until the answer starts.
- While a non-VIP keeps talking, the asker comes back for 2 s every 8 s
  (`vipStretch`) so a long question or a monologue is not a still of the VIP.
- A VIP who talks for 8 s earns a cutaway: 2 s (`cutaway`) on the last
  asker, else the next person in rotation (other VIPs included), then back
  to the VIP. It repeats every 8 s of VIP speech and never starts when the
  VIP could not return for 2 s before the segment ends or within the clip's
  2.5 s tail.
- The opening, silence and unknown stretches hold on the VIP: the VIP who
  speaks first, else the one with the most speech, else the first VIP tile.
- Shot changes are at least 2 s apart (`hold`, or the recipe's own minimum
  hold when larger). Moves: Smooth glides 0.8 s on a single camera; Cuts
  are hard cuts. Separate feeds always cut (a glide between feeds is a wipe).
- Pull back (the wizard's `interviewZoom`) still opens every shot from
  face-tight (0) to the full source height (1).
- Settings (added November 3, 2026, user request): the Framing rows show,
  under Moves, when VIP focus is the shot or Auto will pick it: "Asker"
  (1–5 s, how long an asker or cutaway stays; the hold between changes
  never exceeds it), "Hold" (4–20 s, how long a talker holds the picture)
  and "Sentences" ("Finish the sentence"). Stored on `Framing` as
  `vip_show`, `vip_stretch`, `vip_sentences` (absent = defaults), copied
  to `CropRecipe.vipShow/vipStretch/vipSentences` by FramingPlanner.
- Finish the sentence: a return or cutaway due inside a sentence waits for
  the sentence's end (or the next talker change, whichever is first); a
  new talker always cuts at once. Sentence ends come from the original
  transcript lines that close with sentence punctuation (every line end
  when none do): `VIPFocusPlanning.sentenceEnds`. They reach the planner
  through `FramingContext.sentenceEnds` from the podcast render
  (WizardPodcastTimeline loads the transcript when the option is on) and
  the wizard preview (its recording snapshot's segments). The Builder's
  Compose and scripts plan without them.

## Design

- `Services/VIPFocusPlanning.swift`, a `nonisolated enum` with the
  constants above and `events(segments:tiles:vipTiles:range:hold:)`, the one
  rhythm for both camera kinds. It returns `(time, tile)` on the source
  clock, deduped, hold-spaced, nothing in the tail. A pure function with
  `VIPFocusPlanningTests` beside it.
- `CropRecipePlanner.plan` for `.interview` (raw value `interview_focus`
  unchanged, so saved recipes and provenance keep working; the user-facing
  name is "VIP focus"):
  - hold = `CropRecipePlanner.hold(for:)` (2 s for VIP focus), segments are
    built with `fillOpening: false` so the opening is the planning's call;
  - single camera: a face-tight rectangle per tile from
    `InterviewFocusPlanning.rects(vipFace:otherFaces: [])` with the recipe's
    pull-back, shots from the events, path through
    `InterviewFocusPlanning.path(shots:length:moveSeconds:)` (0 for cuts);
  - separate feeds: the `.talker` cell takes the events (hard cuts or, under
    Steady camera, tracking spans) instead of the talker-cell rules.
- `InterviewFocusPlanning` keeps `rects`, `tightHeight`, `inDeadZone` and
  `path(shots:)`; `moves`, `path(moves:)` and `rect(for:)` are removed with
  their tests. `InterviewPunchIn` and `CropRecipe.interviewPunchIn` stay as
  stored, ignored settings so old JSON decodes.
- `InterviewFaceSampling.sampleTimes` samples the range start and each
  event's settled time (plus the glide when not cutting).
- Renames: `Kind.interview.name` "VIP focus", new summary; `Kind.vip.name`
  "VIP on screen" so the two labels differ; FramingPlanner's reason,
  VIPRecipePlanning's note and InterviewFaceSampling's logs say VIP focus.

## Not changed

Analysis, speaker turns, portraits, the on-disk recipe keys, the Framing
rows (Shot picker shows the new name and summary), Speaker focus's other
shots, the fight "Fighter focus".

## Verification

Suites: VIPFocusPlanningTests, InterviewFocusRecipeTests,
InterviewFocusPlanningTests, InterviewFaceSamplingTests, CropRecipeTests,
CropRecipePlannerTests, FramingPlannerTests, FramingTests,
WizardPreviewCompositeTests, VIPRotationTests. Live: Rough cut on the Johnny
Walker interview with Smooth and Cuts, single camera and a split recording.
