# Speech Polish

Date: October 31, 2026. Status: implemented, awaiting review and a live check. From the October 31
product review, item 2.

## Goal

An audio finishing pass for rendered reels: high-pass, noise reduction, and
loudness normalization with conservative defaults, off by default for fight
reels so crowd and cage ambience survive, with a before/after audition in the
Builder inspector.

## Design

- `ClipBuilder/Services/SpeechPolish.swift` (new, `nonisolated enum`).
  - `struct SpeechPolishSettings: Codable, Sendable, Equatable, Hashable` with
    `enabled: Bool`, `strength: Strength` (`light`, `standard`, `strong`;
    decoded `decodeIfPresent` defaulting to `standard`).
  - `static func filter(_ settings: SpeechPolishSettings) -> String`:
    `highpass=f=80,afftdn=nr=<6|9|12>:nf=-40,loudnorm=I=-16:TP=-1.5:LRA=11`
    (light/standard/strong set `nr`). Pure, string-tested.
  - `static func arguments(input: URL, output: URL, settings:) -> [String]`:
    `-y -i in -map 0:v -map 0:a -c:v copy -af <filter>` +
    `FFmpeg.audioEncodeArgs` + `-ar 44100 -movflags +faststart out`.
  - `@concurrent static func apply(input: URL, output: URL, settings:) async
    throws` via `FFmpeg.run`; skips (copies) when the file has no audio
    stream (`FFmpeg.hasAudioStream`).
- `RenderSettings.speechPolish: SpeechPolishSettings?` (Optional, manual
  decoder updated). `BrandProfile.defaultRenderSettings` carries it so a
  profile can default it on.
- `MultitrackRenderer.renderConfigured`: after dub, music and overlays, just
  before `copyItemReplacing(at: assembled, to: outputURL)`, when
  `settings.speechPolish?.enabled == true` run `SpeechPolish.apply` to a
  sibling temp file and continue with that. Also applied to the exact-preview
  branch so what the user hears matches the export. Express/podcast renders
  reach the same step.
- Wizard default: `WizardOptions` seeds `speechPolish = .init(enabled: true,
  strength: .standard)` only when the source classifies as `podcast` or
  `interview` (`LongRecordingClassifier`), never for the MMA playbook; the
  Express podcast path turns it on by default too.
- Builder inspector: `Views/Builder/SpeechPolishInspector.swift`, an
  `InspectorSection("Speech Polish")` under `DubInspector` with an On toggle,
  a strength picker (`ViewThatFits`), and an Audition control: renders a
  10-second slice at the playhead via the existing exact-preview slice, runs
  `SpeechPolish.apply` on it, and plays Original / Polished with one
  `AVPlayer`, swapping items at the same `currentTime`. Audition work runs
  as a `Task` off the main actor; files live in the scratch cache folder.
- Tests: `ClipBuilderTests/Services/SpeechPolishTests.swift`: filter string
  per strength, argument list shape, settings decode without `strength`,
  `RenderSettings` decode without the key. Integration (in
  `MultitrackRenderTests`): render the same document with polish on and off;
  video timing equal via `framemd5`, SSIM ≥ 0.99, audio differs, and mean
  level from `Analyzer.loudnessCurve` moves toward -16 dB.
