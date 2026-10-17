# Express generate path: stage timings and caption overlap

October 17, 2026. First measurement of the AI Wizard Express generate path, taken with
the new `express` baseline scenario (see [Performance-Baselines.md](Performance-Baselines.md)).
One run, `--scope none`, Apple M4 Pro, macOS 27.2 beta, working tree at db79d8c plus the
uncommitted timing and overlap changes. The caption model was the configured provider
from the user's AI settings. One run supports the shape of the result, not a precise
percentage; collect five before quoting one.

## Fixture

Three saved takes of six two-second clips each from the 140.5-second Du Plessis vs
Strickland source (2868x1320, auto-crop with bars removed), Express default settings:
captions on, watermark on (no logo in the baseline profile, so nothing is burned),
no music, no critique, no fixed overlay, so no second compositor pass. Four ffmpeg jobs.

## Result

| Phase | Wall clock | ffmpeg calls | encodes |
| --- | --- | --- | --- |
| express-overlapped (captions run while the next reel renders) | 44.2 s | 49 | 39 |
| express-inline (captions awaited between reels, the pre-1.106 shape) | 59.5 s | 30 | 25 |

The overlapped phase ran first and cold: its first reel's trait recording took 5.3 s
against 1.2 s for every later reel, and its extra ffmpeg calls are the cold detector
and probe work. Even carrying that cold cost, overlapping saved 15.3 s, about a quarter
of the batch.

Per reel, the stages were:

| Stage | Range across the six reels |
| --- | --- |
| extract clips | 2.5–3.2 s |
| join clips (hard cuts, stream copy) | 1.6–3.5 s |
| quality gate | 0.03 s |
| save record | < 0.01 s |
| reel traits | 1.2 s (5.3 s cold) |
| whole render | 5.8–10.9 s |
| social caption (model round trip) | 10.2–17.4 s |
| run report | < 0.01 s |

## What it says about the ranked options

- The social caption is the single longest stage, roughly twice the render of a
  twelve-second reel. Overlapping it (option 2) was the right first move. The remaining
  exposed wait is the last reel's caption, inherent to doing it last.
- Clip extraction and the hard-cut join are now the biggest render stages. For this
  fixture there is no second compositor pass, so option 1 (one render pipeline) would
  not have helped here; it matters only when a fixed overlay, template watermark or
  bumper forces the compositor. Measure a run with the Express overlay on before
  deciding on it.
- Reel traits cost 1.2 s per reel warm and 5.3 s cold, so option 3 (traits off the
  completion path) is worth about one to two seconds per reel of serial latency on
  this hardware, more for longer reels.
- The quality gate, record insert and run report are negligible.

## Caveats

- Twelve-second reels of a short fight clip. Longer reels, podcast layouts and real
  captions burned from transcripts shift the render share upward.
- The caption time depends entirely on the provider's latency and load.
- Preview-quality hard cuts; a chosen transition re-encodes the join.
