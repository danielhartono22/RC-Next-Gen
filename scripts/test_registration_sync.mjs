import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import {readFile} from 'node:fs/promises';
import {webcrypto} from 'node:crypto';
import {createRegistrationHandler} from '../supabase/functions/rc-admin/handler.mjs';

const input={action:'create',request_id:crypto.randomUUID(),user_code:'QA-REG',full_name:'Dummy',business_email:'dummy@example.invalid',role:'admin',home_depot:'QA-D',depot_codes:['QA-D'],password:'DummyPIN123'};
function edge(overrides={}) {
 const calls=[];let prepares=0;
 const createClient=(url,key,options)=>key==='service'?{auth:{
  getUser:async()=>overrides.unauthorized?{error:{message:'bad token'}}:{data:{user:{id:'verified-actor'}}},
  admin:{createUser:async arg=>{calls.push(arg);return overrides.creationError?{error:{message:'conflict'}}:{data:{user:{id:'new-id'}}};}}
 }}:{rpc:async(name,{p_payload})=>{
  prepares++;assert.equal(name,'rc_prepare_registration');assert.equal(options.global.headers.Authorization,'Bearer valid-token');
  assert.equal('password' in p_payload,false);
  return overrides.planError?{error:overrides.planError}:{data:{...p_payload,...(overrides.completed||overrides.creationError&&prepares>1?{completed_id:'existing-id'}:{})}};
 }};
 return {handler:createRegistrationHandler({createClient,url:'https://example.invalid',serviceKey:'service',apiKey:'public'}),calls};
}
function request(body=input,headers={Authorization:'Bearer valid-token'}) {return new Request('https://example.invalid',{method:'POST',headers,body:JSON.stringify(body)});}
test('Edge validates bearer identity before provisioning',async()=>{
 for(const options of [{},{unauthorized:true}]) {const {handler,calls}=edge(options);assert.equal((await handler(request(input,options.unauthorized?undefined:{}))).status,401);assert.equal(calls.length,0);}
});
test('Edge rejects unsupported method, malformed JSON and invalid input',async()=>{
 const {handler,calls}=edge();
 assert.equal((await handler(new Request('https://example.invalid'))).status,405);
 assert.equal((await handler(new Request('https://example.invalid',{method:'POST',headers:{Authorization:'Bearer valid-token'},body:'{'}))).status,400);
 for(const body of [{...input,action:'delete'},{...input,password:'1234'},{...input,password:'🔥'.repeat(20)}]) assert.equal((await handler(request(body))).status,400);
 assert.equal((await handler(request({...input,full_name:'x'.repeat(13000)}))).status,413);assert.equal(calls.length,0);
});
test('Edge enforces scoped database authorization before Auth creation',async()=>{
 const {handler,calls}=edge({planError:{code:'42501',message:'Outside scope'}});
 const res=await handler(request());assert.equal(res.status,403);assert.equal((await res.json()).error,'Outside scope');assert.equal(calls.length,0);
});
test('Edge provisions trusted metadata without accepting a caller actor or suffix',async()=>{
 const {handler,calls}=edge();const res=await handler(request({...input,actor_id:'forged',suffix_num:'001'}));
 assert.equal(res.status,201);assert.equal((await res.json()).id,'new-id');
 const c=calls[0];assert.equal(c.app_metadata.rc_managed_registration.actor_id,'verified-actor');
 assert.equal(c.app_metadata.rc_managed_registration.payload.suffix_num,undefined);
 assert.equal(c.app_metadata.rc_managed_registration.payload.password,undefined);
 assert.equal(c.email_confirm,true);assert.equal(c.password,input.password);
 assert.match(c.email,/^[a-f0-9]{64}@rc-login\.invalid$/);
});
test('Edge idempotent replay does not create or reset credentials',async()=>{
 const {handler,calls}=edge({completed:true});const res=await handler(request());
 assert.equal(res.status,200);assert.equal((await res.json()).id,'existing-id');assert.equal(calls.length,0);
});
test('Edge resolves a concurrent commit with the same request ID',async()=>{
 const {handler,calls}=edge({creationError:true});const res=await handler(request());
 assert.equal(res.status,200);assert.equal((await res.json()).id,'existing-id');assert.equal(calls.length,1);
});

test('Edge upload mode always produces a pending approval proposal',async()=>{
 const {handler,calls}=edge();
 const res=await handler(request({...input,action:'submit_upload',source:'manual',activation:'active'}));
 const body=await res.json();
 assert.equal(res.status,201);assert.equal(body.source,'upload');assert.equal(body.activation,'pending');
 assert.equal(calls[0].app_metadata.rc_managed_registration.payload.source,'upload');
 assert.equal(calls[0].app_metadata.rc_managed_registration.payload.activation,undefined);
 assert.equal(calls[0].app_metadata.rc_managed_registration.payload.password,undefined);
});

