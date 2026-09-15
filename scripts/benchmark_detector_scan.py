#!/usr/bin/env python3
"""Cold detector scan: concurrent hardware-decoded passes against the sequential software passes.

Each run is the local-only analysis scenario with fresh caches, so the
`detectors-cold` phase is a real scan; pairs alternate order. Peak RSS is the
sampled app-plus-child figure inside each phase's wall-clock window, and CPU
is the sum of sampled process CPU percentages over the phase, in core-seconds
(500 ms samples; an approximation, not an accounting figure).
"""
import argparse
import json
from pathlib import Path
import shutil
import statistics
import subprocess
import sys

from benchmark_incremental_finishing import finishing_phases, phase_peaks

PHASES = ["detectors-cold", "detectors-warm", "detector-cancellation"]


def phase_cpu(phases, samples):
    for row in phases.values():
        inside = [s for s in samples if row["startEpoch"] <= s["time"] <= row["endEpoch"]]
        row["cpuCoreSeconds"] = sum(p["cpu"] for s in inside for p in s["processes"]) / 100 * 0.5


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--pairs", type=int, default=3)
    parser.add_argument("--keep-caches", action="store_true")
    args = parser.parse_args()
    if args.pairs < 1:
        parser.error("--pairs must be positive")
    source = Path(args.source).resolve(strict=True)
    root = Path(args.output).resolve()
    root.mkdir(parents=True, exist_ok=False)
    script = Path(__file__).with_name("performance_baseline.py")
    runs = []
    for pair in range(1, args.pairs + 1):
        for mode in (["control", "concurrent"] if pair % 2 else ["concurrent", "control"]):
            run = root / f"{mode}-{pair:02d}"
            command = [sys.executable, str(script), "record", "--scenario", "analysis",
                       "--source", str(source), "--output", str(run), "--scope", "none", "--local-only"]
            if mode == "control":
                command += ["--detector-mode", "legacy"]
            print(f"{pair}/{args.pairs}: {mode}", flush=True)
            with run.with_suffix(".log").open("w") as log:
                subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
            report = json.loads((run / "phases.json").read_text())
            if report["outcome"] != "completed":
                raise RuntimeError(f"Incomplete run: {run}")
            parsed = finishing_phases((run / "app.log").read_text())
            samples = [json.loads(line) for line in (run / "process-samples.jsonl").read_text().splitlines()]
            phase_peaks(parsed, samples)
            phase_cpu(parsed, samples)
            phases = [dict(phase, **parsed[phase["name"]]) for phase in report["phases"]]
            manifest = json.loads((run / "manifest.json").read_text())
            detectors = json.loads((run / "detectors.json").read_text()) if (run / "detectors.json").is_file() else None
            runs.append(dict(pair=pair, mode=mode, phases=phases, detectors=detectors,
                             executableSHA256=manifest["executableSHA256"]))
            (root / "runs.json").write_text(json.dumps(runs, indent=2))
            if len({r["executableSHA256"] for r in runs}) != 1:
                raise RuntimeError("Profiling executable changed during comparison")
            cache = run / "data/.cache"
            if not args.keep_caches and cache.is_dir():
                assert (run / ".baseline-owned").is_file() and cache.resolve().is_relative_to(run)
                shutil.rmtree(cache)
    summary = {}
    for mode in ["control", "concurrent"]:
        rows = [r for r in runs if r["mode"] == mode]
        summary[mode] = {}
        for phase in PHASES:
            phases = [next(p for p in r["phases"] if p["name"] == phase) for r in rows]
            peaks = [p["peakRSSMiB"] for p in phases if p["peakRSSMiB"] is not None]
            summary[mode][phase] = dict(
                seconds=dict(median=statistics.median(p["seconds"] for p in phases),
                             minimum=min(p["seconds"] for p in phases), maximum=max(p["seconds"] for p in phases)),
                peakRSSMiB=dict(median=statistics.median(peaks), minimum=min(peaks), maximum=max(peaks)) if peaks else None,
                cpuCoreSeconds=dict(median=statistics.median(p["cpuCoreSeconds"] for p in phases),
                                    minimum=min(p["cpuCoreSeconds"] for p in phases),
                                    maximum=max(p["cpuCoreSeconds"] for p in phases)))
    (root / "summary.json").write_text(json.dumps(summary, indent=2))
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
