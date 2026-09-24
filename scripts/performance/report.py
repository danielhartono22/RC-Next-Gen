"""Summarize raw k6 JSON by phase and operation. No averaging of percentile values."""
import argparse,json,math
from array import array
from collections import defaultdict
from pathlib import Path

def percentile(values,q):
    return values[max(0,math.ceil(q*len(values))-1)] if values else None

def summarize(raw,meta):
    groups=defaultdict(lambda:{'times':array('d'),'completed':0,'failures':0,'timeouts':0,'success':0,'bytes':0})
    peak_vus=0
    with Path(raw).open(encoding='utf-8') as f:
        for line in f:
            point=json.loads(line)
            if point.get('type')!='Point':continue
            metric=point['metric'];d=point['data'];tags=d.get('tags',{});value=d['value']
            if metric=='vus':peak_vus=max(peak_vus,value)
            if not metric.startswith('rc_') or 'phase' not in tags:continue
            for key in [(tags['phase'],'ALL'),(tags['phase'],tags.get('operation','unknown'))]:
                g=groups[key]
                if metric=='rc_latency':g['times'].append(value)
                elif metric in ('rc_completed','rc_failure','rc_timeout','rc_success','rc_response_bytes'):
                    g[{'rc_completed':'completed','rc_failure':'failures','rc_timeout':'timeouts','rc_success':'success','rc_response_bytes':'bytes'}[metric]]+=value
    rows=[]
    duration=meta['summary'].get('state',{}).get('testRunDurationMs',0)/1000
    for step in meta['steps']:
        if step['kind'] not in ('hold','recovery'):continue
        for (phase,op),g in groups.items():
            if phase!=step['phase']:continue
            values=sorted(g['times']);n=g['completed'];full=duration>=step['start']+step['seconds']
            seconds=min(step['seconds'],max(0,duration-step['start']))
            rows.append(dict(phase=phase,kind=step['kind'],users_target=step['users'],operation=op,samples=n,
              avg_ms=sum(values)/len(values) if values else None,p50_ms=percentile(values,.5),p95_ms=percentile(values,.95),p99_ms=percentile(values,.99),
              requests_per_second=n/seconds if seconds else None,successful_requests_per_second=g['success']/seconds if seconds else None,
              error_rate=g['failures']/n if n else None,timeout_rate=g['timeouts']/n if n else None,
              failed_requests=g['failures'],timeouts=g['timeouts'],response_characters=g['bytes'],
              status='MEASURED_REQUIRES_REVIEW' if full and n>=200 else 'INSUFFICIENT_SAMPLES_OR_DURATION'))
    return {'dataset_id':meta['datasetId'],'mode':meta['mode'],'observed_peak_vus':peak_vus,
            'percentiles':'nearest-rank over individual request wall-clock observations; ramps excluded',
            'note':'rc_latency includes connection/blocked time; API and SQL latency remain distinct. Peak VUs alone does not establish sustained concurrency.', 'rows':rows}

def markdown(result):
    out=['| Users | Dataset | Avg ms | P50 ms | P95 ms | P99 ms | RPS | Error Rate | Timeout | Status |',
         '|---:|---|---:|---:|---:|---:|---:|---:|---:|---|']
    def fmt(v):return 'N/A' if v is None else f'{v:.2f}'
    for r in result['rows']:
        if r['operation']!='ALL':continue
        out.append(f"| {r['users_target']} | {result['dataset_id']} | {fmt(r['avg_ms'])} | {fmt(r['p50_ms'])} | {fmt(r['p95_ms'])} | {fmt(r['p99_ms'])} | {fmt(r['requests_per_second'])} | {fmt(None if r['error_rate'] is None else r['error_rate']*100)}% | {r['timeouts']:.0f} | {r['phase']}: {r['status']} |")
    return '\n'.join(out)+'\n'

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--raw',required=True);p.add_argument('--summary',required=True);p.add_argument('--out',required=True);a=p.parse_args()
    result=summarize(a.raw,json.loads(Path(a.summary).read_text(encoding='utf-8')))
    Path(a.out+'.json').write_text(json.dumps(result,indent=2),encoding='utf-8');Path(a.out+'.md').write_text(markdown(result),encoding='utf-8')
