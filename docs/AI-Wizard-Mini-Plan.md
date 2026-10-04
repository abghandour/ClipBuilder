# AI Wizard Mini Plan

Date: October 3, 2026. Status: draft for the user's review; implementation by Codex, build/test/review by Claude.

Source request: `docs/New-Ai-Wizard-Wizard.md`.

## Goal

A second, simpler Wizard screen, **AI Wizard Mini**, in the sidebar under AI
Wizard. One video, three questions, one button to find footage, one button to
set the look, one button to render. It is a guided front end over the two-step
engine shipped in 1.91 (`docs/Wizard-Two-Step-Plan.md`): Mini runs produce the
same Selections, takes and Outputs the full Wizard does, so anything found in
Mini can be reopened in the full Wizard or the Builder.

## Decisions (from the user, October 3)

| Question | Decision |
| --- | --- |
| Sources per run | One analyzed video. |
| "Best 3 highlights" | Three alternative reels, each about the target length, from different moments. Keep one or more; regenerate any with a note. |
| Outputs | Chosen per run on the settings step: **Separate videos** (one per kept item) or **One reel** (kept items joined in order). |
| Persisted instructions | Per profile (`BrandProfile`), shared by its projects. |
| "Video resolution" | The existing Canvas presets (9:16 1080p, 16:9 1080p, 1:1, 4:5…); Quality stays High / Balanced / Compact. |
| Podcast Q&A review | Reuse the Transcript Q&A view with a Keep checkbox per section. |
| Sidebar | Project group: Sources, Scenes, AI Wizard, **AI Wizard Mini**, Timelines, Outputs. No shortcut yet. |

Assumed, say if wrong:

- "Podcast/interview" = `VideoRecord.type` is `.podcast` or `.interview`, or the video has `podcast-exchange` scenes.
- Q&A has no Length question; each exchange is kept whole (the podcast Q&A rule from 1.91 applies when an exchange is trimmed by hand).
- Non-podcast footage always uses the tracking camera on the people (`framingCamera` default); no Camera focus question.
- The critic loop is off in Mini; "regenerate with a note" is the user's loop.
- Mini remembers its last answers (video, Q&A/Highlights, duration, settings) per profile, like the full Wizard's form.

## Screen

One scrolling page with three numbered cards. A card below the current one is collapsed to a summary line until its turn.

```
1  Source
   [grid of analyzed videos in this project: thumbnail, name, type, duration]
   Podcast/interview picked →  ( Q&A )  ( Highlights )          segmented
   Otherwise, or Highlights →  Length  ( 10 s ) ( 15 s ) ( 30 s ) ( Auto )
   Instructions for the AI (optional, saved with the profile)
   [ text box ]
   [ Generate footage ]

2  Footage                                      ← appears after footage exists
   Highlights: three candidate cards, each: thumbnail strip, length, the
   planner's one-line reason, ( Keep ) checkbox, [Regenerate] with a note
   field ("What should change?"), and a player with draggable trims when
   selected (the Wizard's ProposedCutsEditor).
   Q&A: the Transcript Q&A view (three columns, player, Start here / End
   here) with a Keep checkbox per section and "Keep all" / "Keep none".
   [ Video Generation Settings ]

3  Settings
   Quality      ( High ) ( Balanced ) ( Compact )
   Canvas       [ 9:16 · 1080p ▾ ]
   Camera focus [ Let AI choose ▾ ]            podcast/interview only
   Captions     (on/off) ; Caption language ( Native ) ( English )  when on
                and the transcript language is not English
   Intro video  (on/off)   Outro video (on/off)      bumpers, disabled with
                "No bumper allows this placement" when none
   Name tags    (on/off)                        podcast/interview only
   Watermark    (on/off)
   Output       ( Separate videos ) ( One reel )
   [ Generate Video(s) ]
```

Status, Stop and results use the existing wizard status row, the Results
sheet and Outputs, unchanged. Long work never runs inside a sheet.

## How each step maps onto the engine

**Source.** `database.fetchVideos(projectID:)` filtered to analyzed videos
(`analyzedAt != nil`, scenes present). Thumbnails from the existing
`VideoThumbnail`. Picking a video sets `WizardOptions.sourceVideoPaths = [path]`,
`sourcesRestricted = true`.

**Instructions.** New Optional `BrandProfile.miniInstructions: String?`
(coding key `mini_instructions`, synthesized decoding, classified as private
in `LearnedRedactionTests.goldenAllowList`). Fed as `aiInstructions` for
highlights and as the `requestText` for podcast highlights, with
`interpretRequest: false` (rules, not hidden settings).

**Generate footage.**

