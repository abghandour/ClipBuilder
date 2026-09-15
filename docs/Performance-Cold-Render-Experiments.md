# Cold render: decoder and encoder experiments (no change)

September 15, 2026. Follow-up to the [encode budget](Performance-Encode-Budget-Results.md) and [detector scan](Performance-Detector-Scan-Results.md) results, which left the cold Builder render (about 27 s on the 40-clip fixture: roughly 13 s of segment encodes, 10 s of overlay burn, 2 s of assembly) as the largest Builder cost with no cheap lever.

## Experiments

Stand-alone ffmpeg runs on the fight source and the retained production overlay capture, machine idle, alternating order. Scripts and outputs are under `build/performance-baseline-runs/2026-09-15/stage-experiments/cold-render/`.

| Experiment | Control | Variant | Result |
| --- | ---: | ---: | --- |
| One 2 s segment (seek, scale, crop, fps, VideoToolbox encode), software vs hardware decode | 0.583 s | 0.754 s | Hardware decode **slower**: session setup outweighs sixty decoded frames |
| Eight 2 s segments, four at a time, software vs hardware decode | 3.248 s | 3.382 s | Slower |
| Eight 2 s segments, four at a time, VideoToolbox vs libx264 veryfast CRF 20 encode | 3.280 s | 3.850 s | x264 slower in parallel (CPU bound); sequential 4.825 s vs 4.330 s |
| Full overlay pass over the 79 s assembled video, software vs hardware decode | 10.314 s | 10.356 s | No change: the pass is bound by the filter thread and encoder |

Decoded frames were identical between software and hardware decoding in both the segment and overlay graphs (framemd5 with a deterministic x264 encode), so hardware decoding remains safe where it helps, as in the detector scan; it simply does not help here.

Four parallel segment encodes finish only 1.47× faster than sequential (3.28 s vs 4.83 s for eight segments), consistent with the encode budget result: the shared hardware encoder, not process count or decode, bounds the segment phase.

## What is left for the cold path

The cold render decodes and encodes the whole timeline twice: once per segment, and once more in the final overlay pass. The only structural saving left is to burn timeline-spanning overlays into the segments and drop the final pass, which would remove about 10 s of the 27 s. It is exact for hard cuts and for crossfades that keep pixels in place (fade, dissolve, wipes), because blending two segments that carry the same overlay at the same absolute time yields that overlay; it is not exact for transitions that move pixels, and every segment after a crossfade must offset the overlay clock by the accumulated overlap. That is the plan's item 5 territory: a renderer change with its own timing, transition and quality validation, not a measurement.
