# Telestrator Plan: pause and draw on the picture

Date: 2026-11-21. Status: accepted by the user 2026-11-21 with the three recommendations (see Decisions); extended the same day from a reference reel (see Reference reel and the revised phase order); phases 1 and 2 with Codex, nothing compiled or reviewed yet.

## What the user asked for

Pause a clip at a moment and draw figures over the picture (arrows, ovals, free-form lines), the way a football broadcast explains a play. In the rendered video the picture freezes there, the figures are drawn on one after another (animated, not all at once), stay for a time the user sets, fade out, and the clip plays on.

## Ground truth (read 2026-11-21, uncommitted tree)

| Thing | Where |
| --- | --- |
| A freeze is its own hold clip: `TimelineClip.hold == true`, zero source span, speed 1, silent | `Data/TimelineModels.swift:1017`, `MultitrackRenderer.swift:1624` |
| Renderer builds the hold as one frame cloned for its duration (`trim=end_frame=1,tpad=stop_mode=clone`), after the strike overlay, before crop | `Services/MultitrackRenderer.swift` ~2754-2763 |
| Splitting a clip at a moment and inserting a hold | `Services/StrikeFreezeRules.swift` (`pieces`), `TimelineSplit.pieces`, `HoldClipRules.cameraPath` |
| Wizard/Express pauses are applied at assembly; the plan is unchanged; captions, text, image, crop and overlay blocks are shifted across the pause | `Services/Wizard/WizardStrikePauses.swift` (`Timing.outputTime`, `Timing.captions`, `mapLayers`) |
| Preview and renderer share the clock | `MultitrackRenderer.plannedSegments`, `WizardPreviewClips.assembly`, `WizardStrikePauses.Timing` |
| Vector drawing over video, one painter for player and render | `Services/StrikeHighlightPainter.swift` (CGContext, 0...1 top-left of the SOURCE frame), `Views/StrikeHighlightOverlay.swift` (`TimelineView` + `Canvas`) |
| Burn-in: 30 fps PNG sequence overlaid on the source pixels inside the segment encode, so crop, rotation and 9:16 follow by themselves | `Services/StrikeHighlightBurn.swift` (`prepare`, `inGraph`) |
| Frame stepping on source footage (the only one) | `Views/Fight/FightActionPlayback.swift` (`step`), `FightActionPreview.swift` |
| Drag on a preview, snapping | `Views/Builder/PreviewPane.swift`, `Views/Wizard/WizardPreviewColumn.swift`; there is no freehand drawing anywhere |
| Rendered-cut player with a picture overlay closure | `Views/ScrubbingPlayerView.swift`, hosted by `RoughCutReviewSheet` |
| Storage | Builder: `timelines.document_json` (Codable, local, new properties Optional). Wizard: `wizard_highlights.plan_json` / `settings_json` (synced JSON, Optional keys need no server migration). `fight_picks` has a fixed synced column list: do not add a column there |
| Pauses are skipped on dubbed reels today | `WizardStrikePauses.dubSkipMessage` |

## Design

### Model (`Services/Telestration.swift`, pure, Codable, every stored property Optional-safe)

- `Telestration`: `time` (source seconds of the frozen frame), `figures: [Figure]`, `stay` (seconds the finished drawing stays, the number the user sets, default 2.0, range 0.5...10), `drawSpeed` (seconds per figure, default 0.5, range 0.15...2), `fade` (default 0.3).
- `Figure`: `kind` (`arrow`, `oval`, `line`, `free`), `points: [CGPoint]` in 0...1 of the SOURCE frame, top-left origin (arrow and line: start, end; oval: two opposite corners of its box; free: the simplified path), `color` (one of a fixed palette of 5: yellow, red, white, cyan, green), `width` (share of the frame height: thin 0.006, medium 0.010, thick 0.016).
- The freeze lasts `figures.count * drawSpeed + stay + fade`. One number, `Telestration.duration`, used by the editor, the preview and the renderer.
- Limits: 12 figures per pause; a free path is simplified (Douglas-Peucker, tolerance 0.002) and capped at 200 points; at most 8 drawn pauses per clip.
- Source-frame coordinates are the reason crop and 9:16 need no work: the drawing is laid on the source pixels before the crop, as strike highlights are.

### Animation rules (pure, same file)

`Telestration.state(at elapsed:) -> [(figure, progress 0...1)], opacity`:

