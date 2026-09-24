-- Self registration and System Manager approval.
-- Run inside a transaction that is rolled back, like the other files in this directory.
-- NOT YET EXECUTED: this session had no permission on the DEV project, so nothing here may
-- be reported as PASS until it has actually run against PostgreSQL.
--
-- Run this only on a project where 20260917020000_rc_auth_reset_and_signup.sql has been
-- applied. The first-registrant rule only fires while public.profiles is empty, so on a
-- project that already has accounts, section 1 checks the opposite: that a later
-- registration does NOT become a manager.
begin;

create temporary table t_ids(label text primary key, id uuid);
insert into t_ids values
 ('boot',gen_random_uuid()),('pending_a',gen_random_uuid()),
 ('pending_b',gen_random_uuid()),('outsider',gen_random_uuid()),('extra',gen_random_uuid());

create or replace function pg_temp.register(p_label text,p_code text,p_role text,p_depot text)
returns void language plpgsql as $$
declare uid uuid;
begin
 select id into uid from t_ids where label=p_label;
 insert into auth.users(id,instance_id,aud,role,email,encrypted_password,
   email_confirmed_at,created_at,updated_at,raw_user_meta_data)
 values(uid,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
   lower(p_code)||'@rc-signup-test.invalid','x',now(),now(),now(),
   jsonb_build_object('user_code',p_code,'full_name','Uji '||p_code,
     'business_email',lower(p_code)||'@contoh.test','requested_role',p_role,'requested_depot',p_depot));
end $$;

create or replace function pg_temp.become(p_label text) returns void language plpgsql as $$
declare uid uuid;
begin
 select id into uid from t_ids where label=p_label;
 execute 'set local role authenticated';
 execute format('set local request.jwt.claims=%L',json_build_object('sub',uid,'role','authenticated')::text);
end $$;

-- 1. The first account to register becomes an active System Manager, with no approval.
do $$ declare bootstrapping boolean; begin
 select not exists(select 1 from public.profiles) into bootstrapping;
 perform pg_temp.register('boot','ZZFIRST','supervisor','Kantor Pusat');
 if bootstrapping then
  assert (select status from public.profiles where user_code='ZZFIRST')='active',
   'the first registration must be active immediately';
  assert (select role from public.profiles where user_code='ZZFIRST')='system manager',
   'the first registration must hold the system manager role';
  assert (select suffix_num from public.profiles where user_code='ZZFIRST')='001',
   'the first registration must hold the first batch suffix';
  assert (select count(*) from public.user_permissions where user_id=(select id from t_ids where label='boot'))
   =(select count(*) from public.permissions),'the first account must hold every permission';
  assert (select count(*) from public.user_depot_access where user_id=(select id from t_ids where label='boot'))
   =(select count(*) from public.depots),'the first account must reach every depot';
 else
  -- The window is closed on this project, which is the state that matters in production.
  assert (select status from public.profiles where user_code='ZZFIRST')='pending',
   'once any profile exists, a new registration must never become a manager';
  assert (select role from public.profiles where user_code='ZZFIRST')<>'system manager',
   'the manager role must not be granted by registration alone';
 end if;
end $$;

-- 1b. The rule fires once. A second registration is pending whatever happened above.
do $$ begin
 perform pg_temp.register('outsider','ZZSECOND','admin','Depot Uji Z');
 assert (select status from public.profiles where user_code='ZZSECOND')='pending',
  'the second registration must always be pending';
 assert not exists(select 1 from public.user_permissions
   where user_id=(select id from t_ids where label='outsider')),
  'the second registration must grant no permission';
end $$;

-- 2. Everyone else lands in pending with nothing granted.
do $$ begin
 perform pg_temp.register('pending_a','ZZPENDA','admin','Depot Uji A');
 perform pg_temp.register('pending_b','ZZPENDB','osc','Depot Uji B');
 assert (select status from public.profiles where user_code='ZZPENDA')='pending',
  'a normal registration must be pending';
 assert (select suffix_num from public.profiles where user_code='ZZPENDA')='000',
  'an unapproved account must not hold a real batch suffix';
 assert not exists(select 1 from public.user_permissions
   where user_id=(select id from t_ids where label='pending_a')),'pending must grant no permission';
 assert not exists(select 1 from public.user_depot_access
   where user_id=(select id from t_ids where label='pending_a')),'pending must grant no depot';
end $$;

-- 3. Untrusted registration metadata is validated, not accepted.
do $$ begin
 begin
  perform pg_temp.register('extra','ZZPENDA','admin','Depot Uji A');
  raise exception 'a duplicate user code must be refused';
 exception when others then
  if sqlerrm like '%must be refused%' then raise; end if;
 end;
end $$;
do $$ begin
 begin
  perform pg_temp.register('extra','ZZBADROLE','superuser','X');
  raise exception 'an unknown requested role must be refused';
 exception when others then
  if sqlerrm like '%must be refused%' then raise; end if;
 end;
end $$;

-- 4. A pending applicant sees a waiting message and reaches no business data.
select pg_temp.become('pending_a');
do $$ declare v jsonb; begin
 v:=public.rc_legacy_bootstrap();
 assert v->>'status'='error','a pending account must not bootstrap into the application';
 assert (v->>'pendingApproval')::boolean,'the response must say the account is awaiting approval';
 assert not rc_private.can_access(null),'a pending account must fail every access check';
 assert not exists(select 1 from public.claims),'RLS must hide all claims from a pending account';
