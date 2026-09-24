-- All fixtures and DDL are rolled back by the runner. No real account is modified.
create temporary table qa_access_context(prefix text,manager uuid,supervisor uuid,viewer uuid,osc uuid,outside_osc uuid,admin uuid,d1 uuid,d2 uuid) on commit drop;
create temporary table qa_access_results(scenario text,status text) on commit drop;
create function pg_temp.qa_assert(ok boolean,label text) returns void language plpgsql as $$ begin
 if ok is distinct from true then raise exception 'FAILED: %',label; end if;
 insert into qa_access_results values(label,'PASS'); end $$;
create function pg_temp.qa_actor(actor uuid) returns void language plpgsql as $$ begin
 perform set_config('request.jwt.claims',jsonb_build_object('sub',actor,'role','authenticated')::text,true);
 perform set_config('request.jwt.claim.sub',actor::text,true); end $$;
create function pg_temp.qa_auth(code text,depot text,peran text default 'admin',app jsonb default '{}',extra jsonb default '{}') returns uuid language plpgsql as $$
declare uid uuid:=gen_random_uuid(); begin
 insert into auth.users(id,email,raw_user_meta_data,raw_app_meta_data) values(uid,lower(code)||'@example.invalid',
 jsonb_build_object('user_code',code,'full_name','Dummy access QA','business_email','qa@example.invalid','requested_role',peran,'requested_depot',depot)||extra,app);
 return uid; end $$;
do $$ declare pre text:='QA-ACCESS-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,10)); d1 uuid:=gen_random_uuid();d2 uuid:=gen_random_uuid();m uuid;sp uuid;v uuid;o uuid;oo uuid;a uuid;x uuid;
begin
 insert into public.depots(id,depot_code,depot_name,region) values(d1,pre||'-D1','Dummy depot 1',pre||'-R1'),(d2,pre||'-D2','Dummy depot 2',pre||'-R2');
 m:=pg_temp.qa_auth(pre||'-SM',pre||'-D1');sp:=pg_temp.qa_auth(pre||'-SP',pre||'-D1');v:=pg_temp.qa_auth(pre||'-VIEW',pre||'-D1');
 o:=pg_temp.qa_auth(pre||'-OSC',pre||'-D1');oo:=pg_temp.qa_auth(pre||'-OUTSIDE',pre||'-D2');a:=pg_temp.qa_auth(pre||'-ADMIN',pre||'-D1');
 foreach x in array array[m,sp,v,o,oo,a] loop update public.profiles set status='active',must_change_password=false,suffix_num='999',
 role=case when x=m then 'system manager' when x=sp then 'supervisor' when x in(o,oo) then 'osc' else 'admin' end,
 home_depot_id=case when x=oo then d2 else d1 end where id=x; end loop;
 insert into public.user_depot_grants(user_id,depot_id,kind) values(v,d1,'rp'),(o,d1,'assigned'),(oo,d2,'assigned'),(a,d1,'rp');
 insert into public.user_supervision(supervisor_id,osc_id) values(sp,o);
 foreach x in array array[m,sp,v,o,oo,a] loop perform rc_private.rebuild_with_supervisors(x); end loop;
 insert into public.user_permissions values(v,'manage_access'),(a,'approve_claim'),(a,'upload_claim');
 insert into qa_access_context values(pre,m,sp,v,o,oo,a,d1,d2);
end $$;
create function pg_temp.qa_plan(actor uuid,p jsonb) returns jsonb language plpgsql as $$ declare r jsonb; begin
 perform pg_temp.qa_actor(actor); set local role authenticated; r:=public.rc_prepare_registration(p); reset role; return r;
 exception when others then reset role; raise; end $$;
create function pg_temp.qa_access(actor uuid,p jsonb) returns jsonb language plpgsql as $$ declare r jsonb; begin
 perform pg_temp.qa_actor(actor);set local role authenticated;r:=public.rc_update_access(p);reset role;return r;
 exception when others then reset role; raise; end $$;
create function pg_temp.qa_forbidden(actor uuid,p jsonb,mode text,label text) returns void language plpgsql as $$ begin
 begin
  if mode='plan' then perform pg_temp.qa_plan(actor,p);else perform pg_temp.qa_access(actor,p);end if;
 exception when others then
  if sqlstate not in('42501','P0001') then raise; end if;
  perform pg_temp.qa_assert(true,label);return;
 end;
 raise exception 'FAILED: % allowed',label;
