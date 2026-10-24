# Caption position per speaker

Date: October 24, 2026. Status: implemented by Codex, including the speaker-naming follow-up; build, tests and live verification pending Claude

Builds on docs/Caption-Styles-Per-Speaker-Plan.md (implemented, verified
October 24, 2026). Read that plan first: `CaptionRendererSet`,
`CaptionSpeakerColors.speakerKey/personKey`, `Page.styleID`,
`CaptionSpeakerStylesEditor` and the preview's speaker evidence
(`Scene.speakerTurns/speakerRows`) all exist already.

## Goal

Each person who speaks in the run's footage can have their own caption
position, chosen next to their caption style in the Captions section
(Express `MiniSettingsCard` Overlays tab and `WizardView+Look`). A person
with no choice follows the run's Caption position. Dragging a caption in
the preview moves that speaker's caption only. The preview draws one
caption per speaker the user has switched on, each with a name marker; the
user can add or remove speakers from the preview at will; overlapping
captions are simply drawn one over the other.

## Data: positions are a run setting, stored generically

Caption position depends on the footage (where the faces are), so this is
a run setting like `captionPosition`, not a profile attribute like the
style. The user wants the stored form to be generic so that presets and
memory carry over to other footage: keys are `speaker1`, `speaker2`, …
(speaking order), not person keys.

- `MiniWizardSettings.speakerCaptionPositions: [String: String]?` and
  `WizardOptions.speakerCaptionPositions: [String: String]?`. Key
  `"speaker<n>"` (1-based), value the same strings `captionPosition`
  takes: `"bottom"`, `"middle"`, `"top"`, or `custom:x,y`. A missing key
  means "run position". Optional, synthesized/decodeIfPresent decoding so
  existing JSON decodes (both structs have custom `init(from:)`; add a
  `decodeIfPresent` line and a CodingKeys case `speakerCaptionPositions`).
  `MiniWizardSettings.effective(...)` copies it to the options.
  `MiniWizardMemory.Field` gains `speakerCaptionPositions`; `remembered`
  reads it with `defaults.dictionary(forKey:) as? [String: String]`,
  `remember` writes it. `AIRunSettings` `.options` list gains
  `"speakerCaptionPositions"`. Express presets (`MiniWizardPreset`) carry
  it for free through `MiniWizardSettings`.
- New `nonisolated enum CaptionSpeakerOrder` in
  `Services/CaptionSpeakerOrder.swift`:
  `static func ordinals(turns: [SpeakerTurn], rows: [TranscriptRow], roster: [String]) -> [String: Int]`
  person key → 1-based ordinal. Order: people in order of their first
  person-attributed speech (`CaptionSpeakerColors.speakerKey` over the
  ordered turns, with explicit row attribution first, mirroring
  `color(for:)`'s key list), then roster people who never speak, sorted by
  key. `static func slot(_ ordinal: Int) -> String { "speaker\(ordinal)" }`,
  `static func ordinal(slot: String) -> Int?`.
  `static func position(forPerson key: String?, ordinals: [String: Int], positions: [String: String]?, runPosition: String) -> String`
  returns the person's valid position (same validity rule as
  `WizardOptions.captionPositionOverride`: bottom/middle/top/custom) else
  `runPosition`.
- For the full wizard with several videos, ordinals are computed over the
  concatenation of the selected videos' turns in source order (first
  video's speakers first). Document this in the enum.

## Rendering

`CaptionOverlayPlan.pages(segments:renderers:…)` already resolves the
speaker per segment. Add a parameter
`speakerPositions: (String?) -> String` (person key → position string;
default `{ _ in position }`) and set `Page.position` from it instead of
the `position` argument. Nothing else in the plan or raster changes: the
raster is positioned with `renderer(styleID:).position(for:positionOverride:/clipPosition:)`
using `overlay.position`, which already flows per page.

Call sites:

- `WizardEngine` clip render (~4160–4200): compute
  `ordinals = CaptionSpeakerOrder.ordinals(turns:rows:roster:)` from the
  turns/rows it already fetches (fetch them when
  `options.speakerCaptionPositions?.isEmpty == false` as well; extend the
  `needsSpeakers` condition) and the video roster
  (`database.fetchVideoPeople(videoID:)` keys), pass the closure.
- `MultitrackRenderer`: untouched. The Builder renders from the profile
  and has no run options, so it keeps the run position for everyone.
- `WizardPreviewComposite` (see below).

## Preview

`WizardPreviewComposite`:

- `Scene` gains `roster: [String: String]` (video roster person key →
  display name). `Input` gains `var shownSpeakers: Set<String> = []`
  (person keys the user switched on; empty draws the speaker of the
  moment only, as today).
- Draw the moment's speaker caption as today, at
  `CaptionSpeakerOrder.position(...)` for that speaker. Then for every
  other key in `shownSpeakers` that has a renderer or a position of its
  own or is in the roster: render `CaptionPreviewImage.sampleText` (first
  page, middle word active, `plan` with that speaker's styleID) at that
  speaker's position, with that speaker's colour when the style uses
  speaker colours. Overlaps are drawn one over the other; the moment's
  speaker is drawn last (on top).
- `Layout.caption: CGRect?` becomes
  `captions: [CaptionBox]` with `struct CaptionBox: Sendable, Equatable { var rect: CGRect; var personKey: String?; var name: String; var isTalking: Bool }`.
  `name` is the person's display name from `roster` records (pass
  `[VideoPersonRecord]`-derived `[String: String]` key → name in the
  Scene) or "Caption" when no person.

`WizardPreviewColumn`:

