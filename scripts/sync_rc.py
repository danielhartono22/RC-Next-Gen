"""Import one RC CSV snapshot into Supabase DEV using only Python stdlib."""
import argparse
import csv
import datetime as dt
import getpass
import json
import os
import sys
import urllib.error
import urllib.request

URL = 'https://vvojshgcduqlugngpzkj.supabase.co'
SHEETS = ['Compile', 'ListCampaign', 'ListCust', 'DepoMaster', 'LogActivity', 'ReqProfile', 'BatchLog']

def normalize_headers(headers):
    """Name blank/duplicate headers by position, preserving every column and cell."""
    reserved = set(headers)
    seen = set()
    result = []
    for index, header in enumerate(headers, 1):
        value = header
        if not header.strip() or header in seen:
            value = f'__column_{index:03d}'
            while value in reserved or value in seen:
                value += '_'
        result.append(value)
        seen.add(value)
    return result

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('csv_file')
    parser.add_argument('--sheet', required=True, choices=SHEETS)
    parser.add_argument('--source', required=True, help='Stable name of anonymized RC DEV source')
    parser.add_argument('--snapshot-at', required=True, help='Snapshot timestamp with timezone (ISO 8601)')
    parser.add_argument('--push', action='store_true', help='Send validated snapshot; default is dry run')
    parser.add_argument('--normalize-headers', action='store_true',
                        help='Assign positional names to blank/duplicate headers; preserve all cells')
    args = parser.parse_args()
    timestamp = dt.datetime.fromisoformat(args.snapshot_at.replace('Z', '+00:00'))
    if timestamp.tzinfo is None:
        raise ValueError('snapshot-at must include timezone')
    if not args.source.strip() or len(args.source) > 200:
        raise ValueError('source must contain 1-200 characters')
    with open(args.csv_file, encoding='utf-8-sig', newline='') as stream:
        reader = csv.reader(stream, strict=True)
        headers = next(reader, [])
        if args.normalize_headers:
            original = headers
            headers = normalize_headers(original)
            print(json.dumps({'renamed_headers': [
                {'column': i, 'original': old, 'imported': new}
                for i, (old, new) in enumerate(zip(original, headers), 1) if old != new
            ]}, ensure_ascii=True))
        if not headers or any(not h.strip() for h in headers) or len(set(headers)) != len(headers):
            raise ValueError('CSV requires unique, nonempty headers. Use --normalize-headers for positional names without removing columns.')
        rows = []
        for line, row in enumerate(reader, 2):
            if len(row) != len(headers):
                raise ValueError(f'CSV record {line}: width differs from headers')
            rows.append(row)
            if len(rows) > 10000:
                raise ValueError('Maximum 10000 rows per snapshot')
    if len(json.dumps(rows, ensure_ascii=False).encode('utf-8')) > 10 * 1024 * 1024:
        raise ValueError('Snapshot exceeds 10 MiB')
    payload = dict(p_source=args.source, p_sheet=args.sheet,
                   p_snapshot_at=timestamp.isoformat(), p_headers=headers, p_rows=rows)
    print(json.dumps(dict(sheet=args.sheet, rows=len(rows), columns=len(headers), mode='push' if args.push else 'dry-run')))
    if not args.push:
        return
    key = os.environ.get('SUPABASE_SERVICE_ROLE_KEY') or getpass.getpass('Supabase DEV service_role JWT (hidden): ')
    if not key or not key.startswith('eyJ'):
        raise ValueError('Use the legacy service_role JWT from the DEV project, not a publishable key')
    request = urllib.request.Request(URL + '/rest/v1/rpc/rc_import_snapshot',
        data=json.dumps(payload, ensure_ascii=False).encode('utf-8'),
        headers={'Content-Type': 'application/json', 'apikey': key, 'Authorization': 'Bearer ' + key},
        method='POST')
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            print(response.read().decode('utf-8'))
    except urllib.error.HTTPError as error:
        # Do not print server bodies: they may contain source data.
        raise RuntimeError(f'Supabase HTTP {error.code}; inspect database logs. Retry with the same snapshot timestamp.') from None
    except urllib.error.URLError:
        raise RuntimeError('Network failed; retry with the same snapshot timestamp (safe replay).') from None

if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, RuntimeError, csv.Error) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