end $$;
do $$ declare c record;p jsonb;r jsonb;plan jsonb;uid uuid;uid2 uuid;req uuid:=gen_random_uuid();item text;code text;info jsonb;
begin
 select * into c from qa_access_context;
 p:=jsonb_build_object('request_id',req,'user_code',c.prefix||'-NEW','full_name','Dummy New Account','business_email','new@example.invalid',
  'role','admin','home_depot',c.prefix||'-D1','depot_codes',jsonb_build_array(c.prefix||'-D1'));
 plan:=pg_temp.qa_plan(c.manager,p);
 perform pg_temp.qa_assert(plan->>'role'='admin' and not plan ? 'password','Plan validates fields without retaining passwords');
 uid:=pg_temp.qa_auth(c.prefix||'-NEW',c.prefix||'-D1','admin',jsonb_build_object('rc_managed_registration',jsonb_build_object('actor_id',c.manager,'payload',plan)));
 perform pg_temp.qa_assert((select status='active' and must_change_password and suffix_num<>'000' and home_depot_id=c.d1 from public.profiles where id=uid),'Auth trigger creates active profile with PIN gate and depot');
 perform pg_temp.qa_assert((select count(*)=1 from public.user_depot_access where user_id=uid and depot_id=c.d1),'Managed account mapping materialized atomically');
 perform pg_temp.qa_assert(not exists(select 1 from public.user_permissions where user_id=uid),'Module permissions require explicit assignment');
 perform pg_temp.qa_assert((pg_temp.qa_plan(c.manager,p)->>'completed_id')::uuid=uid,'Registration retry returns original profile');
 perform pg_temp.qa_forbidden(c.manager,p||'{"full_name":"Changed payload"}','plan','Changed payload cannot reuse request ID');
 perform pg_temp.qa_forbidden(c.viewer,p||jsonb_build_object('request_id',gen_random_uuid(),'user_code',c.prefix||'-VFAIL'),'plan','Viewer cannot create account');
 perform pg_temp.qa_forbidden(c.supervisor,p||jsonb_build_object('request_id',gen_random_uuid(),'user_code',c.prefix||'-SMFAIL','role','system manager','depot_codes','[]'::jsonb),'plan','Supervisor cannot create System Manager');
 perform pg_temp.qa_forbidden(c.supervisor,p||jsonb_build_object('request_id',gen_random_uuid(),'user_code',c.prefix||'-DFAIL','depot_codes',jsonb_build_array(c.prefix||'-D2')),'plan','Supervisor cannot grant outside depot');
 perform pg_temp.qa_forbidden(c.supervisor,p||jsonb_build_object('request_id',gen_random_uuid(),'user_code',c.prefix||'-RFAIL','role','management','depot_codes','[]'::jsonb,'regions',jsonb_build_array(c.prefix||'-R2')),'plan','Supervisor cannot grant outside region');
 perform pg_temp.qa_forbidden(c.supervisor,p||jsonb_build_object('request_id',gen_random_uuid(),'user_code',c.prefix||'-OFAIL','role','supervisor','depot_codes','[]'::jsonb,'osc_codes',jsonb_build_array(c.prefix||'-OUTSIDE')),'plan','Supervisor cannot adopt outside OSC');
 foreach item in array array['osc','others','finance','depot head','management','supervisor','system manager'] loop
  r:=p||jsonb_build_object('request_id',gen_random_uuid(),'user_code',c.prefix||'-ROLE-'||replace(item,' ','-'),'role',item);
  if item='management' then r:=r||jsonb_build_object('depot_codes','[]'::jsonb,'regions',jsonb_build_array(c.prefix||'-R1'));
  elsif item='supervisor' then r:=r||jsonb_build_object('depot_codes','[]'::jsonb,'osc_codes',jsonb_build_array(c.prefix||'-OSC'));
  elsif item='system manager' then r:=r||jsonb_build_object('depot_codes','[]'::jsonb);end if;
  plan:=pg_temp.qa_plan(c.manager,r);
  uid2:=pg_temp.qa_auth(r->>'user_code',c.prefix||'-D1',item,jsonb_build_object('rc_managed_registration',jsonb_build_object('actor_id',c.manager,'payload',plan)));
  perform pg_temp.qa_assert((select role=item from public.profiles where id=uid2),'Managed registration supports role '||item);
 end loop;
 uid2:=pg_temp.qa_auth(c.prefix||'-SPOOF',c.prefix||'-D1','depot head','{}',jsonb_build_object('rc_managed_registration',jsonb_build_object('actor_id',c.manager,'payload',plan)));
 perform pg_temp.qa_assert((select status='pending' from public.profiles where id=uid2) and not exists(select 1 from public.user_depot_access where user_id=uid2),'User metadata cannot self-activate or assign scope');
 perform pg_temp.qa_actor(c.supervisor);set local role authenticated;
 r:=public.rc_review_registration(uid2,true,null);reset role;
 perform pg_temp.qa_assert((select status='active' and role='depot head' and home_depot_id=c.d1 from public.profiles where id=uid2)
  and exists(select 1 from public.user_depot_access where user_id=uid2 and depot_id=c.d1),'Scoped self-registration approval synchronizes identity and depot');
 perform pg_temp.qa_access(c.supervisor,jsonb_build_object('userId',c.prefix||'-ADMIN','auth',jsonb_build_object('approval','Yes')));
 perform pg_temp.qa_assert(exists(select 1 from public.user_permissions where user_id=c.admin and permission_code='approve_claim'),'Approval permission survives access save');
 perform pg_temp.qa_access(c.supervisor,jsonb_build_object('userId',c.prefix||'-ADMIN','fullName','Dummy renamed'));
 perform pg_temp.qa_assert((select status='active' from public.profiles where id=c.admin) and (select count(*)=2 from public.user_permissions where user_id=c.admin),'Identity-only edit preserves activation and permissions');
 perform pg_temp.qa_forbidden(c.supervisor,jsonb_build_object('userId',c.prefix||'-ADMIN','rpDepots',jsonb_build_array(c.prefix||'-D2')),'access','Access edit rejects outside depot');
 perform pg_temp.qa_forbidden(c.supervisor,jsonb_build_object('userId',c.prefix||'-OUTSIDE','auth',jsonb_build_object('j','Yes')),'access','Access edit rejects outside target');
 perform pg_temp.qa_access(c.supervisor,jsonb_build_object('userId',c.prefix||'-ADMIN','role','management','regions',jsonb_build_array(c.prefix||'-R1')));
 perform pg_temp.qa_actor(c.supervisor);set local role authenticated;r:=public.rc_legacy_manageable();reset role;
 perform pg_temp.qa_assert(exists(select 1 from jsonb_array_elements(r->'users') u where u->>'userId'=c.prefix||'-ADMIN' and u->'regions' ? (c.prefix||'-R1')),'Access response returns assigned regions');
 perform pg_temp.qa_access(c.supervisor,jsonb_build_object('userId',c.prefix||'-ADMIN','role','finance','assignedDepots',jsonb_build_array(c.prefix||'-D1')));
 perform pg_temp.qa_assert(not exists(select 1 from public.user_region_access where user_id=c.admin) and exists(select 1 from public.user_depot_grants where user_id=c.admin and kind='assigned'),'Role change removes stale region and retains Finance scope');
 perform pg_temp.qa_actor(c.viewer);set local role authenticated;r:=public.rc_legacy_manageable();reset role;
 perform pg_temp.qa_assert(r->>'status'='success' and (r->>'canEdit')::boolean=false,'Viewer can read Access Management without editing');
 perform pg_temp.qa_assert(not exists(select 1 from jsonb_array_elements(r->'users') u where u->>'userId'=c.prefix||'-OUTSIDE'),'Viewer cannot read outside account');
 perform pg_temp.qa_actor(c.manager);set local role authenticated;r:=public.rc_legacy_manageable();reset role;
 perform pg_temp.qa_assert(jsonb_array_length(r->'registrationOptions'->'roles')=8,'Server returns all eight role choices');
 perform pg_temp.qa_assert(not exists(select 1 from public.profiles where user_code like c.prefix||'%' and status='active' and suffix_num<>'999' group by suffix_num having count(*)>1),'Allocated suffixes do not collide');
