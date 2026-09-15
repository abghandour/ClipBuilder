#!/usr/bin/env python3
"""Compare overlay fusion (spanning overlays burned into segments) with the final overlay pass in one Release binary.

Each run starts with fresh caches and renders cold, unchanged, after a
caption edit (the first edit creates the ranges) and after a second edit of
the same caption (the steady state: one range rebuilt). Pairs alternate order.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import statistics
import subprocess
import sys

PHASES = ["render-cold", "render-warm", "render-caption-edit", "render-second-edit"]


def finishing_phases(log):
    phases = {}
    current = None
    for line in log.splitlines():
        if line.startswith("PHASE START "):
            fields = line.removeprefix("PHASE START ").split()
            current = fields[0]
            phases[current] = dict(segmentHits=0, finishingHits=0, fullPasses=0, rangeHits=0,
                                   rangeEncodes=0, rangeFailures=0, fused=0, fallbacks=0,
                                   startEpoch=float(fields[1].removeprefix("epoch=")))
        elif current is not None:
            row = phases[current]
            if line.startswith("PHASE END "):
                row["endEpoch"] = float(line.rsplit("epoch=", 1)[1])
                current = None
            elif re.fullmatch(r"Segment \d+: cache hit; encodes=0", line):
                row["segmentHits"] += 1
            elif line.startswith("Finishing cache hit;"):
                row["finishingHits"] += 1
            elif line.startswith("Burning "):
                row["fullPasses"] += 1
            elif match := re.fullmatch(r"Finishing ranges: hits=(\d+) encodes=(\d+)", line):
                row["rangeHits"] += int(match.group(1))
                row["rangeEncodes"] += int(match.group(2))
            elif line.startswith("Finishing ranges failed"):
                row["rangeFailures"] += 1
            elif line.startswith("Spanning overlays fused into segments: "):
                row["fused"] += int(line.rsplit(" ", 1)[1])
            elif line.startswith("Framing failed (") or "continuing without" in line:
                row["fallbacks"] += 1
    return phases


def phase_peaks(phases, samples):
    """Peak sampled app-plus-child RSS inside each phase's wall-clock window."""
    for row in phases.values():
        inside = [s["totalRSSKiB"] for s in samples if row["startEpoch"] <= s["time"] <= row["endEpoch"]]
        row["peakRSSMiB"] = max(inside) / 1024 if inside else None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--pairs", type=int, default=5)
    parser.add_argument("--keep-caches", action="store_true",
                        help="Retain each completed run's scratch caches as well as logs and outputs")
    args = parser.parse_args()
    if args.pairs < 1:
        parser.error("--pairs must be positive")
    source = Path(args.source).resolve(strict=True)
    root = Path(args.output).resolve()
    root.mkdir(parents=True, exist_ok=False)
    script = Path(__file__).with_name("performance_baseline.py")
    runs = []
    for pair in range(1, args.pairs + 1):
        for mode in (["control", "fused"] if pair % 2 else ["fused", "control"]):
            run = root / f"{mode}-{pair:02d}"
            command = [sys.executable, str(script), "record", "--scenario", "render",
                       "--source", str(source), "--output", str(run), "--scope", "none", "--local-only",
                       ] + (["--overlay-fusion", "off"] if mode == "control" else [])
            print(f"{pair}/{args.pairs}: {mode}", flush=True)
            with run.with_suffix(".log").open("w") as log:
                subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
            report = json.loads((run / "phases.json").read_text())
            if report["outcome"] != "completed":
                raise RuntimeError(f"Incomplete run: {run}")
            parsed = finishing_phases((run / "app.log").read_text())
            samples = [json.loads(line) for line in (run / "process-samples.jsonl").read_text().splitlines()]
            phase_peaks(parsed, samples)
            phases = [dict(phase, **parsed[phase["name"]]) for phase in report["phases"]]
            byName = {p["name"]: p for p in phases}
            assert byName["render-warm"]["finishingHits"] == 1
            assert byName["render-caption-edit"]["segmentHits"] == 39, "Caption edit invalidated other segments"
            assert byName["render-second-edit"]["segmentHits"] == 39
            assert not any(p["fallbacks"] or p["rangeFailures"] for p in phases)
            if mode == "control":
                assert byName["render-cold"]["fullPasses"] == 1 and byName["render-caption-edit"]["fullPasses"] + byName["render-caption-edit"]["rangeEncodes"] >= 1
            else:
                assert all(p["fullPasses"] == 0 for p in phases), "Fusion did not remove the final pass"
                assert all(p["rangeEncodes"] == 0 and p["rangeHits"] == 0 for p in phases)
                assert byName["render-cold"]["fused"] >= 1
            hashes = {}
            for name in PHASES:
                with (run / "outputs" / f"{name}.mp4").open("rb") as stream:
                    hashes[name] = hashlib.file_digest(stream, "sha256").hexdigest()
            assert hashes["render-cold"] == hashes["render-warm"]
            assert hashes["render-cold"] != hashes["render-caption-edit"] != hashes["render-second-edit"]
            manifest = json.loads((run / "manifest.json").read_text())
            cache = run / "data/.cache"
            inventory = {str(p.relative_to(cache)): p.stat().st_size for p in cache.rglob("*") if p.is_file()}
            (run / "cache-inventory.json").write_text(json.dumps(inventory, indent=2))
            runs.append(dict(pair=pair, mode=mode, phases=phases, outputSHA256=hashes,
                             peakRSSMiB=max(s["totalRSSKiB"] for s in samples) / 1024,
                             cacheBytes=sum(inventory.values()),
                             executableSHA256=manifest["executableSHA256"]))
            (root / "runs.json").write_text(json.dumps(runs, indent=2))
            if len({r["executableSHA256"] for r in runs}) != 1:
                raise RuntimeError("Profiling executable changed during comparison")
            if not args.keep_caches:
                assert (run / ".baseline-owned").is_file() and cache.resolve().is_relative_to(run)
                shutil.rmtree(cache)
    summary = {}
    for mode in ["control", "fused"]:
        rows = [r for r in runs if r["mode"] == mode]
        summary[mode] = dict(medianPeakRSSMiB=statistics.median(r["peakRSSMiB"] for r in rows),
                             medianCacheBytes=statistics.median(r["cacheBytes"] for r in rows), phases={})
        for phase in PHASES:
            phases = [next(p for p in r["phases"] if p["name"] == phase) for r in rows]
            peaks = [p["peakRSSMiB"] for p in phases if p["peakRSSMiB"] is not None]
            summary[mode]["phases"][phase] = dict(
                seconds=dict(median=statistics.median(p["seconds"] for p in phases),
                             minimum=min(p["seconds"] for p in phases), maximum=max(p["seconds"] for p in phases)),
                peakRSSMiB=dict(median=statistics.median(peaks), minimum=min(peaks), maximum=max(peaks)) if peaks else None,
                rangeHits=[p["rangeHits"] for p in phases], rangeEncodes=[p["rangeEncodes"] for p in phases],
                fullPasses=[p["fullPasses"] for p in phases], fused=[p["fused"] for p in phases])
    (root / "summary.json").write_text(json.dumps(summary, indent=2))
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
