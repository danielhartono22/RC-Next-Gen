// Run with k6, not node. Test-only credentials live outside source control.
import http from 'k6/http';
import {sleep, check} from 'k6';
import exec from 'k6/execution';
import {SharedArray} from 'k6/data';
import {Trend, Rate, Counter} from 'k6/metrics';
import {validateTarget, plan, phaseAt, laneFor, outcome} from './plan.mjs';

const cfg=validateTarget(JSON.parse(open(__ENV.RC_TEST_CONFIG)));
const users=new SharedArray('dummy-identities',()=>JSON.parse(open(__ENV.RC_TEST_USERS)));
const mode=__ENV.RC_MODE||'baseline', steps=plan(mode,Number(__ENV.RC_HOLD_SECONDS||300));
const maxUsers=Math.max(...steps.map(s=>s.users));
if(users.length<maxUsers) throw Error('Not enough unique dummy users for requested VUs');
const unique=new Set(users.map(u=>u.id));
if(unique.size!==users.length || users.some(u=>!u.userCode?.startsWith('PERF_') || !/@(example|rc-login)\.invalid$/.test(u.email||'') || !u.password)) throw Error('Unique synthetic identities required');
const latency=new Trend('rc_latency',true), failures=new Rate('rc_failure'), timeouts=new Rate('rc_timeout');
const completed=new Counter('rc_completed'), good=new Counter('rc_success'), bytes=new Counter('rc_response_bytes');
const exhausted=new Counter('rc_fixture_exhausted'), invalid=new Counter('rc_integrity_failure');
const budgets=__ENV.RC_BASELINE_BUDGETS?JSON.parse(open(__ENV.RC_BASELINE_BUDGETS)):null;
if(mode!=='baseline'&&!budgets) throw Error('Run and review staging baseline before load/stress');
const threshold={rc_integrity_failure:['count==0'],rc_fixture_exhausted:['count==0']};
for(const s of steps.filter(s=>['hold','recovery'].includes(s.kind))){
  threshold[`rc_failure{phase:${s.phase}}`]=['rate<0.01'];
  threshold[`rc_timeout{phase:${s.phase}}`]=['rate<0.001'];
  for(const [op,b] of Object.entries(budgets||{}))threshold[`rc_latency{phase:${s.phase},operation:${op}}`]=[`p(95)<${b.p95}`,`p(99)<${b.p99}`];
}
export const options={
  scenarios:{journeys:{executor:'ramping-vus',startVUs:0,stages:steps.map(s=>({duration:s.seconds+'s',target:s.users})),gracefulRampDown:'0s',gracefulStop:'0s'}},
  thresholds:threshold,summaryTrendStats:['avg','med','p(95)','p(99)','max'],
  systemTags:['status','method','name','scenario','error_code'],
  tags:{suite:'rc-scale',mode,dataset:cfg.datasetId},
};
const headers=(token)=>({apikey:cfg.publishableKey,'Content-Type':'application/json',...(token?{Authorization:'Bearer '+token}:{})});
function tags(operation){const p=phaseAt(steps,(Date.now()-exec.scenario.startTime)/1000);return {operation,phase:p.phase,target_users:String(p.users)};}
function request(operation,path,body,token,verify){
  const t=tags(operation),start=Date.now();
  const p={headers:headers(token),timeout:cfg.timeoutSeconds+'s',redirects:0,tags:{...t,name:operation},responseType:'text'};
  const r=body===undefined?http.get(path.startsWith('https://')?path:cfg.baseUrl+path,p):http.post(cfg.baseUrl+path,JSON.stringify(body),p);
  let data;try{data=r.json();}catch{}
  const valid=r.status>=200&&r.status<300&&(!verify||verify(data,r));
  latency.add(Date.now()-start,t);completed.add(1,t);good.add(valid?1:0,t);
  const result=outcome(r.status,r.error_code,valid);
  failures.add(result.failed,t);timeouts.add(result.timeout,t);bytes.add(r.body?.length||0,t);
  check(r,{[operation+' semantic response']:()=>!!valid},t);
  return {ok:valid,data,response:r};
}
function rpc(name,args,token,operation=name,verify=d=>d!=null&&d.status!=='error'){
  return request(operation,'/rest/v1/rpc/'+name,args,token,verify);
}
export function setup(){
  // Small staging-only attestation endpoint: install after verified dummy seed.
  const r=http.post(cfg.baseUrl+'/rest/v1/rpc/rc_perf_environment','{}',{headers:headers(),timeout:'15s',redirects:0});
  const m=r.status===200?r.json():null;
  if(!m||m.project_ref!==cfg.projectRef||m.dataset_id!==cfg.datasetId||m.claim_rows!==1000000||!m.dummy_only||!m.side_effects_disabled)throw Error('Staging dataset attestation missing/mismatched');
  const f=http.get(cfg.frontendUrl+'/config/rc-env.js',{timeout:'15s',redirects:0});
  if(f.status!==200||!f.body.includes(cfg.baseUrl)||f.body.includes('vvojshgcduqlugngpzkj')||!f.body.includes("dataBackend: 'supabase'"))throw Error('Frontend is not wired to the isolated test project');
}
let token=null,expires=0,refreshToken=null,index=0;
function session(u){
  if(token&&Date.now()<expires)return token;
  const refresh=!!refreshToken;
  const r=request(refresh?'refresh_token':'login','/auth/v1/token?grant_type='+(refresh?'refresh_token':'password'),refresh?{refresh_token:refreshToken}:{email:u.email,password:u.password},null,d=>!!d?.access_token);
  if(!r.ok){token=null;return null;}
  token=r.data.access_token;refreshToken=r.data.refresh_token;expires=Date.now()+(r.data.expires_in-60)*1000;
  if(!refresh)rpc('rc_legacy_bootstrap',{},token,'bootstrap',d=>d?.status==='success');
  return token;
}
function uuid(){return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g,c=>{const n=Math.random()*16|0;return(c==='x'?n:(n&3)|8).toString(16);});}
function mutate(u,action,batch){
  // Pools must be disjoint by VU; never wrap and silently repeat exhausted claims.
  const pool=u.documents?.[action]||[],items=pool.slice(index,index+batch);
  if(items.length!==batch){exhausted.add(1);exec.test.abort('Dummy write pool exhausted; reseed before rerun');return;}
  index+=batch;
  if(items.some(i=>!i.no_doc.startsWith('PERF/')||!Number.isInteger(i.version_no)))throw Error('Invalid dummy write fixture');
  const payload={p_action:action,p_items:items,p_request_id:uuid(),p_reason:''};
  const expectedStatus=action==='submit'?'submitted':'released'; // Fixture campaigns are Transfer.
  const r=rpc('rc_process_claims',payload,token,action==='submit'?(batch>1?'upload_batch':'submit_form'):'update_transaction',d=>
    d?.count===items.length&&d.processed?.length===items.length&&
    new Set(d.processed.map(row=>row.no_doc)).size===items.length&&
    d.processed.every(row=>items.some(i=>i.no_doc===row.no_doc&&row.version_no===i.version_no+1)&&row.status===expectedStatus));
  if(!r.ok)return;
  // Read-after-write validates the state returned by the database, through the same user's RLS.
  for(const row of r.data.processed){
    const v=request('verify_write','/rest/v1/claims?select=no_doc,status,version_no&no_doc=eq.'+encodeURIComponent(row.no_doc),undefined,token,d=>d?.length===1&&d[0].status===row.status&&d[0].version_no===row.version_no);
    if(!v.ok)invalid.add(1);
  }
}
export default function(){
  invalid.add(0);exhausted.add(0);
  const u=users[exec.vu.idInTest-1];if(!session(u)){sleep(3);return;}
  // Baseline cycles all lanes; mixed workload at 1000 VUs is exactly 100/200/200/200/150/150.
  const lane=mode==='baseline'?['dashboard','search','report','transaction','update','upload'][exec.vu.iterationInScenario%6]:laneFor(exec.vu.idInTest);
  if(mode!=='baseline'&&u.lane!==lane){exec.test.abort('Fixture lane/role mismatch');return;}
  if(lane==='dashboard'){
    request('page',cfg.frontendUrl,undefined,null,(_,r)=>r.body?.includes('<html'));
    rpc('rc_legacy_dashboard',{},token,'dashboard',d=>d?.status==='success'&&Array.isArray(d.history)&&Array.isArray(d.compileData));
  }else if(lane==='search'){
    const offset=[0,50,500,5000][exec.vu.iterationInScenario%4];
    rpc('rc_open_claims',{p_search:u.search||'PERF/',p_campaign:u.campaign||'',p_offset:offset,p_limit:50},token,'search_filter_page',d=>d?.status==='success'&&Array.isArray(d.rows)&&d.rows.length<=50&&Number.isInteger(d.total));
    request('select_sort_page','/rest/v1/claims?select=no_doc,status,cb_net,updated_at&order=updated_at.desc,id.asc&limit=50&offset='+offset,undefined,token,d=>Array.isArray(d)&&d.length<=50);
  }else if(lane==='report')rpc('rc_report_dashboard',{p_filter:{}},token,'report',d=>d?.status==='success'&&d.kpi&&Array.isArray(d.status_distribusi));
  else if(mode==='soak'&&!cfg.soakWrites)rpc('rc_legacy_workflow',{},token,'workflow_read_soak');
  else mutate(u,lane==='transaction'?'release':'submit',lane==='upload'?cfg.batchSize:1);
  sleep(cfg.thinkSeconds+Math.random()*2);
}
export function handleSummary(data){return {[(__ENV.RC_RESULT_PREFIX||'rc-perf')+'-summary.json']:JSON.stringify({mode,datasetId:cfg.datasetId,steps,summary:data},null,2)};}
