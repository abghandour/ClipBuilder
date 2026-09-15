# Preview slice validation on the main actor

September 15, 2026. Follow-up to the [improvement plan](Performance-Improvement-Plan.md) item on removing repeated preview-key work from the main actor.

## Question

Every Builder document revision calls `pruneBuilderPreviewCache`, which recomputes the identity of each cached exact-preview slice (up to twelve) on the main actor: window the document, resolve its clips, collect scene facts, JSON-encode the evidence with the brand profile, and hash it. The plan flagged this as a possible drag-responsiveness cost and asked for a measurement before any change.

## Measurement

`ClipBuilderTests/App/PreviewKeyCostTests` times exactly that work, `AppStore.builderPreviewKey` for twelve five-second windows, on a document like the harness fixture (two-second clips, every fourth with Center Stage, captions, a fade every tenth clip, a title and an overlay block), 30 repetitions, Debug test build on the 12-core Mac.

| Timeline | Twelve slices validated, median (range) |
| --- | ---: |
| 40 clips, 80 s | 2.14 ms (2.12–2.69) |
| 200 clips, 400 s | 3.15 ms (3.00–3.32) |

The cost grows slowly with timeline length because each key windows a five-second span; only the windowing scan touches every clip. A Release build would be faster still.

## Decision

**No change.** One revision costs about a fifth of a 60 Hz frame in a Debug build, well inside Apple's guidance of keeping discrete main-thread work under about 100 ms and continuous work within a refresh interval. Moving it off the main actor would add revision bookkeeping and stale-result handling for no perceptible gain. The test stays as a regression guard with a 50 ms bound, more than twenty times the measured cost, and writes its measurement to `PreviewKeyCost.txt` in the temporary directory because the test host's output is not surfaced by `xcodebuild`.

This does not measure dragging itself: SwiftUI layout, the lanes' viewport filtering and autosave are separate costs that a Time Profiler trace of a real drag would show. Nothing in this measurement suggests the key work is the place to look.
