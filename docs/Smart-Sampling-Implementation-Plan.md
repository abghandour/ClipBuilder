# Smart Sampling — phased analysis for long footage

September 9, 2026. Implemented the same day; this records the design and
what is and is not covered so a later change knows where the edges are.

## Problem

The visual analysis pass samples at most 30 frames for the whole file
(`Analyzer.maxFrames`), then makes one model call. For a 60-minute file that
is one frame every two minutes: short fights are missed, and the only way to
look closer was to pick breakdown tags by hand, which then ran one model
call per scene, serially. Podcasts and interviews paid for the same dense
passes whenever a user had breakdown tags on.

## Decisions

- **S1. Keep the classic pass.** The 30-frame call still runs first and
  still owns people, the fight outcome, the filename proposal and the
  video type. Smart Sampling adds to it; nothing it returns is dropped.
- **S2. Coarse map by windows.** Files of 5 minutes or more (`minDuration`)
  are split into 5-minute windows (a tail under 60 s joins its predecessor)
  and sampled every 15 s. Each window is one call with the classic JSON
  shape plus an `activity` score (0–10). Windows run three at a time.
- **S3. Dense pass only where action is.** Windows are chosen from three
  signals, unioned: ranges carrying an action tag (the fight-scoring tag
  list, now `SmartSampling.actionTags`), windows the model scored ≥ 7, and
  windows whose ffmpeg cut rate is ≥ 12 per minute. Candidates merge when
  ≤ 2 s apart and split into equal chunks of ≤ 60 s so each stays in the
  100-frame budget (the model image limit) at ≥ 0.5 s spacing. Podcast and interview footage never
  enters the dense pass. The dense pass reuses `breakdownScene` and runs
  three windows at a time; the user's own breakdown tags go through the
  same parallel path.
- **S4. Near-duplicate suppression.** Two passes look at the same footage.
  A map range is dropped when an existing same-tag range already covers
  70 % of it (`SmartSampling.merge`). Dense sub-ranges are appended as
  before; scenes matching a coarse range exactly become its children via
  `parent_scene_id`, everything else lands unparented in the same run.
- **S5. Off switch, on by default.** `analysis.smartSampling` in
  UserDefaults, a toggle in the dispatch plan sheet, recorded per run in
  `AnalysisRunSettings.smartSampling` (optional, so old runs decode).
  Smart Sampling does not apply to trimmed runs, to a user-chosen frame
  interval, to incremental tag-only runs, or when Gemini watches the
  video natively.
- **S6. Cut detection is cached, never recomputed here.** The cut list
  comes from `AppStore.cachedDetectors`, the same per-file cache the trim
  and long-recording classifier use. With no cache the cut-rate signal is
  simply absent.

## What it costs and saves

- A 60-minute podcast: classic pass, 12 map calls in parallel, no dense
  pass. Before, with breakdown tags on, each tagged scene was a serial
  dense call.
- A 60-minute fight card: the same map, then dense calls only for action
  windows, three at a time, instead of one serial call per tagged scene.
- A 4-minute clip: unchanged.

## Tests

`SmartSamplingTests` covers window tiling, timestamps, applicability,
merge suppression, dense-window selection for every signal and the talk
formats, and even chunking. `AnalyzerStaticTests` is unchanged; the map
prompt and parser are exercised through `Analyzer.parseWindowMap` with
synthetic JSON in the same suite.

## Not done

- No visual verification against a real long recording yet; the map
  prompt's `activity` calibration is untested on real footage.
- The long-recording classifier still runs only for files ≥ 300 s with no
  type; short clips get no local triage.
- Progress percentages inside parallel windows arrive out of order.
