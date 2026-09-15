#!/usr/bin/env python3
"""Framing evidence reuse against the previous per-caller Vision passes, in one Release binary.

Each run is the local-only analysis scenario with fresh caches and forty
two-second fixture scenes: portrait fit, then the static camera with framed:
tags, then the moving camera without tags, all inside one run-scoped frame
cache as the analysis pipeline nests them. Pairs alternate order and the
retained per-scene paths and tags must be identical across every run.
"""
import argparse
import json
from pathlib import Path
import re
import shutil
import sqlite3
import statistics
import subprocess
import sys

from benchmark_incremental_finishing import finishing_phases, phase_peaks
from benchmark_detector_scan import phase_cpu

PHASES = ["portrait-fit-local-only", "framing-static-local-only", "framing-tracked-local-only"]
COUNTERS = {"portrait-fit-local-only": "PORTRAIT_FIT", "framing-static-local-only": "FRAMING_STATIC",
            "framing-tracked-local-only": "FRAMING_TRACKED"}


def normalized_framing(run, rows):
    """Compare values keyed by scene start time: scene ids are assigned in a
    different order each process, and stored paths are JSON strings whose key
    order is not stable."""
    with sqlite3.connect(run / "data/baseline.db") as db:
        starts = dict(db.execute("SELECT id, start_time FROM scenes"))
    return sorted((dict(start=round(starts[r["id"]], 3), tags=r["tags"],
                        path=json.loads(r["path"]) if r.get("path") else None) for r in rows),
                  key=lambda r: r["start"])


def vision_requests(log):
    """Cumulative Vision request count logged at the end of each phase."""
    found = {}
    for line in log.splitlines():
        match = re.match(r"(PORTRAIT_FIT|FRAMING_STATIC|FRAMING_TRACKED) .*visionRequests=(\d+)", line)
        if match:
            found[match.group(1)] = int(match.group(2))
    return found


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--pairs", type=int, default=3)
    parser.add_argument("--keep-caches", action="store_true")
    parser.add_argument("--resume", action="store_true",
                        help="Continue an interrupted comparison: keep completed runs, redo incomplete ones")
    args = parser.parse_args()
    if args.pairs < 1:
        parser.error("--pairs must be positive")
    source = Path(args.source).resolve(strict=True)
    root = Path(args.output).resolve()
    root.mkdir(parents=True, exist_ok=args.resume)
    script = Path(__file__).with_name("performance_baseline.py")
    runs = []
    for pair in range(1, args.pairs + 1):
        for mode in (["control", "shared"] if pair % 2 else ["shared", "control"]):
            run = root / f"{mode}-{pair:02d}"
            command = [sys.executable, str(script), "record", "--scenario", "analysis",
                       "--source", str(source), "--output", str(run), "--scope", "none", "--local-only"]
            if mode == "control":
                command += ["--framing-mode", "legacy"]
            completed = args.resume and (run / "phases.json").is_file() \
                and json.loads((run / "phases.json").read_text()).get("outcome") == "completed"
            if completed:
                print(f"{pair}/{args.pairs}: {mode} (kept)", flush=True)
            else:
                if run.exists():
                    assert (run / ".baseline-owned").is_file(), f"Refusing to remove unmarked {run}"
                    shutil.rmtree(run)
                print(f"{pair}/{args.pairs}: {mode}", flush=True)
                with run.with_suffix(".log").open("w") as log:
                    subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
            report = json.loads((run / "phases.json").read_text())
            if report["outcome"] != "completed":
                raise RuntimeError(f"Incomplete run: {run}")
            app_log = (run / "app.log").read_text()
            parsed = finishing_phases(app_log)
            samples = [json.loads(line) for line in (run / "process-samples.jsonl").read_text().splitlines()]
            phase_peaks(parsed, samples)
            phase_cpu(parsed, samples)
            phases = [dict(phase, **parsed[phase["name"]]) for phase in report["phases"]]
            cumulative = vision_requests(app_log)
            previous = 0
            for phase in phases:
                counter = COUNTERS.get(phase["name"])
                if counter:
                    phase["visionRequests"] = cumulative[counter] - previous
                    previous = cumulative[counter]
            manifest = json.loads((run / "manifest.json").read_text())
            static_framing = normalized_framing(run, json.loads((run / "framing-static.json").read_text()))
            tracked_framing = normalized_framing(run, json.loads((run / "framing-tracked.json").read_text()))
            runs.append(dict(pair=pair, mode=mode, phases=phases, staticFraming=static_framing,
                             trackedFraming=tracked_framing, executableSHA256=manifest["executableSHA256"]))
            (root / "runs.json").write_text(json.dumps(runs, indent=2))
            if len({r["executableSHA256"] for r in runs}) != 1:
                raise RuntimeError("Profiling executable changed during comparison")
            for kind in ["staticFraming", "trackedFraming"]:
                if len({json.dumps(r[kind], sort_keys=True) for r in runs}) != 1:
                    raise RuntimeError(f"{kind} results differ between runs: {run}")
            cache = run / "data/.cache"
            if not args.keep_caches and cache.is_dir():
                assert (run / ".baseline-owned").is_file() and cache.resolve().is_relative_to(run)
                shutil.rmtree(cache)
    summary = {}
    for mode in ["control", "shared"]:
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
                                    maximum=max(p["cpuCoreSeconds"] for p in phases)),
                visionRequests=[p["visionRequests"] for p in phases])
    summary["framingIdenticalAcrossRuns"] = True
    (root / "summary.json").write_text(json.dumps(summary, indent=2))
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
