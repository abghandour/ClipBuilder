# Segment cache: no directory scan per hit

September 15, 2026. Follow-up to the [framing evidence change](Performance-Framing-Evidence-Results.md) and the [improvement plan](Performance-Improvement-Plan.md) item on bounding cache maintenance.

## Problem

`RenderSegmentCache.restore` copied the hit, touched its modification date for LRU order, and then ran the same eviction pass as a publish: list the whole cache directory, read each file's size and modification date, sort, and sum. A warm render of the 40-clip fixture performs about 60 restores (segments, framing intermediates, crossfade groups, finishing ranges or the whole finishing artifact), so every warm render scanned the directory about 60 times. A hit adds no bytes, so the scan could never have anything to evict that the last publish had not already handled.

## Change

`restore` no longer evicts. The touch is kept, so eviction order is unchanged; eviction runs in `store`, the only path that grows the cache, exactly as before. The existing `RenderSegmentCacheTests/eviction` test, which restores an entry and then checks that the next publish evicts the untouched one, still passes.

## Measurement

The scan is pure filesystem work, so it was timed in isolation with the eviction code copied verbatim into a standalone program (`build/performance-baseline-runs/2026-09-15/stage-experiments/segment-cache/scan.swift`): a cache directory of N one-kilobyte files, 60 restores (copy plus touch) and 60 scans, machine idle.

| Cache files | 60 copies with touch | 60 scans | Per scan |
| ---: | ---: | ---: | ---: |
| 100 | 0.010 s | 0.026 s | 0.43 ms |
| 500 | 0.011 s | 0.120 s | 2.01 ms |
| 1,400 | 0.009 s | 0.314 s | 5.24 ms |

Today's benchmark caches hold a few hundred files (290–340 MiB), where the scans cost about 0.1 s per warm render. The 2 GiB quota holds roughly 1,400 files of typical segment size, where they would cost about 0.3 s: more than the entire 0.16 s unchanged-rerender path measured with a fresh cache. The saving is therefore small today and grows with cache occupancy; it was not measured at the application level because filling a 2 GiB cache would take many renders and the fresh-cache benchmarks cannot show it.

## Limitations

- A cache that exceeds its limit because the limit changed, or because files were added outside the app, is trimmed only at the next publish, not the next hit. Publishes happen at the end of every successful render, so this is at most one render's delay.
- Publish still scans the directory once; a persistent size index would remove that too, but at once per render it is not worth the bookkeeping.
