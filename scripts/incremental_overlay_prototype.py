#!/usr/bin/env python3
"""Opt-in overlay range-cache experiment on captured production renderer inputs.

This does not change app exports. Capture with performance_baseline.py's
--capture-overlay-inputs first. Results require media validation before adoption.
"""

import argparse
import concurrent.futures
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import threading
import time

VERSION = 'overlay-range-prototype-v7'
CACHE_BYTES = 2 * 1024 * 1024 * 1024


def digest(path):
    result = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(block)
    return result.hexdigest()


def probe(path):
    return json.loads(subprocess.check_output([
        'ffprobe', '-v', 'error', '-show_format', '-show_streams', '-of', 'json', str(path)], text=True))


class Runner:
    """Bounded caller concurrency, cancellation and process-group cleanup."""
    def __init__(self):
        self.lock = threading.Lock()
        self.processes = set()
        self.cancelled = False

    def cancel(self):
        with self.lock:
            self.cancelled = True
            for process in self.processes:
                if process.poll() is None:
                    try:
                        os.killpg(process.pid, signal.SIGTERM)
                    except ProcessLookupError:
                        pass

    def check(self):
        if self.cancelled:
            raise InterruptedError('Prototype cancelled')

    def run(self, arguments):
        with tempfile.TemporaryFile() as log:
            with self.lock:
                if self.cancelled:
                    raise InterruptedError('Prototype cancelled')
                process = subprocess.Popen(['ffmpeg', '-v', 'error', *arguments],
                                           stdout=log, stderr=log, start_new_session=True)
                self.processes.add(process)
            try:
                deadline = time.monotonic()+900
                cancelled_at = None
                while True:
                    try:
                        status = process.wait(timeout=0.1)
                        break
                    except subprocess.TimeoutExpired:
                        if self.cancelled and cancelled_at is None:
                            cancelled_at = time.monotonic()
                        if time.monotonic() > deadline or (cancelled_at is not None and time.monotonic()-cancelled_at > 3):
                            os.killpg(process.pid, signal.SIGKILL)
                            process.wait()
                            raise TimeoutError('FFmpeg did not finish or acknowledge cancellation')
                if self.cancelled:
                    raise InterruptedError('Prototype cancelled')
                if status:
                    log.seek(0, 2)
                    log.seek(max(0, log.tell()-8192))
                    raise RuntimeError(log.read().decode(errors='replace'))
            finally:
                with self.lock:
                    self.processes.discard(process)


def plan_ranges(durations, target=4.0):
    """Only cut between assembly groups; crossfade groups remain intact."""
    if not durations or any(not math.isfinite(d) or d <= 0 for d in durations):
        raise ValueError('Every assembly group must have a positive finite duration')
    result = []
    start = 0.0
    first = 0
    end = 0.0
    for index, duration in enumerate(durations):
        end += duration
        if end-start >= target-1e-6 or index == len(durations)-1:
            result.append(dict(start=start, end=end, first=first, last=index))
            start, first = end, index+1
    return result


def source_inputs(command):
    return [command[index+1] for index, value in enumerate(command) if value == '-i']


def normalized_command(command):
    result = list(command)
    for index, value in enumerate(command):
        if value == '-i':
            result[index+1] = '<assembled>' if index == command.index('-i') else digest(command[index+1])
    result[-1] = '<output>'
    return result


def range_key(part, group_hashes, command, tool_version):
    # Adjacent groups cover possible frame resampling around a hard cut.
    dependencies = group_hashes[max(0, part['first']-1):part['last']+2]
    payload = dict(version=VERSION, part=part, groups=dependencies,
                   command=normalized_command(command), ffmpeg=tool_version)
    return hashlib.sha256(json.dumps(payload, sort_keys=True).encode()).hexdigest()


def chunk_command(command, part, output):
    result = []
    index = 0
    label = command[command.index('-map')+1]
    graph_index = command.index('-filter_complex')+1
    while index < len(command)-1:
        value = command[index]
        if value == '-map' and command[index+1] == '0:a?':
            index += 2
        elif value in ['-c:a', '-movflags']:
            index += 2
        elif value == '-t' and index > graph_index:
            index += 2
        else:
            if index == graph_index:
                value += (f";{label}trim=start={max(0, part['clockStart']-1/60):.9f}:"
                          f"end={part['trimEnd']:.9f},setpts=PTS-{part['clockStart']:.9f}/TB[rangeout]")
            elif index > graph_index and value == label:
                value = '[rangeout]'
            result.append(value)
            index += 1
    # Select on the original animation clock before resetting the chunk PTS.
    # Keep VFR gaps: forcing CFR changes the existing renderer's timing.
    return result + ['-an', '-fps_mode', 'vfr', '-t',
                     f"{part['clockEnd']-part['clockStart']:.9f}", str(output)]


def clock_ranges(parts, video, limit):
    if video.get('r_frame_rate') != '30/1':
        raise ValueError("Prototype requires the renderer's normalized 30 fps video")
    start = float(video['start_time'])
    boundaries = [round(start*30)/30]+[round((start+p['start'])*30)/30 for p in parts[1:]]
    for index, part in enumerate(parts):
        end = boundaries[index+1] if index+1 < len(parts) else limit
        part.update(clockStart=boundaries[index], clockEnd=end,
                    trimEnd=end-1/60 if index+1 < len(parts) else math.ceil(end*30-1e-9)/30-1/60)


