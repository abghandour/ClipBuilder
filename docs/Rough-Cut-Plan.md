# Rough cut: a fast framing check before the final render

Date: November 2, 2026. Status: implemented November 2, 2026 (Claude), verified live on both pages; Codex read-only review done, 6 findings applied (cards and transitions stripped, one scale factor, Generate navigates back to the page, per-job cache folders pruned by retained reviews, cancellation checked before touching disk, preview files cleaned on every path).

Phase 2 (controls in the window, playback speed, Apply and Discard, Steady camera): implemented November 2, 2026 (Claude); see "Phase 2" below for status.

## Why

The Wizard preview is a still. It renders one exact frame at the scrubbed
moment, so it shows where the crop lands at that instant but not whether
the camera path, the talker switching or a face leaving the focus frame
hold up over time. Finding that out meant a full render: captions, name
tags, overlays, music, dub, bumpers, speech polish, full canvas. The user
asked for a low-quality moving cut with only framing and focus, on both
wizard pages.

## Design

- **One batch mode.** `WizardBatchMode.roughCut` joins `render` and
  `openInEditor`. Both pages reach it through the shared
  `generateWizardBatch`, so Express's kept candidates and the AI Wizard's
  kept takes get the same treatment.
- **Options stripped before the document is built.** `WizardRoughCut.options`
  turns off everything that is not framing: captions, name tags, text and
  fixed overlays, watermark, headline and outro cards, bumpers, music,
  dub, speech polish, strike cards, looks, B-roll, transitions (hard cuts).
  The canvas keeps its aspect at a third of the size (one factor for both
  sides, the short side never under 240 px, never upscaled, even
  dimensions), quality Compact, source audio kept and unmuted so the
  talker can be heard. Framing subject, focus frame, interview zoom and
  cuts, pacing and screen-crop layouts are untouched. Stripping before
  `editorDocument` also skips the AI work those layers need (tag text,
  caption translation, dub preparation).
- **Document stripped after.** `WizardRoughCut.strip` removes what the
  engine adds regardless of options: overlay items and blocks, brand
  layers, sound items, dub lines, clip effects, transitions, cutaways and
  the generated intro and outro cards (a compilation's intro card is added
  whatever the options say; the gap it left is closed), and sets every
  clip's captions to none.
- **Render.** The stripped document goes through
  `MultitrackRenderer.render(preview: true)`, the same path the content
  critic's proxy and the Builder's exact preview use. Nothing is written to
  the generated-videos table. The files move to
  `<data>/.cache/rough-cuts/<profile db>/<job id>/`; folders no retained job
  result points at are deleted when the next job starts, and a failed or
  stopped job removes its own folder.
- **Job.** `AppJobKind.roughCut`, channel "wizard", one per project at a
  time (`subjectID` "wizard-rough-<projectID>"), status-bar row with Stop.
  Each take renders in turn with a progress fraction. The result is
  `AppJobResult.roughCut(RoughCutReview)` and opens `RoughCutReviewSheet`
  from the root: a player per cut, the list of what was left out, Close,
  and Generate, which returns to the cut's project, the Wizard page and
  its mode, then sends the page's existing `wizard.generate` command
  through the assistant namespace the cut came from.
- **Controls.** Express: a "Rough cut" icon button between Open in Editor
  and Reset on the Generate panel. AI Wizard: the same next to Open in
  Editor, shown only when Generate renders kept takes. Both disable while
  a rough cut, an Open in Editor job or a render runs for the project.

## Files

- Services/Wizard/WizardRoughCut.swift (new): options, strip, review types
- App/AppStore+WizardBatch.swift: mode, job, `isRoughCutRunning`
- App/AppJobs.swift: kind and result
- Views/AppJobReviewSheet.swift: route
- Views/RoughCutReviewSheet.swift (new)
- Views/MiniGeneratePanel.swift, Views/WizardView.swift, Views/WizardView+Look.swift: buttons
- Tests: ClipBuilderTests/Services/Wizard/WizardRoughCutTests.swift