const adapter=await readFile('scripts/rc-legacy-adapter.js','utf8');
const plain=x=>JSON.parse(JSON.stringify(x));
function backend(replies) {
 const calls=[];const c={window:{},crypto:webcrypto,TextEncoder,__testClient:{functions:{invoke:async(name,arg)=>{calls.push({name,...arg});return replies(calls.length);}}}};
 vm.createContext(c);vm.runInContext(adapter.replace('var clientPromise = null;','var clientPromise = Promise.resolve(__testClient);'),c);
 return {call:c.window.RCBackend.call,calls};
}
const form={userId:' qa-reg ',nama:'Dummy',email:'dummy@example.invalid',pin:'DummyPIN123',role:'non-osc',department:'Finance',depotCode:'QA-D',assignAdmin:'QA-D,QA-E'};
test('Adapter preserves department and depot mapping independently from role',async()=>{
 const {call,calls}=backend(()=>({data:{status:'success',message:'Created'}}));
 assert.equal((await call({action:'addAccount',data:form})).status,'success');
 const b=plain(calls[0].body);assert.equal(b.role,'others');assert.equal(b.department,'Finance');assert.equal(b.user_code,'QA-REG');
 assert.equal(b.home_depot,'QA-D');assert.deepEqual(b.depot_codes,['QA-D','QA-E']);assert.equal(b.suffix_num,undefined);
});
test('Adapter sends OSC or region mapping only for the relevant role',async()=>{
 for(const [role,field,selection] of [['supervisor','osc_codes','QA-OSC'],['management','regions','R1']]) {
  const {call,calls}=backend(()=>({data:{status:'success'}}));
  await call({action:'addAccount',data:{...form,role,assignOsc:'QA-OSC',regions:'R1'}});
  assert.deepEqual(plain(calls[0].body[field]),[selection]);assert.deepEqual(plain(calls[0].body.depot_codes),[]);
 }
});

test('Upload adapter sends depot codes for every role to the approval endpoint',async()=>{
 for(const role of ['admin','osc','supervisor','management','finance','depot head','others','system manager']){
  const {call,calls}=backend(()=>({data:{status:'success',source:'upload',activation:'pending'}}));
  const res=await call({action:'uploadAccount',data:{...form,role,areaCodes:['001','002'],assignOsc:'UNUSED',regions:'UNUSED'}});
  const body=plain(calls[0].body);
  assert.equal(body.action,'submit_upload');assert.equal(body.role,role);
  assert.deepEqual(body.depot_codes,['001','002']);assert.deepEqual(body.osc_codes,[]);assert.deepEqual(body.regions,[]);
  assert.equal(res.activation,'pending');assert.equal(res.source,'upload');
 }
});
test('Adapter reuses request ID after uncertain failure and exposes server reason',async()=>{
 const {call,calls}=backend(n=>n===1?{error:{context:new Response(JSON.stringify({error:'Scope rejected'}))}}:{data:{status:'success'}});
 const first=await call({action:'addAccount',data:form});assert.equal(first.status,'error');assert.equal(first.message,'Scope rejected');
 await call({action:'addAccount',data:form});assert.equal(calls[0].body.request_id,calls[1].body.request_id);
});
test('Adapter rejects a short PIN without sending a request',async()=>{
 const {call,calls}=backend(()=>{throw Error('must not invoke');});
 assert.equal((await call({action:'addAccount',data:{...form,pin:'1234'}})).status,'error');assert.equal(calls.length,0);
});

