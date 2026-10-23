"""Correlate captured samples using Core Audio host timestamps, without DAW compensation.

Results are timestamp-referenced path delays, not callback/monitoring RTL:
client scheduling (buffer and safety offset) is already represented in timestamps.
"""
import csv
import itertools
import tempfile
import json
import sys
from pathlib import Path
import numpy as np


def load(prefix):
    data = np.memmap(str(prefix) + '.f32', dtype='<f4', mode='r')
    with open(str(prefix)+'.csv') as source, tempfile.TemporaryFile() as cache:
        rows=csv.reader(source);names=next(rows);dtype=np.dtype([(name,'f8') for name in names])
        while True:
            batch=list(itertools.islice(rows,65536))
            if not batch:break
            values=np.array([tuple(map(float,row)) for row in batch],dtype=dtype)
            values.tofile(cache)
        cache.flush();size=cache.tell()//dtype.itemsize
        if size<2:raise ValueError('At least two timestamp blocks are required')
        blocks=np.memmap(cache,dtype=dtype,mode='r',shape=(size,))
    for start in range(0,len(blocks),65536):
        part=blocks[max(0,start-1):start+65536]
        if np.any((part['flags'].astype(int)&3)!=3):raise ValueError('Invalid timestamps')
        if np.any(part['offset'][1:]!=(part['offset']+part['count'])[:-1]):raise ValueError('Capture offsets are discontinuous')
        if np.any(np.abs(np.diff(part['sample'])-part['count'][:-1])>.01):raise ValueError('Sample timestamps are discontinuous')
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
    signal_end=0
    for end in range(len(x),0,-65536):
        start=max(0,end-65536);nz=np.flatnonzero(x[start:end])
        if len(nz):signal_end=start+int(nz[-1])+1;break
    if not signal_end:raise ValueError('Missing test signal')
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
        # 1024-frame correlation can hide short missing playback blocks.
        # This stricter local diagnostic is calibrated against the same analog
        # loopback reference; it is not an exact digital sample-loss counter.
        short_min=1.0;short_low=short_count=0
        for n in range(0,len(reference)-64,64):
            a=reference[n:n+64].astype(float);b=received[n:n+64].astype(float)
            norm=np.linalg.norm(a)*np.linalg.norm(b)
            q=float(abs(np.dot(a,b))/norm) if norm else 0
            short_min=min(short_min,q);short_low+=int(q<.7);short_count+=1
        zero_count=longest=carry=0
        for start in range(0,len(received),65536):
            mask=received[start:start+65536]==0;zero_count+=int(mask.sum())
            edges=np.flatnonzero(np.diff(np.r_[False,mask,False]))
            for lo,hi in zip(edges[::2],edges[1::2]):
                length=int(hi-lo)+(carry if lo==0 else 0);longest=max(longest,length)
            if mask.all():carry+=len(mask)
            elif len(mask) and mask[-1]:carry=int(edges[-1]-edges[-2])
            else:carry=0
        integrity=dict(short_window_frames=64,short_window_threshold=.7,short_windows=short_count,
                       short_min_correlation=short_min,short_low_correlation_windows=short_low,
                       windows=len(qualities),min_correlation=min(qualities),
                       zero_samples=zero_count,longest_zero_run=longest,
                       low_correlation_windows=sum(q<.8 for q in qualities))
    return dict(output=str(output), capture=str(capture), rate=rate,
                duplex_round_trip_frames=rtl,duplex_round_trip_ms=rtl*1000/rate if rtl else None,
                integrity=integrity,
                peak_input=max(float(np.max(np.abs(y[n:n+65536]))) for n in range(0,len(y),65536)), measurements=results,
                median_frames=(float(np.median([r['frames'] for r in results]))
                               if valid else None))


if __name__ == '__main__':
    print(json.dumps(analyze(Path(sys.argv[1]), Path(sys.argv[2])), indent=2))
