# AI Image Generation and Ask-AI Plan

Date: October 30, 2026. Status: Phases 1, 2 and 3 implemented on October 30, 2026, uncommitted. All three verified live on scratch data the same night: Phase 1 (sticker, edit, Stop), Phase 2 (Ask AI → Generate Image with Follow the face, 13 keys persisted, preview follows the keys, Stop Following and Follow Face from the inspector, export covered by `TrackedImageOverlayRenderTests`), Phase 3 (Ask AI on Reports → AI Report job → Keep → AI Reports page with Copy and Delete; Save… opens the panel, the write itself was not exercised).

## Problem

The app can analyze, cut, caption and publish, but it cannot make a new picture.
The user wants to stand on the Builder timeline, type "put a duck face on the
fighter on the left", and get a sticker placed over that fighter at the
playhead. Later they want the same text field on other pages: on Instagram →
Reports, "write me a report on what worked this month from the data you have".

Everything needed already exists on this Mac and in the app:

- Gemini CLI 0.53.1 is installed with the Nano Banana extension
  (`~/.gemini/extensions/nanobanana`, model `gemini-3.1-flash-image-preview`).
  Its MCP tools `generate_image` and `edit_image` write PNG files to
  `./nanobanana-output/` under the process working directory and print the
  path. The key comes from `GEMINI_API_KEY` in `~/.gemini/.env`. The app holds
  no key.
- `AIService.callGemini` already builds a one-shot `gemini -p` call with
  `@path` attachments and runs it with `GEMINI_CLI_TRUST_WORKSPACE=true`.
  `runRequest` and `ProcessRunner` accept `currentDirectory`.
- `FrameSampler` returns people and face boxes for a frame;
  `CenterStageService.faces(in:region:)` runs Vision face detection on a
  `CGImage`; `ThumbnailService.jpegFrame(url:at:maxDimension:quality:)`
  grabs a frame.
- `BuilderTimelineModel.addImage(path:at:)` (in `App/BuilderStore.swift`) creates an `ImageOverlayItem` from a path
  in the Images library and selects it. `BuilderTimelineModel.playhead` and
  `sourceTime(for:atTimeline:)` map the playhead to a source frame.
- `AppJobs` runs long work off-sheet with a status-bar row, Stop, and a review
  sheet from the root view.

Constraints:

- Gemini image output is opaque. There is no alpha channel. A sticker needs a
  chroma-keyed background, or the result is used as a full-frame freeze.
- The Builder agent has Gemini disabled (`BuilderAgentProvider.gemini`), so
  image calls go through the one-shot `AIService` path, never the agent loop.
- Long AI or media work never runs inside a modal sheet. It goes through
  `AppJobs`.
- Every feature needs a visible control. The Builder inspector gets a button;
  the Ask-AI field gets a toolbar button.
- New stored properties on Codable records are Optional.

## Phase 1: Generate Sticker from the Builder (this handoff)

### 1.1 `ImageGeneration` service

New file `ClipBuilder/Services/ImageGeneration.swift`. Pure request/response
types plus the prompt builder go in a `nonisolated enum ImageGeneration`;
the process call goes through `AIService`.

```swift
nonisolated enum ImageGeneration {
    enum Mode: String, Codable, Sendable { case sticker, edit }

    struct Request: Sendable {
        var prompt: String            // user text, e.g. "duck face"
        var mode: Mode                // sticker = isolated object on key color; edit = modify the frame
        var frame: Data?              // JPEG of the source frame at the playhead (edit, and reference for sticker)
        var subject: CGRect?          // face/person box in frame fractions, if the user picked one
        var keyColor: String = "#00FF00"
    }

    struct Result: Sendable {
        var path: String              // final PNG in the Images library
        var sourcePath: String        // raw CLI output (debugging)
        var width: Int, height: Int
    }

    static func prompt(for request: Request) -> String
    static func newOutputFiles(in scratch: URL, before: Set<String>) -> [URL]
}
```

`prompt(for:)` rules, tested:

