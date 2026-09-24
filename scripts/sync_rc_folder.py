"""Validate every supported RC CSV first, then push with one hidden key prompt."""
import argparse
import getpass
import os
from pathlib import Path
import subprocess
import sys
from sync_rc import SHEETS

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('folder')
    parser.add_argument('--source', required=True)
    parser.add_argument('--snapshot-at', required=True)
    parser.add_argument('--push', action='store_true')
    args = parser.parse_args()
    folder = Path(args.folder)
    if not folder.is_dir():
        raise ValueError('Folder does not exist')
    files = sorted(p for p in folder.iterdir() if p.is_file() and p.suffix.lower() == '.csv')
    if not files:
        raise ValueError('No CSV files found')
    unsupported = [p.name for p in files if p.stem not in SHEETS]
    if unsupported:
        raise ValueError('Unsupported CSV files; nothing pushed: ' + ', '.join(unsupported))
    commands = []
    for path in files:
        command = [sys.executable, str(Path(__file__).with_name('sync_rc.py')), str(path),
                   '--sheet', path.stem, '--source', args.source,
                   '--snapshot-at', args.snapshot_at, '--normalize-headers']
        print('Validating ' + path.name, flush=True)
        if subprocess.run(command).returncode:
            raise ValueError('Validation failed; nothing pushed')
        commands.append((path.name, command))
    if not args.push:
        print(f'Validated {len(files)} files. Add --push to upload.')
        return
    key = (os.environ.get('SUPABASE_SERVICE_ROLE_KEY') or
           getpass.getpass('Supabase DEV service_role JWT (hidden): ')).strip()
    if not key.startswith('eyJ'):
        raise ValueError('Expected legacy service_role JWT; nothing pushed')
    child_env = os.environ.copy()
    child_env['SUPABASE_SERVICE_ROLE_KEY'] = key
    completed = 0
    try:
        for name, command in commands:
            print('Pushing ' + name, flush=True)
            if subprocess.run(command + ['--push'], env=child_env).returncode:
                raise ValueError(f'Push stopped at {name}; {completed} files completed. Retry with the same timestamp to avoid duplicates.')
            completed += 1
    finally:
        child_env.pop('SUPABASE_SERVICE_ROLE_KEY', None)
    print(f'Success: {completed} files pushed/replayed.')

if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        print('\nCancelled. Retry with the same timestamp if any files were already sent.', file=sys.stderr)
        sys.exit(130)
