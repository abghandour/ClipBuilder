#!/usr/bin/env python3
"""Alternating stage-only controls for the opt-in overlay prototype."""
import argparse
import hashlib
import json
from pathlib import Path
import statistics
import subprocess
import sys
import threading
import time

from performance_baseline import sample_processes


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--capture', required=True, type=Path,
                        help='Root produced by --capture-overlay-inputs')
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--pairs', type=int, default=5)
    args = parser.parse_args()
    if args.output.exists() or args.pairs < 1:
        parser.error('Use a fresh output directory and a positive pair count')
    root = args.output.resolve()
    root.mkdir(parents=True)
    (root/'.overlay-prototype-owned').touch()
    script = Path(__file__).with_name('incremental_overlay_prototype.py').resolve()
    manifest = dict(scope='finishing stage only; no assembly, captions, framing or whole-finishing cache lookup',
        prototypeSHA256=hashlib.sha256(script.read_bytes()).hexdigest(), pairs=args.pairs,
        captureManifest=json.loads((args.capture/'manifest.json').read_text()),
        ffmpeg=subprocess.check_output(['ffmpeg','-version'],text=True).splitlines()[0])
    (root/'manifest.json').write_text(json.dumps(manifest,indent=2))
    runs=[]
    for pair in range(1,args.pairs+1):
        modes=['incremental','full'] if pair % 2 else ['full','incremental']
        for mode in modes:
            directory=root/f'{mode}-{pair:02}'
            directory.mkdir()
            for phase in ['render-cold','render-caption-edit']:
                capture=args.capture.resolve()/'overlay-inputs'/phase
                output=directory/(phase+'.mp4')
                command=[sys.executable,str(script),'--capture',str(capture),
                    '--cache',str(directory/'cache'),'--output',str(output),'--mode',mode]
                samples=directory/phase
                samples.mkdir()
                stop=threading.Event()
                with (samples/'process.log').open('w') as log:
                    start=time.monotonic()
                    process=subprocess.Popen(command,stdout=log,stderr=subprocess.STDOUT)
                    sampler=threading.Thread(target=sample_processes,args=(process.pid,samples,stop),daemon=True)
                    sampler.start()
                    try:
                        status=process.wait(timeout=900)
                    except subprocess.TimeoutExpired:
                        process.terminate()
                        try:
                            process.wait(timeout=10)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            process.wait()
                        raise
                    finally:
                        stop.set()
                        sampler.join(timeout=5)
                    if status:
                        raise RuntimeError(f'Prototype run failed: {samples}')
                    wall=time.monotonic()-start
                result=json.loads(output.with_suffix('.json').read_text())
                memory=[json.loads(line)['totalRSSKiB']/1024 for line in (samples/'process-samples.jsonl').read_text().splitlines()]
                runs.append(dict(pair=pair,mode=mode,phase=phase,wallSeconds=wall,
                    seconds=result['seconds'],hits=result['hits'],misses=result['misses'],peakRSSMiB=max(memory)))
                (root/'runs.json').write_text(json.dumps(runs,indent=2))
                print(runs[-1],flush=True)
    summary={}
    for mode in ['incremental','full']:
        summary[mode]={}
        for phase in ['render-cold','render-caption-edit']:
            selected=[r for r in runs if r['mode']==mode and r['phase']==phase]
            summary[mode][phase]={}
            for key in ['seconds','peakRSSMiB']:
                values=[r[key] for r in selected]
                summary[mode][phase][key]=dict(median=statistics.median(values),minimum=min(values),maximum=max(values),samples=values)
    (root/'summary.json').write_text(json.dumps(summary,indent=2))
    print(json.dumps(summary,indent=2),flush=True)


if __name__=='__main__':
    main()
