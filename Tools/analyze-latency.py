"""Correlate captured samples using Core Audio host timestamps, without DAW compensation.

Results are timestamp-referenced path delays, not callback/monitoring RTL:
client scheduling (buffer and safety offset) is already represented in timestamps.
"""
import json
import sys
from pathlib import Path
import numpy as np


def load(prefix):
    data = np.fromfile(str(prefix) + '.f32', dtype='<f4')
    blocks = np.genfromtxt(str(prefix) + '.csv', delimiter=',', names=True)
    if len(blocks) < 2 or np.any((blocks['flags'].astype(int) & 3) != 3):
        raise ValueError('Valid sample and host timestamps are required')
    if np.any(blocks['offset'][1:] != (blocks['offset'] + blocks['count'])[:-1]):
        raise ValueError('Capture offsets are discontinuous')
    if np.any(np.abs(np.diff(blocks['sample']) - blocks['count'][:-1]) > 0.01):
        raise ValueError('Sample timestamps are discontinuous')
    return data, blocks


def host_frame(blocks, index, epoch, rate):
    b = blocks[np.searchsorted(blocks['offset'], index, side='right') - 1]
    return (b['host'] - epoch) * b['tick_ns'] * rate / 1e9 + index - b['offset']


def analyze(output, capture):
    x, xb = load(output)
    y, yb = load(capture)
    rate = xb['rate'][0]
    if np.any(xb['rate'] != rate) or np.any(yb['rate'] != rate):
        raise ValueError('Sample rates must match')
    epoch = min(xb['host'][0], yb['host'][0])
    results = []
    nonzero=np.flatnonzero(x)
    if not len(nonzero):raise ValueError('Missing test signal')
    signal_end=min(len(x),nonzero[-1]+1)
    for sec in np.linspace(1.5,signal_end/rate-.5,5):
        start = int(sec * rate)
        ref = x[start:start + 4096].astype(float)
        origin = host_frame(xb, start, epoch, rate)
        approx = int(origin - host_frame(yb, 0, epoch, rate))
        lo, hi = max(0, approx - int(rate * .1)), min(len(y), approx + int(rate * .2))
        segment = y[lo:hi].astype(float)
        if len(ref) != 4096 or len(segment) < len(ref) or np.linalg.norm(ref) == 0:
            raise ValueError('Missing test signal')
        corr = np.correlate(segment, ref, mode='valid')
        peak = int(np.argmax(np.abs(corr)))
        matched = segment[peak:peak + len(ref)]
        norm = np.linalg.norm(ref) * np.linalg.norm(matched)
        quality = abs(corr[peak]) / norm if norm else 0
        delay = host_frame(yb, lo + peak, epoch, rate) - origin
        results.append(dict(reference_seconds=sec, frames=delay, ms=delay * 1000 / rate,
                            correlation=quality, valid=bool(quality > .8),
                            output_index=start,input_index=lo+peak,
                            output_host=epoch+origin*1e9/rate/xb['tick_ns'][0]))
    valid=all(r['valid'] for r in results)
    # For duplex capture, both arrays start in the same callback. Their index
    # difference includes the input/output scheduling gap (unlike host delay).
    duplex=str(output).removesuffix('-output')==str(capture).removesuffix('-input')
    offsets=[r['input_index']-r['output_index'] for r in results]
    rtl=float(np.median(offsets)) if valid and duplex else None
    integrity=None
    if valid and len(set(offsets))==1:
        offset=offsets[0];start=int(rate*1.2);end=signal_end-int(rate*.2)
        reference=x[start:end];received=y[start+offset:end+offset]
        qualities=[]
        for n in range(0,len(reference)-1024,1024):
            a=reference[n:n+1024].astype(float);b=received[n:n+1024].astype(float)
            norm=np.linalg.norm(a)*np.linalg.norm(b)
            qualities.append(float(abs(np.dot(a,b))/norm) if norm else 0)
        zeros=np.flatnonzero(received==0)
        runs=np.split(zeros,np.flatnonzero(np.diff(zeros)>1)+1)
        integrity=dict(windows=len(qualities),min_correlation=min(qualities),
                       zero_samples=int(np.count_nonzero(received==0)),
                       longest_zero_run=max(map(len,runs)),
                       low_correlation_windows=sum(q<.8 for q in qualities))
    return dict(output=str(output), capture=str(capture), rate=rate,
                duplex_round_trip_frames=rtl,duplex_round_trip_ms=rtl*1000/rate if rtl else None,
                integrity=integrity,
                peak_input=float(np.max(np.abs(y))), measurements=results,
                median_frames=(float(np.median([r['frames'] for r in results]))
                               if valid else None))


if __name__ == '__main__':
    print(json.dumps(analyze(Path(sys.argv[1]), Path(sys.argv[2])), indent=2))
