#!/usr/bin/env python3
"""Compare framing reuse with the corrected-caption control in one Release binary."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import statistics
import subprocess
import sys

from benchmark_framing import framing_phases


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
        for mode in (["control", "cache"] if pair % 2 else ["cache", "control"]):
            run = root / f"{mode}-{pair:02d}"
            command = [sys.executable, str(script), "record", "--scenario", "render",
                       "--source", str(source), "--output", str(run), "--scope", "none",
                       "--local-only", "--framing-clips", "40"]
            if mode == "control":
                command.append("--disable-framing-cache")
            print(f"{pair}/{args.pairs}: {mode}", flush=True)
            with run.with_suffix(".log").open("w") as log:
                subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
            report = json.loads((run / "phases.json").read_text())
            if report["outcome"] != "completed":
                raise RuntimeError(f"Incomplete run: {run}")
            log = (run / "app.log").read_text()
            if "FIXTURE clips=40 framingClips=40" not in log.splitlines():
                raise RuntimeError("Expected forty framed clips; use a wide source and current profiling app")
            parsed = framing_phases(log)
            phases = [dict(phase, **parsed[phase["name"]]) for phase in report["phases"]]
            warm = next(p for p in phases if p["name"] == "render-warm")
            edit = next(p for p in phases if p["name"] == "render-caption-edit")
            assert warm["segmentHits"] == 40 and warm["finishingHits"] == 1
            assert edit["segmentHits"] == 39, "Caption edit unexpectedly invalidated other segments"
            assert warm["framingHits"] == (40 if mode == "cache" else 0)
            assert warm["framingBuilds"] == (0 if mode == "cache" else 40)
            assert not any(p["fallbacks"] for p in phases)
            hashes = {}
            for name in ["render-cold", "render-warm", "render-caption-edit"]:
                with (run / "outputs" / f"{name}.mp4").open("rb") as stream:
                    hashes[name] = hashlib.file_digest(stream, "sha256").hexdigest()
            assert hashes["render-cold"] == hashes["render-warm"]
            assert hashes["render-cold"] != hashes["render-caption-edit"]
            samples = [json.loads(line) for line in (run / "process-samples.jsonl").read_text().splitlines()]
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
                # Only this just-finished, marked scratch run; retain all media,
                # manifests, timings and a cache inventory. No user cache access.
                assert (run / ".baseline-owned").is_file() and cache.resolve().is_relative_to(run)
                shutil.rmtree(cache)
    summary = {}
    for mode in ["control", "cache"]:
        rows = [r for r in runs if r["mode"] == mode]
        summary[mode] = dict(medianPeakRSSMiB=statistics.median(r["peakRSSMiB"] for r in rows), phases={})
        for phase in ["render-cold", "render-warm", "render-caption-edit"]:
            phases = [next(p for p in r["phases"] if p["name"] == phase) for r in rows]
            summary[mode]["phases"][phase] = {
                field: dict(median=statistics.median(p[field] for p in phases),
                            minimum=min(p[field] for p in phases), maximum=max(p[field] for p in phases))
                for field in ["seconds", "framingSeconds"]}
    (root / "summary.json").write_text(json.dumps(summary, indent=2))
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
