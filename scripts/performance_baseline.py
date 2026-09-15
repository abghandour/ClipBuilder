#!/usr/bin/env python3
"""Build and record opt-in Release baselines without opening the user's library."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import queue
import shutil
import signal
import subprocess
import sys
import threading
import time
import xml.etree.ElementTree as ET

REPO = Path(__file__).resolve().parents[1]
DEVELOPER = "/Applications/Xcode-beta.app/Contents/Developer"
DERIVED = REPO / "build/performance-baseline"
APP = DERIVED / "Build/Products/Release/Clip Builder.app/Contents/MacOS/Clip Builder"


def environment():
    return dict(os.environ, DEVELOPER_DIR=os.environ.get("DEVELOPER_DIR", DEVELOPER))


def output(command):
    return subprocess.check_output(command, text=True, env=environment()).strip()


def build():
    DERIVED.mkdir(parents=True, exist_ok=True)
    log = DERIVED / "build.log"
    command = [
        "xcodebuild", "-project", str(REPO / "Clip Builder.xcodeproj"),
        "-scheme", "MyApp", "-configuration", "Release",
        "-derivedDataPath", str(DERIVED), "-destination", "generic/platform=macOS",
        "ENABLE_CODE_COVERAGE=NO", "CLANG_ENABLE_CODE_COVERAGE=NO",
        "CODE_SIGN_IDENTITY=-",
        "PRODUCT_BUNDLE_IDENTIFIER=com.mokotti-solutions.clipbuilder.performance-baseline",
        "OTHER_SWIFT_FLAGS=$(inherited) -D PERFORMANCE_BASELINE", "build",
    ]
    beautifier = shutil.which("xcbeautify")
    print(f"Building Release baseline; full log: {log}", flush=True)
    with log.open("w") as stream:
        process = subprocess.Popen(command, cwd=REPO, env=environment(),
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        pretty = subprocess.Popen([beautifier], stdin=subprocess.PIPE, text=True) if beautifier else None
        for line in process.stdout:
            stream.write(line)
            if pretty:
                pretty.stdin.write(line)
            elif any(word in line for word in ("error:", "warning:", "** BUILD")):
                print(line, end="", flush=True)
        status = process.wait()
        if pretty:
            pretty.stdin.close()
            pretty.wait()
    if status:
        raise RuntimeError(f"Build failed ({status}); inspect {log}")
    if "-profile-generate" in log.read_text():
        raise RuntimeError(f"Profiling build still enables code coverage; inspect {log}")


def sample_processes(app_pid, root, stop):
    """Sample simultaneous app + descendant RSS; not an exact peak allocation metric."""
    with (root / "process-samples.jsonl").open("w") as stream:
        while not stop.is_set():
            rows = []
            try:
                table = output(["ps", "-axo", "pid=,ppid=,rss=,pcpu=,comm="])
                for line in table.splitlines():
                    fields = line.split(None, 4)
                    if len(fields) == 5:
                        rows.append(dict(pid=int(fields[0]), ppid=int(fields[1]),
                                         rssKiB=int(fields[2]), cpu=float(fields[3]), name=fields[4]))
                descendants = {app_pid}
                while True:
                    expanded = descendants | {r["pid"] for r in rows if r["ppid"] in descendants}
                    if expanded == descendants:
                        break
                    descendants = expanded
                selected = [r for r in rows if r["pid"] in descendants]
                stream.write(json.dumps(dict(time=time.time(), processes=selected,
                                             totalRSSKiB=sum(r["rssKiB"] for r in selected))) + "\n")
                stream.flush()
            except (OSError, ValueError, subprocess.CalledProcessError):
                pass
            stop.wait(0.5)


def record(args):
    source = Path(args.source).expanduser().resolve(strict=True)
    root = Path(args.output).expanduser().resolve()
    if root.exists():
        raise ValueError("Output directory already exists. Use a fresh path; warm cases run within it.")
    if not APP.is_file():
        raise ValueError("Build first: python3 scripts/performance_baseline.py build")
    root.mkdir(parents=True)
    (root / ".baseline-owned").touch()
    data = root / "data"
    data.mkdir()
    if args.settings:
        settings = json.loads(Path(args.settings).expanduser().read_text())
        # Keep only pipeline configuration. No account, sync or library state.
        selected = {key: settings[key] for key in ("ai", "transitions") if key in settings}
        (data / "app_settings.json").write_text(json.dumps(selected))
    config = dict(scenario=args.scenario, source=str(source), root=str(root),
                  provider=args.provider, model=args.model, localOnly=args.local_only,
                  disableFinishingCache=args.disable_finishing_cache,
                  disableAssemblyCache=args.disable_assembly_cache,
                  captureOverlayInputs=args.capture_overlay_inputs,
                  disableReelDetectorCache=args.disable_reel_detector_cache,
                  framingClipCount=args.framing_clips,
                  disableFramingCache=args.disable_framing_cache,
                  incrementalFinishing=args.incremental_finishing, overlayFusion=args.overlay_fusion)
    (root / "config.json").write_text(json.dumps(config, indent=2))
    with APP.open("rb") as binary:
        digest = hashlib.sha256()
        for chunk in iter(lambda: binary.read(1024 * 1024), b""):
            digest.update(chunk)
    metadata = dict(executableSHA256=digest.hexdigest(), revision=output(["git", "-C", str(REPO), "rev-parse", "HEAD"]),
                    dirtyStatus=output(["git", "-C", str(REPO), "status", "--short"]),
                    os=output(["sw_vers"]), hardware=output(["sysctl", "-n", "machdep.cpu.brand_string"]),
                    memoryBytes=output(["sysctl", "-n", "hw.memsize"]),
                    ffmpeg=output(["ffmpeg", "-version"]).splitlines()[0],
                    sourceProbe=json.loads(output(["ffprobe", "-v", "error", "-show_format", "-show_streams", "-of", "json", str(source)])),
                    startedAt=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                    configuration="Release PERFORMANCE_BASELINE", captureScope=args.scope,
                    ffmpegJobs=args.ffmpeg_jobs, detectorMode=args.detector_mode, framingMode=args.framing_mode,
                    coldDefinition="fresh app artifact caches; OS file cache is not purged",
                    commandCounter="successful FFmpeg.run calls only; excludes ffprobe, AVFoundation and failed/cancelled commands")
    (root / "manifest.json").write_text(json.dumps(metadata, indent=2))
    tracer = app = None
    stop = threading.Event()
    sampler = None
    events = queue.Queue()
    command = ["xcrun", "xctrace", "record", "--template", "Time Profiler", "--instrument", "Points of Interest",
               "--output", str(root / "baseline.trace"), "--time-limit", f"{args.limit}s"]
    print(f"Recording {args.scenario} into {root}", flush=True)
    trace_log = (root / "recorder.log").open("w")
    app_log = (root / "app.log").open("w")
    reader = None

    def launch_app():
        app_env = dict(environment(), CLIPBUILDER_BASELINE_CONFIG=str(root / "config.json"),
                       LLVM_PROFILE_FILE=str(root / "coverage-%p.profraw"))
        if args.ffmpeg_jobs:
            app_env["CLIPBUILDER_FFMPEG_JOBS"] = str(args.ffmpeg_jobs)
        if args.detector_mode:
            app_env["CLIPBUILDER_DETECTOR_MODE"] = args.detector_mode
        if args.framing_mode:
            app_env["CLIPBUILDER_FRAMING_MODE"] = args.framing_mode
        return subprocess.Popen([str(APP), "-ClipBuilderDataFolder", str(data),
                                 "-ApplePersistenceIgnoreState", "YES"], env=app_env,
                                stdout=app_log, stderr=subprocess.STDOUT, start_new_session=True)

    try:
        if args.scope == "none":
            app = launch_app()
        else:
            if args.scope == "app":
                app = launch_app()
                # Hold only our new scratch process until the attached recorder is ready.
                os.kill(app.pid, signal.SIGSTOP)
                command.extend(["--attach", str(app.pid)])
            else:
                command.append("--all-processes")
            tracer = subprocess.Popen(command, env=environment(), stdout=subprocess.PIPE,
                                      stderr=subprocess.STDOUT, text=True)

            def drain():
                for line in tracer.stdout:
                    trace_log.write(line)
                    trace_log.flush()
                    events.put(line)
                events.put(None)

            reader = threading.Thread(target=drain, daemon=True)
            reader.start()
            deadline = time.monotonic() + 60
            while True:
                line = events.get(timeout=max(0.1, deadline - time.monotonic()))
                if line is None:
                    raise RuntimeError("Recorder exited before startup; see recorder.log")
                print(line, end="", flush=True)
                if "Ctrl-C to stop" in line:
                    break
                if time.monotonic() >= deadline:
                    raise RuntimeError("Recorder did not start within 60 seconds")
            if app is None:
                app = launch_app()
            else:
                os.kill(app.pid, signal.SIGCONT)
        (root / "app.pid").write_text(str(app.pid))
        sampler = threading.Thread(target=sample_processes, args=(app.pid, root, stop), daemon=True)
        sampler.start()
        try:
            code = app.wait(timeout=args.limit - 5)
        except subprocess.TimeoutExpired:
            raise RuntimeError("Baseline exceeded its external deadline; partial evidence retained") from None
        if tracer is not None:
            if tracer.poll() is None:
                tracer.send_signal(signal.SIGINT)
            tracer.wait(timeout=300)
        if reader:
            reader.join(timeout=5)
        if code:
            raise RuntimeError(f"App exited {code}; inspect app.log")
    finally:
        stop.set()
        if sampler:
            sampler.join(timeout=5)
        if app is not None and app.poll() is None:
            os.killpg(app.pid, signal.SIGTERM)
            os.killpg(app.pid, signal.SIGCONT)
            try:
                app.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(app.pid, signal.SIGKILL)
                app.wait()
        if tracer is not None and tracer.poll() is None:
            tracer.send_signal(signal.SIGINT)
            try:
                tracer.wait(timeout=300)
            except subprocess.TimeoutExpired:
                tracer.kill()
                tracer.wait()
        if reader:
            reader.join(timeout=5)
        trace_log.close()
        app_log.close()
    if args.scope != "none":
        with (root / "export.log").open("w") as export_log:
            toc = subprocess.check_output(
                ["xcrun", "xctrace", "export", "--input", str(root / "baseline.trace"), "--toc"],
                text=True, env=environment(), stderr=export_log)
        toc_tree = ET.fromstring(toc)
        for parent in toc_tree.iter():
            for child in list(parent):
                if child.tag == "environment":
                    parent.remove(child)
        ET.ElementTree(toc_tree).write(root / "trace-toc.xml", encoding="utf-8", xml_declaration=True)
    phases_path = root / "phases.json"
    if not phases_path.exists():
        raise RuntimeError("No phase report was produced; inspect app.log")
    report = json.loads(phases_path.read_text())
    for phase in report["phases"]:
        print(f'{phase["name"]}: {phase["seconds"]:.3f}s ({phase["outcome"]})')
    if report["outcome"] != "completed":
        raise RuntimeError(f'Baseline failed: {report.get("error")}')
    print(f"Baseline evidence saved: {root}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("build")
    capture = commands.add_parser("record")
    capture.add_argument("--scenario", choices=["analysis", "render", "export", "metadata", "playback", "contention"], required=True)
    capture.add_argument("--source", required=True)
    capture.add_argument("--output", required=True)
    capture.add_argument("--settings", help="Optional settings JSON; only AI and transition settings are copied")
    capture.add_argument("--provider")
    capture.add_argument("--model")
    capture.add_argument("--scope", choices=["all", "app", "none"], default="all",
                         help="all: system trace; app: focused CPU trace; none: phase timings and RSS without Instruments")
    capture.add_argument("--local-only", action="store_true", help="Analysis: omit remote AI; results are explicitly partial")
    capture.add_argument("--disable-finishing-cache", action="store_true", help="Render-only control: bypass finishing reuse in the same binary")
    capture.add_argument("--disable-assembly-cache", action="store_true", help="Render-only control: bypass crossfade group reuse in the same binary")
    capture.add_argument("--capture-overlay-inputs", action="store_true", help="Render-only diagnostic: retain assembly groups and final overlay inputs; capture timings include file copies")
    capture.add_argument("--disable-reel-detector-cache", action="store_true", help="Export-only control: recompute reel detector scans")
    capture.add_argument("--framing-clips", type=int, default=1, help="Number of Center Stage clips in the 40-clip render fixture (0–40; default 1)")
    capture.add_argument("--disable-framing-cache", action="store_true", help="Render/export control: recompute framing intermediates")
    capture.add_argument("--ffmpeg-jobs", type=int, choices=range(1, 17), metavar="N",
                         help="Override the concurrent ffmpeg job limit and encoding budget (default: the app's own, 4 on this Mac)")
    capture.add_argument("--detector-mode", choices=["legacy"],
                         help="Analysis control: sequential software detector passes instead of concurrent hardware-decoded ones")
    capture.add_argument("--framing-mode", choices=["legacy"],
                         help="Analysis control: run Vision for every framing caller and sample every scene")
    capture.add_argument("--overlay-fusion", choices=["off"],
                         help="Render control: keep the final overlay pass instead of fusing spanning overlays into segments")
    capture.add_argument("--incremental-finishing", choices=["off", "editsOnly", "always"],
                         help="Render-only: when the final overlay pass may run as cached ranges (app default: editsOnly)")
    capture.add_argument("--limit", type=int, default=1800)
    args = parser.parse_args()
    if args.command == "build":
        build()
    else:
        if args.disable_framing_cache and args.scenario not in ("render", "export"):
            parser.error("--disable-framing-cache applies only to render and export scenarios")
        if not 0 <= args.framing_clips <= 40:
            parser.error("--framing-clips must be between 0 and 40")
        if args.framing_clips != 1 and args.scenario not in ("render", "export"):
            parser.error("--framing-clips applies only to render and export scenarios")
        if args.disable_reel_detector_cache and args.scenario not in ("export", "metadata"):
            parser.error("--disable-reel-detector-cache applies only to export and metadata scenarios")
        if args.disable_finishing_cache and args.scenario != "render":
            parser.error("--disable-finishing-cache applies only to the render scenario")
        if args.incremental_finishing and args.scenario != "render":
            parser.error("--incremental-finishing applies only to the render scenario")
        if args.disable_assembly_cache and args.scenario != "render":
            parser.error("--disable-assembly-cache applies only to the render scenario")
        if args.capture_overlay_inputs and args.scenario != "render":
            parser.error("--capture-overlay-inputs applies only to the render scenario")
        if args.limit < 30:
            parser.error("--limit must be at least 30 seconds")
        record(args)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError, queue.Empty) as error:
        sys.exit(str(error))
