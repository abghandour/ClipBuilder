# Strike Stats Overlay Plan

Date: October 11, 2026. Status: phases A and B implemented October 12, 2026 (Codex), uncommitted; Debug build passes, 22 new tests and the 3 team-sync suites pass. Phases C to G not started. Revised October 11 after the Codex
review in docs/Strike-Stats-Overlay-Codex-Review.md.
Implementation: Codex; build, tests and review: Claude (per the September 23 working rule).

## Problem

Fight clips are the app's main genre, and the most shareable moment is a
landed strike or a takedown. Viewers want a number on it. Real impact force
cannot be measured from video: force is impulse over contact time, contact
time is 5 to 20 ms, and effective striking mass is a technique variable, not
the fighter's weight. Single-camera 2D pose tracking also cannot see motion
toward the camera. So the product never shows newtons, "pounds of force",
energy, or any wording that reads as a physical measurement of the blow.

What video does support, and what this plan ships, in two tiers:

| Tier | Quantity | Source | Label |
| --- | --- | --- | --- |
| Counts | strikes, significant strikes, knockdowns per fighter, per analyzed span | existing `fight_events` | AI-scored |
| Counts | takedown attempts, completions, success rate, opponent's takedown defense | fight-scoring pass with an attempt sequence (new) | AI-scored, "n of m resolved, k unclear" |
| Counts | submission attempts, finishes, opponent's submission defense, by hold type | the same attempt sequence | AI-scored, "n of m resolved, k unclear" |
| Estimates | peak projected hand or foot speed around a strike | on-device body pose over a short window, calibrated per fighter from a known height | "estimated", with a visibility badge, or unavailable |
| Estimates | projected head movement of the target after a landed strike | same pass, target's calibration | "estimated", or unavailable |
| Rankings | highest estimated speed among the accepted strikes in the clip or round | derived from accepted estimates only | scoped: "among 12 analyzed strikes" |

Deferred, not in any phase: impact energy, force, head rotation in degrees,
"hardest hit", fatigue or speed-decay claims, `ground_strike` metrics,
3D depth, cage-geometry calibration.

## What exists today

- `Analyzer.scoreFightAction` (Services/Analyzer.swift L1238) produces
  `FightEventRecord` rows (video, time, fighter key, action, points) for
  `.fight` and `.recap` videos through an AI pass over frames sampled at about
  1 s, only over action-tagged scenes (L1252). The prompt (L1193) already
  describes a completed takedown as ending in control; it has no failed
  attempt category. `submission_attempt` exists (5 points) with no outcome
  or hold type. Event rows have no target, interval, outcome or scoring
  version. `replaceFightEvents` (Data/Database+Fights.swift L21) deletes and
  reinserts all rows for a video, and fight events sync to the team workspace
  (Services/TeamSync/SyncTable.swift L165).
- Vision use is the new Swift struct API; no body-pose request exists.
  `MediaWorkScheduler` allows one Vision permit; `CenterStageService` shows
  decode and Vision permits (L430, L512).
- Per-video roster: `VideoPersonRecord` with one portrait box at one time, not
  a track. Fighter attributes are `person_tag_fields` rows; height is not
  stored.
- Overlays: `TextOverlayItem.design` dispatches "nameTag" / "hero" / "tag" in
  `Services/TextOverlayRenderer.swift` L169. `TextOverlayItem` has explicit
  `CodingKeys`, `init(from:)` and `encode(to:)` (Data/TimelineModels.swift
  L1230, L1259, L1292), so a new property must be added to all three.
  `MultitrackRenderer` pre-renders overlays to timed full-frame PNGs at
  timeline times (L444, L463); captions are remapped from source to screen
  time per clip speed separately (L1410).
- Coverage: `AnalysisPipeline` has `visualPass` and `podcastPass`;
  `AnalysisCoverage` reads one pipeline integer from the latest run.