- `PreviewElement.caption` carries the stored slot:
  `case caption(slot: String?)` (`"speaker<n>"`, nil for the run
  caption). `PreviewHandlesLayer` makes one
  handle per `layout.captions` entry. Each caption handle shows a marker:
  a small capsule label with the speaker's name at the handle's top
  leading corner (lineLimit 1, fixedSize, `.font(.caption2)`, accent
  background when talking, secondary otherwise), always visible, not only
  on hover.
- Under the preview, a row of toggle chips, one per roster person that
  speaks (ordinals), `ViewThatFits` or a horizontal `ScrollView`: tapping
  adds or removes the person from `shownSpeakers` (`@State` in the
  column, remembered per profile+video in `@AppStorage`-style
  UserDefaults key `preview.shownSpeakers.<profile>.<videoID>`; store the
  joined keys). The speaker of the moment is always drawn and their chip
  is shown selected and disabled with help "Talking at this moment".
  Rows need a visible control; no context menus.
- `onMove(.caption(slot:), position)`: `MiniWizardView` and
  `WizardView+Steps` write
  `speakerCaptionPositions[slot] = position.string` when `slot` is
  non-nil, else `captionPosition = position.string` as today. The column
  resolves person → slot with `CaptionSpeakerOrder.ordinals` from the
  model's snapshot (turns, rows, roster) when it builds the layout.
- `ContentKey` / `PreviewKey` include `options.speakerCaptionPositions`
  (already via options if the key hashes the whole options; verify) and
  `shownSpeakers`.

## UI

`CaptionSpeakerStylesEditor` gains a second control per row, to the left
of the style picker: a `Picker` with "Run position" (nil), Bottom,
Middle, Top and, when the stored value is custom, "Custom (dragged)". Bind through `MiniWizardSettings`/wizard
options, so the editor takes
`positions: Binding<[String: String]?>` and `ordinals: [String: Int]`
(the editor already loads the roster; load turns/rows there too via
`database.fetchSpeakerTurns(videoID:)` / `fetchTranscripts(videoID:)`
for the Express case; the wizard passes the ordinals it computes from its
source videos). Rows are sorted by ordinal, then key. Footer caption
becomes: "People without a choice use the Caption position and style
above. Positions are saved by speaking order (speaker 1, speaker 2, …) so
presets apply to other footage; styles are saved with the profile."
`CaptionPositionPicker` can be reused with a `runLabel: String = "Auto"`
parameter so the nil item reads "Run position".

## Tests

- `CaptionSpeakerOrderTests` (new): ordinals follow first speech with
  explicit row attribution first; non-speaking roster people come after;
  multi-video concatenation; `position(forPerson:)` fallbacks and
  invalid-string rejection; slot round trip.
- `MiniWizardSettingsTests` / `WizardOptionsTests`: round trip with the
  mapping; old JSON decodes; `remembered`/`remember` carry it;
  `effective` copies it.
- `CaptionOverlayPlanTests`: two segments by two people get different
  `Page.position` through the closure; a person without a choice gets the
  run position.
- `WizardPreviewCompositeTests`: a moment inside person A's turn with
  `shownSpeakers = [A, B]` yields two `layout.captions`, A `isTalking`,
  positions differ; empty `shownSpeakers` yields one.

## Verification (Claude)

Debug build; the suites above plus `CaptionRendererTests`,
`RenderSegmentCacheTests`; live in Express › Overlays on the scratch
instance: pick Top for speaker 1, drag speaker 2's caption, check both
markers and chips, remove and re-add a speaker, confirm the stored
`speaker1`/`speaker2` keys in the Express memory defaults.

## Follow-up (October 24, 2026): name the turns before keying speakers

Found live: on a recording transcribed before the people pass, every
`SpeakerTurn.personKey` is nil (cluster or feed only). The transcript UI
still shows names because the loaders run
`TranscriptSpeakers.named(turns, roster:)` (= `DubPlanning.namingTurns`)
first. The caption path (`CaptionSpeakerColors.speakerKey`,
`CaptionSpeakerOrder.ordinals`, the preview, the editors) uses the raw
turns, so `personKey` is nil for everyone: no per-speaker style or
position ever applies, the preview marker reads "Caption", no chips.

Fix, one helper used everywhere caption speaker evidence is fetched:

- `nonisolated struct CaptionSpeakerEvidence: Sendable { var turns: [SpeakerTurn]; var rows: [TranscriptRow]; var roster: [VideoPersonRecord] }`
  in `Services/CaptionSpeakerEvidence.swift` with
  `static func load(database: Database, videoID: Int64) async -> CaptionSpeakerEvidence`
  (turns = `TranscriptSpeakers.named(fetchSpeakerTurns(videoID:), roster:)`
  then any `personKey` not in the roster set back to nil, so leftover
  "speaker-N" placeholders never become a person; rows =
  `fetchTranscripts`; roster = `fetchVideoPeople`; each read `try?` to
  `[]`), plus `var rosterKeys: [String]` and `var names: [String: String]`.
  `static func load(database:videoIDs:) async` concatenates in the given
  order.
- Replace the raw fetches with it in: `WizardEngine` (the ordinals block
  and `extractPlannedClip`'s turns/rows), `MultitrackRenderer.renderSegment`,
  `WizardPreviewModel.loadScene` (the snapshot's turns/rows/roster; keep
  the transcription-key filter by passing the fetched turns through
  `TranscriptSpeakers.named` with the roster instead), `WizardView.loadCaptionOrdinals`,
  `CaptionSpeakerStylesEditor.load`.
- Tests: `CaptionSpeakerEvidenceTests` (fixture DB with cluster-only turns
  and a two-person roster: turns come back person-keyed, a cluster beyond
  the roster stays nil) and one `WizardPreviewCompositeTests` case where
  the scene's turns are cluster-only but `Scene.roster`/named turns yield
  the person's style and marker name.