- Figure `i` draws from `i * drawSpeed` to `(i + 1) * drawSpeed`, eased out; earlier figures are complete, later ones absent.
- Progress is a share of the figure's length: a line or free path is revealed along its arc length; an arrow's shaft is revealed, then its head opens over the last 20%; an oval is traced once round from its top.
- After the last figure, everything stays for `stay`, then opacity falls linearly to 0 over `fade`.

### Painter (`Services/TelestrationPainter.swift`)

One CGContext painter, `draw(_ state:, in:rect:topLeftOrigin:)`, shaped like `StrikeHighlightPainter.draw`: round caps and joins, a dark outline under each stroke (so yellow reads on a pale canvas), arrow head sized from the stroke width. Used by the editor, the previews and the burn-in. No second implementation.

### Editor (`Views/Telestrator/TelestratorSheet.swift`)

One sheet for every entry point, presented by the parent view (never inside a split-view child):

- Top: the frozen source frame, shown inside the clip's output crop with the cropped-away area dimmed, so the user only draws where the viewer will see. Frame step buttons and a scrubber to pick the moment (reuse the stepping in `FightActionPlayback`; extract the player part if needed, do not copy it).
- Tools row (`lineLimit(1)` + `fixedSize`, in a `FlowLayout`): Arrow, Oval, Line, Free line, colour swatches, width, Undo, Clear.
- Drawing: drag to create. A figure can be selected, moved and deleted; no reshaping in the first version.
- Figure list: the order they are drawn in, drag to reorder.
- Timing: "Stays for" seconds, "Drawing speed". The total pause length is shown.
- "Play" runs the animation on the frozen frame with the same rules and painter as the render.
- Save / Cancel. Nothing long runs in the sheet.

Icon: `pencil.tip` is already used for the draw mode in `PreviewPane`; use it for every control that opens this editor.

### Where it is stored and applied

- **Builder.** `TimelineClip` gains `telestration: Telestration?`, meaningful on a hold clip. "Draw on pause" on a selected clip at the playhead: split with the existing `StrikeFreezeRules`/`TimelineSplit` path, insert a hold of `Telestration.duration`, open the editor. Editing the drawing updates the hold's duration. Deleting the hold deletes the drawing.
- **Wizard and Express.** `WizardPlanClip` gains `telestrations: [Telestration]?` (source time, like a strike contact). At assembly `WizardStrikePauses` treats each one as a pause: generalise its pause list from "contacts with one hold length" to "pauses with their own length and an optional drawing"; `Timing` already shifts captions and layers by whatever the pauses are. A drawn pause within 0.25 s of a strike contact replaces that contact's pause (one freeze, not two).
- **Renderer.** A hold with a telestration gets a second overlay stage placed AFTER the frame is cloned (`tpad`) and before the crop: a PNG sequence of the animation at 30 fps for the hold's duration, produced by a `TelestrationBurn` that reuses `StrikeHighlightBurn`'s sequence writer and `inGraph`. The existing strike overlay stays where it is (it is still on the frozen frame).
- **Preview.** Reel preview and Rough cut sheet draw the same state through `ScrubbingPlayerView.pictureOverlay` / the preview column, from the shared clock. The Builder's still preview shows the finished drawing (no animation) on a hold.

### Entry points (every one a visible control)

- Builder: a "Draw on pause" button (`pencil.tip`) in the clip inspector, and on a hold clip "Edit drawing".
- Reel panel (`WizardPreviewList`) and Express Footage list (`RangeReviewView`), in the same pass per the standing rule: a `pencil.tip` button on a clip row opens the editor on that clip; a badge shows how many drawn pauses it has.
- Fight Action popup: "Draw on this action" under the preview, opening the editor at the strike's contact time. Stored on the reel clip that contains that time when there is one; otherwise disabled with a reason.

### Not in this plan

Drawings that follow a player, text labels and numbers, shapes snapping to people, spotlight/dim effects, syncing Builder timelines. (Icon stamps and drawings kept over slow motion were excluded in the first draft and are now phases 2b and 6.)

## Reference reel (user, 2026-11-21)

A 63 s 9:16 fight-breakdown reel the user pointed at as the target look. What it does, and where each part lands:

