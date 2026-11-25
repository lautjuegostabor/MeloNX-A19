#!/usr/bin/env python3
"""Read schema-5/6 A19Core JSONL; incomplete last line is tolerated, never infer GPU utilization."""
import json, sys, math
from pathlib import Path

def analyze(path):
    lines=Path(path).read_bytes().splitlines(); rows=[]; partial=False
    for i,line in enumerate(lines):
        try: rows.append(json.loads(line))
        except (ValueError,UnicodeError):
            if i!=len(lines)-1: raise
            partial=True
    h=next(x for x in rows if x.get('type')=='header'); assert h['schemaVersion'] in (5,6)
    names=h['counterNames']; freq=h['stopwatchFrequency']; assert freq>0 and len(names)==len(set(names))
    ctx=next((x['data'] for x in rows if x.get('type')=='context'),{})
    samples=[x for x in rows if x.get('type')=='sample']; foot=next((x for x in rows if x.get('type')=='footer'),None)
    for i,s in enumerate(samples):
        assert len(s['counters'])==len(names) and s['seq']==i
        s['v']=dict(zip(names,s['counters']))
    if not samples: return {'context':ctx,'samples':0,'footer':foot,'partialLastLine':partial}
    end=samples[-1]['v']; first=samples[0]['v']; stamps=[s['elapsedSeconds'] for s in samples]; assert stamps==sorted(stamps)
    bounds=[int(n.split('_')[-2]) for n in names if n.startswith('frame_hist_le_')]
    hist=[end[f'frame_hist_le_{b}_us'] for b in bounds]+[end['frame_hist_over_2000000_us']]
    def percentile(q):
        n=sum(hist)
        if not n:return None
        t=math.ceil(n*q); cum=0
        for i,count in enumerate(hist):
            cum+=count
            if cum>=t:return {'lowerExclusiveMs':0 if i==0 else bounds[i-1]/1000,'upperInclusiveMs':bounds[i]/1000 if i<len(bounds) else None}
    stages=['jit','fence','queue_submit','pipeline_create','background_compile','allocation','present_loop','pipeline_lock']
    windows=[]
    for a,b in zip(samples,samples[1:]):
        av,bv=a['v'],b['v']; dt=b['elapsedSeconds']-a['elapsedSeconds']; frames=bv['frames']-av['frames']; slow=bv['frame_gt_100ms']-av['frame_gt_100ms']
        since_last=(bv['sample_stopwatch_ticks']-bv['last_guest_frame_ticks'])/freq if bv['last_guest_frame_ticks']>0 else None
        if slow>0 or (b.get('phase')==1 and since_last is not None and since_last>=0.1):
            windows.append({'endSeconds':b['elapsedSeconds'],'intervalSeconds':dt,'guestIntervals':frames,'over100ms':slow,'secondsSinceLastGuestFrame':since_last,'availableMiB':b['availableProcessBytes']/1048576,'thermal':b['thermalState'],'inflight':{n:bv[n+'_inflight'] for n in stages},'slowCompletions':{n:bv[n+'_slow_ge_16ms']-av[n+'_slow_ge_16ms'] for n in stages}})
    windows.sort(key=lambda w:(w['secondsSinceLastGuestFrame'] or 0,w['over100ms']),reverse=True)
    avail=[s['availableProcessBytes'] for s in samples]; footprint=[s['footprintBytes'] for s in samples if s['footprintBytes']>0]
    return {'context':ctx,'samples':len(samples),'durationSeconds':stamps[-1],'footer':foot,'partialLastLine':partial,'guestFramesWithIntervals':end['frames'],'guestFpsFromIntervals':end['frames']*1e6/end['frame_interval_us'] if end['frame_interval_us'] else None,'framePercentileBinsMs':{str(q):percentile(q) for q in (.5,.95,.99)},'maxGuestIntervalMs':end['frame_max_us']/1000,'peakFootprintMiB':max(footprint)/1048576 if footprint else None,'minAvailableMiB':min(avail)/1048576,'gcCollectionDeltas':{n:end[n]-first[n] for n in ('gc_gen0','gc_gen1','gc_gen2')},'stages':{n:{'started':end[n+'_started'],'inflightAtLastSample':end[n+'_inflight'],'maxMs':end[n+'_max_ticks']*1000/freq,'slowCompleted':end[n+'_slow_ge_16ms']} for n in stages},'mvkReadback':{n:end[n] for n in names[29:36]},'optionActivity':{n:end[n] for n in names[61:79]+names[171:]},'hotCountersAreLowerBounds':h['schemaVersion']>=6,'largestStallWindows':windows[:20], 'notes':['Counters are approximate across threads. Concurrent durations overlap; no causal proof.','Percentiles are histogram intervals, not exact per-frame values. Missing footer may indicate abrupt process exit, not necessarily a crash.','Thermal state is last sampled by UI. Zero footprint means unavailable.']}

if __name__=='__main__':
    print(json.dumps(analyze(sys.argv[1]),indent=2,ensure_ascii=False))
