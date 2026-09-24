import pathlib
import subprocess
import sys
import tempfile
import unittest
from sync_rc import normalize_headers

SCRIPT = pathlib.Path(__file__).with_name('sync_rc.py')

class CsvValidationTests(unittest.TestCase):
    def test_normalize_headers_preserves_positions_and_avoids_collisions(self):
        original = ['id', '', 'id', '__column_002', ' ']
        result = normalize_headers(original)
        self.assertEqual(result, ['id', '__column_002_', '__column_003', '__column_002', '__column_005'])
        self.assertEqual(original, ['id', '', 'id', '__column_002', ' '])

    def run_csv(self, content, sheet='Compile'):
        with tempfile.TemporaryDirectory() as folder:
            path = pathlib.Path(folder) / 'sample.csv'
            path.write_text(content, encoding='utf-8')
            return subprocess.run([sys.executable, str(SCRIPT), str(path), '--sheet', sheet,
                '--source', 'synthetic', '--snapshot-at', '2026-09-15T00:00:00Z'],
                capture_output=True, text=True)

    def test_valid_quoted_csv(self):
        result = self.run_csv('id,value\n0001,"a,b"\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('"rows": 1', result.stdout)
        self.assertIn('dry-run', result.stdout)

    def test_reject_duplicate_headers(self):
        self.assertNotEqual(self.run_csv('id,id\n1,2\n').returncode, 0)

    def test_reject_bad_width(self):
        self.assertNotEqual(self.run_csv('id,value\n1\n').returncode, 0)

    def test_reject_document_center(self):
        self.assertNotEqual(self.run_csv('id\n1\n', 'Upload').returncode, 0)

    def test_reject_authority(self):
        self.assertNotEqual(self.run_csv('id\n1\n', 'Authority').returncode, 0)

if __name__ == '__main__':
    unittest.main()
