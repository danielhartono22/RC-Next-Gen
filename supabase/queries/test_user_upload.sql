-- Appended to test_access_registration.sql; shared fixtures and every write roll back.
create function pg_temp.qa_review_upload(actor uuid,uid uuid,approved boolean) returns jsonb language plpgsql as $$
declare r jsonb;
begin
 perform pg_temp.qa_actor(actor);set local role authenticated;
 r:=public.rc_review_request('signup:'||uid,approved);reset role;return r;
exception when others then reset role;raise;end $$;

create function pg_temp.qa_upload(actor uuid,p jsonb,metadata_update boolean default false) returns uuid language plpgsql as $$
declare plan jsonb;uid uuid;
begin
 plan:=pg_temp.qa_plan(actor,p);
 if metadata_update then
  uid:=pg_temp.qa_auth(p->>'user_code',p->>'home_depot',p->>'role');
  update auth.users set raw_app_meta_data=jsonb_build_object('rc_managed_registration',jsonb_build_object('actor_id',actor,'payload',plan)) where id=uid;
 else
  uid:=pg_temp.qa_auth(p->>'user_code',p->>'home_depot',p->>'role',
   jsonb_build_object('rc_managed_registration',jsonb_build_object('actor_id',actor,'payload',plan)));
 end if;
 return uid;
end $$;