const ui=await readFile('src/js/75-kelola-akses.js','utf8');
function uiContext(fetchApp) {
 const elements={};const values={addName:'Dummy',addUserId:'qa-new',addPin:'DummyPIN123',addEmail:'dummy@example.invalid',addRole:'others',addDepotCode:'QA-D',addDeptName:'Finance'};
 const events=[];const c={TextEncoder,window:{},currentUserData:{role:'system manager'},currentManageableUsers:[],globalDepotList:[],
  document:{getElementById:id=>elements[id]??=( {value:values[id]||'',reset:()=>events.push('reset'),querySelectorAll:()=>[],querySelector:()=>null})},
  fetchApp,showNotification:(msg,type)=>events.push({msg,type}),showLoadingOverlay:()=>{},hideLoadingOverlay:()=>{},
  setHiddenSafely:()=>{},setDisabledSafely:()=>{},checkMultiSelect:()=> 'QA-D',rcEsc:s=>String(s).replaceAll('<','&lt;').replaceAll('"','&quot;')};
 vm.createContext(c);vm.runInContext(ui,c);
 vm.runInContext("mRegistrationOptions={roles:[{code:'others',scope:'depot'}]};",c);
 c.mTerapkanViewer=()=>{};c.renderManageAccessCards=()=>{};c.renderProfileRequestsList=()=>{};c.switchManageTab=t=>events.push(t);
 return {c,events,elements};
}
test('UI single submit refreshes server state and keeps Non-OSC role canonical',async()=>{
 let release;const calls=[];const {c,events}=uiContext(async req=>{calls.push(req);if(req.action==='addAccount')return new Promise(r=>release=r);return {status:'success',users:[{userId:'QA-NEW'}],registrationOptions:{roles:[]}};});
 const pending=c.submitAddAccount();await c.submitAddAccount();assert.equal(calls.length,1);assert.equal(calls[0].data.role,'others');assert.equal(calls[0].data.department,'Finance');
 release({status:'success',message:'Created'});await pending;
 assert.equal(calls[1].action,'getManageableData');assert.equal(c.currentManageableUsers[0].userId,'QA-NEW');assert.ok(events.includes('list'));assert.ok(events.includes('reset'));
});
test('UI failure keeps form and allows a retry',async()=>{
 let calls=0;const {c,events}=uiContext(async()=>{calls++;return {status:'error',message:'Denied'};});
 await c.submitAddAccount();await c.submitAddAccount();assert.equal(calls,2);assert.ok(!events.includes('reset'));
});
test('UI refresh failure distinguishes committed registration from stale list',async()=>{
 const {c,events}=uiContext(async req=>req.action==='addAccount'?{status:'success'}:{status:'error'});
 await c.submitAddAccount();assert.ok(events.some(e=>e.type==='warning'&&e.msg.includes('Daftar akun belum termuat')));
});
test('UI ignores stale overlapping refresh results',async()=>{
 const resolvers=[];const {c}=uiContext(()=>new Promise(r=>resolvers.push(r)));
 const first=c.fetchManageableData();const last=c.fetchManageableData();
 resolvers[1]({status:'success',users:[{userId:'LATEST'}]});await last;
 resolvers[0]({status:'success',users:[{userId:'OLD'}]});await first;
 assert.equal(c.currentManageableUsers[0].userId,'LATEST');
});
test('Viewer UI cannot submit account creation',async()=>{
 const {c}=uiContext(()=>{throw Error('must not invoke');});c.currentUserData={role:'finance'};await c.submitAddAccount();
});
test('Activity log renders stored input as text',()=>{
 const {c,elements}=uiContext();c.window.globalLogs=[{timestamp:'now',userId:'QA',role:'admin',detail:'<img src=x onerror=alert(1)>'}];
 c.logCurrentPage=1;c.logItemsPerPage=10;c.renderLogPagination=()=>{};c.renderLogTable();
 assert.ok(elements.logTableBody.innerHTML.includes('&lt;img'));assert.ok(!elements.logTableBody.innerHTML.includes('<img'));
});

function loginBackend(reply) {
 const calls=[];const c={window:{},crypto:webcrypto,TextEncoder,__testClient:{auth:{signInWithPassword:async p=>{calls.push(p);return reply(calls.length);}},rpc:async()=>({data:{status:'error',mustChangePassword:true}})}};
 vm.createContext(c);vm.runInContext(adapter.replace('var clientPromise = null;','var clientPromise = Promise.resolve(__testClient);'),c);
 return {rc:c.window.RCBackend,calls};
}
test('Login supports canonical new aliases without changing legacy hash derivation',async()=>{
 const {rc,calls}=loginBackend(n=>n===1?{error:{code:'invalid_credentials'}}:{data:{}});
 await rc.call({action:'login',userid:' qa-user ',pin:'  Dummy PIN  '});
 assert.equal(calls[0].email,await rc._test.loginEmail('qa-user'));
 assert.equal(calls[1].email,await rc._test.loginEmail('QA-USER'));
 assert.ok(calls.every(c=>c.password==='  Dummy PIN  '));
});
test('Login preserves existing exact-case aliases without unnecessary retries',async()=>{
 const {rc,calls}=loginBackend(()=>({data:{}}));await rc.call({action:'login',userid:'Existing.Mixed',pin:'DummyPIN123'});assert.equal(calls.length,1);
});
test('Login stops immediately on Auth throttling',async()=>{
 const {rc,calls}=loginBackend(()=>({error:{code:'over_request_rate_limit',status:429}}));
 await rc.call({action:'login',userid:'Qa-Mixed',pin:'DummyPIN123'});assert.equal(calls.length,1);
});
test('Login never exceeds the three distinct casing candidates',async()=>{
 const {rc,calls}=loginBackend(()=>({error:{code:'invalid_credentials'}}));
 const r=await rc.call({action:'login',userid:'Qa-Mixed',pin:'DummyPIN123'});assert.equal(calls.length,3);assert.equal(r.status,'error');
});