def concat_listing(paths):
    return ''.join("file '" + str(path).replace("'", "'\\''") + "'\n" for path in paths)


def evict(cache):
    files = sorted(cache.glob('*.mp4'), key=lambda p: p.stat().st_mtime)
    total = sum(p.stat().st_size for p in files)
    for path in files:
        if total <= CACHE_BYTES:
            break
        total -= path.stat().st_size
        path.unlink()


def render(capture, cache, output, runner, jobs=4, mode='incremental'):
    start = time.monotonic()
    command = json.loads((capture/'command.json').read_text())
    if output.exists():
        raise ValueError(f'Output exists: {output}')
    if mode == 'full':
        with tempfile.TemporaryDirectory(prefix='overlay-full-', dir=output.parent) as temporary:
            pending = Path(temporary)/'complete.mp4'
            runner.run(command[:-1]+[str(pending)])
            runner.check()
            os.replace(pending, output)
        return dict(seconds=time.monotonic()-start, hits=0, misses=1, mode=mode)
    if not (capture/'groups.json').is_file():
        result = render(capture, cache, output, runner, jobs, mode='full')
        return dict(result, mode='full-fallback', reason='No captured hard-cut assembly groups')
    groups = [Path(p) for p in json.loads((capture/'groups.json').read_text())]
    durations = []
    for path in groups:
        runner.check()
        durations.append(float(probe(path)['format']['duration']))
    parts = plan_ranges(durations)
    assembled = source_inputs(command)[0]
    video = next(s for s in probe(assembled)['streams'] if s['codec_type'] == 'video')
    if video.get('r_frame_rate') != '30/1' or len(parts) < 2:
        result = render(capture, cache, output, runner, jobs, mode='full')
        return dict(result, mode='full-fallback', reason='Requires multiple ranges and normalized 30 fps')
    limit = float(command[len(command)-1-command[::-1].index('-t')+1])
    clock_ranges(parts, video, limit)
    group_hashes = [digest(p) for p in groups]
    tool_version = subprocess.check_output(['ffmpeg', '-version'], text=True).splitlines()[0]
    keys = [range_key(part, group_hashes, command, tool_version) for part in parts]
    cache.mkdir(parents=True, exist_ok=True)
    entries = [cache/(key+'.mp4') for key in keys]
    hits = [entry.is_file() for entry in entries]
    with tempfile.TemporaryDirectory(prefix='overlay-ranges-', dir=output.parent) as temporary:
        scratch = Path(temporary)
        paths = [scratch/f'part-{i}.mp4' for i in range(len(parts))]
        def process(index):
            runner.check()
            if hits[index]:
                shutil.copyfile(entries[index], paths[index])
                entries[index].touch()
            else:
                runner.run(chunk_command(command, parts[index], paths[index]))
        try:
            with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
                futures = [pool.submit(process, i) for i in range(len(parts))]
                for future in concurrent.futures.as_completed(futures):
                    try:
                        future.result()
                    except BaseException:
                        runner.cancel()
                        raise
            listing = scratch/'concat.txt'
            listing.write_text(concat_listing(paths))
            assembled = source_inputs(command)[0]
            pending_output = scratch/'complete.mp4'
            runner.run(['-y', '-itsoffset', f"{parts[0]['clockStart']:.9f}", '-f', 'concat', '-safe', '0', '-i', str(listing),
                        '-i', assembled, '-map', '0:v:0', '-map', '1:a?', '-c', 'copy',
                        '-movflags', '+faststart', str(pending_output)])
            if runner.cancelled:
                raise InterruptedError('Prototype cancelled')
            # Publish only after every chunk and final mux succeeded. A
            # cancelled batch removes newly published entries, not old hits.
            published = []
            try:
                for index, entry in enumerate(entries):
                    if runner.cancelled:
                        raise InterruptedError('Prototype cancelled')
                    if not hits[index] and not entry.exists():
                        staged = scratch/f'publish-{index}.mp4'
                        shutil.copyfile(paths[index], staged)
                        os.replace(staged, entry)
                        published.append(entry)
                if runner.cancelled:
                    raise InterruptedError('Prototype cancelled')
                os.replace(pending_output, output)
            except BaseException:
                for entry in published:
                    entry.unlink(missing_ok=True)
                raise
        except BaseException:
            runner.cancel()
            raise
    evict(cache)
    return dict(seconds=time.monotonic()-start, hits=sum(hits), misses=len(parts)-sum(hits),
                ranges=parts, mode=mode, limitation='Timestamp trimming evaluates the prefix before an edited range')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--capture', required=True, type=Path)
    parser.add_argument('--cache', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--mode', choices=['full','incremental'], default='incremental')
    parser.add_argument('--jobs', type=int, choices=range(1,5), default=4)
    args = parser.parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    runner = Runner()
    signal.signal(signal.SIGTERM, lambda *_: runner.cancel())
    signal.signal(signal.SIGINT, lambda *_: runner.cancel())
    result = render(args.capture.resolve(), args.cache.resolve(), args.output.resolve(), runner, args.jobs, args.mode)
    args.output.with_suffix('.json').write_text(json.dumps(result, indent=2))
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