- `sticker`: "Create a single PNG of <prompt> as a sticker. Fill the entire
  background with solid pure <keyColor> (RGB 0,255,0), no gradients, no shadow
  on the background, nothing else in the image. The sticker must be centered,
  fill about 80 % of the canvas, and face the camera." When `frame` is
  attached, add "Match the lighting and head angle of the person in the
  attached frame at the region x=…, y=…, w=…, h=… (fractions)."
- `edit`: "Edit the attached image: <prompt>. Keep everything else identical,
  same size and framing." With a subject box, add "Apply the change only to the
  person at x=…".
- Both end with: "Use the nanobanana edit_image tool when an image is attached
  and generate_image otherwise. Save the file and print only its absolute
  path." Nano Banana saves under `./nanobanana-output/` on its own; the prompt
  asks for the path so the stdout parse has a second chance, but the file
  listing is the contract (1.2).

### 1.2 `AIService.generateImage`

New method on `AIService` (`ClipBuilder/Services/AIService.swift`, near
`callGemini`):

```swift
func generateImage(_ request: ImageGeneration.Request,
                   timeout: TimeInterval = 180,
                   log: @escaping @Sendable (String) -> Void) async throws -> URL
```

- Creates a scratch directory
  `FileManager.default.temporaryDirectory/cb_imagegen_<uuid>/`, writes
  `frame.jpg` into it when `request.frame` is set.
- Runs the gemini binary resolved the same way `callGemini` does (reuse the
  binary lookup, model argument `-m gemini-2.5-flash` or whatever the current
  text default is; the image model is chosen by the extension, not by `-m`).
  Arguments: `["-p", prompt]` with `@frame.jpg` prefixed as `callGemini` does
  for frames. Environment: `GEMINI_CLI_TRUST_WORKSPACE=true`.
  `currentDirectory: scratch`. The Nano Banana extension must be allowed to
  run its tools headlessly: pass `--approval-mode yolo` (verified in
  `gemini --help` for 0.53.1; `-y` is the short alias). The scratch folder is
  the working directory, so the extension can only write there.
- Contract for the output: list `scratch/nanobanana-output/` after the run;
  the newest `.png` or `.jpg` is the result. If none exists, fall back to a
  path printed on stdout that exists on disk. Otherwise throw
  `AIError.emptyResponse("Gemini image")` with the first stderr line in the
  log, and treat quota and auth errors exactly as `callGemini` does (reuse
  `isQuotaError`, `authFailure`, `isProviderUnavailable`).
- Returns the URL of the raw file in scratch. The caller moves it; the
  service removes the scratch folder only on failure (a `defer` that keeps the
  returned file is wrong; move first, then clean up in the store).
- Add `case imageGeneration = "image_generation"` to `AITask` with a label
  "Image Generation", default provider "gemini", recommended chain `["gemini"]`
  in `AICatalog`, so provenance and settings routing work and the task shows
  in Settings → AI. The service ignores any provider other than gemini for
  this task and throws `AIError.notConfigured("Image generation needs the
  Gemini CLI with the Nano Banana extension installed.")`.

### 1.3 Chroma key to a transparent PNG

New file `ClipBuilder/Services/StickerKey.swift`, `nonisolated enum
StickerKey`, Core Image, no main-actor work:

```swift
static func keyed(_ image: CGImage, color: (r: Double, g: Double, b: Double),
                  tolerance: Double = 0.35) -> CGImage
static func trimmedToContent(_ image: CGImage, alphaThreshold: UInt8 = 8) -> CGImage
```

- `keyed` uses `CIColorCube` (or a `CIKernel`) that maps pixels within
  `tolerance` of the key color in hue distance to alpha 0, with a soft edge of
  about 0.05 so the sticker edge is not jagged.
- `trimmedToContent` crops to the bounding box of non-transparent pixels, with
  a 2 % margin.
- Test in `ClipBuilderTests/Services/StickerKeyTests.swift`: a synthesized
  green canvas with a red circle keys to an image whose corner pixel alpha is
  0 and center alpha 255, and trims to roughly the circle's bounds.

### 1.4 Store action and job

In `ClipBuilder/App/AppStore+AITools.swift` (or a new
`AppStore+ImageGeneration.swift` if the file is near 2k lines), add:

