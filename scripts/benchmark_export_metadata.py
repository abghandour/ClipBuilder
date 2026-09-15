#!/usr/bin/env python3
"""Alternate same-binary detector-cache/control pairs on a completed export."""
import argparse
import json
from pathlib import Path
import statistics
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', required=True)
    parser.add_argument('--output', required=True)
    parser.add_argument('--pairs', type=int, default=5)
    args = parser.parse_args()
    if args.pairs < 1:
        parser.error('--pairs must be positive')
    source = Path(args.source).resolve(strict=True)
    root = Path(args.output).resolve()
    root.mkdir(parents=True, exist_ok=False)
    script = Path(__file__).with_name('performance_baseline.py')
    results = []
    for pair in range(1, args.pairs + 1):
        modes = ['control', 'cache'] if pair % 2 else ['cache', 'control']
        for mode in modes:
            run = root / f'{mode}-{pair:02d}'
            command = [sys.executable, str(script), 'record', '--scenario', 'metadata',
                       '--source', str(source), '--output', str(run), '--scope', 'none', '--local-only']
            if mode == 'control':
                command.append('--disable-reel-detector-cache')
            print(f'{pair}/{args.pairs}: {mode}', flush=True)
            with (root / f'{mode}-{pair:02d}.log').open('w') as log:
                subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
            report = json.loads((run / 'phases.json').read_text())
            samples = [json.loads(line) for line in (run / 'process-samples.jsonl').read_text().splitlines()]
            results.append(dict(pair=pair, mode=mode, phases=report['phases'],
                                peakRSSMiB=max(s['totalRSSKiB'] for s in samples) / 1024,
                                executableSHA256=json.loads((run / 'manifest.json').read_text())['executableSHA256']))
            (root / 'runs.json').write_text(json.dumps(results, indent=2))
    assert len({row['executableSHA256'] for row in results}) == 1, 'Binary changed during benchmark'
    summary = {}
    for mode in ['control', 'cache']:
        rows = [r for r in results if r['mode'] == mode]
        summary[mode] = {phase: statistics.median(next(p['seconds'] for p in r['phases'] if p['name'] == phase)
                                                for r in rows)
                         for phase in ['metadata-cold', 'metadata-warm']}
        summary[mode]['medianPeakRSSMiB'] = statistics.median(r['peakRSSMiB'] for r in rows)
    (root / 'summary.json').write_text(json.dumps(summary, indent=2))
    print(json.dumps(summary, indent=2))


if __name__ == '__main__':
    main()