- Look step Overlays group is gated by `lookFormPlan.step2Controls`
  (Views/WizardView+Look.swift L112); Builder has `BuilderAddMenu` (L77).
  `WizardEngine` (L899) receives scenes, outcomes and fight research, not the
  event list.

## Design

### 1. Definitions and storage contracts (prerequisite for everything)

**Fight event identity.** Lazy, optional columns on `fight_events`:
`target_key`, `end_time` (nil for instantaneous actions), `outcome`
(`completed`, `defended`, `unresolved`, nil for non-attempt actions),
`detail` (free text such as the hold type for a submission attempt),
`scoring_version` (Int), `generation` (Int64, one value per
`replaceFightEvents` call, stored on every row of that call). All optional so
synthesized decoding of older rows and old sync payloads keeps working.

**Deduplication rule.** One physical blow is one row. The prompt is told that
`significant_strike`, `hurt` and `knockdown` replace `strike` for the same
blow, never accompany it. `StrikeStatsSummary` additionally merges rows for
the same fighter within 0.4 s whose actions are in the strike family and keeps
the highest-value one, so legacy rows do not double count.

**Pass coverage.** New table `analysis_passes(video_id, pass, version, status,
started_at, completed_at, note)` with pass in `fightScore`, `strikePose`.
Status is `running`, `completed`, `cancelled`, `failed`. A completed pass with
zero results is still `completed`. `AnalysisCoverage` reads this table for
fight passes; the single pipeline integer stays for the visual and podcast
passes. The Analyze coverage column shows "scored v2 · pose v1" or "scored v1
(no attempts)".

**Metric lifetime.** `strike_metrics` rows carry the event `generation`. A
pose job reads the generation at start and discards its results if the
generation changed when it tries to commit. `replaceFightEvents`, including
the sync path, deletes `strike_metrics` rows of the previous generation. The
previous completed pose result stays visible until a replacement pass
completes; a cancelled pass writes nothing.

**Round scope.** Rates are reported "in analyzed footage", never "in the
round", unless round boundaries are known. Boundaries come from
`fight_research` when the story JSON has them, otherwise from scene tags
`round:N` that the scorer emits when it sees a round card or clock, otherwise
the editor sets them in the Analyze table. Recaps always use "analyzed
footage" wording.

**Source binding for overlays.** A strike stat overlay stores
`sourceVideoID` and `sourceTime`, and the renderer maps that to timeline time
through the clip that contains it (trim, speed, repeats), the same way
captions are remapped at L1410. If no clip contains the source time, the
overlay is skipped and the Builder marks it "source not on timeline". The
overlay keeps its own snapshot of the numbers; re-analysis never edits an
existing overlay. The inspector offers Refresh from analysis.

### 2. Grappling attempts: takedowns and submissions

Takedowns and submissions share one attempt-sequence model: an action with an
entry time, a resolution time, a target and an outcome. The scorer never
reports an attempt as an instant. `StrikeStatsSummary` treats both with the
same code path, keyed by `AttemptKind` (`takedown`, `submission`).

**Takedown protocol (`fightScorePass = 2`).** The scorer reports a takedown
as a sequence: `takedown_attempt` with `at_time` (entry),
`end_time` (resolution or last observed frame), `target_key`, and `outcome`:

- `completed`: the attacker establishes the control criterion (opponent's
  hips or back on the mat with the attacker on top or holding a dominant
  position). A completion that is immediately reversed is still completed,
  followed by a separate `reversal`. Standing back up is an escape and does
  not undo the completion.
- `defended`: the attempt ends with the defender on the feet and free.
- `unresolved`: the attempt is still in progress when the sampled window
  ends, or the frames do not show the resolution.

The existing `takedown` action becomes the completed case: the scorer emits
`takedown_attempt` with `outcome = completed`, and `FightScoring.actionPoints`
maps that to the existing 4 points. `defended` and `unresolved` attempts
score 0 points, so pace and "who is winning" outputs do not change. A
separate activity count is available in the summary if a future scoring
change wants it. The prompt gets three worked examples (sprawled single leg =
defended; completed double leg then scramble up = completed + reversal;
window ends in the clinch against the fence = unresolved) and is told a
continuing chain is one attempt, not several.