```swift
func generateSticker(prompt: String, mode: ImageGeneration.Mode,
                     video: URL?, sourceTime: Double?, subject: CGRect?,
                     builder: BuilderTimelineModel)
```

- Starts `jobs.start(.generateImage, ...)` (new `AppJobKind.generateImage`,
  `shortTitle` "Generate Image"). Inside the job:
  1. If `video` and `sourceTime` are set, grab the frame with
     `ThumbnailService.jpegFrame(url:at:maxDimension: 1280)`.
  2. If `subject` is nil and mode is `.sticker`, run
     `CenterStageService.faces(in:)` on the frame; when exactly one face is
     found use it, when more than one found use the largest and note it in
     the log. (Phase 1 does not pick a person by name; the user chooses with
     the picker in 1.5.)
  3. Call `ai.generateImage`.
  4. For `.sticker`: decode the file from `Data` (not lazily from the URL;
     the scratch folder is deleted after), key it, trim it, write PNG to
     `AssetKind.images.rootURL/Generated/<slug>-<yyyyMMdd-HHmmss>.png`.
     For `.edit`: copy the file as-is to the same folder.
  5. Remove the scratch folder.
  6. Result `AppJobResult.generatedImage(GeneratedImage)` with
     `needsReview` false; the job's completion handler, on the main actor,
     calls `builder.addImage(path:at:)` and then adjusts the new item: for
     sticker mode with a subject box, `wFrac = subject.width * 1.6`,
     `xFrac = subject.midX`, `yFrac = subject.midY`, start at the playhead,
     end at playhead + 3 s (the `addImage` default). For edit mode,
     `wFrac = 1`, centered, same timing.
  7. Log one line in the AI log with the prompt and the output path.
- The provenance record uses task `.imageGeneration` with the prompt and
  output path, like other tasks.

### 1.5 Builder UI

In `ClipBuilder/Views/Builder/BuilderAddMenu.swift`, add a "Generate
Image…" entry right after "Add Image…" (the entry that sets
`showImagePicker`, line 91), bound to a new `showGenerateImage` state on
`BuilderView.swift` next to `showImagePicker`. It opens
`GenerateImageSheet` (new file `ClipBuilder/Views/Builder/GenerateImageSheet.swift`):

- Text field "What to add" (focused on open), Picker "Place as": Sticker on a
  person / Edit the whole frame.
- A thumbnail of the frame at the playhead (reuse the Builder's current frame
  if available, otherwise `ThumbnailService.jpegFrame`), with face boxes drawn
  from `CenterStageService.faces`; clicking a box selects the subject
  (highlighted). No box selected means the largest face.
- "Generate" calls `store.generateSticker(...)` and dismisses immediately.
  The sheet never waits. The status bar shows the job; the image appears on
  the timeline when the job ends.
- The sheet is disabled with an explanation when the Gemini CLI is missing
  (`ai` knows the binary lookup; expose `aiService.hasGeminiImageTools`
  that checks the binary and `~/.gemini/extensions/nanobanana` exist).
- The Add menu is the visible control. A context-menu entry on the
  timeline is optional and never the only entry point.

### 1.6 Tests

- `ImageGenerationTests`: prompt builder includes the key color, the 80 %
  rule and the subject box text only when a box is given; `newOutputFiles`
  returns only files created after the `before` set.
- `StickerKeyTests` as in 1.3.
- `AppJobKind.generateImage` appears in `shortTitle` and the status bar
  without crashing (existing `AppJobs` tests pattern).
- No live Gemini call in tests.

### 1.7 Verification (Claude, live)

Build with `build-for-testing`, run the app on scratch data, open a project in
the Builder, place the playhead on a frame with a face, Generate Image
"a cartoon duck beak" as sticker, confirm a PNG lands in
`~/Documents/ClipBuilder/<profile>/images/Generated/`, that the overlay item
is on the timeline at the playhead sized to the face, and that the
background is transparent in the preview.

### 1.8 Placement through the screen layout (done October 30, 2026)

