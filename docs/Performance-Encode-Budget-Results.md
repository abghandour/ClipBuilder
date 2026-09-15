# Cold render against the encode budget

September 15, 2026. Follow-up to [finishing ranges](Performance-Incremental-Finishing-Results.md), whose stage experiments showed the shared hardware encoder gaining little beyond two workers.

## Question

Cold renders encode every segment through `FFmpeg.jobLimit` concurrent ffmpeg jobs, which is also the scheduler's encoding budget: `max(2, min(4, cores / 2))`, four on this 12-core Mac. Does raising the budget shorten a cold render, and what does lowering it cost?

## Method

`FFmpeg.jobLimit` now honours `CLIPBUILDER_FFMPEG_JOBS` (1–16) from the environment, the harness passes it through `--ffmpeg-jobs`, and the fixture log line records the value the app used. `scripts/benchmark_encode_jobs.py` runs the render scenario with fresh caches for each budget, alternating the order across repetitions, and reports per-phase medians and sampled peak app-plus-child RSS. Three repetitions of budgets 2, 3, 4 and 6 on the standard 40-clip, 80-second fixture with one Center Stage clip at 1080 × 1920, `--scope none`, executable SHA-256 `5f882c85332cd888b33fba7f8274294b6e6d2aca0f35c1a33d44c20741964b44`. Every cold phase ran 43 successful video encodes. The comparison was interrupted once when the disk filled (the script did not yet remove finished runs' caches); the three missing runs were completed with `--resume` in the same binary, and runs 11 and 12 are therefore not in the original alternating order. Evidence: `build/performance-baseline-runs/2026-09-15/encode-jobs/`.

## Results

| Budget | Cold render, median (range) | Change vs 4 | Cold sampled peak RSS, median (range) |
| ---: | ---: | ---: | ---: |
| 2 | 28.555 s (28.543–29.057) | +6.7% | 918 MiB (917–921) |
| 3 | 27.138 s (26.373–27.315) | +1.4% | 1,274 MiB (1,250–1,276) |
| **4 (current)** | 26.765 s (26.229–26.921) | — | 1,563 MiB (1,559–1,614) |
| 6 | 26.397 s (26.335–26.731) | −1.4% | 2,266 MiB (2,229–2,295) |

The edit phases did not move with the budget (first edit 13.5–13.6 s, second edit 2.9–3.1 s across all budgets), as expected: they encode one segment plus finishing ranges, which use their own two-worker cap.

## Decision

**Keep the budget at four.** Six saves 0.37 s of a 26.8 s cold render for 700 MiB more memory, inside the range overlap. Three costs 0.37 s and saves 290 MiB; two costs 1.8 s and saves 645 MiB. The cold render is not bound by encoder concurrency beyond about three jobs: the hardware encoder is shared, and the remaining cold time is framing preparation, per-segment decode and filtering, assembly and the full overlay pass. Cold work therefore has to shrink by doing less per segment, not by running more segments at once.

The environment override stays as a measurement aid and is not exposed in the app's settings. No renderer behaviour changed.