end $$;

-- 5. A pending applicant cannot approve anything, including itself.
do $$ begin
 begin
  perform public.rc_review_request('signup:'||(select id from t_ids where label='pending_a'),true);
  raise exception 'a pending account must not approve itself';
 exception when insufficient_privilege then null;
 end;
end $$;

-- 6. The System Manager sees both kinds of request in one inbox.
-- Guarantee a manager exists regardless of how section 1 went, so the rest of the file
-- tests approval rather than accidentally testing the bootstrap rule again.
do $$ declare uid uuid; begin
 select id into uid from t_ids where label='boot';
 update public.profiles set status='active',role='system manager',suffix_num='001' where id=uid;
 insert into public.user_permissions(user_id,permission_code)
  select uid,code from public.permissions on conflict do nothing;
 insert into public.user_depot_access(user_id,depot_id)
  select uid,id from public.depots on conflict do nothing;
end $$;
select pg_temp.become('boot');
do $$ declare v jsonb; ids text; begin
 v:=public.rc_legacy_manageable();
 assert v->>'status'='success','the manager must read the access console';
 select string_agg(x->>'id',',') into ids from jsonb_array_elements(v->'profileRequests') x;
 assert ids like '%signup:%','pending registrations must appear in the approval inbox';
 assert (select count(*) from jsonb_array_elements(v->'profileRequests') x
   where x->>'requesterId' in('ZZPENDA','ZZPENDB'))=2,'both pending registrations must be listed';
end $$;

-- 7. Approval activates the account, assigns a unique batch suffix, and grants nothing else.
do $$ declare res jsonb; assigned text; begin
 res:=public.rc_review_request('signup:'||(select id from t_ids where label='pending_a'),true);
 assigned:=res->>'suffix_num';
 assert (select status from public.profiles where user_code='ZZPENDA')='active','approval must activate';
 assert assigned ~ '^[0-9]{3}$' and assigned<>'000','approval must assign a real batch suffix';
 assert (select count(*) from public.profiles where suffix_num=assigned and status='active')=1,
  'an active batch suffix must be unique';
 assert not exists(select 1 from public.user_permissions
   where user_id=(select id from t_ids where label='pending_a')),
  'approval alone must not grant module permissions';
 assert not exists(select 1 from public.user_depot_access
   where user_id=(select id from t_ids where label='pending_a')),
  'approval alone must not grant depot scope';
end $$;

-- 8. The same registration cannot be approved twice.
do $$ begin
 begin
  perform public.rc_review_request('signup:'||(select id from t_ids where label='pending_a'),true);
  raise exception 'a processed registration must not be reprocessed';
 exception when others then
  if sqlerrm like '%must not be reprocessed%' then raise; end if;
 end;
end $$;

-- 9. Rejection is recorded and the applicant is told.
do $$ begin
 perform public.rc_review_request('signup:'||(select id from t_ids where label='pending_b'),false);
 assert (select status from public.profiles where user_code='ZZPENDB')='rejected','rejection must be recorded';
end $$;
select pg_temp.become('pending_b');
do $$ declare v jsonb; begin
 v:=public.rc_legacy_bootstrap();
 assert v->>'status'='error','a rejected account must not enter the application';
 assert coalesce((v->>'pendingApproval')::boolean,false)=false,'a rejected account is not pending';
end $$;

-- 10. The authorization matrix refuses an account that has not been approved yet.
select pg_temp.become('boot');
do $$ begin
 perform pg_temp.register('extra','ZZPENDC','admin','Depot Uji C');
 begin
  perform public.rc_legacy_update_access('ZZPENDC',jsonb_build_object('i','Active','j','Yes'),null);
  raise exception 'a pending account must be approved before its access is edited';
 exception when others then
  if sqlerrm like '%must be approved before%' then raise; end if;
 end;
end $$;

-- 11. Granting real scope still goes through the tested path, and then the account works.
do $$ declare first_depot text; begin
 select depot_code into first_depot from public.depots order by depot_code limit 1;
 perform public.rc_legacy_update_access('ZZPENDA',
  jsonb_build_object('i','Active','j','Yes','m','Yes'),first_depot);
 assert exists(select 1 from public.user_permissions
   where user_id=(select id from t_ids where label='pending_a') and permission_code='upload_claim'),
  'the matrix must grant upload_claim';
 assert exists(select 1 from public.user_depot_access
   where user_id=(select id from t_ids where label='pending_a')),'the matrix must grant depot scope';
end $$;
select pg_temp.become('pending_a');
do $$ declare v jsonb; begin
 v:=public.rc_legacy_bootstrap();
 assert v->>'status'='success','an approved and scoped account must bootstrap';
 assert v->'data'->'auth'->>'j'='Yes','granted upload_claim must appear as legacy flag j';
 assert jsonb_array_length(v->'depots')=1,'the account must see exactly the depot it was given';
end $$;

-- 12. Anonymous callers reach nothing.
reset role;
set local role anon;
do $$ begin
 begin
  perform public.rc_legacy_bootstrap();
  raise exception 'anon must not bootstrap';
 exception when insufficient_privilege then null;
 end;
 begin
  perform public.rc_review_request('signup:00000000-0000-0000-0000-000000000000',true);
  raise exception 'anon must not approve';
 exception when insufficient_privilege then null;
 end;
end $$;

reset role;
rollback;