Face boxes come from the source frame, but `ImageOverlayItem` fractions are in
the output frame. `BuilderTimelineModel.framePlacement(for:atTimeline:)`
(`App/BuilderStore+ImagePlacement.swift`) mirrors the preview pane's clip
layer and returns an `ImageGeneration.Placement` (visible source `window`,
output `box`); `overlayGeometry` maps the face through it. Edit mode sends
only the visible window of the frame and covers the box. The sheet shades the
cropped-out part of the frame, labels faces with roster names, and the
generated item sets `keepsPlacement` so the safe-area rule never moves it.

## Phase 2: Keep the sticker on the face (Codex)

A sticker placed on a face drifts off it as soon as the person moves. Track
the face over the overlay's span and move the sticker with it.

### 2.1 Model

`ImageOverlayItem` (`Data/TimelineModels.swift`) gains one Optional stored
property, decoded with the synthesized decoder (older JSON has no key):

```swift
/// Position keyframes in output-frame fractions over timeline seconds
/// (absolute, not clip-relative). Nil = static placement.
var track: [ImageTrackKey]?
nonisolated struct ImageTrackKey: Codable, Sendable, Equatable {
    var time: Double     // timeline seconds
    var xFrac: Double    // center
    var yFrac: Double    // center
    var wFrac: Double    // width
}
```

CodingKeys add `case track`. `ImageTrackKey` uses CodingKeys `time`, `x_frac`,
`y_frac`, `w_frac`. `RenderSegmentCache.key(item)` must include `track` so a
changed track re-renders.

### 2.2 Tracking (`Services/ImageTracker.swift`, `nonisolated enum`)

```swift
static func track(video: URL, clip: TimelineClip, model placement: (Double) -> ImageGeneration.Placement,
                  start: Double, end: Double, seed: CGRect, step: Double = 0.25) async throws -> [ImageTrackKey]
```

- Samples source frames every `step` seconds from `start` to `end` with
  `ThumbnailService.jpegFrames(url:at:maxDimension: 640)`; timeline time ↔
  source time through `sourceTime(for:atTimeline:)` (passed in as a closure
  so the enum stays free of the store).
- On each frame runs `CenterStageService.faces(in:)`, picks the face whose
  center is nearest the previous key's source-space center and whose size is
  within 2x of it; if none within 0.15 of the frame, repeats the previous key
  (hold) and counts a miss. Three consecutive misses end the track early
  (the remaining span keeps the last key).
- Each key maps the chosen face box through `placement(time)` with
  `ImageGeneration.overlayGeometry(mode: .sticker, …)` and stores the
  output-frame center and width at that timeline time.
- Smooths centers with a 3-tap moving average before returning. Keys are
  strictly increasing in time; the first key is at `start`, the last at `end`.
- Pure parts (nearest-face choice, hold rule, smoothing) are separate static
  functions with tests in `ClipBuilderTests/Services/ImageTrackerTests.swift`
  using synthetic boxes, no video.

### 2.3 Store and job

`AppStore+ImageGeneration.swift`: `func trackImageOverlay(_ uid: UUID, builder:)`
starts `AppJobKind.trackImage` ("Track Face"), gets the picture clip at the
item's start, seeds with the item's current geometry mapped back to source
space (invert `Placement.outputRect`, add `inputRect(_:)` to `Placement`), and
on completion sets `item.track` through `builder.updateImage`. A second run
replaces the track. "Stop Following" sets `track = nil`.

`generateSticker` gets a `follow: Bool` parameter; when true it chains the
track job after the image is placed.

### 2.4 Renderer