do $$
declare c record;p jsonb;plan jsonb;r jsonb;uid uuid;rejected uuid;sm uuid;sp uuid;mg uuid;updated uuid;item text;
begin
 select * into c from qa_access_context;
 p:=jsonb_build_object('source','upload','request_id',gen_random_uuid(),'user_code',c.prefix||'-UPLOAD',
  'full_name','Dummy Uploaded User','business_email','upload@example.invalid','role','admin',
  'home_depot',c.prefix||'-D1','depot_codes',jsonb_build_array(c.prefix||'-D2',c.prefix||'-D1',c.prefix||'-D1'),
  'password','NeverStoreThisPIN','activation','active','suffix_num','007','regions',jsonb_build_array('NOT-USED'));
 plan:=pg_temp.qa_plan(c.manager,p);
 perform pg_temp.qa_assert(plan->>'source'='upload' and plan->>'activation'='pending' and jsonb_array_length(plan->'depot_codes')=2
  and not plan ? 'password' and not plan ? 'suffix_num' and not plan ? 'regions','Upload plan normalizes depot codes and discards PIN and activation overrides');
 uid:=pg_temp.qa_upload(c.manager,p);
 perform pg_temp.qa_assert((select status='pending' and role='others' and requested_role='admin' and must_change_password and reviewed_at is null
  from public.profiles where id=uid),'Uploaded account stays Pending until approval');
 perform pg_temp.qa_assert(not exists(select 1 from public.user_depot_access where user_id=uid)
  and not exists(select 1 from public.user_depot_grants where user_id=uid)
  and not exists(select 1 from public.user_permissions where user_id=uid),'Pending upload receives no effective depot or module grants');
 perform pg_temp.qa_actor(uid);
 perform pg_temp.qa_assert(not rc_private.can_access(null),'Pending uploaded account cannot access the application');
 perform pg_temp.qa_forbidden(c.manager,jsonb_build_object('userId',p->>'user_code','auth',jsonb_build_object('i','Active')),'access','Edit Access cannot bypass pending upload approval');
 perform pg_temp.qa_actor(c.manager);set local role authenticated;r:=public.rc_legacy_manageable();reset role;
 perform pg_temp.qa_assert(exists(select 1 from jsonb_array_elements(r->'profileRequests') x where x->>'id'='signup:'||uid
  and (x->>'uploaded')::boolean and x#>>'{changes,User ID}'=p->>'user_code'
  and x#>>'{changes,Resource Partner / Area}'=c.prefix||'-D1, '||c.prefix||'-D2'),'Approval inbox shows uploaded identity, requested role and all depot codes');
 perform pg_temp.qa_assert((pg_temp.qa_plan(c.manager,p)->>'completed_id')::uuid=uid,'Upload retry returns the same pending profile');
 perform pg_temp.qa_forbidden(c.manager,p||jsonb_build_object('depot_codes',jsonb_build_array(c.prefix||'-D1')),'plan','Upload request ID cannot be reused for changed area');
 perform pg_temp.qa_forbidden(c.manager,p-'source','plan','Manual creation cannot reuse an uploaded registration request');
 perform pg_temp.qa_forbidden(c.supervisor,p||jsonb_build_object('request_id',gen_random_uuid(),'user_code',c.prefix||'-OUTSCOPE'),'plan','Upload rejects depot outside uploader jurisdiction');
 begin
  perform pg_temp.qa_review_upload(c.supervisor,uid,true);raise exception 'Expected scope denial';
 exception when sqlstate '42501' then perform pg_temp.qa_assert(true,'Reviewer must control every requested depot');end;
 perform pg_temp.qa_actor(c.supervisor);set local role authenticated;r:=public.rc_legacy_manageable();reset role;
 perform pg_temp.qa_assert(not exists(select 1 from jsonb_array_elements(r->'profileRequests') x where x->>'id'='signup:'||uid),'Upload outside reviewer scope is absent from their inbox');
 r:=pg_temp.qa_review_upload(c.manager,uid,true);
 perform pg_temp.qa_assert((select status='active' and role='admin' and suffix_num<>'000' and must_change_password from public.profiles where id=uid)
  and (select count(*)=2 from public.user_depot_access where user_id=uid),'Approval activates uploaded role and exact area with generated suffix');
 perform pg_temp.qa_assert((pg_temp.qa_plan(c.manager,p)->>'activation')='active','Approved upload replay reports current activation without resetting account');
 begin
  perform pg_temp.qa_review_upload(c.manager,uid,true);raise exception 'Expected already reviewed';
 exception when others then if sqlerrm not ilike '%sudah diproses%' then raise;end if;
  perform pg_temp.qa_assert(true,'A second approval cannot repeat activation');end;
 p:=p||jsonb_build_object('request_id',gen_random_uuid(),'user_code',c.prefix||'-REJECT','depot_codes',jsonb_build_array(c.prefix||'-D1'));
 rejected:=pg_temp.qa_upload(c.supervisor,p);
 perform pg_temp.qa_review_upload(c.manager,rejected,false);
 perform pg_temp.qa_assert((select status='rejected' and reviewed_at is not null from public.profiles where id=rejected)
  and not exists(select 1 from public.user_depot_access where user_id=rejected),'Reject keeps uploaded account inactive with no area grants');
 perform pg_temp.qa_forbidden(c.manager,jsonb_build_object('userId',p->>'user_code','auth',jsonb_build_object('i','Active')),'access','Edit Access cannot reactivate a rejected upload');
 p:=p||jsonb_build_object('request_id',gen_random_uuid(),'user_code',c.prefix||'-UP-SM','role','system manager');
 perform pg_temp.qa_forbidden(c.supervisor,p,'plan','Supervisor cannot upload System Manager');
 sm:=pg_temp.qa_upload(c.manager,p);
 perform pg_temp.qa_assert((select status='pending' and role='others' and requested_role='system manager' from public.profiles where id=sm)
  and not exists(select 1 from rc_private.effective_depots(sm)),'Pending System Manager upload has no global role or scope');
 begin perform pg_temp.qa_review_upload(c.supervisor,sm,true);raise exception 'Expected System Manager denial';
 exception when sqlstate '42501' then perform pg_temp.qa_assert(true,'Supervisor cannot approve uploaded System Manager');end;
 perform pg_temp.qa_review_upload(c.manager,sm,true);
 perform pg_temp.qa_assert((select status='active' and role='system manager' from public.profiles where id=sm),'System Manager upload activates only after authorized approval');
 foreach item in array array['supervisor','management','osc','finance','depot head','others'] loop
  p:=p||jsonb_build_object('request_id',gen_random_uuid(),'user_code',c.prefix||'-UP-'||replace(item,' ','-'),'role',item);
  updated:=pg_temp.qa_upload(c.manager,p,true);
  perform pg_temp.qa_assert((select status='pending' and requested_role=item from public.profiles where id=updated),'Metadata UPDATE remains Pending for uploaded '||item);
  perform pg_temp.qa_review_upload(c.manager,updated,true);
  perform pg_temp.qa_access(c.manager,jsonb_build_object('userId',p->>'user_code','assignedDepots',jsonb_build_array(c.prefix||'-D1')));
  perform pg_temp.qa_assert((select role=item and status='active' from public.profiles where id=updated)
   and (select count(*)=1 from public.user_depot_access where user_id=updated)
   and exists(select 1 from public.user_depot_access where user_id=updated and depot_id=c.d1),'Direct depot area survives Access save for '||item);
 end loop;
 p:=p||jsonb_build_object('request_id',gen_random_uuid(),'user_code',c.prefix||'-TAB-REQ','role','osc');
 updated:=pg_temp.qa_upload(c.manager,p);
 insert into rc_private.user_tab_access values(c.supervisor,'access.req',false);
 begin perform pg_temp.qa_review_upload(c.supervisor,updated,true);raise exception 'Expected denied tab';
 exception when sqlstate '42501' then perform pg_temp.qa_assert(true,'Denied Approval Request tab blocks upload review');end;
 delete from rc_private.user_tab_access where user_id=c.supervisor and tab_code='access.req';
 perform pg_temp.qa_review_upload(c.supervisor,updated,true);
 perform pg_temp.qa_assert((select reviewed_by=c.supervisor from public.profiles where id=updated),'Scoped Supervisor can approve upload');
 perform pg_temp.qa_assert(not exists(select 1 from rc_private.managed_registrations where payload::text like '%NeverStoreThisPIN%')
  and not exists(select 1 from public.activity_logs where details::text like '%NeverStoreThisPIN%'),'PIN is absent from proposal ledger and audit logs');
 perform pg_temp.qa_assert(exists(select 1 from public.activity_logs where entity_id=uid and event_type='registration_uploaded'
  and module='Access Management' and process_stage='Pending'),'Upload audit records timestamp context and pending stage');
end $$;
select * from qa_access_results;
