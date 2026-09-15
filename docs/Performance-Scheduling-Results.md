# Media scheduling and cancellation

Subsequent measurements and finishing-cache validation are documented in [Performance-Finishing-Cache-Results.md](Performance-Finishing-Cache-Results.md).

September 14, 2026. Implements section 1 of [Performance-Improvement-Plan.md](Performance-Improvement-Plan.md) and the scheduler coverage recommendation in [Performance-Plan-Independent-Review.md](Performance-Plan-Independent-Review.md), following the [baseline captures](Performance-Baseline-Results.md).

## Changes

| Work | Admission |
| --- | --- |
| ffprobe | Separate bounded probe queue, capacity 2 |
| Known frame extraction, detector scans, loudness/beat analysis, and PCM audio extraction | Decode queue |
| Other ffmpeg graphs and Center Stage AVFoundation exports | Shared encode queue |
| Podcast face landmarks | Existing Vision queue |
| Requested exact previews | Interactive priority, inherited by media leaves |
| Speculative preview prefetch | Background priority |

Existing decode, encode, and Vision capacities remain unchanged. After four interactive admissions while background work waits, the scheduler admits an eligible background job. Decode reservation counts active background decoders, allowing background work to use its slot while an interactive decoder occupies the reserved slot. Priority affects queued work; it does not interrupt work already running. Unknown ffmpeg graphs conservatively retain encode admission; known decode leaves opt in explicitly.

Center Stage uses the throwing async AVFoundation export API, whose initiating task cancellation cancels the export ([Apple documentation](https://developer.apple.com/documentation/avfoundation/avassetexportsession/export%28to%3Aas%3Aisolation%3A%29)). The encode permit and original asset/Drive lease remain alive until export returns. A failed or cancelled export removes partial output before releasing capacity; cancelling in the queue leaves the destination untouched. Existing renderer fallback catches check task cancellation before retrying. A post-Vision cancellation check also prevents the tracking pass from interpreting cancellation as missing people.

`MediaQueueWait` intervals cover admission waits, including cancelled waits. `MediaExecution` covers admitted subprocess work through termination and pipe drainage, or the async AVFoundation export. The existing `FramingExport` includes composition preparation and queueing; use `MediaExecution` to separate admitted work. Instrumentation remains gated by signpost enablement.

## Validation

- Eight focused Swift Testing tests passed, including 30 cancellation/admission races, priority overtaking with bounded background progress, task-local inheritance, and the decode reservation behavior.
- Real ffmpeg/ffprobe and AVFoundation integration tests verify that probes and JPEG extraction finish while a Center Stage export waits behind ffmpeg, that cancelling ffmpeg admits the export, and that the resulting portrait video has the expected dimensions and duration.
- Queued export cancellation preserves existing destination bytes. Running export cancellation is triggered after the output file appears, then verifies removal and an idle encode queue.
- Final full suite (`scripts/test.sh`): 834 tests passed, representing 1,028 executions including parameterized cases; no failures. One opt-in Google Drive integration test was skipped. Result bundle: `/private/tmp/clipbuilder-scheduling-final.xcresult`.
- Test scheduler instances are task-local, and media fixtures use unique temporary directories. Tests do not alter the user's media library or global data-folder override.

The normal ad-hoc Release build passed with Xcode beta, scheme `MyApp`, and derived data in `build`. Changed-file whitespace checks and `git diff --check` passed. This change has no measured end-to-end speedup claim. Long-recording, Drive-backed contention, sustained UI responsiveness, and before/after Release timing remain to be measured with the baseline workflow.
