"""Private migration input on stdout. Never redirect to a tracked file or logs."""
import csv
import hashlib
import json
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / '.runtime/auth-migration'))
import bcrypt

def prepare(path):
    result = []
    seen = set()
    with open(path, encoding='utf-8-sig', newline='') as stream:
        for row in csv.DictReader(stream):
            code = row['User Id'].strip()
            password = row['Pin'].strip().encode('utf-8')
            if not code or code in seen or not password or len(password) > 72:
                raise ValueError('Invalid or duplicate identity/password; migration cancelled')
            seen.add(code)
            result.append({'user_code': code,
                'login_email': hashlib.sha256(code.encode('utf-8')).hexdigest() + '@rc-login.invalid',
                'password_hash': bcrypt.hashpw(password, bcrypt.gensalt(rounds=12)).decode()})
    return result

if __name__ == '__main__':
    print(json.dumps(prepare(sys.argv[1])))