## Not done

- The Builder has no rough cut; its exact preview already plays the timeline.
- No per-clip rough cut; the whole kept reel renders.

## Phase 2: controls in the window, Steady camera

Date: November 2, 2026. Status: implemented, build and unit tests pass;
live verification and Codex read-only review recorded in HANDOFF.md.

The user wants to change framing while watching the rough cut and preview
again, rather than closing the sheet, editing the page and starting over;
to play the cuts faster or slower while comparing settings; to decide at
the end whether the page keeps the change (Apply) or not (Discard); and a
way to absorb the recording camera's own movement when the picture follows
one person (the opening of an interview recording where the camera nudges
and pans while the guest sits still).

### Design

- **The sheet carries the framing.** `RoughCutReview` gains the request id,
  the `Framing` the cuts were made with, the footage type, the recordings
  and the canvas aspect. `RoughCutReviewSheet` shows the shared
  `FramingRows` (Framing, Pull back, Shot, Moves, Camera, Fit, Blur,
  Feather, Focus frame, Zoom, VIPs) in a column beside the players, bound to
  its own copy of the framing. The page is not touched until Apply.
- **Preview again.** The store keeps every rough cut request
  (`AppStore.roughCutRequests`, `RoughCutRequest`: project, options, takes
  closures, page namespace), pruned to the ids retained job results still
  point at when a new job starts. `rerunRoughCut(requestID:framing:)`
  patches `options.framing` and starts the same job again; the sheet
  closes and the new job's sheet opens with the edited framing in its rows.
- **Speed.** A segmented 0.5×/1×/1.5×/2× control sets `defaultRate` on
  every player (and the live rate while playing).
- **Apply, Discard, Generate.** Discard closes without changes. Apply
  returns to the cut's project, page and mode, then sends
  `wizard.applyFraming` with `Framing.joined` as the text; Express writes
  it into `miniSettings.framing` (remembered per profile as before), the
  AI Wizard into its `framing` AppStorage. Generate sends
  `wizard.generateWithFraming`: the same write, then the page's Generate.
  One pending command per page, hence one action for the pair.
- **Steady camera.** `Framing.steady` (`steady` key, nil when off) becomes
  `CropRecipe.steady` in `FramingPlanner.resolve`. In
  `CropRecipePlanner.plan` the talker cell then tracks the person inside
  their feed (tracking spans per feed change, region = the feed's picture,
  focus = the face centre; one span becomes region + focus), the way a VIP
  cell already does, instead of holding a fixed crop of the feed. The
  renderer and the still preview pick the `steady` tuning
  (`CenterStageService.Tuning.steady`: no dead zone to drift in, slow
  time-based smoothing, zoom held unless the size really changes), named by
  `FramingPlan.camera` / `isSteady`; fighter focus keeps "fast". The
  Camera row ("Steady" switch) shows for Speaker focus, VIP focus on
  non-fight footage, and Center stage, with a caption saying what it does.

### Files

- Services/Framing/Framing.swift, Data/CropRecipe.swift,
  Services/Framing/FramingPlanner.swift, Services/CenterStageService.swift,
  Services/MultitrackRenderer.swift, Services/Wizard/WizardPreviewFraming.swift
- Views/Wizard/FramingRows.swift (Camera row)
- Services/Wizard/WizardRoughCut.swift (review fields, request),
  App/AppStore.swift (`roughCutRequests`), App/AppStore+WizardBatch.swift
  (`rerunRoughCut`), Views/RoughCutReviewSheet.swift
- Services/Assistants/WizardAssistant.swift (action ids),
  Views/MiniWizardView.swift, Views/WizardView.swift (handlers)
- Tests: FramingTests, FramingPlannerTests, InterviewFocusRecipeTests

### Not done

- The single-camera Interview focus path (one feed, glides between the VIP
  and the interviewer) keeps its planned path; Steady applies to separate
  feeds and to the talker full screen, where a feed's fixed crop was the
  problem.
- Steady does not change Fighter focus.

