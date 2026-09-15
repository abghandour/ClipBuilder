#!/usr/bin/env python3
"""Profile pre-cache framing in the existing and all-Center-Stage render fixtures."""
import argparse
import json
from pathlib import Path
import re
import statistics
import subprocess
import sys


def framing_phases(log):
    phases = {}
    current = None
    for line in log.splitlines():
        if line.startswith("PHASE START "):
            current = line.removeprefix("PHASE START ").split()[0]
            phases[current] = dict(passes=[], segmentHits=0, finishingHits=0, fallbacks=0,
                                   framingHits=0, framingBuilds=0)
        elif current is not None:
            row = phases[current]
            if line.startswith("FRAMING_PASS "):
                fields = dict(field.split("=", 1) for field in line.split()[1:])
                row["passes"].append(dict(area=fields["area"] == "true", jobs=int(fields["jobs"]),
                                          uses=int(fields["uses"]), seconds=float(fields["seconds"])))
            elif line.startswith("FRAMING_PREPARATION seconds="):
                row["framingSeconds"] = float(line.split("=", 1)[1])
            elif re.fullmatch(r"Segment \d+: cache hit; encodes=0", line):
                row["segmentHits"] += 1
            elif line.startswith("Finishing cache hit;"):
                row["finishingHits"] += 1
            elif line.startswith("Framing failed ("):
                row["fallbacks"] += 1
            elif line.startswith("Framing cache hit;"):
                row["framingHits"] += 1
            elif line.startswith("Framing prepass:"):
                row["framingBuilds"] += 1
            elif line.startswith("PHASE END "):
                current = None
    return phases


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--repetitions", type=int, default=3)
    args = parser.parse_args()
    if args.repetitions < 1:
        parser.error("--repetitions must be positive")
    source = Path(args.source).resolve(strict=True)
    root = Path(args.output).resolve()
    root.mkdir(parents=True, exist_ok=False)
    script = Path(__file__).with_name("performance_baseline.py")
    results = []
    for repetition in range(1, args.repetitions + 1):
        counts = [1, 40] if repetition % 2 else [40, 1]
        for count in counts:
            run = root / f"framing-{count:02d}-{repetition:02d}"
            command = [sys.executable, str(script), "record", "--scenario", "render",
                       "--source", str(source), "--output", str(run), "--scope", "none",
                       "--local-only", "--framing-clips", str(count), "--disable-framing-cache"]
            print(f"{repetition}/{args.repetitions}: {count} framed clips", flush=True)
            with run.with_suffix(".log").open("w") as log:
                subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
            report = json.loads((run / "phases.json").read_text())
            if report["outcome"] != "completed":
                raise RuntimeError(f"Incomplete baseline: {run}")
            app_log = (run / "app.log").read_text()
            if f"FIXTURE clips=40 framingClips={count}" not in app_log.splitlines():
                raise RuntimeError("Framing benchmark requires a wide source and the current profiling app")
            parsed = framing_phases(app_log)
            phases = []
            for phase in report["phases"]:
                row = dict(phase, **parsed[phase["name"]])
                if phase["name"] != "render-cancellation":
                    if "framingSeconds" not in row:
                        raise RuntimeError("Missing framing instrumentation; rebuild the profiling app")
                    row["framingPercent"] = 100 * row["framingSeconds"] / row["seconds"]
                phases.append(row)
            samples = [json.loads(line) for line in (run / "process-samples.jsonl").read_text().splitlines()]
            manifest = json.loads((run / "manifest.json").read_text())
            results.append(dict(repetition=repetition, framingClips=count, phases=phases,
                                peakRSSMiB=max(s["totalRSSKiB"] for s in samples) / 1024,
                                executableSHA256=manifest["executableSHA256"]))
            (root / "runs.json").write_text(json.dumps(results, indent=2))
            if len({row["executableSHA256"] for row in results}) != 1:
                raise RuntimeError("Profiling executable changed during measurements")
    summary = {}
    for count in [1, 40]:
        runs = [row for row in results if row["framingClips"] == count]
        summary[count] = {}
        for phase in ["render-cold", "render-warm", "render-caption-edit"]:
            rows = [next(p for p in run["phases"] if p["name"] == phase) for run in runs]
            summary[count][phase] = {
                field: dict(median=statistics.median(row[field] for row in rows),
                            minimum=min(row[field] for row in rows), maximum=max(row[field] for row in rows))
                for field in ["seconds", "framingSeconds", "framingPercent", "segmentHits", "finishingHits", "fallbacks"]
            }
    (root / "summary.json").write_text(json.dumps(summary, indent=2))
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