**Submission protocol (same pass).** The scorer reports `submission_attempt`
with `at_time` (the hold is locked or the attacker commits to it, for example
hooks in for a rear-naked choke, hips through for an armbar), `end_time`,
`target_key`, `detail` (hold type from a fixed list: rear-naked choke,
guillotine, arm triangle, triangle, D'Arce/anaconda, armbar, kimura,
americana, heel hook, kneebar, ankle lock, other choke, other lock, unknown)
and `outcome`:

- `completed`: the defender taps, goes out, or the referee stops the fight
  during the hold. A completed submission ends the fight, so the summary
  cross-checks it against `FightOutcome.method`; a completed submission
  without a submission outcome, or two completed submissions, is flagged
  `outcome_check` in the Analyze table rather than silently counted.
- `defended`: the defender escapes, the hold is released, or position changes
  so the hold is gone while the defender is conscious.
- `unresolved`: the window ends with the hold still on, or the frames do not
  show the resolution.

Transitions between holds (triangle to armbar) are one attempt with the
final hold in `detail`; a release and a fresh entry more than 3 s later is a
new attempt. Points stay at the existing 5 for any `submission_attempt`
regardless of outcome, so existing pace output is unchanged; a completed
submission adds nothing beyond the fight outcome. The prompt gets examples
(guillotine released on a standing pass = defended; rear-naked choke with the
tap = completed; mounted triangle into armbar when the window ends = one
unresolved attempt, detail armbar).

**Rates** (pure `StrikeStatsSummary`), per attempt kind, per
attacker–defender pair and scope:

```
resolved = completed + defended
success  = completed / resolved
defense  = defended  / resolved      (the defender's takedown or submission defense)
```

Both numbers come from the same rows so they always sum to 100 % for the
pair. For submissions the summary also groups attempts by `detail` so the
card can say "3 submission attempts · 2 chokes, 1 armbar". A fighter's own offensive success and defensive rate are shown as two
separate lines and are not presented as complements.

**Display.** Always numerator and denominator: "Takedowns 3 of 5 resolved ·
60 % · 2 unclear"; "Submissions 0 of 3 resolved · 3 attempts · defense
100 %" for the opponent's line. With no attempts: "No takedown attempts" /
"No submission attempts". Legacy rows (scoring version 1) have takedown
completions but no denominator: "3 takedowns · attempts not scored", and
submission attempts with no outcome: "2 submission attempts · outcomes not
scored", each with a Re-score hint. Percentages are never shown with
fewer than 2 resolved attempts; the "n of m" text is always shown. Every
takedown and strike count carries the `AI-scored` badge, because strike
counts come from the same sparse inference.

**Pose cross-check** (phase E, advisory only, takedowns only; submissions
have no pose-visible resolution). When the pose pass runs, it samples −1 s to
+4 s around each takedown attempt and records whether the defender's
hip landmarks drop below the knee landmarks of the attacker for at least 0.5 s,
in image space, only when the camera is static over the window. Disagreement
with the scorer's outcome is stored as `strike_metrics.flag = outcome_check`
and shown as a "check" badge in the Analyze table. It never changes the
outcome or the rates.

### 3. Strike speed and head movement estimates

**Contact refinement.** Fight event times are about 1 s coarse. For each
event in the strike family the pass decodes native frames from −1.5 s to
+0.8 s around `at_time`, runs pose, and locates contact as the frame where the
striker's candidate limb endpoint is nearest the target's head or torso
landmarks and the approach velocity changes sign. If more than one candidate
contact exists in the window, the one nearest `at_time` is taken and the
others are dropped (they are either a different scored event or an unscored
blow). If no contact candidate is found the metric is `unavailable: no
contact`.

