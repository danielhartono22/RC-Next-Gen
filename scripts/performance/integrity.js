// Destructive test cases ONLY on disjoint, disposable dummy documents in attested staging.
import http from 'k6/http';
import {check,sleep} from 'k6';
import {validateTarget} from './plan.mjs';
import {Counter} from 'k6/metrics';
const c=validateTarget(JSON.parse(open(__ENV.RC_TEST_CONFIG)));
const f=JSON.parse(open(__ENV.RC_INTEGRITY_FIXTURE));
const timeoutObserved=new Counter('rc_ambiguous_timeout_observed');
export const options={vus:1,iterations:1,thresholds:{checks:['rate==1'],rc_ambiguous_timeout_observed:['count>=1']}};
const h=t=>({apikey:c.publishableKey,'Content-Type':'application/json',...(t?{Authorization:'Bearer '+t}:{})});
function json(r){try{return r.json();}catch{return null;}}
function assert(name,yes){check(yes,{[name]:Boolean});if(!yes)throw Error(name);}
function login(u){assert('dummy identity',u.userCode?.startsWith('PERF_'));const r=http.post(c.baseUrl+'/auth/v1/token?grant_type=password',JSON.stringify({email:u.email,password:u.password}),{headers:h(),timeout:'30s'});assert('login succeeds',r.status===200&&json(r)?.access_token);return json(r).access_token;}
function read(doc,t){const r=http.get(c.baseUrl+'/rest/v1/claims?select=id,no_doc,status,version_no&no_doc=eq.'+encodeURIComponent(doc),{headers:h(t),timeout:'30s'});assert('read scoped dummy document',r.status===200&&json(r)?.length===1);return json(r)[0];}
function history(row,t){const r=http.get(c.baseUrl+'/rest/v1/claim_status_history?select=id&claim_id=eq.'+row.id,{headers:h(t),timeout:'30s'});assert('history readable',r.status===200&&Array.isArray(json(r)));return json(r).length;}
function uuid(){return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g,c=>{const n=Math.random()*16|0;return(c==='x'?n:(n&3)|8).toString(16);});}
function payload(row,id=uuid()){return {p_action:'release',p_items:[{no_doc:row.no_doc,version_no:row.version_no}],p_request_id:id,p_reason:''};}
function request(p,t,timeout='30s'){return {method:'POST',url:c.baseUrl+'/rest/v1/rpc/rc_process_claims',body:JSON.stringify(p),params:{headers:h(t),timeout,tags:{name:'integrity_release'}}};}
function send(q){return http.post(q.url,q.body,q.params);}
function committed(r){return r.status===200&&json(r)?.count===1;}
export default function(){
 const att=http.post(c.baseUrl+'/rest/v1/rpc/rc_perf_environment','{}',{headers:h(),timeout:'30s'}),m=json(att);
 assert('isolated million-row dummy fixture',att.status===200&&m?.project_ref===c.projectRef&&m?.dataset_id===c.datasetId&&m?.claim_rows===1000000&&m?.dummy_only&&m?.side_effects_disabled);
 assert('four disjoint dummy integrity documents',f.documents?.length===4&&new Set(f.documents).size===4&&f.documents.every(d=>d.startsWith('PERF/')));
 const a=login(f.userA),b=login(f.userB);
 // Double click: same actor, same request key, exactly one commit and one history entry.
 let row=read(f.documents[0],a),before=history(row,a),p=payload(row);
 assert('prepared submitted document',row.status==='submitted');
 const replay=http.batch([request(p,a),request(p,a)]);
 assert('both idempotent responses succeed',replay.every(committed));
 assert('identical retry results',JSON.stringify(json(replay[0]))===JSON.stringify(json(replay[1])));
 let after=read(row.no_doc,a);
 assert('one version and history increment',after.status==='released'&&after.version_no===row.version_no+1&&history(after,a)===before+1);
 const altered=send(request({...p,p_reason:'different payload'},a));
 assert('same request key with changed payload rejected',altered.status>=400&&json(altered)?.message?.includes('Request ID reused'));
 // Two actors, distinct request keys and same expected version: one commit, one stale conflict.
 row=read(f.documents[1],a);before=history(row,a);assert('peer sees same row',read(row.no_doc,b).version_no===row.version_no);
 const race=http.batch([request(payload(row),a),request(payload(row),b)]);
 assert('one race winner',race.filter(committed).length===1);
 assert('one explicit stale-version conflict',race.filter(r=>json(r)?.code==='40001').length===1);
 after=read(row.no_doc,a);assert('no lost update or duplicate history',after.status==='released'&&after.version_no===row.version_no+1&&history(after,a)===before+1);
 // Client timeout is ambiguous, so retry exactly the same request key and payload.
 row=read(f.documents[2],a);before=history(row,a);p=payload(row);
 let r=send(request(p,a,'1ms'));timeoutObserved.add(r.error_code===1050?1:0);
 for(let i=0;i<3&&!committed(r);i++){sleep(1);r=send(request(p,a));}
 assert('retry completes',committed(r));after=read(row.no_doc,a);
 assert('timeout retry causes one commit',after.version_no===row.version_no+1&&history(after,a)===before+1);
 // Batch containing a valid and a nonexistent document must roll back entirely.
 row=read(f.documents[3],a);before=history(row,a);p=payload(row);p.p_items.push({no_doc:'PERF/ZZZ-NOT-FOUND',version_no:1});
 r=send(request(p,a));assert('invalid batch rejected',r.status>=400);
 after=read(row.no_doc,a);assert('batch atomicity',after.version_no===row.version_no&&after.status===row.status&&history(after,a)===before);
}
export function handleSummary(d){return {[(__ENV.RC_RESULT_PREFIX||'rc-integrity')+'-summary.json']:JSON.stringify(d,null,2)};}
