#!/usr/bin/env python3
"""Compare a prototype artifact with the current renderer; never approve on SSIM alone."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess


def decoded(path):
    frames = subprocess.check_output(['ffmpeg','-v','error','-threads','2','-i',str(path),
        '-map','0:v:0','-map','0:a:0','-c:v','rawvideo','-c:a','pcm_f32le','-f','framemd5','-'],text=True)
    path.with_suffix('.framemd5').write_text(frames)
    streams = {}
    for line in frames.splitlines():
        if not line.startswith('#') and line.strip():
            fields = [f.strip() for f in line.split(',')]
            streams.setdefault(fields[0],[]).append(fields[1:])
    return streams


def packets(path):
    result = json.loads(subprocess.check_output(['ffprobe','-v','error','-show_streams','-show_packets',
        '-show_entries','stream=index,codec_type,time_base,start_time,duration,nb_frames:packet=stream_index,pts,dts,duration',
        '-of','json',str(path)],text=True))
    return result


def validate(reference, candidate, output):
    before = decoded(reference)
    after = decoded(candidate)
    clocks = [packets(p) for p in [reference,candidate]]
    result = dict(reference=str(reference), candidate=str(candidate),
        videoFrameCounts=[len(before['0']),len(after['0'])],
        decodedVideoIdentical=before['0']==after['0'],
        decodedAudioIdentical=before['1']==after['1'],
        videoFrameTimingIdentical=[r[:4] for r in before['0']]==[r[:4] for r in after['0']],
        streamMetadata=[p['streams'] for p in clocks])
    for kind in ['video','audio']:
        values=[]
        for clock in clocks:
            stream = next(s for s in clock['streams'] if s['codec_type']==kind)
            values.append(sorted((p['pts'],p.get('duration')) for p in clock['packets'] if p['stream_index']==stream['index']))
        result[kind+'PacketTimingIdentical']=values[0]==values[1]
    stats = output.with_suffix('.ssim.log')
    command=['ffmpeg','-v','info','-i',str(candidate),'-i',str(reference),'-lavfi',
             f'[0:v]setpts=PTS-STARTPTS[a];[1:v]setpts=PTS-STARTPTS[b];[a][b]ssim=stats_file={stats}',
             '-an','-f','null','-']
    log=subprocess.run(command,capture_output=True,text=True,check=True).stderr
    values=[float(x) for x in re.findall(r'All:([0-9.]+)',stats.read_text())]
    result['ssim'] = dict(mean=sum(values)/len(values),minimum=min(values),frames=len(values))
    result['timingAndAudioPass'] = all(result[k] for k in ['decodedAudioIdentical','videoFrameTimingIdentical','videoPacketTimingIdentical','audioPacketTimingIdentical'])
    result['note']='SSIM is descriptive; it is not automatic approval of changed encoding quality.'
    output.write_text(json.dumps(result,indent=2))
    print(json.dumps(result,indent=2))
    return result


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference',required=True,type=Path)
    parser.add_argument('--candidate',required=True,type=Path)
    parser.add_argument('--output',required=True,type=Path)
    args=parser.parse_args()
    result=validate(args.reference.resolve(),args.candidate.resolve(),args.output.resolve())
    raise SystemExit(0 if result['timingAndAudioPass'] else 2)
