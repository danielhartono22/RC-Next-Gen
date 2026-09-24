import json, tempfile, unittest
from pathlib import Path
from generate_dataset import generate, verify

class DatasetTest(unittest.TestCase):
    def test_count_relationships_repeatability_and_tamper_detection(self):
        root=Path('.runtime/performance/unit-tmp').resolve();root.mkdir(parents=True,exist_ok=True)
        with tempfile.TemporaryDirectory(dir=root) as t:
            a,b=Path(t)/'a',Path(t)/'b'
            m=generate(a,1000);n=generate(b,1000)
            self.assertEqual([f['sha256'] for f in m['files']],[f['sha256'] for f in n['files']])
            self.assertEqual(verify(a)['claim_rows'],1000)
            self.assertEqual(sum(m['status_distribution'].values()),1000)
            self.assertEqual(len(m['status_distribution']),7)
            self.assertGreater(len(m['depot_distribution']),90)
            with self.assertRaises(ValueError):generate(a,1000)
            with (a/'claims.csv').open('a') as f:f.write('tampered')
            with self.assertRaises(ValueError):verify(a)

if __name__=='__main__':unittest.main()
