"""Smoke-test an existing legacy credential without exposing it or changing password."""
import csv,json,re,urllib.request,urllib.error
from pathlib import Path
cfg=Path('config/rc-auth-dev.js').read_text()
base=re.search(r"url: '([^']+)'",cfg)[1]
key=re.search(r"publishableKey: '([^']+)'",cfg)[1]
import hashlib
with open(r'D:\DANIEL\data-rc\Authority\Authority.csv',encoding='utf-8-sig',newline='') as f:
    row=next(r for r in csv.DictReader(f) if r['activation'].lower()=='active' and r['Role'].lower()=='admin')
email=hashlib.sha256(row['User Id'].strip().encode()).hexdigest()+'@rc-login.invalid'
def call(path,data=None,token=None,method=None):
    headers={'apikey':key,'Content-Type':'application/json'}
    if token: headers['Authorization']='Bearer '+token
    req=urllib.request.Request(base+path,data=None if data is None else json.dumps(data).encode(),headers=headers,method=method)
    try:
        with urllib.request.urlopen(req,timeout=30) as r:
            body=r.read();return r.status,json.loads(body) if body else None
    except urllib.error.HTTPError as e:
        return e.code,None
status,session=call('/auth/v1/token?grant_type=password',{'email':email,'password':row['Pin'].strip()})
del row
if status!=200:
    raise SystemExit('FAIL sign-in HTTP '+str(status))
token=session['access_token']
try:
    status,profiles=call('/rest/v1/profiles?select=must_change_password',token=token)
    assert status==200 and len(profiles)==1 and profiles[0]['must_change_password'] is True
    status,claims=call('/rest/v1/claims?select=id&limit=1',token=token)
    assert status==200 and claims==[]
    status,_=call('/rest/v1/rpc/rc_process_claims',{'p_action':'release','p_items':[],'p_request_id':'00000000-0000-0000-0000-000000000001'},token)
    assert status in (401,403)
    print('PASS: native legacy sign-in, password-change gate, workflow denial')
finally:
    status,_=call('/auth/v1/logout?scope=local',token=token,method='POST')
    print('Logout HTTP',status)
