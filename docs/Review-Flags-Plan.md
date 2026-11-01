# Review flags (review queue for questionable moments)

Date: October 31, 2026. Status: implementing (Claude). From the October 31
product review, item 1.

## Goal

After a wizard reel renders, list the moments where the pipeline was unsure so
the editor jumps straight to them in the Builder instead of rewatching the
export: unnamed or low-confidence speakers, framing that fell back to a static
crop, wide scenes with no tracking path, and quality-gate warnings.

## Design

- `ClipBuilder/Services/ReviewFlagBuilder.swift` (new, `nonisolated enum`).
  - `struct ReviewFlag: Codable, Sendable, Hashable, Identifiable` with
    `id: String` (stable, derived from kind + clip origin + time), `kind`
    (`unnamedSpeaker`, `lowConfidenceSpeaker`, `framingFallback`,
    `noTrackingPath`, `qualityWarning`), `time: Double` (output seconds),
    `endTime: Double?`, `clipOriginKey: String?`, `severity` (`info`,
    `warning`), `message: String`. All decoded with `decodeIfPresent` so older
    JSON keeps loading.
  - `static func flags(document: TimelineDocument, scenes: [Int64: SceneRecord],
    turns: [SpeakerTurn], quality: ReelQualityReport?, renderFallbacks:
    [RenderFramingFallback]) -> [ReviewFlag]`, sorted by time, deduplicated by
    id.
  - Speaker flags: for each main-track clip, find speaker turns whose source
    range overlaps the clip's `sourceStart...sourceEnd` on the same video.
    `personKey == nil` → `unnamedSpeaker`; `max(confidence, pictureConfidence)
    < 0.5` → `lowConfidenceSpeaker`. Output time = `clip.startTime +
    (turn.start - clip.sourceStart) / clip.speed`, clamped to the clip.
  - Framing flags: a wide scene tagged `portrait-fit:poor` with no
    `centerStagePathJSON` → `noTrackingPath` at the clip start; a render
    fallback (renderer caught `CenterStageError` or `fellBack`) →
    `framingFallback` at the clip start.
  - Quality: each `ReelQualityReport.warnings` / `failures` string →
    `qualityWarning` at time 0 (`severity` warning for failures).
- `MultitrackRenderer`: collect `RenderFramingFallback(clipOriginKey:
  startTime: reason:)` where it currently emits "Framing failed … using the
  static crop" and where `usedFallback`/`fellBack` is set, and return them on
  the render result (add an Optional field; do not change existing call sites'
  behaviour).
- `WizardEngine`: after the post-render quality gate (~line 4224) build the
  flags and store them.
- Storage: `generated_videos.review_flags_json TEXT` (migration via
  `columnNames` + `ALTER TABLE` in `Database.swift`), Optional
  `reviewFlagsJSON: String?` on `GeneratedVideoRecord`, decoded accessor
  `reviewFlags: [ReviewFlag]`, `updateGeneratedReviewFlags(id:json:)` in
  `Database+Generated.swift`, and the insert/select mapping updated.
- Builder: `AppStore.openInBuilder` passes the record's flags into the Builder
  model (`BuilderTimelineModel.reviewFlags: [ReviewFlag]`, not persisted in the
  document). `BuilderTimelineModel.jump(to flag:)` sets `selection =
  .clip(uid)` for the clip whose `originKey` matches (else the clip at that
  time) and `playhead = snap(flag.time)`.
- UI: `Views/Builder/ReviewFlagsInspector.swift`, an `InspectorSection("Review")`
  shown above the selection content in `BuilderInspector` when flags are
  non-empty: one row per flag with an icon per kind, the message
  (`lineLimit(2)`), the time, and a Jump button. Library card: a small
  "N to review" badge next to the quality verdict when flags exist (visible
  control, not context-menu only).
- Tests: `ClipBuilderTests/Services/ReviewFlagBuilderTests.swift` using
  Fixtures (`timelineDocument`, `scene`) plus a new `speakerTurn` fixture:
  unnamed turn maps to output time with speed; low confidence; wide poor-fit
  scene without path; quality failure at time 0; dedupe; sorted.
