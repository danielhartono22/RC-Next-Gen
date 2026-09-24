"""Run against an explicitly provisioned disposable DEV test identity only."""
import concurrent.futures,hashlib,json,re,sys,uuid,urllib.request,urllib.error
from pathlib import Path
if '--legacy-contract' not in sys.argv:
    raise SystemExit('Legacy submit-to-release contract is retired. Use test_pending_approval.mjs and test_registration_http.mjs. Only pass --legacy-contract against a historical disposable environment.')
sys.argv.remove('--legacy-contract')
code=sys.argv[1]
assert code.startswith('__rc_e2e_')
cfg=Path('config/rc-auth-dev.js').read_text();base=re.search(r"url: '([^']+)'",cfg)[1];key=re.search(r"publishableKey: '([^']+)'",cfg)[1]
email=hashlib.sha256(code.encode()).hexdigest()+'@rc-login.invalid'
def call(path,data=None,token=None,method=None):
    headers={'apikey':key,'Content-Type':'application/json'}
    if token:headers['Authorization']='Bearer '+token
    req=urllib.request.Request(base+path,data=None if data is None else json.dumps(data).encode(),headers=headers,method=method)
    try:
        with urllib.request.urlopen(req,timeout=40) as r:
            b=r.read();return r.status,json.loads(b) if b else None
    except urllib.error.HTTPError as e:
        return e.code,None
status,s=call('/auth/v1/token?grant_type=password',{'email':email,'password':'Rc-Dev-E2E-Initial-2026!'})
assert status==200,('login',status)
token=s['access_token']
try:
    status,p=call('/rest/v1/profiles?select=must_change_password',token=token);assert status==200 and p[0]['must_change_password']
    status,rows=call('/rest/v1/claims?select=id',token=token);assert status==200 and rows==[]
    status,_=call('/auth/v1/user',{'password':'Rc-Dev-E2E-Changed-2026!'},token,method='PUT');assert status==200,('change password',status)
    status,p=call('/rest/v1/profiles?select=must_change_password',token=token);assert status==200 and not p[0]['must_change_password']
    status,rows=call('/rest/v1/claims?select=id,no_doc,version_no',token=token);assert status==200 and len(rows)==1 and rows[0]['no_doc']==code
    request={'p_action':'submit','p_items':[{'no_doc':code,'version_no':1,'tax_subject':'Badan'}],'p_request_id':str(uuid.uuid4()),'p_reason':''}
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        results=list(pool.map(lambda _:call('/rest/v1/rpc/rc_process_claims',request,token),range(2)))
    assert all(x[0]==200 for x in results),('concurrent retry',[x[0] for x in results])
    assert results[0][1]==results[1][1]
    status,rows=call('/rest/v1/claims?select=id,status,version_no,gross_up',token=token);assert status==200 and rows[0]['version_no']==2 and rows[0]['gross_up']==100000
    # Conflicting transactions: one stale version must fail.
    def release(_):
        return call('/rest/v1/rpc/rc_process_claims',{'p_action':'release','p_items':[{'no_doc':code,'version_no':2}],'p_request_id':str(uuid.uuid4()),'p_reason':''},token)
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool: results=list(pool.map(release,range(2)))
    assert sum(r[0]==200 for r in results)==1,('concurrent release',[r[0] for r in results])
    status,summary=call('/rest/v1/rpc/rc_dashboard',{},token);assert status==200 and summary[0]['count']==1
    status,_=call('/rest/v1/claims',{'no_doc':'forbidden'},token);assert status in (401,403)
    status,history=call('/rest/v1/claim_status_history?select=action',token=token);assert status==200 and len(history)==2
    status,_=call('/functions/v1/rc-admin',{'action':'unknown'},token);assert status==400,('edge authentication',status)
    print('PASS: native login/password change, scoped data, concurrent idempotency, conflicting versions, gross-up, analytics, history, write denial, Edge auth')
finally:
    call('/auth/v1/logout?scope=local',token=token,method='POST')