| What the reel does | Lands in |
| --- | --- |
| Freeze, a glowing white box traced round the target, hold, resume | Phases 1-4, plus the rectangle kind (2b) |
| Striking limb as a solid red fill with a glow, through slow motion | Existing HD strike highlight; solid-fill style (2b) |
| Straight and curved arrows for the punch and the counter | Arrow (1); arrow head on a free line (2b) |
| Every figure white with a soft outer glow | Neon stroke style (2b) |
| Red X at the point of contact, short flash on impact | X kind (2b); flash preset at the scored contact time (7) |
| Icon in a box above a fighter's head | Icon stamp kind (2b) |
| Presenter strip on top, narration running through the freeze | Phase 4 (pause on a stacked layout, voice-over through the hold) |
| Arrows staying while the picture moves in slow motion | Phase 6 |
| Slow motion into the strike | Phase 7 |

## Phases

Order as accepted by the user on 2026-11-21: 0, 1, 2, 2b, 4, 3, 5, 6, 7.

0. **Checks.** Confirm where a user edit of one Wizard clip is persisted (`plan_json` round trip through `wizard_highlights`), the Builder's hold-insert path (`BuilderStore`, `TimelineSplit`), and that an overlay stage after `tpad` composes with the strike overlay in the segment graph. Write the findings into this plan.
1. **Rules.** `Telestration`, animation state, path simplification, arrow and oval geometry, `TelestrationPainter`. Tests: timing (figure order, stay, fade, total), arc-length reveal, arrow head, simplification cap, old JSON without the new keys decodes, painter pixel probes.
2. **Editor.** The sheet, drawing tools, selection, order, timing, Play.
2b. **Reference-reel figures and styles.** Model, painter and editor only; no renderer work.
   - `Figure.kind` gains `rectangle` (two corners, traced corner by corner from its top-left), `cross` (an X in a two-corner box, one stroke then the other) and `stamp` (an SF Symbol name from a fixed short list, drawn in a rounded box; it scales in instead of being traced). An unknown kind in stored JSON decodes to a figure that is skipped, never a failure.
   - `Figure.head: Bool?` puts an arrow head on a `free` path (direction of its last segment), which gives curved arrows.
   - `Figure.style: Style?` with `flat` (today's stroke with a dark outline, the default) and `neon` (white core, soft outer glow in the figure's colour).
   - `StrikeHighlightPainter` gains a solid-fill style for the limb area (fill plus glow), chosen where the highlight colour is chosen today. Optional stored property; existing saved highlights are unchanged.
   - Editor: the three tools, a head toggle for free lines, a Flat / Neon choice, an icon picker for the stamp.
   - Tests: reveal rules for each new kind, unknown-kind decode, neon and flat pixel probes, stamp scale-in.
4. **Wizard and Express.** Plan storage, generalised pauses (each pause its own length; `StrikeFreezeRules.pieces` takes a length per contact), Reel panel and Footage list controls, Rough cut preview, Fight Action popup entry. **Narration through the freeze:** a pause on a stacked or composed layout holds only the area showing the paused source and keeps the other areas running, and a voice-over keeps playing across the hold instead of the hold being silent. This replaces the "composed cut needs a shared multi-source pause" skip for drawn pauses and for Pause on contact alike; the remaining skips (B-roll cutaways over the held frame, bumpers at the clip, recipe transitions, dubbed reels) stay, each with its message. Tests: `Timing` with mixed pauses, the merge with a strike contact, preview clock equals renderer segments, a two-area render where one area holds and the other advances (timing, audio and SSIM), voice-over placement across a hold.
3. **Builder.** Hold with drawing, renderer stage, still preview. Test: a render with a drawn hold compared by timing, audio and per-frame SSIM (`compareDecoded`); the overlay is present mid-hold and gone after the fade.
5. **Live check** on real footage, then a read-only Codex review of the diff.
6. **Drawings over slow motion.** `Figure.linger: Double?` (seconds a figure stays after the pause ends, 0...3, default 0). A lingering figure is fixed on the screen, it does not follow anyone; it is drawn by the same painter on the moving piece that follows the hold and fades over `fade` at its end. Decision 2 below becomes the default, not the rule.
7. **Impact presets.** A slow-into-contact speed ramp for a clip holding a scored strike, and a short flash at the contact time. Separate plan section to be written when reached.

Phases 1 and 2 have a spec above: Codex implements, Claude builds, tests and reviews. Phase 2b gets its exact spec after 1 and 2 compile and are reviewed. Phases 3 and 4 touch the renderer and the shared clock: Claude writes the exact spec after phase 0, then the same split.

## Phase 0 findings (2026-11-21, read from the code)