- *Highlights, non-podcast or podcast:* one planner call that returns three
  distinct candidates. New `WizardEngine.findCandidates(count: 3, options:…)`:
  the step-1 planning prompt gains a `candidates` wrapper ("return 3
  alternative plans, each ≈ target_duration, no overlapping footage between
  candidates"), parsed and validated per candidate with the existing
  `validatePlan`. Each candidate becomes its own Selection (named from the
  candidate's headline, `recipe` = `custom` for non-podcast, `podcast_highlights`
  for podcast) with Take 1; the three carry one `mini_batch` id (new nullable
  column on `wizard_selections`) so the Footage card can list them together.
  For podcast Highlights the existing `findPodcastHighlights` finder is used
  instead of the planner (count 3, max seconds = Length), and each
  `HighlightCandidate` becomes a Selection the same way.
- *Regenerate one:* `findMoments(note:previousTakes:)` on that Selection,
  with the note plus an automatic rule listing the other kept candidates'
  ranges as footage to avoid. The card shows the new take; earlier takes stay
  in the Selection (visible in the full Wizard).
- *Q&A:* no AI. The video's `q&a` scenes load into `TranscriptQAView` (new
  `keepable: Bool` mode adding the checkbox column and the Keep all / none
  buttons; `onSave` keeps writing `AppStore.setSceneEditRange`). Kept
  exchanges are recorded as one Selection per exchange (Take 1 = the
  exchange's range via `WizardPlanRules.podcastExchangeCuts` with no target)
  when the user moves to Settings, so Outputs link back to a take.

**Settings** fill `WizardStep2Options`: `renderSettings.quality`,
`renderSettings.preset`, `highlightFraming`/`podcastFraming` (the
`WizardCameraFocusPicker` choices), `addCaptions`, `captionLanguage`
(`nil` = native, `"en"` = English; the Native/English control shows only when
the transcript's language is not English — `database.videoIDsWithOriginalTranscripts`
plus the stored language), `includeIntroBumper`, `includeOutroBumper`,
`enableTextOverlays` restricted to speaker introductions for Name tags (a
new `nameTagsOnly` flag on step 2 that keeps `speakerIntroductions` and drops
other overlays in `renderSelection`), `includeWatermark`. Everything else
stays at the profile's defaults.

**Generate Video(s).**

- *Separate videos:* one `makeReel(take:options:)` per kept Selection, run
  sequentially through the existing wizard task so Stop cancels the rest;
  Results sheet lists all of them.
- *One reel:* a new Selection named after the first kept item whose Take 1
  plan is the kept takes' clips in card order (transitions `cut`, text
  carried per clip), then one `makeReel`. The kept Selections remain for
  later separate renders.

## Files

| Area | Files |
| --- | --- |
| Pure flow | `Services/Wizard/MiniWizardFlow.swift`: the card state machine (which card is open, which questions show for a video type and footage kind, settings visibility rules, output mode), `MiniWizardFlowTests` |
| Screen | `Views/MiniWizardView.swift` (three cards), `Views/MiniFootageCard.swift` (candidate cards + ProposedCutsEditor), `Views/MiniSettingsCard.swift`; `TranscriptQAView` gains `keepable` |
| Store | `App/AppStore+MiniWizard.swift`: load analyzed videos, generate footage, regenerate, keep set, build step-2 options, render separate or combined; state lives in `AppStore` (`miniRun: MiniWizardRun?`) |
| Engine | `WizardEngine.findCandidates`, candidate prompt wrapper, avoid-ranges rule in `WizardPlanRules` (pure), combined-plan builder in `WizardPlanRules` (pure) |
| Data | `BrandProfile.miniInstructions`; `wizard_selections.mini_batch` (additive migration); `Database+WizardSelections` queries by batch; per-profile Mini defaults in `UserDefaults` keyed by profile name (`mini.<profile>.<field>`) |
| Sidebar | `SidebarSection.wizardMini` in `projectSections` after `.wizard`, label "AI Wizard Mini", symbol `wand.and.stars.inverse` |
| Docs | this plan; a paragraph in the Getting Started guide |

## Phases

**P1 — Flow and screen skeleton.** `MiniWizardFlow` (pure, tested: podcast
shows Q&A/Highlights; non-podcast skips to Length; Q&A hides Length; Camera
focus and Name tags only for podcast; caption language only when captions are
on and the language is not English; cards collapse/expand). Sidebar entry,
`MiniWizardView` with the Source card working (grid, segmented controls,
instructions saved to the profile), the other two cards as collapsed
placeholders. Builds and navigates.

**P2 — Footage: highlights.** `findCandidates` with the candidates prompt
wrapper and per-candidate validation; `mini_batch`; the Footage card with
three candidate cards, Keep, Regenerate with a note (avoid-ranges rule), the
trim editor. Tests: prompt asks for three non-overlapping candidates; parser
yields three validated plans; regenerate note includes the other kept ranges.

**P3 — Footage: podcast Q&A and podcast highlights.** `TranscriptQAView`
keepable mode; kept exchanges recorded as Selections; podcast Highlights
through `findPodcastHighlights` into Selections. Tests: Q&A keep set →
Selections with exact exchange ranges; highlight candidates → Selections.

**P4 — Settings and generation.** The Settings card, step-2 mapping (name
tags only, native/English), Separate videos vs One reel, the combined-plan
builder, Results sheet. Tests: settings → `WizardStep2Options` mapping;
combined plan order and cut transitions; output count per mode.

**P5 — Remembered answers and polish.** Per-profile remembered answers,
empty states ("No analyzed videos in this project" with Open Sources,
"No Q&A found" with Open Transcript), Getting Started paragraph, run summary
line.

## Acceptance

1. Sidebar shows AI Wizard Mini under AI Wizard; the page opens with the
   project's analyzed videos.
2. A fight video: Length appears, Q&A/Highlights does not; Generate footage
   yields three candidates ≈ the chosen length; Regenerate on one with
   "start on the knockdown" replaces only that candidate; the others' footage
   is not reused.
3. A podcast video: Q&A shows every exchange in the Q&A view with Keep
   boxes; Highlights asks Length and yields three candidates.
4. Settings shows Camera focus and Name tags only for podcast/interview;
   Caption language only when captions are on and the transcript is not
   English.
5. Separate videos renders one reel per kept item; One reel renders a single
   reel in card order. Outputs shows "Take N" and opens the Selection in the
   full Wizard.
6. Instructions typed in Mini survive relaunch and a project switch within
   the profile.
7. No planner call happens on Generate Video(s) (log has no "Phase 2").