**Active limb.** Candidates are both wrists, both elbows, both ankles and
both knees. The active limb is the one whose endpoint is nearest the target at
contact, and the technique family (punch, elbow, kick, knee) follows from the
limb, not from which joint moved fastest. The Builder inspector lets the
editor change the limb; the metric is recomputed from the stored tracks.

**Tracking and identity.** Bodies per frame are matched to the two roster
fighters by a short-term tracker: Hungarian assignment on a cost of box IoU
plus pose-similarity, seeded from the `VideoPersonRecord` portrait boxes and
from the scorer's fighter reference crops. If the assignment confidence
margin is below a threshold for more than 0.2 s inside the contact window, or
the two tracks cross, the metric is `unavailable: identity`. The previous
identity is never carried silently through a clinch.

**Camera motion.** A window is accepted only if the background is static:
sparse feature tracking on regions outside both person boxes must show median
motion under 1 px per frame. Pans, zooms and cuts give
`unavailable: camera`. No motion compensation in the first release.

**Calibration, per fighter.**

```
metres_per_pixel = torsoRatio × height_m / projected_torso_px
```

`projected_torso_px` is the distance from the shoulder midpoint to the hip
midpoint, measured on calibration frames only: frames where both shoulders
and both hips have confidence ≥ 0.5 and the shoulder width to torso length
ratio is within the upright range (rejects bent-over and strongly
foreshortened torsos). The median over accepted calibration frames in the
window is used. `torsoRatio` is a named constant with its source cited in
code; the spike (phase C) checks it against manually measured frames and
adjusts. Without a stored height for that fighter there is no absolute
figure: the overlay is `unavailable: no height` and the Analyze table says
which fighters need a height. There is no default height. The striker's
calibration applies to the striker's speed; the target's calibration applies
to head movement.

**Trajectory and peak.** Landmarks with confidence under 0.3 are gaps. Gaps
are never interpolated across contact; a gap of more than 50 ms inside the
0.3 s before contact gives `unavailable: occluded`. Speed is the derivative of
a Savitzky–Golay fit of degree 2 over a fixed 50 ms time window (so the
smoothing scale is the same at 60 and 120 fps; at 30 fps the window holds
only two samples and the metric is `unavailable: frame rate`). Derivatives
are one-sided at the contact boundary so post-contact motion does not enter.
Peak is the maximum fitted speed in the 0.3 s before contact. A peak more
than 3× both neighbours and with the landmark jumping more than a torso
length between frames is treated as a tracking jump and the metric is
`unavailable: tracking`. These parameters are initial values; the spike
replaces them with values chosen against manual annotations.

**Head movement.** Fixed landmark: the target's nose; if the nose is a gap
at contact the metric is `unavailable`. Reference is the nose's mean position
over the 0.2 s before contact; the value is the peak displacement over the
0.25 s after contact, converted with the target's calibration. Reported as
"estimated projected head movement". No degrees.

**View suitability.** The spike will produce a rule for views where the
strike travels mostly toward the camera. Until that rule exists the badge
reflects visibility and tracking only, and the label always says estimated.

**Badges and states.** Each metric has its own state: `estimated` with a
visibility badge (`clear` when every requirement above was met with margin,
`partial` when confidence or calibration count was near a threshold) or
`unavailable: <reason>`. Badges describe visibility and tracking, not
measurement error, and the inspector says so. A strike can have an estimated
speed and an unavailable head movement.

**Storage.** `strike_metrics(id, video_id, fight_event_id, generation,
fighter_key, target_key, limb, technique, contact_time, speed_mps,
speed_state, head_move_m, head_state, calibration_json, tracks_json, fps,
vision_revision, algorithm_version, flag, note)`. `calibration_json` holds
height, ratio, frames used and source; `tracks_json` holds the smoothed
landmark tracks so the inspector can change the limb and recompute without
re-decoding. Local only, not synced.

### 4. Presentation rules (enforced in code)