`MultitrackRenderer` image overlay pass (line ~618): an item with a track is
still rendered once at `wFrac` of its first key by `ImageOverlayRenderer`, but
the PNG is rendered at the sticker's own size (not composited into a full
frame), and the overlay filter gets piecewise-linear `x`/`y` expressions over
`t`, built like `AreaFramer.expression(_:clock:)` from the keys (center minus
half width/height in pixels). Width changes are ignored in Phase 2 (use the
first key's width). The `TimedOverlayPNG` struct gains Optional `xExpr`,
`yExpr`; the compositing site at ~2816 uses them when present.

### 2.5 UI

`Views/Builder/BuilderInspector.swift`, image overlay section: a "Follow
Face" button (sparkles.rectangle.stack) when `track == nil`, "Stop Following"
when set, and a caption "Tracked, N keys". `GenerateImageSheet` gets a
"Follow the face" toggle (default on in sticker mode) that passes `follow`.
The timeline preview (`PreviewPane`) draws the sticker at the interpolated
key for the current time when a track exists; a pure
`ImageTrackKey.interpolate(_:at:)` does the lerp, with a test.

## Phase 3: Ask AI on every page (Codex)

### 3.1 Shape

A toolbar button "Ask AI" (sparkles) placed in the window toolbar before the
page's primary action, shown on every page through a new modifier
`.askAI(_ assistant: any PageAssistant)` applied next to `.screenTitle` in
each page view. The button opens a popover (`Views/AskAIPopover.swift`) with
one `TextField` (focused on open, `axis: .vertical`, `lineLimit(1...4)`),
three example chips from the assistant, a Send button (⌘↩), and the last
outcome's one-line summary. Send dismisses the popover and hands the text to
the assistant; the work runs through `AppJobs`.

```swift
protocol PageAssistant: Sendable {
    var page: String { get }                // "Builder", "Reports"
    var examples: [String] { get }
    @MainActor func handle(_ text: String, store: AppStore) -> AskAIOutcome
}
enum AskAIOutcome { case started(jobTitle: String), handled(String), unavailable(String) }
// Wizard assistant returns .handled: the visible form consumes the request and decides whether it can run.
```

The modifier reads the assistant from the environment so a page without one
shows nothing. Pages wired in Phase 3: Builder, AI Wizard (Express and Full) and Instagram → Reports.
Every other page gets no button yet.

### 3.2 Builder assistant (`Services/Assistants/BuilderAssistant.swift`)

- Image verbs route to Phase 1: a text matching
  `^(add|put|give|draw|generate|make)\b.*\b(sticker|image|picture|face|hat|
  nose|glasses|crown|beak|mask)\b` (case-insensitive) opens `GenerateImageSheet`
  with the prompt prefilled (new `prefill` parameter) via
  `store.builder.pendingGenerateImagePrompt`, which `BuilderView` observes.
- Anything else sets `store.builderWizard?.request = text` and calls
  `await store.builderWizard?.run()` (the Wizard tab path at
  `Views/Builder/WizardSheetModel.swift` line ~604), switching the left panel
  to the AI Wizard tab. The pure routing function `BuilderAssistant.route(_:)`
  returns `.image(prompt)` or `.wizard(text)` and has tests.

### 3.2b Wizard assistant (`Services/Assistants/WizardAssistant.swift`)

Added October 30, 2026 after the first live pass: the user expected the
button on the AI Wizard page too. The host view applies `.askAI(WizardAssistant())`
so both Express and Full show it. `WizardAssistant.decide(text:mode:hasVideo:hasScenes:running:)`
is the pure gate (empty text, a running Wizard, Express without a chosen video,
Full without scenes). A passing request is stored as
`AppStore.pendingWizardAssistantRequest`; the visible form consumes it:
Express writes the text into the profile's Highlights instructions, switches
Footage to Highlights and calls `generateMiniFootage`; Full sets its
instructions field and calls `startGeneration()` when it can start, otherwise
posts a notice to choose sources. Tests: `WizardAssistantTests`.

### 3.3 Reports assistant (`Services/Assistants/ReportAssistant.swift`)

"Create a report on …" or any free text becomes an AI report built from the
data the Reports page already holds:

- Context builder `ReportAssistant.context(report: InstagramReport, account:
  IGAccountRecord, posts limit: 60) -> String`: the period label, overview
  KPIs (`overview.kpis` label/value/delta), follower series start/end,
  published counts, engagement windows, the top posts by reach and by
  engagement (date, type, caption first 80 chars, reach, views, likes,
  comments, shares, saves), community rankings (top commenters), audience
  splits. Plain text sections with `##` headers, the same style as
  `generateGapReport`'s inventory in `AppStore+AITools.swift`. Pure, tested
  against a fixture report (`ClipBuilderTests/Services/ReportAssistantTests.swift`).
- Prompt: "You are the analyst for this Instagram account. Using only the
  data below, write the report the user asked for in Markdown with short
  sections and concrete numbers. Say what is missing when the data does not
  cover the question." plus the user's text and the context.
- New `AITask.report` ("AI Report", default provider claude, chain claude →
  antigravity → gemini like `.gap`), called with `ai.call(prompt:task:)`, no
  frames. Runs as `AppJobKind.report` ("AI Report") with
  `AppJobResult.report(AIReportRecord)` and `needsReview` true, so the root
  review sheet opens it.
- Storage: table `ig_ai_reports` (`id`, `account_id` → `ig_accounts` cascade,
  `period_key`, `prompt`, `markdown`, `provider`, `model`, `created_at`) in
  `Database.swift` schema (`CREATE TABLE IF NOT EXISTS`, bump `schemaVersion`
  to 37) and `Database+Instagram.swift` (`saveIGAIReport`, `fetchIGAIReports
  (accountID:)`, `deleteIGAIReport(id:)`). `AIReportRecord` in
  `Data/InstagramReportModels.swift`.
- UI: `InstagramReportsView.Page` gains `case aiReports = "AI Reports"`: a
  list of saved reports (prompt, date, provider) on the left, the selected
  report rendered with `LearnedRichTextView` on the right, with Copy
  (Markdown to the pasteboard), Save… (`.md` through `NSSavePanel`), and
  Delete. The review sheet for a finished job shows the same rendered report
  with Keep and Discard; Keep stores it and selects it on the AI Reports page.
- Examples: "Create a report on what worked this month", "Which post types
  drive saves?", "Summarize follower growth versus last month".

### 3.4 Tests

`BuilderAssistantTests` (routing), `ReportAssistantTests` (context contains
the KPIs, caps posts, says "no data" when `hasData` is false),
`AskAIPopover` has no logic to test. `AppJobKind.report` and `.trackImage`
appear in `shortTitle`.

## Later: video generation

Veo through the same CLI route (`generate_video` is not in Nano Banana 1.0.12;
needs the `veo` extension or the Gemini API). B-roll shots of a few seconds
from a text prompt, imported as a clip. No date.

## Files touched in Phases 2 and 3

New: `Services/ImageTracker.swift`, `Services/Assistants/BuilderAssistant.swift`,
`Services/Assistants/ReportAssistant.swift`, `Views/AskAIPopover.swift`,
`ClipBuilderTests/Services/ImageTrackerTests.swift`,
`ClipBuilderTests/Services/BuilderAssistantTests.swift`,
`ClipBuilderTests/Services/ReportAssistantTests.swift`.

Edited: `Data/TimelineModels.swift` (track), `Services/MultitrackRenderer.swift`
(x/y expressions, cache key), `Services/ImageOverlayRenderer.swift`,
`Views/Builder/PreviewPane.swift`, `Views/Builder/BuilderInspector.swift`,
`Views/Builder/GenerateImageSheet.swift`, `Views/Builder/BuilderView.swift`,
`App/AppStore+ImageGeneration.swift`, `App/AppJobs.swift`,
`Views/AppJobReviewSheet.swift`, `Services/AITask.swift`, `Data/AppSettings.swift`,
`Data/Database.swift`, `Data/Database+Instagram.swift`,
`Data/InstagramReportModels.swift`, `Views/Instagram/InstagramReportsView.swift`,
`Views/InstagramView.swift` (toolbar), `Views/Theme.swift` (askAI modifier).

## Files touched in Phase 1

New: `Services/ImageGeneration.swift`, `Services/StickerKey.swift`,
`Views/Builder/GenerateImageSheet.swift`, `App/AppStore+ImageGeneration.swift`,
`ClipBuilderTests/Services/ImageGenerationTests.swift`,
`ClipBuilderTests/Services/StickerKeyTests.swift`.

Edited: `Services/AIService.swift` (generateImage, hasGeminiImageTools),
`Services/AITask.swift` and `Data/AppSettings.swift` (`AICatalog`) for the
new task, `App/AppJobs.swift` (kind + result case), `Views/AppJobReviewSheet.swift`
only if a review is added, `Views/Builder/BuilderAddMenu.swift` (menu entry),
`Views/Builder/BuilderView.swift` (sheet presentation).