end $$;
do $$ declare c record; p jsonb; plan jsonb; uid uuid; bad uuid; begin
 select * into c from qa_access_context;
 p:=jsonb_build_object('request_id',gen_random_uuid(),'user_code',c.prefix||'-AUTH-UPDATE','full_name','Dummy Admin API',
  'business_email','qa@example.invalid','role','admin','home_depot',c.prefix||'-D1','depot_codes',jsonb_build_array(c.prefix||'-D1'));
 plan:=pg_temp.qa_plan(c.manager,p);
 uid:=pg_temp.qa_auth(p->>'user_code',c.prefix||'-D1');
 update auth.users set raw_app_meta_data=jsonb_build_object('rc_managed_registration',jsonb_build_object('actor_id',c.manager,'payload',plan)) where id=uid;
 perform pg_temp.qa_assert((select status='active' and must_change_password from public.profiles where id=uid)
  and exists(select 1 from rc_private.managed_registrations where profile_id=uid),'Admin metadata UPDATE completes pending profile atomically');
 perform pg_temp.qa_assert(not exists(select 1 from public.activity_logs where actor_id=uid and event_type='registration_submitted'),'Managed creation does not leave a false pending-registration event');
 bad:=gen_random_uuid();
 begin
  insert into auth.users(id,email,raw_user_meta_data) values(bad,lower(c.prefix)||'-invalid@example.invalid',
   jsonb_build_object('user_code',c.prefix||'-INVALID','full_name','Dummy invalid','business_email','qa@example.invalid','requested_role','admin','requested_depot',c.prefix||'-D1'));
  update auth.users set raw_app_meta_data=jsonb_build_object('rc_managed_registration',jsonb_build_object('actor_id',c.supervisor,
   'payload',p||jsonb_build_object('request_id',gen_random_uuid(),'user_code',c.prefix||'-INVALID','depot_codes',jsonb_build_array(c.prefix||'-D2')))) where id=bad;
  raise exception 'Unexpected scope acceptance' using errcode='ZX001';
 exception when insufficient_privilege then null;
 end;
 perform pg_temp.qa_assert(not exists(select 1 from auth.users where id=bad) and not exists(select 1 from public.profiles where id=bad),'Invalid post-insert metadata rolls back Auth and profile together');
 perform pg_temp.qa_assert(not has_function_privilege('authenticated','rc_private.registration_plan(jsonb,uuid)','execute'),'Browser cannot call duplicate-bypass internal validator');
end $$;
select * from qa_access_results;
