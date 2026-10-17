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

## Second run: traits moved into the finish (option 3)

Same fixture, same settings, same machine, later on October 17 with reel trait
recording moved out of the render into the deferred finish (after the caption).
Evidence in `build/performance-baseline-runs/express-02`.

| Phase | Wall clock | ffmpeg calls | encodes |
| --- | --- | --- | --- |
| express-overlapped (captions and traits run while the next reel renders) | 37.1 s | 58 | 46 |
| express-inline (everything awaited between reels) | 64.0 s | 35 | 28 |

| Stage | Range across the six reels |
| --- | --- |
| extract clips | 2.6–3.1 s |
| join clips | 1.7–3.5 s |
| whole render (no traits inside any more) | 4.7–6.6 s |
| social caption | 8.4–29.6 s |
| reel traits (in the finish) | 1.2–1.4 s |

The three overlapped renders were all done 18.7 s into the phase; the remaining
18.4 s was reel 1's caption, which this time took 29.6 s against 8.4–13.7 s for
the others. The overlapped batch is now bound by the slowest caption round trip,
not by rendering. The caption spread between runs (8 to 30 s for the same prompt
shape) dwarfs every remaining render-side option, so a faster caption provider
is the biggest lever left; code can only hide it behind the renders, which it
now does for all but the last.

The inline phase came out slower than in run one (64.0 s against 59.5 s) purely
on caption latency (22.8 s on reel 2); its render stages were 4.7–5.7 s against
5.8–10.9 s, the trait pass having left them.

## Third run: the caption request starts before its own render

Same fixture, settings and machine, later on October 17. The caption prompt needs
only the plan, so `renderSelection` now fires the model request as the render
starts and the finish awaits it; `caption wait` is the part of the round trip the
render did not hide. Evidence in `build/performance-baseline-runs/express-03`.

| Phase | Wall clock | ffmpeg calls | encodes |
| --- | --- | --- | --- |
| express-overlapped | 35.6 s | 39 | 31 |
| express-inline (each caption still overlaps its own render) | 39.2 s | 65 | 50 |

| Stage | Range across the six reels |
| --- | --- |
| whole render | 4.8–8.0 s |
| social caption (round trip) | 9.8–22.2 s |
| caption wait (exposed, inline reels) | 3.9–6.4 s |
| caption wait (exposed, last overlapped reel) | 15.8 s |
| reel traits | 1.3–1.7 s |

The inline shape gained the most: every caption now hides behind its own render,
so the full AI Wizard (which renders one reel at a time) also benefits, 39.2 s
against 64.0 s and 59.5 s in the earlier runs. The overlapped batch again ended
on its slowest caption: reel 3's round trip took 22.2 s, which started 12.0 s into
the phase and finished at 34.3 s. With a 10 s caption the batch would have ended
with the last render at about 20 s.

Across the three runs, caption round trips ranged from 8.4 to 29.6 s on the same
prompt shape. Rendering a reel takes 5 to 8 s. Everything left on the Express
clock is the caption model.

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
  this hardware, more for longer reels. Done after this run: trait recording now
  runs in the deferred finish after the caption (so the traits carry it), before the
  run report and critique. Measured in the second run above.
- The quality gate, record insert and run report are negligible.

## Caveats

- Twelve-second reels of a short fight clip. Longer reels, podcast layouts and real
  captions burned from transcripts shift the render share upward.
- The caption time depends entirely on the provider's latency and load.
- Preview-quality hard cuts; a chosen transition re-encodes the join.