1. **Where a reel clip lives.** Express and Wizard takes are `wizard_selection_takes.plan_json`, written by `Database.updateWizardSelectionTakePlan` through `AppStore.saveWizardTakePlan` / `saveMiniCandidatePlan`. Local, not in Team Sync. `wizard_highlights` is insert-only history and never updated. `WizardPlanClip` decodes with synthesized Codable: `telestrations` must be Optional. So a drawing is local to this Mac in the first version.
2. **Takes are rebuilt from picks.** Manual per-clip data survives a rebuild only where it is captured and re-applied; `brollCuts` does this for transcript picks (`reviewedCutsByPick`, `miniReviewedBRoll`). No such path was found for fight picks or Q&A. Drawings need the same capture and re-apply, for all three kinds, and a trim (`MiniHighlightReview.trimming`, `WizardPlanRules.applyPacing`) must drop a drawing whose time falls outside the clip, as it re-clips `brollCuts`.
3. **Pause lengths.** `Pause` and `Timing` already carry a length per pause. One length is assumed in `timing(for:contacts:seconds:)`, `prepare` (`pauses[0].duration`), `StrikeFreezeRules.pieces(_:contacts:hold:)` and `StrikeClipStatus` (`pauses[0].duration`). `holdRange` is 0.05...5.0 and shared with the Builder and settings; a drawn pause can be longer and needs its own limit.
4. **Gates that block a drawn pause.** `prepare`, `resolveJoins` and `contactPaths` run only when Pause on contact is on and the source is fight footage. `pieces` marks every piece `strikeImpactsFrozen`, and `selection` refuses a clip so marked: strike pauses and drawn pauses must be split in one pass.
5. **Renderer.** A hold is `trim=end_frame=1,tpad=stop_mode=clone` (`MultitrackRenderer.swift` ~2760). A second overlay stage right after it, still in source pixels, is feasible. A hold can span several render segments; the offset into the hold is `timelineOffset - originalStart`. `ResolvedClip` is encoded whole into the segment cache key, so a new stored field is keyed by itself. `StrikeHighlightBurn.prepare` / `inGraph` is the PNG-sequence model to reuse.
6. **Voice over already runs through a hold.** A take is one audio file on the reel clock; `VoiceOverPlacement` already places takes across pauses. Not confirmed: that the mix itself never cuts at a hold. Source audio is muted on a hold (`MultitrackRenderer.swift:1624`), which is what we want.
7. **Stacked and composed layouts.** Other areas are extra video tracks (`areaClips` on track slot+1; composed framing one clip per segment per area). `prepare`, `skipReason` and `pieces` assume one video track. Freezing one area means hold pieces on that track only and every other track's clip lengthened by the hold (its source range runs on).
8. **The Reel preview never plays a hold.** `KeptClipsPlayer` plays the source recording; nothing is drawn over it. Holds, strike highlights and therefore drawings are seen only in the rendered rough cut, where they are baked in. No live overlay is needed in phase 4; the editor's Play is the preview.
9. **Entry points.** `WizardPreviewList` rows have no buttons today (a comment says so on purpose); the Footage list row (`RangeReviewView` ~1040) has a trailing button group. `MiniWizardView` presents the sheets. A row carries `videoURL`, `start`, `end`, `videoID` but not the source aspect or the output crop: `visibleRect` needs a helper over `FramingPlanner.resolve`.
10. **Tests that pin pause behaviour:** WizardStrikePausesTests, StrikeFreezeRulesTests, StrikeClipStatusTests, HoldRenderTests, TimelineClipHoldTests, MultitrackRendererPlanningTests, PreviewWindowTests, WizardBuilderParityTests, VoiceOverTests, WizardRoughCutTests, MiniWizardSettingsTests.

**Consequence: phase 4 is split.**

- **4a. Drawn pauses on a single-source clip.** Storage on the take with capture and re-apply across rebuilds; pauses with their own length, independent of Pause on contact and of the source type; one split pass for contacts and drawings; the renderer overlay stage; the editor opened from the Footage list and Reel panel rows; status lines. Voice over runs through the pause as it already does. Seen in the rough cut.
- **4b. Pauses on stacked and composed layouts** (the reference reel's presenter strip): hold on one track, the others lengthened. Lifts the "composed cut" skip for drawn pauses and Pause on contact alike.

## Decisions (user, 2026-11-21: "go with your recommendations")

1. **Where first.** Wizard and Express reels before the Builder: phase 4 is done before phase 3.
2. **After the pause.** The drawing fades out before the picture moves again. From phase 6 a figure can be set to linger into the motion; fading first stays the default.
3. **Dubbed reels.** Drawn pauses are skipped on dubbed reels, with the same message as Pause on contact, until a dub can hold with it.
