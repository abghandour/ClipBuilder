#!/usr/bin/env python3
"""Check full decoded media parity for one retained framing-cache benchmark pair."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True)
    parser.add_argument("--pair", type=int, default=1)
    args = parser.parse_args()
    root = Path(args.root).resolve(strict=True)
    records = {}
    for mode in ["control", "cache"]:
        directory = root / f"{mode}-{args.pair:02d}" / "outputs"
        hashes = {}
        for name in ["render-cold", "render-warm"]:
            with (directory / f"{name}.mp4").open("rb") as stream:
                hashes[name] = hashlib.file_digest(stream, "sha256").hexdigest()
        assert hashes["render-cold"] == hashes["render-warm"], "Warm output differs from cold"
        records[mode] = {}
        # Warm is byte-identical to cold above; decoding it again adds no coverage.
        for name in ["render-cold", "render-caption-edit"]:
            video = directory / f"{name}.mp4"
            frames = subprocess.check_output([
                "ffmpeg", "-v", "error", "-threads", "2", "-i", str(video),
                "-map", "0:v:0", "-map", "0:a:0", "-c:v", "rawvideo", "-c:a", "pcm_f32le",
                "-f", "framemd5", "-"], text=True)
            (directory / f"{name}-decoded.framemd5").write_text(frames)
            streams = {}
            for line in frames.splitlines():
                if not line.strip() or line.startswith("#"):
                    continue
                fields = [field.strip() for field in line.split(",")]
                streams.setdefault(fields[0], []).append(fields[1:])
            probe = json.loads(subprocess.check_output([
                "ffprobe", "-v", "error", "-show_format", "-show_streams", "-of", "json", str(video)], text=True))
            (directory / f"{name}-probe.json").write_text(json.dumps(probe, indent=2))
            records[mode][name] = dict(duration=probe["format"]["duration"], streams={
                key: dict(frames=len(values), timestampedFrameDigest=hashlib.sha256(json.dumps(values).encode()).hexdigest())
                for key, values in streams.items()})
            print(mode, name, records[mode][name], flush=True)
    checks = {phase: records["control"][phase] == records["cache"][phase]
              for phase in ["render-cold", "render-caption-edit"]}
    report = dict(pair=args.pair, records=records, decodedMatch=checks,
                  warmByteIdenticalToCold=True, format="rawvideo and pcm_f32le, timestamps/durations/byte counts/frame hashes")
    (root / f"media-validation-{args.pair:02d}.json").write_text(json.dumps(report, indent=2))
    if not all(checks.values()):
        raise SystemExit("Decoded media differs; inspect retained frame hashes")


if __name__ == "__main__":
    main()
