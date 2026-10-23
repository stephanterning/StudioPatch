"""Compare repeated analog captures of the same deterministic output signal.

Uses existing, timestamp-validated analyzer results. Compensates integral RTL,
then compares 64-frame input windows. This cancels the converter's repeatable
filter response, which can lower short-window input/output correlation even in
an intact analog path. It is not an exact digital sample-loss counter.
"""
import json
import sys
from pathlib import Path
import numpy as np

def compare(first, second):
    def read(prefix):
        result=json.loads(Path(str(prefix)+'-analysis.json').read_text())
        if result.get('duplex_round_trip_frames') is None or not result.get('integrity'):
            raise ValueError('Both captures require valid timestamp and fixed-offset analysis')
        return result, np.memmap(str(prefix)+'-output.f32', dtype='<f4',mode='r'), np.memmap(str(prefix)+'-input.f32',dtype='<f4',mode='r')
    ar,ax,ay=read(first);br,bx,by=read(second)
    if ar['rate']!=br['rate']:raise ValueError('Sample rates differ')
    ao=int(ar['duplex_round_trip_frames']);bo=int(br['duplex_round_trip_frames']);rate=ar['rate']
    limit=min(len(ax),len(bx),len(ay)-ao,len(by)-bo)
    # Find the common active reference interval without materializing the capture.
    for end in range(limit,0,-65536):
        start=max(0,end-65536);nz=np.flatnonzero((ax[start:end]!=0)&(bx[start:end]!=0))
        if len(nz):limit=start+int(nz[-1])+1;break
    start=int(1.2*rate);end=limit-int(.2*rate);minimum=1.0;low=windows=0
    for pos in range(start,end-63,65536):
        count=min(65536,end-pos)//64*64
        if not np.array_equal(ax[pos:pos+count],bx[pos:pos+count]):raise ValueError('Output references differ')
        a=ay[pos+ao:pos+ao+count].astype(float).reshape(-1,64)
        b=by[pos+bo:pos+bo+count].astype(float).reshape(-1,64)
        norm=np.linalg.norm(a,axis=1)*np.linalg.norm(b,axis=1)
        q=np.divide(np.abs(np.sum(a*b,axis=1)),norm,out=np.zeros(len(norm)),where=norm!=0)
        minimum=min(minimum,float(q.min()));low+=int((q<.95).sum());windows+=len(q)
    if not windows:raise ValueError('No common active reference interval')
    return dict(reference=str(first),capture=str(second),window_frames=64,threshold=.95,
                windows=windows,min_correlation=minimum,low_correlation_windows=low)

if __name__=='__main__':
    print(json.dumps(compare(Path(sys.argv[1]),Path(sys.argv[2])),indent=2))