- Every pose-derived number renders with the word "estimated" in the overlay
  copy, including `clear` results, and with its badge. The qualification is
  part of the burned-in overlay, not only in the inspector.
- `unavailable` metrics never render a number; the Builder shows the reason.
- Rankings are computed only over `estimated` metrics of the same fighter
  within the clip's source span, with the scope in the copy: "highest
  estimated hand speed of 12 analyzed strikes". Never "of the round" unless
  the round scope is known and the pass covered it.
- Units are km/h, mph or m/s rounded to the nearest 5 km/h, 5 mph or 1 m/s.
- The strings "force", "N", "lbf", "PSI", "energy", "J", "hardest", "power"
  never appear in `StrikeStatsCopy` output; a test asserts it over every
  state, unit and technique.
- Strike and takedown counts carry `AI-scored`; wording is "in analyzed
  footage" unless round scope is known.
- The overlay's numbers are typed metadata; the rendered text is derived from
  it. Editing the text in the Builder detaches the item (badge removed, design
  falls back to "tag") so a badge never endorses a hand-edited number.
- A callout placed beside a fighter is static; its default duration is 1.2 s
  and it is placed by the fighter's box at contact time, transformed through
  the clip's crop. Panels (`roundCard`, `takedownCard`) are not attributed
  spatially and may run longer.

### 5. Overlay designs and data

Four `TextOverlayItem.design` values in `TextOverlayRenderer`:

- `strikeSpeed`: large speed with unit, "estimated · right cross", badge glyph.
- `headMove`: "estimated head movement 14 cm", badge, beside the target.
- `grapplingCard`: takedown row and submission row for each fighter, attacker
  success and defender defense, each "n of m resolved · % · k unclear", the
  submission row with the hold breakdown, `AI-scored`. The Builder can show
  only one of the two rows.
- `roundCard`: fighter name, strikes landed, strikes per minute of analyzed
  footage, top estimated speed with scope, takedowns row, submissions row,
  each with its badge.

`TextOverlayItem` gains `stat: StrikeStatPayload?`, a typed, versioned
Codable struct (`version`, `kind`, `sourceVideoID`, `sourceTime`,
`fighterKey`, `values`, `states`, `unit`, `scope`, `calibrationSummary`),
added to `CodingKeys`, `init(from:)` and `encode(to:)`. Older timelines decode
with `stat == nil`.

### 6. Controls

- **Analyze table:** "Strike estimates" button next to Score/Re-score, run as
  an `AppJobs` job with Stop and a status-bar row. Coverage column per
  section 1. Rows with `outcome_check` show a "check" badge. A "Fighter
  heights" affordance appears when any roster fighter lacks a height.
- **People:** "Height" tag field (metres) on fighters, editable by hand first;
  person research fills it when the web profile has it (later phase).
- **Builder:** Add menu entries "Strike speed", "Head movement", "Grappling
  card", "Round card". The two callouts pick the nearest eligible event
  within the selected clip's source span, within 2 s of the playhead, and say
  so when none qualifies. Grappling and round cards need no pose metrics. The
  inspector shows values, states, badge, calibration summary, limb picker,
  unit picker and Refresh from analysis.
- **Look step, Overlays group** (visible only when the video type supports
  fight features): "Strike stats" toggle. Indented under it: Units; Speed
  callouts (on); Grappling card (on); Round card (on). Keys
  `wizard.strikeStats`, `wizard.strikeUnits`, `wizard.strikeSpeedCallouts`,
  `wizard.strikeGrapplingCard`, `wizard.strikeRoundCard`. Persisted with the
  run options like the other Look settings so copied runs keep them.

### 7. Wizard automation (last)

