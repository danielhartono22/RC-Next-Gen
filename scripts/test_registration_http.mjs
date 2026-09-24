// Bounded integration smoke test. Creates only UUID-prefixed dummy fixtures and removes
// them in finally. Never sends invitation email or mutates an existing account/claim.
import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {createHash,randomUUID} from 'node:crypto';
import assert from 'node:assert/strict';
import sql from './lib-sql.mjs';
const ref='vvojshgcduqlugngpzkj',base=`https://${ref}.supabase.co`;
const env=await readFile('.env','utf8');
const pat=process.env.SUPABASE_ACCESS_TOKEN||env.match(/^\s*SUPABASE_ACCESS_TOKEN\s*=\s*(.+?)\s*$/m)?.[1].replace(/^["']|["']$/g,'');
const keysResponse=await fetch(`https://api.supabase.com/v1/projects/${ref}/api-keys?reveal=true`,{headers:{Authorization:`Bearer ${pat}`}});
if(!keysResponse.ok)throw Error(`Cannot read test keys: ${keysResponse.status}`);
const keys=await keysResponse.json(),service=keys.find(k=>k.name==='service_role')?.api_key,anon=keys.find(k=>k.name==='anon')?.api_key;
if(!service||!anon)throw Error('Legacy API keys unavailable');
const prefix='QA-HTTP-'+randomUUID().replaceAll('-','').slice(0,12).toUpperCase();
const upload=process.argv.includes('--upload');
const depot=prefix+'-D',manager=prefix+'-SM',newCode=prefix+'-NEW',password=randomUUID()+'Aa1!';
const email=code=>createHash('sha256').update(code).digest('hex')+'@rc-login.invalid';
const q=x=>"'"+String(x).replaceAll("'","''")+"'";
const checks=[];
const call=async(path,body,token=anon,key=anon,method='POST')=>{
 const start=performance.now();const r=await fetch(base+path,{method,headers:{apikey:key,Authorization:`Bearer ${token}`,'Content-Type':'application/json'},...(body===undefined?{}:{body:JSON.stringify(body)})});
 const t=await r.text();let data;try{data=JSON.parse(t);}catch{data={};}return {status:r.status,data,ms:Math.round(performance.now()-start)};
};
const check=(ok,scenario)=>{assert.ok(ok,scenario);checks.push({scenario,status:'PASS'});};
let cleanup=false;
try {
 await sql(`insert into public.depots(depot_code,depot_name,region) values(${q(depot)},'Dummy HTTP QA',${q(prefix+'-R')});`);
 const created=await call('/auth/v1/admin/users',{email:email(manager),password,email_confirm:true,user_metadata:{user_code:manager,full_name:'Dummy HTTP Manager',business_email:'qa@example.invalid',requested_role:'admin',requested_depot:depot}},service,service);
 assert.equal(created.status,200,'fixture Auth create');
 await sql(`begin; update public.profiles set status='active',role='system manager',must_change_password=false,suffix_num=rc_private.next_suffix(),home_depot_id=(select id from public.depots where depot_code=${q(depot)}) where user_code=${q(manager)}; commit;`);
 const session=await call('/auth/v1/token?grant_type=password',{email:email(manager),password});
 check(session.status===200,'Native Auth login for dummy manager');const jwt=session.data.access_token;
 const payload={action:upload?'submit_upload':'create',request_id:randomUUID(),user_code:newCode,full_name:'Dummy HTTP Account',business_email:'qa@example.invalid',role:'others',department:'QA Test',home_depot:depot,depot_codes:[depot],password};
 const noAuth=await call('/functions/v1/rc-admin',payload);
 check(noAuth.status===401,'Anonymous caller denied');
 const results=await Promise.all([call('/functions/v1/rc-admin',payload,jwt),call('/functions/v1/rc-admin',payload,jwt)]);
 if(results.some(r=>![200,201].includes(r.status))) { const {password: ignored, action: omitted, ...safePayload}=payload; const replay=await call('/rest/v1/rpc/rc_prepare_registration',{p_payload:safePayload},jwt); console.log('Replay diagnostics:',JSON.stringify({statuses:results.map(r=>r.status),replay:replay.data,db:await sql(`select p.status, (u.raw_app_meta_data ? 'rc_managed_registration') app_envelope,(select count(*) from rc_private.managed_registrations x where x.profile_id=p.id) ledger from public.profiles p join auth.users u on u.id=p.id where p.user_code=${q(newCode)}`)})); }
 check(results.every(r=>[200,201].includes(r.status)),`Concurrent registration returns success (${results.map(r=>r.status).join(',')})`);
 check(results[0].data.id===results[1].data.id,'Concurrent duplicate returns the same account');
 const state=await sql(`select p.status,p.role,p.department,p.must_change_password,(select count(*) from public.user_depot_access a where a.user_id=p.id) scopes,(select count(*) from public.user_permissions a where a.user_id=p.id) permissions,(select count(*) from rc_private.managed_registrations a where a.profile_id=p.id) requests,(select count(*) from public.activity_logs a where a.entity_id=p.id and event_type='account_created') creations from public.profiles p where user_code=${q(newCode)}`);
 if(upload){
  check(results.every(r=>r.data.source==='upload'&&r.data.activation==='pending'),'Upload endpoint confirms Pending Approval');
  check(state.length===1&&state[0].status==='pending'&&state[0].scopes===0&&state[0].permissions===0,'Uploaded account is pending without depot or module grants');
  check(state[0].requests===1&&state[0].creations===0,'Upload creates one proposal and no active account-created event');
 }else{
  check(state.length===1&&state[0].status==='active'&&state[0].role==='others'&&state[0].department==='QA Test','Auth/profile/role/department persisted');
  check(state[0].scopes===1&&state[0].permissions===0&&state[0].must_change_password,'Depot assigned with least privilege and initial PIN gate');
  check(state[0].requests===1&&state[0].creations===1,'One ledger entry and one creation audit event');
 }
 const list=await call('/rest/v1/rpc/rc_legacy_manageable',{},jwt);
 check(list.status===200&&list.data.users.some(u=>u.userId===newCode),'Created account immediately visible in Access Management');
 const userSession=await call('/auth/v1/token?grant_type=password',{email:email(newCode),password});
 check(userSession.status===200,'Managed account can login through native Auth');
 if(upload){
  check(list.data.profileRequests.some(r=>r.id==='signup:'+results[0].data.id&&r.uploaded===true&&r.changes['Resource Partner / Area']===depot),'Uploaded proposal immediately appears in approval inbox');
  const pending=await call('/rest/v1/rpc/rc_legacy_bootstrap',{},userSession.data.access_token);
  check(pending.status===200&&pending.data.pendingApproval===true&&!pending.data.documents,'Real login blocks application access before upload approval');
  const reviewed=await call('/rest/v1/rpc/rc_review_request',{p_id:'signup:'+results[0].data.id,p_approve:true},jwt);
  check(reviewed.status===200&&reviewed.data.status==='success','Approval Request activates uploaded user through HTTP');
  const after=await call('/rest/v1/rpc/rc_legacy_manageable',{},jwt);
  const user=after.data.users.find(u=>u.userId===newCode);
  check(user.activation==='Active'&&user.role==='others'&&user.assignedDepots.includes(depot),'Approved uploaded role and area synchronize with Access Management');
  check(!after.data.profileRequests.some(r=>r.id==='signup:'+results[0].data.id),'Reviewed upload leaves approval inbox');
  const replay=await call('/functions/v1/rc-admin',payload,jwt);
  check(replay.status===200&&replay.data.id===results[0].data.id&&replay.data.activation==='active','HTTP retry after approval retains the same account and current status');
 }
 const gate=await call('/rest/v1/rpc/rc_legacy_bootstrap',{},userSession.data.access_token);
 check(gate.status===200&&gate.data.status==='error'&&gate.data.mustChangePassword===true&&!gate.data.documents,'Business bootstrap denied before initial PIN change');
 const changed=await call('/auth/v1/user',{password:randomUUID()+'Bb2!'},userSession.data.access_token,anon,'PUT');
 check(changed.status===200,'Managed account can change initial PIN');
 const flag=await sql(`select must_change_password from public.profiles where user_code=${q(newCode)}`);
 check(flag[0].must_change_password===false,'Password-change trigger clears initial PIN gate');
 const denied=await call('/functions/v1/rc-admin',{...payload,request_id:randomUUID(),user_code:prefix+'-DENIED'},userSession.data.access_token);
 check(denied.status===403,'Non-manager denied account provisioning over HTTP');
 const invalidCode=prefix+'-INVALID';
 const {password: ignoredPassword,action: ignoredAction,...invalidPlan}=payload;
 const invalid=await call('/auth/v1/admin/users',{email:email(invalidCode),password,email_confirm:true,
  user_metadata:{user_code:invalidCode,full_name:'Dummy rejected transaction',business_email:'qa@example.invalid',requested_role:'others',requested_depot:depot},
  app_metadata:{rc_managed_registration:{actor_id:created.data.id,payload:{...invalidPlan,request_id:randomUUID(),user_code:invalidCode,depot_codes:[prefix+'-MISSING']}}}},service,service);
 check(invalid.status>=400,'Auth Admin rejects invalid assignment during metadata update');
 const orphan=await sql(`select (select count(*) from auth.users where email=${q(email(invalidCode))}) identities,(select count(*) from public.profiles where user_code=${q(invalidCode)}) profiles`);
 check(orphan[0].identities===0&&orphan[0].profiles===0,'Actual Auth Admin transaction leaves no orphan after trigger rejection');
} finally {
 // Exact UUID-derived account names only; any unexpected dependent data aborts cleanup.
 await sql(`begin;
 create temporary table qa_cleanup_ids on commit drop as select id from public.profiles where user_code in(${q(manager)},${q(newCode)},${q(prefix+'-DENIED')},${q(prefix+'-INVALID')})
 union select id from auth.users where email in(${[manager,newCode,prefix+'-DENIED',prefix+'-INVALID'].map(x=>q(email(x))).join(',')});
 delete from rc_private.managed_registrations where profile_id in(select id from qa_cleanup_ids);
 delete from public.activity_logs where actor_id in(select id from qa_cleanup_ids);
 delete from public.user_permissions where user_id in(select id from qa_cleanup_ids);
 delete from public.user_depot_access where user_id in(select id from qa_cleanup_ids);
 delete from public.user_depot_grants where user_id in(select id from qa_cleanup_ids);
 delete from public.profiles where id in(select id from qa_cleanup_ids);
 delete from auth.users where id in(select id from qa_cleanup_ids);
 delete from public.depots where depot_code=${q(depot)};
 commit;`);
 const remains=await sql(`select (select count(*) from public.profiles where user_code like ${q(prefix+'%')}) profiles,(select count(*) from public.depots where depot_code=${q(depot)}) depots,(select count(*) from auth.users where email in(${[manager,newCode,prefix+'-DENIED',prefix+'-INVALID'].map(x=>q(email(x))).join(',')})) identities`);
 cleanup=Object.values(remains[0]).every(n=>n===0);
 await mkdir('.runtime/access-audit',{recursive:true});
 await writeFile('.runtime/access-audit/http-smoke'+(upload?'-upload':'')+'.json',JSON.stringify({testedAt:new Date().toISOString(),project:ref,fixturePrefix:prefix,mode:upload?'upload':'manual',cleanup,checks},null,2));
 console.log(`${checks.length} HTTP assertions passed; dummy fixture cleanup=${cleanup}`);
}
