#!/usr/bin/env python3
"""Cold render time and memory against the concurrent ffmpeg job limit, in one Release binary.

Each run has fresh caches; variants alternate order across repetitions so
thermal drift does not favour one budget. Only the cold phase encodes every
segment, but the whole render scenario runs so the comparison matches the
other paired benchmarks.
"""
import argparse
import json
from pathlib import Path
import shutil
import statistics
import subprocess
import sys

from benchmark_incremental_finishing import finishing_phases, phase_peaks

PHASES = ["render-cold", "render-warm", "render-caption-edit", "render-second-edit"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--jobs", type=int, nargs="+", default=[2, 3, 4, 6])
    parser.add_argument("--repetitions", type=int, default=3)
    parser.add_argument("--framing-clips", type=int, default=1)
    parser.add_argument("--keep-caches", action="store_true",
                        help="Retain each completed run's scratch caches as well as logs and outputs")
    parser.add_argument("--resume", action="store_true",
                        help="Continue an interrupted comparison: keep completed runs, redo incomplete ones")
    args = parser.parse_args()
    if args.repetitions < 1 or any(j < 1 or j > 16 for j in args.jobs):
        parser.error("--repetitions must be positive and --jobs within 1–16")
    source = Path(args.source).resolve(strict=True)
    root = Path(args.output).resolve()
    root.mkdir(parents=True, exist_ok=args.resume)
    script = Path(__file__).with_name("performance_baseline.py")
    runs = []
    for repetition in range(1, args.repetitions + 1):
        order = args.jobs if repetition % 2 else list(reversed(args.jobs))
        for jobs in order:
            run = root / f"jobs-{jobs:02d}-{repetition:02d}"
            command = [sys.executable, str(script), "record", "--scenario", "render",
                       "--source", str(source), "--output", str(run), "--scope", "none", "--local-only",
                       "--framing-clips", str(args.framing_clips), "--ffmpeg-jobs", str(jobs)]
            completed = args.resume and (run / "phases.json").is_file() \
                and json.loads((run / "phases.json").read_text()).get("outcome") == "completed"
            if completed:
                print(f"{repetition}/{args.repetitions}: jobs={jobs} (kept)", flush=True)
            else:
                if run.exists():
                    # Only this task's own marked scratch run is discarded.
                    assert (run / ".baseline-owned").is_file(), f"Refusing to remove unmarked {run}"
                    shutil.rmtree(run)
                print(f"{repetition}/{args.repetitions}: jobs={jobs}", flush=True)
                with run.with_suffix(".log").open("w") as log:
                    subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
            report = json.loads((run / "phases.json").read_text())
            if report["outcome"] != "completed":
                raise RuntimeError(f"Incomplete run: {run}")
            app_log = (run / "app.log").read_text()
            if f"ffmpegJobs={jobs}" not in app_log:
                raise RuntimeError(f"The app did not honour the job limit {jobs}")
            parsed = finishing_phases(app_log)
            samples = [json.loads(line) for line in (run / "process-samples.jsonl").read_text().splitlines()]
            phase_peaks(parsed, samples)
            phases = [dict(phase, **parsed[phase["name"]]) for phase in report["phases"]]
            assert not any(p["fallbacks"] for p in phases)
            manifest = json.loads((run / "manifest.json").read_text())
            runs.append(dict(repetition=repetition, jobs=jobs, phases=phases,
                             executableSHA256=manifest["executableSHA256"]))
            (root / "runs.json").write_text(json.dumps(runs, indent=2))
            if len({r["executableSHA256"] for r in runs}) != 1:
                raise RuntimeError("Profiling executable changed during comparison")
            cache = run / "data/.cache"
            if not args.keep_caches and cache.is_dir():
                assert (run / ".baseline-owned").is_file() and cache.resolve().is_relative_to(run)
                shutil.rmtree(cache)
    summary = {}
    for jobs in args.jobs:
        rows = [r for r in runs if r["jobs"] == jobs]
        summary[str(jobs)] = {}
        for phase in PHASES:
            phases = [next(p for p in r["phases"] if p["name"] == phase) for r in rows]
            peaks = [p["peakRSSMiB"] for p in phases if p["peakRSSMiB"] is not None]
            summary[str(jobs)][phase] = dict(
                seconds=dict(median=statistics.median(p["seconds"] for p in phases),
                             minimum=min(p["seconds"] for p in phases), maximum=max(p["seconds"] for p in phases)),
                peakRSSMiB=dict(median=statistics.median(peaks), minimum=min(peaks), maximum=max(peaks)) if peaks else None,
                videoEncodes=[p["successfulVideoEncodes"] for p in phases])
    (root / "summary.json").write_text(json.dumps(summary, indent=2))
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