`WizardEngine` loads fight events and metrics for the run's sources and adds a
compact list to the planner context (time, fighter, action, speed state). The
plan clip gets `strikeStat: String?` validated by `WizardPlanRules` against
the metrics actually present. Automatic mode places one `strikeSpeed` on the
top accepted strike of the reel, a `grapplingCard` when the reel has a
resolved takedown or submission attempt (a completed submission is always the
reel's closing stat), and a `roundCard` on the last clip when the reel covers a known
round.

## Phases

- **A. Definitions and storage.** Event columns, generation, dedup rule,
  `analysis_passes`, coverage reading, metric invalidation on replace and on
  sync, source binding on `TextOverlayItem` with the typed payload. Tests:
  migration on an old DB, generation discard, coverage states, payload
  round-trip, sync replace clears metrics.
- **B. Grappling statistics.** Prompt v2 with takedown and submission
  examples, attempt sequence parsing for both kinds, hold-type list, points
  mapping, `StrikeStatsSummary` rates and display rules, `grapplingCard` and
  the grappling rows of `roundCard`, Analyze Re-score, Builder Add entries for
  both cards, Look toggles for them. Tests: pair rates sum to 100 % for each
  kind, unresolved shown, legacy rows show "attempts not scored" / "outcomes
  not scored", no percentage under 2 resolved, hold grouping, completed
  submission must match the fight outcome or be flagged, a hold transition is
  one attempt, no-force copy test. Hand check on three real fights with
  manually annotated takedown and submission attempts; record agreement in
  the plan. Ships on its own.
- **C. Feasibility spike (no product code).** A scratch tool under
  `scripts/` or a test target runs pose over 20 annotated strikes from the
  user's footage: measures runtime per frame on this machine, identity
  reliability, contact localization error, calibration ratio against manual
  measurement, and speed error against manual landmark tracks, with the same
  120 fps source downsampled to 60 and 30 at several offsets. Output is a
  results doc with acceptance gates (for example median speed error under 15 %
  on clear views, rejection rate, ranking agreement) and the chosen filter
  parameters and view-suitability rule. If the gates fail, phases E to G do
  not proceed and only the counts tier ships.
- **D. Heights.** People "Height" field by hand with provenance; Analyze
  affordance.
- **E. Estimates core and pose pass.** `StrikeTrajectory`, `StrikeScale`,
  `StrikeContact`, `StrikeTracker`, `CameraStaticCheck`, `StrikeStatsSummary`
  extensions, the pose sampler (AVAssetReader, merged windows, sequential
  bounded decode, `MediaWorkScheduler` permits, `nonisolated`), AppJobs job,
  `strike_metrics`, advisory takedown check. Tests: synthetic tracks for the
  numerics; plumbing on a `FixtureVideo`; parameters from C.
- **F. Rendering and Builder.** `strikeSpeed`, `headMove` designs, placement
  through `NameTagPlanner` collision logic with crop transforms, source to
  screen remap with speed, inspector with limb and unit pickers and Refresh,
  detach-on-edit. Tests: `MultitrackRenderTests` timing and SSIM, placement
  inside the safe area at 9:16 and 1:1, remap on a 0.5× clip.
- **G. Wizard automation.** Section 7. Person-research height extraction.

## Verification

- Unit tests per phase as listed. Hand checks use scratch data only.
- Phase C results are the gate for E to G and are recorded in
  `docs/Strike-Stats-Spike-Results.md`.
- After F, a hand check compares the same strike in the live angle and the
  slow-motion replay. Both must show the same technique and either agree
  within the spike's error band or one must be `unavailable` with a stated
  reason. No ordering between frame rates is assumed.

## Re-analysis

Already-analyzed fight and recap videos keep their fight events. To get
takedown and submission rates and defense they need a Re-score (scoring v2); to get speed or
head movement estimates they need the strike pass and a height for each
fighter. Nothing else re-runs. Coverage shows which is missing, and the Wizard
Look group says "no strike stats yet" with a button that starts the job.

## Open questions

1. Who sets round boundaries when neither fight research nor the scorer
   finds them: is a per-video manual field in the Analyze table enough?
2. Should the `AI-scored` badge be on by default on existing strike-count
   overlays (name tags with counts) too, as a separate small change?
3. Spike footage: which fights have a 120 fps source available for phase C?
