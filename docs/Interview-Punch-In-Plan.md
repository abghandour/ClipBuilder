# Interview focus punch-ins and font-only caption emphasis

Date: October 23, 2026. Status: planned; Codex implements, Claude builds, tests and reviews.

## Goal

Reproduce a reference reel made in another app (Volkov interview, 9:16,
13.5 s): a full-height two-shot most of the time, hard cuts to a tighter shot
on the interviewer while he asks, back to the two-shot for the answer;
captions mid-frame, 2–3 words per page, revealed as spoken, the spoken word
red, one word per page set in an italic serif while the rest are a bold sans;
no caption box. Everything else in that reel (edge-to-edge two-shot, word
reveal, red highlight, mid-frame placement, intro overlay) already exists.

## A. Interview focus: cuts and "Punch in on"

Settings (all optional / default-decoding; the same plumbing `interviewZoom`
and `interviewZoomMoves` use, see `docs/Interview-Focus-Plan.md`):

- `CropRecipe.interviewCuts: Bool = false` and
  `CropRecipe.interviewPunchIn: InterviewPunchIn = .vip` where
  `nonisolated enum InterviewPunchIn: String, Codable, CaseIterable, Sendable { case vip, interviewer, talker }`
  (put the enum in `Services/InterviewFocusPlanning.swift`).
- `WizardOptions.interviewCuts: Bool?`, `WizardOptions.interviewPunchIn: String?`
  (+ CodingKeys in `WizardEngine.swift`, `WizardOptionsDecoding.swift`),
  `WizardStep2Options` (var, CodingKeys, step-2 mapping, merge),
  `MiniWizardSettings.interviewCuts = false` / `interviewPunchIn: String?`
  (CodingKeys, decode, `previewOptions`, `remembered`/`remember`, boolean
  field list, `MiniWizardMemory.Field.interviewCuts/.interviewPunchIn`,
  `WizardPresetBridge` fields `interviewCuts` / `interviewPunchIn`),
  `AIRunSettings` key list, `AISettingsPreferences` map
  (`wizard.interviewCuts`, `wizard.interviewPunchIn`), full wizard
  `@AppStorage` in `WizardView.swift` + `formOptions`, `AppStore+WizardPipeline`
  step-2 defaults, `AppStore+Analysis.swift` Builder compose-as-recipe
  (reads the same defaults as it does for Pull back), `PodcastRecipeTimeline.build`
  and both `WizardPreviewFraming` recipe builders, `PreviewKey.visual` and
  `WizardPreviewColumn.ContentKey`. Update `MiniWizardMemoryTests` catalog.

Planner (`InterviewFocusPlanning`):

- `Shot.Kind` gains `.interviewerTight`. `rects(...)` also returns
  `interviewerTight: FreeCropRect?` = the tight shot (same `tightHeight`
  rule and zoom) centred on the first other face, nil without others.
- `moves(segments:vipTiles:range:hold:minimumTurn:punchIn:)`: with `.vip`
  (default) unchanged: VIP turns → `.tight`, others → `.twoShot`. With
  `.interviewer`: interviewer turns → `.interviewerTight`, VIP turns →
  `.twoShot`. With `.talker`: VIP turns → `.tight`, interviewer turns →
  `.interviewerTight`; the two-shot is used only when nobody is known to be
  talking at the range start. Same hold / minimumTurn / tail rules.
- `path(moves:tight:twoShot:interviewerTight:length:moveSeconds:)` maps the
  three kinds to their rects; `inDeadZone` is checked per pair.
- `interviewCuts` → `moveSeconds` 0: the camera cuts. Cuts must follow the
  planner's convention for hard cuts (a hold key just before the cut so
  `CenterStageService.interpolated` and `AreaFramer` stay right-continuous
  and never ramp); verify against `CropRecipe.swift`'s talker path and the
  comment "Recipe paths are hard cuts, with a hold key just before each cut".
- `CropRecipe.swift` interview branch passes `punchIn` and `cuts` through,
  both in the single-VIP path and the merged rotation path.
- `InterviewFaceSampling.sampleTimes` uses `moves(...)`: pass the punch-in
  choice so faces are sampled at the shots actually used.

UI:

- Express (`MiniSettingsCard`, under Camera focus when Interview focus) and
  the full wizard (`WizardView+Look`): a "Shot changes" segmented picker
  (Smooth moves / Cuts) and a "Punch in on" menu (VIP / Interviewer / Whoever
  talks) with one caption each; shared views in `Views/InterviewZoomSlider.swift`
  next to the existing controls. Pull back and Zoom in/out keep their rules.

Tests: `InterviewFocusPlaningTests` for each punch-in choice (which shot each
turn gets, interviewer tight centred on the other face, cuts produce
hold+cut keyframes with no ramp), `InterviewFocusRecipeTests` plan path for
`.interviewer` + cuts, `WizardPreviewCompositeTests` showing the preview cell
during the interviewer's question is centred on the interviewer with
`.interviewer`, `MiniWizardSettingsTests` round trip.

## B. Caption emphasis style "font"

- `CaptionStyle.resolvedEmphasis` accepts `"font"` (font only: the emphasis
  word takes `resolvedEmphasisFont` and `emphasisDecor`, no colour, no
  scale). `CaptionRenderer` already splits colour (`color`/`both`) and scale
  (`scale`/`both`) checks, so `font` falls through to the plain fill at
  normal scale; confirm `states` includes `.emphasis` for it.
- The caption style editor's Emphasis picker (`Views/CaptionWordDecorControls.swift`
  or wherever the "Emphasis" picker lives; search `resolvedEmphasis`) gains
  "Font only".
- Test in `CaptionStyleTests` / `CaptionRendererTests`: `emphasis = "font"`
  renders the emphasis word in the emphasis font with the text colour.

## C. Caption preset "Interview Serif"

Add to `CaptionPresets.styles`: weight bold, `wordsPerPage` 3, `reveal`
"word", `highlight` "color", `highlightColor` "#e5322d", `emphasis` "font",
`emphasisFont` a serif italic that resolves on a stock Mac (check
`CaptionRenderer`'s font resolution: family names → `CTFontCreateWithName`;
"Georgia" italic or "Baskerville" italic via the italic trait; if the
resolver cannot apply an italic trait to a family name, add that ability),
`position` "middle", `shadow` true, `bgOn` false, `strokeWidth` 0. Preset
tests (`CaptionPresetsTests` or the existing preset coverage) updated.

## Verification (Claude)

Debug build; the suites above; live in Express: Interview focus, Shot
changes = Cuts, Punch in on = Interviewer, scrub the preview across a
question/answer boundary: a hard cut from the two-shot to a tight shot on
the interviewer and back; caption preset "Interview Serif" shows the serif
italic emphasis word with the red spoken word.
