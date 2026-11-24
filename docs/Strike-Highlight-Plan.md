# Strike Highlight Plan

Date: 2026-11-18, spec for phases 4 to 6 added 2026-11-19, phase 7 added 2026-11-20. Status: phases 1 to 5 and the highlight half of 6 implemented (committed since, checked 2026-11-24); phase 7 (Express action overlays and pause on contact, which includes Wizard freezes) specified at the end, in progress.

## What it is

Strikes are broken down into punches and kicks (knees and elbows are named too), and while a strike plays, the attacking limb gets a green band and the spot it lands on a red ring. Playback can hold for a moment on the impact. The highlight can optionally be burned into a rendered reel.

## Phase 1: punch and kick breakdown (done)

- The scoring prompt asks, per strike, for `technique` (punch, kick, knee, elbow), `limb` (attacker's left or right), `target` (head, body, legs) and `side` (the half of the still the attacker stands in).
- `Services/StrikeDetail.swift` holds them and stores them in the existing `fight_events.detail` column as `kick|left|legs|right`. No schema or sync change.
- `FightScoreDigest` counts punches and kicks; the inspector's Fight Action row shows "N punches" and "N kicks" chips beside "N strikes", each opening its frames. Strikes scored before this have no technique and appear only under strikes until re-scored.
- `StrikeStatsSummary.deduplicatedStrikes` no longer merges two blows 0.25 s apart when the scorer named them differently.

## Phase 2: highlight in the Sources player (done)

- `Services/StrikeHighlightRules.swift` (pure): from the body poses of the frames around a strike, picks the limb whose hand or foot is closest to the right part of another body AND has just travelled (a referee's arm or a held guard has not). The model's words only add penalties. Output is a track of keyframes in source seconds and 0…1 source-frame coordinates.
- `Services/StrikeHighlightFinder.swift`: Vision `DetectHumanBodyPoseRequest` on 12 stills a second, ±0.55 s around the logged time. About 0.3 s per strike.
- `Services/StrikeHighlightPainter.swift`: one CoreGraphics painter (green limb, red impact), used by `Views/StrikeHighlightOverlay.swift` over the player.
- Metadata: every strike's track (keyframes, `contact` time, aspect) is saved as JSON in the local table `strike_highlights` (video_id, at_time, fighter_key, contact_time, track_json, rules_version), written at the end of the scoring pass and dropped when the events are replaced. A strike scored earlier is found and saved the first time it is played (`AppStore.strikeHighlight`). The table is not synced: it is derived from the file and the events. Bump `StrikeHighlightRules.version` to have tracks found again.
- Fight Action header toggles: "Highlight" and "Pause on impact" (holds `StrikeHighlightRules.impactHold`, 0.8 s, at `contact` on every pass of the loop). Both are viewing preferences; the metadata is saved either way.
- Measured on "Blachowicz vs Ulberg - R3 Final Minute", 12 strikes: 10 got a highlight, about 7 of those on the right limb. Known misses: a walking referee's leg next to a fighter, and frames where the kicking leg is not detected.

## Phase 3: in the final video (highlight done; freeze frame not started)

Done:
- Per clip switch `TimelineClip.strikeHighlights: Bool?` (`strike_highlights` in the document, written only when on). Builder inspector: Fight > "Highlight strikes". Builder script op `set_clip_strike_highlights {clip, enabled}` and the typed request "show/hide strike highlights on this clip".
- Segment encode: `StrikeHighlightBurn.prepare` draws the pictures, `inGraph` lays them on the placement's source inside the existing encode graph, before any crop and before the speed change. No extra encode. Done inside the block that always releases the segment's dedupe key.
- Clips that get a framing intermediate (Center Stage, area frame): `StrikeHighlightBurn.burn` writes a QuickTime copy of the stretch first, because the framer reads a file with AVFoundation. A job that only tracks a camera path keeps highlights out of its key.
- Saved rows carry the `fight_event_generations` value of their events. Reads return only rows of the current generation and rules version; a save for an older generation is refused. So a re-score or a sync that replaces events hides old highlights without touching the table.
- Cache identity: clips carry `StrikeHighlightRules.drawable` tracks (only what is painted); a clip with nothing to draw is keyed as switched off. The Builder preview slice key includes `AppStore.strikeHighlightRevision` for windows that draw highlights.
- "Mark strikes" (Sources, Fight Action header): an AppJobs job that marks the strikes with nothing saved from the existing events, no AI pass.
- The finder tells "no match" (saved, not retried) from "could not read" (not saved, retried), and shares poses between nearby strikes on one file-wide frame grid.

- Rules v3 (2026-11-18): reach is measured from the last stretch of the limb (forearm, shin), with a hard `maxReach`; the impact circle sits where the limb meets the body part; the hand or foot must be closing on the target; two poses closer than `minSeparation` are one body; the model's `side` hint only breaks ties. `StrikeHighlightRules.contenders` picks the fighters as the two barest torsos (`Pose.bare`, the skin share `StrikeHighlightFinder` reads from the still), falling back to everyone when fewer than two are bare. Judged with `StrikeHighlightDiagnosticTests` contact sheets on the reference fight.

- Rules v4 (2026-11-19): the scorer's `target` is a preference (`targetPenalty`), no longer a filter on where a limb may land. A kick to the thigh logged as "body" got no highlight (the 0:03 kick of the reference fight after the re-score). The `technique` is still a filter.

Not done:
- Freeze frame on impact in a reel: phases 4 and 5 below.
- Wizard reels: phase 6 below.
- The QuickTime burn ahead of a framing intermediate was not reached in the live pass of 2026-11-19: both Center Stage renders stayed in the encode graph.
- The Builder's still preview does not draw the highlight; the rendered in-place preview does.
- Scoring windows do not overlap, so an exchange across a 12 s boundary can lose its lead-in. Changing that changes what the model is asked and needs re-checking against real footage.
- `docs/Builder-Scripting-Reference.md` is exported from the app and has not been re-exported with the new op.

## Spec for phases 4 to 6 (2026-11-19)

### Decisions

- A freeze is a clip of its own on the timeline, a "hold": one source frame shown for a stretch of screen time. It is not a hidden property of a moving clip. Every time map in the renderer (captions, camera paths, cutaways, `transcriptStart`) assumes `source = sourceStart + (t - startTime) * speed`; a freeze inside a clip would break all of them, a separate clip breaks none.
- "Freeze on impacts" is an edit, done once: it splits the clip at each saved contact time and puts a hold between the pieces. The holds are then ordinary timeline content: visible, trimmable, deletable, undoable. A later re-score or Mark strikes does not move them.
- The renderer learns one new thing, the hold clip, and nothing about strikes. The highlight on a hold comes from the existing switch: the hold inherits `strikeHighlights` from the clip it was cut from.
- Hold length defaults to `StrikeHighlightRules.impactHold` (0.8 s). A hold is silent; music and the timeline's other tracks play through.

### Phase 4: the hold clip

Model, `ClipBuilder/Data/TimelineModels.swift`:
- `TimelineClip.hold: Bool?`, coding key `hold`, decoded with `decodeIfPresent`, encoded only when true (same pattern as `strikeHighlights`), included in `==`.
- A hold has `sourceEnd == sourceStart`, `speed == nil`, and `duration` is its screen time. `sourceSpan` returns 0 for a hold. The decoder's legacy branch that derives `duration` from `end - start` must not run for a hold (the explicit `duration` key is always written; keep it that way).
- `MultitrackRenderer.windowed` and any other slicing: a hold cut by a window keeps its `sourceStart`.

Edits, `ClipBuilder/App/BuilderStore.swift` and `ClipBuilder/Services/Script/TimelineSplit.swift`:
- Trimming a hold changes `duration` only (floor `precision.minimumDuration`, ceiling 5 s); `sourceStart` and `sourceEnd` do not move.
- Splitting a hold and setting its speed are refused with the existing `ClipEditFailure` cases. `BuilderSilenceExpansion` and dub line ownership skip holds.
- Inspector (`Views/Builder/BuilderInspector.swift`): a selected hold shows "Freeze frame" as its kind and a duration field; Speed, Trim and Captions rows are hidden.
- Timeline lane: a hold is drawn with a snowflake badge (`snowflake`; grep Views first for an existing freeze icon) so it is told apart from a 0.8 s moving clip.

Renderer, `ClipBuilder/Services/MultitrackRenderer.swift`:
- `ResolvedClip.hold: Bool = false`, set in clip resolution; `speed` is 1; `captionsPosition` is nil; `muted` is true.
- Add `ResolvedClip.sourceSpan` (`hold ? 0 : duration * speed`) and use it wherever `duration * speed` is written today: the strike track window (around line 361), the framing prepass calls (around lines 530 to 560), `StrikeHighlightBurn.prepare` (around line 2414).
- Segment graph (around line 2613): for a hold placement the video chain is seek to `sourceStart`, keep one frame, `tpad=stop_mode=clone:stop_duration=<placement duration>`, then the usual `setpts`. It goes after the strike overlay and before any crop or area filter, so the highlight and the framing freeze with the picture. There is already a `tpad` clone at line 1801 to copy the style from. Audio for a hold placement is the existing silent source (line 1839).
- `StrikeHighlightBurn.prepare` and `tracks` accept `duration == 0`: one picture, the track sampled at `start`. Today `prepare` returns nil for `duration > 0` false.
- Center Stage and area framing on a hold use the camera position at `sourceStart`. A hold made by phase 5 carries the path slice the split gives it; a hold with no usable path is framed like a one-frame clip. Whatever route is taken, the crop of a hold must equal the crop of the frame before it (see tests).
- `hold` is part of the segment cache key (around line 1964).
- The Builder's in-place rendered preview goes through the same renderer and needs nothing. The scrub preview: find where a clip's source time is computed for the player and return `sourceStart` for a hold; if that preview cannot show a still cheaply, show the frame at `sourceStart` paused and say so in HANDOFF.

Older builds: they ignore the `hold` key and would play the hold as 0.8 s of moving footage from the same point. No schema or sync change; accepted.

Tests (Swift Testing, written and compiled; run only when asked):
- `ClipBuilderTests/Data/TimelineClipHoldTests.swift`: round trip, absent key decodes to nil, `sourceSpan == 0`, a hold is not written for an ordinary clip.
- `ClipBuilderTests/Integration/HoldRenderTests.swift`, modelled on `StrikeHighlightBurnTests`: a 1 s piece, a 0.8 s hold, a 1 s piece from a synthetic moving source. Output lasts 2.8 s; frames at 1.1 s and 1.7 s match (SSIM >= 0.99 via `compareDecoded` helpers); the frame at 1.0 s matches the hold (>= 0.97, encoder noise); the frame at 1.9 s differs; audio between 1.0 and 1.8 s is silent. A second case with `centerStage` on checks the crop does not jump at the hold.

### Phase 5: Freeze on impacts in the Builder

Rules, new `ClipBuilder/Services/StrikeFreezeRules.swift` (`nonisolated enum`, no database):
- Input: the clip's `sourceStart`, `sourceSpan`, `speed`, and the contact times of the saved highlights for its video (`StrikeHighlightRecord.contactTime` where `track != nil`).
- Output: the contact times to freeze at, ascending.
- A contact qualifies when it is at least `minimumPiece` (0.25 s of screen time, so times `speed` in source seconds) from the clip's start, from its end, and from the previous kept contact. Contacts closer together than that keep the earliest. At most 8 per clip, the earliest 8.
- `static func pieces(_ clip: TimelineClip, contacts: [Double], hold: Double) -> [TimelineClip]`: the alternating moving pieces and holds, in order, `startTime` running on from the clip's own. Every piece copies the clip's settings. `transIn` stays on the first piece only, `transOut` on the last only. Each piece gets a new `uid`; `originKey` follows what `TimelineSplit.pieces` does for a split. Moving pieces are cut with `TimelineSplit.pieces` so camera paths and source ranges are sliced exactly as a hand split would.
- Running it on a piece it already produced returns no contacts (they sit on the piece's edges), so pressing twice does nothing.

Store, `ClipBuilder/App/BuilderStore.swift`:
- `func freezeOnImpacts(_ uid: UUID, contacts: [Double], hold: Double = StrikeHighlightRules.impactHold) -> Result<Int, ClipEditFailure>`: replaces the clip with `StrikeFreezeRules.pieces`, one undo step named "Freeze on Impacts". Refused for bumpers, cutaways and holds.
- Later clips: the clip grows by `count * hold`. Use the same ripple a slow-down through `setClipSpeed` applies to clips after it on the track, and to nothing else. Do not write a second ripple.
- The contacts are read by the caller: `database.fetchStrikeHighlights(videoID:overlapping:)` for the clip's source range. That read is async, so the caller captures `profileGeneration` and the clip's value, and applies only if both are unchanged when the read returns (the profile-switch defect class: a plain `Task` outliving `switchProfile`).

Controls:
- Inspector, Fight section, under "Highlight strikes": button "Freeze on impacts". Disabled with a help line when the video has no saved highlights in the clip's range ("Mark strikes in Sources first"). After it runs, a notice says "Froze N impacts" or "No impact far enough from the clip's edges".
- Script op `freeze_clip_on_impacts {clip, hold?}` in `Services/Script/BuilderCommand.swift`, `BuilderCommandCatalog.swift`, `ScriptRunner.swift`; the legacy schema fixture in `ClipBuilderTests/Services/Script/JS/LegacyBuilderSchema.swift` gets the op.
- Typed request in `BuilderRequestParser.swift`: "freeze on impact(s) on/for/in this clip", listed in `supportedRequests`.

Tests: `ClipBuilderTests/Services/StrikeFreezeRulesTests.swift` (edge distances, merging, the cap, speed 0.5 and 2, idempotence, piece order and durations, transitions kept on the ends); a `BuilderStore` case for piece count, total duration, the ripple and undo; `BuilderRequestParserTests` for the new shape.

Not in this phase: a "remove freezes" action (undo, or delete the holds), and per-hold zoom or sound effects.

### Phase 6: Wizard reels

Highlights:
- `WizardOptions.strikeHighlights: Bool?` in `ClipBuilder/Services/WizardEngine.swift`. The struct has hand-written `CodingKeys` and `encode` (lines 29 and 48): add the key to both.
- Look controls: a "Highlight strikes" toggle next to the strike stats rows in `ClipBuilder/Views/WizardView+Look.swift` (around line 151), as its own row, not inside `StrikeStatsLookControls` (it does not depend on "Strike stats" being on). Shown under the same condition as the strike stats rows.
- When the option is on, every `TimelineClip` the Wizard builds from a source whose type is fight gets `strikeHighlights = true`. That is the editable document and the per-clip cut documents (`prepareAssembly`, `WizardPodcastTimeline.cutDocuments`; the per-clip render goes `renderPlannedClip` -> `ExpressPodcastRenderer.extract` -> `MultitrackRenderer`, which already draws the switch). Check: the rendered reel shows the highlight, and the document opened in the Builder has the checkbox on.
- Before rendering, fight sources in the plan that have events but nothing saved are marked with the same finder as Mark strikes. Move the body of `AppStore.markStrikes` (`App/AppStore+FightResearch.swift`) into a function both call; in the Wizard it runs inside the Wizard's own job and logs one line per file. No AI call.

Freeze in Wizard reels: `WizardOptions.strikeImpactFreeze: Bool?` and a second toggle, enabled only when "Highlight strikes" is on. It is applied to the finished editable document as the last step of `prepareAssembly`, clip by clip through `StrikeFreezeRules.pieces`, moving later content with `BumperPlanner.insertGap`. Open point to settle before this part is built: `renderPlannedClip` renders each planned clip from its own cut document and times its overlays and captions from the plan's duration, so a hold inside a planned clip changes that clip's length after the plan was validated. Either the holds are applied before the cut documents are derived and the plan clip's duration is recomputed, or Wizard freezes wait and the user presses "Freeze on impacts" in the Builder on the Wizard's document. Recommended: ship phases 4, 5 and Wizard highlights first, decide this after seeing holds in a real reel.

### Order and ownership

Phase 4, then 5, then the highlight half of 6. Codex implements each from this spec; Claude builds (`build-for-testing`, Debug), drives it live on the scratch profile and reviews the diff. Tests are written and compiled per phase and run only when the user asks or in `scripts/release.sh`.

## Spec for phase 7: Express action overlays and pause on contact (2026-11-20)

Asked for by the user on 2026-11-20 with a screenshot of the Rough cut sheet's Overlays tab: for a fight video that has strike data, the Overlays section gets two toggles, "Action overlays" and "Pause on contact", the second with a field for the pause length. This also settles the open point of phase 6: Wizard reels do get freezes, applied when the reel is assembled, with the affected clip's screen length recomputed.

### Decisions

- Where: Express Settings, Overlays tab (`Views/MiniOverlayRows.swift`, shared by `MiniSettingsCard` and `RoughCutReviewSheet`), so the rough cut sheet shows the same two rows and its Apply carries them to the page. The full Wizard keeps its "Highlight strikes" row unchanged in this phase.
- When shown: only when the selected footage is a fight (`VideoType.fight`) that has at least one scored strike event. A new page fact next to `showsNameTags` / `showsCaptionLanguage` (`MiniWizardFlow`, `RoughCutOverlays`). Hidden rows contribute nothing (`effective(for:)` forces them off), as name tags do.
- "Action overlays" is the existing strike highlight (limb in green, impact in red): `WizardOptions.strikeHighlights`. Off by default.
- "Pause on contact" is independent of "Action overlays": a reel can pause without drawing marks. Off by default. Its field is seconds, default `StrikeHighlightRules.impactHold` (0.8), limited to `StrikeFreezeRules.holdRange`, shown only while the toggle is on, with a stepper of 0.1.
- Both need the same saved contacts, so either one triggers the marking step before the first render (the shared, once-per-run step of phase 6).
- A pause is a hold clip (phase 4): one frozen frame, silent source audio, music and overlays keep running. Same limits as Freeze on impacts in the Builder (`StrikeFreezeRules`: 0.25 s minimum piece, 8 per clip).

### Part A: settings, rows, rough cut

- `MiniWizardSettings`: `actionOverlays: Bool?`, `pauseOnContact: Bool?`, `pauseOnContactSeconds: Double?` (Optional; hand-written coding, add to `CodingKeys`, `encode`, `init(from:)`). Carried by `applyOverlayOptions(to:)`, `adoptingOverlays(from:)`, `effective(for:)`, and wherever the Overlays tab choices are copied, compared or summarised.
- `WizardOptions.strikeImpactFreeze: Double?` (seconds; nil or 0 is off), carried exactly as `strikeHighlights` is (step 2 options, decoding, run settings, presets, preferences, assistant context).
- `WizardRoughCut.options` keeps turning both off for the plain cut and lets `extras.overlays` turn them back on, as it does for captions and the watermark. The rough cut then shows the marks and the pauses at its small size. `leftOut` wording is unchanged.
- Rows in `MiniOverlayRows`, after Watermark: `MiniRow("Action overlays")` with a toggle; `MiniRow("Pause on contact")` with a toggle and, when on, the seconds field. `MiniRow` draws its own divider. Text is `lineLimit(1)` + `fixedSize`.

### Part B: pauses in Wizard reels

Behaviour:
- For every planned clip from a fight source, the contacts are the saved highlights' contact times inside the clip's source range, filtered by `StrikeFreezeRules.contacts`. Each becomes a hold of the chosen length at that point of the clip.
- The plan and the take are not changed: planning, plan validation and the critic's plan text see the clips as planned. The pause is applied at assembly, in one place both the editable document and the per-clip renders use, so the rendered reel and the document opened in the Builder agree: the document carries the pieces and hold clips (`StrikeFreezeRules.pieces`, `strikeImpactsFrozen` set), later content moved by the added time.
- A clip with n pauses is n × hold longer on screen. Everything positioned on the output clock that derives from the clip's planned length uses the lengthened value: the clip's `-t`, brand layers and fixed overlays that ride the clip, captions and name tags (those after a pause move later by it; one spanning a pause stays up through it), strike stats callouts, later clips' start times, crop blocks, overlay blocks, music length, the reel's reported duration, `WizardPreviewClip.outputStart/outputDuration`.
- Action overlays stay visible on the frozen frame (phase 4 already draws the highlight at a hold's source time).
- Transitions between planned clips stay on the outer edges of a split clip; the inner boundaries are hard cuts.
- Critic proxies, the final render, Generate again, reel variants and the rough cut (with the Overlays tab on) all apply it. The plain rough cut does not.
- Dubbed reels: a hold is silent and has no speech, so with a dub language chosen pauses are skipped and the log says so once.
- A fight source with no saved contacts in a clip's range leaves that clip unchanged. A failure to read contacts never fails the reel.

One pure function decides, for a planned clip and a contact list, the hold positions and the output-time map (planned output time to paused output time), in a `nonisolated enum` under `Services/Wizard` with tests; the engine and the document builder both call it. No second copy of the split math: the pieces come from `StrikeFreezeRules`.

Tests: settings and options round trips (absent keys decode to nil); `effective(for:)` forcing the rows off for non-fight footage; rough cut options with and without `extras.overlays`; the time map (no contacts, one, several, speed 0.5 and 2, a contact too near an edge, the cap); document assembly with a pause (pieces, holds, later clips and blocks moved, total duration); a caption after a pause moved by it; dub on skips pauses.

Not in this phase: pauses in the full Wizard's Look controls, a zoom or sound effect on the pause, finding 2 of the proxy-fix review (highlight revision).

