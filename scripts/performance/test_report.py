import json,tempfile,unittest
from pathlib import Path
from report import summarize,percentile
class ReportTest(unittest.TestCase):
 def test_samples_not_average_percentiles_and_timeout_is_failure(self):
  root=Path('.runtime/performance/unit-tmp').resolve();root.mkdir(parents=True,exist_ok=True)
  with tempfile.TemporaryDirectory(dir=root) as t:
   f=Path(t)/'raw.json';points=[]
   for n in range(1,201):
    for metric,value in [('rc_latency',n),('rc_completed',1),('rc_success',0 if n==200 else 1),('rc_failure',1 if n==200 else 0),('rc_timeout',1 if n==200 else 0)]:
     points.append({'type':'Point','metric':metric,'data':{'value':value,'tags':{'phase':'hold_100','operation':'search'}}})
   f.write_text('\n'.join(json.dumps(p) for p in points))
   meta={'datasetId':'dummy','mode':'load','steps':[{'phase':'hold_100','kind':'hold','users':100,'seconds':10,'start':0}], 'summary':{'state':{'testRunDurationMs':10000}}}
   r=summarize(f,meta)['rows'][0]
   self.assertEqual(r['avg_ms'],100.5);self.assertEqual(r['p95_ms'],190);self.assertEqual(r['p99_ms'],198)
   self.assertEqual(r['requests_per_second'],20);self.assertEqual(r['error_rate'],.005);self.assertEqual(r['timeouts'],1)
   self.assertEqual(r['status'],'MEASURED_REQUIRES_REVIEW')
   meta['summary']['state']['testRunDurationMs']=5000
   self.assertEqual(summarize(f,meta)['rows'][0]['status'],'INSUFFICIENT_SAMPLES_OR_DURATION')
 def test_empty_percentile_is_not_zero(self):self.assertIsNone(percentile([], .95))
if __name__=='__main__':unittest.main()
