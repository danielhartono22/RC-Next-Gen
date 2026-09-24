-- Allow/deny and shape checks for the legacy compatibility API.
-- Run inside a transaction that is rolled back, the same way rc_workflow.sql is run.
-- NOT YET EXECUTED: this session had no permission on the DEV project, so no result here
-- may be reported as PASS until it has actually run.
begin;

-- Synthetic identities only. No real account is touched and nothing is left behind.
create temporary table t_ids(label text primary key, id uuid);
insert into t_ids values
 ('admin_a',gen_random_uuid()),('admin_b',gen_random_uuid()),('manager',gen_random_uuid());

insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
select id,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
 label||'@rc-compat-test.invalid','x',now(),now(),now() from t_ids;

insert into public.profiles(id,user_code,full_name,business_email,role,status,suffix_num,must_change_password)
select id,'ZZCOMPAT-'||label,'Compat '||label,label||'@rc-compat-test.invalid',
 case when label='manager' then 'system manager' else 'admin' end,'active','999',false
from t_ids;

-- Give each test admin exactly one depot, and give them different depots.
insert into public.user_depot_access(user_id,depot_id)
select (select id from t_ids where label='admin_a'),id from public.depots order by depot_code limit 1;
insert into public.user_depot_access(user_id,depot_id)
select (select id from t_ids where label='admin_b'),id from public.depots order by depot_code offset 1 limit 1;
insert into public.user_depot_access(user_id,depot_id)
select (select id from t_ids where label='manager'),id from public.depots;

insert into public.user_permissions(user_id,permission_code)
select (select id from t_ids where label='admin_a'),x from unnest(array['upload_claim','view_analytics']) x;
insert into public.user_permissions(user_id,permission_code)
select (select id from t_ids where label='admin_b'),'upload_claim';
insert into public.user_permissions(user_id,permission_code)
select (select id from t_ids where label='manager'),code from public.permissions;

create or replace function pg_temp.become(p_label text) returns void language plpgsql as $$
declare uid uuid;
begin
 select id into uid from t_ids where label=p_label;
 execute format('set local role authenticated');
 execute format('set local request.jwt.claims=%L',json_build_object('sub',uid,'role','authenticated')::text);
end $$;

-- 1. Bootstrap returns the legacy shape and the caller's own scope only.
select pg_temp.become('admin_a');
do $$ declare v jsonb; begin
 v:=public.rc_legacy_bootstrap();
 assert v->>'status'='success','bootstrap must succeed for an active admin';
 assert jsonb_typeof(v->'documents')='array','documents must be an array';
 assert jsonb_typeof(v->'campaigns')='array','campaigns must be an array';
 assert v->'data'->>'userId' like 'ZZCOMPAT-%','profile must be the caller';
 assert jsonb_array_length(v->'depots')=1,'admin_a must see exactly its own depot';
 assert v->'data'->'auth'->>'j'='Yes','upload_claim must map to legacy flag j';
 assert v->'data'->'auth'->>'n'='No','manage_access must not be granted';
 assert v->'data'->'auth'->>'s'='No','bulk_process must not be granted';
end $$;

-- 2. Documents carry a version, so the client cannot submit without optimistic locking.
do $$ declare v jsonb; begin
 v:=public.rc_legacy_documents();
 if jsonb_array_length(v)>0 then
  assert (v->0) ? 'versionNo','every document row must expose versionNo';
  assert (v->0) ? 'noDoc' and (v->0) ? 'cbNet','legacy field names must be preserved';
 end if;
end $$;

-- 3. Depot isolation: the two admins must not see each other's documents.
create temporary table t_docs_a as select jsonb_array_elements(public.rc_legacy_documents())->>'noDoc' as no_doc;
select pg_temp.become('admin_b');
create temporary table t_docs_b as select jsonb_array_elements(public.rc_legacy_documents())->>'noDoc' as no_doc;
do $$ begin
 assert not exists(select 1 from t_docs_a intersect select no_doc from t_docs_b),
  'documents must not overlap between two single-depot admins';
end $$;

-- 4. Analytics requires the permission, not a role string from the browser.
do $$ begin
 begin
  perform public.rc_legacy_dashboard();
  raise exception 'admin_b has no view_analytics and must be refused';
 exception when insufficient_privilege then null;
 end;
end $$;

-- 5. Access management requires manager; an ordinary admin must be refused.
do $$ begin
 begin
  perform public.rc_legacy_manageable();
  raise exception 'non-manager must not read the access console';
 exception when insufficient_privilege then null;
 end;
 begin
  perform public.rc_legacy_update_access('ZZCOMPAT-admin_a',jsonb_build_object('i','Active','n','Yes'),null);
  raise exception 'non-manager must not change access';
 exception when insufficient_privilege then null;
 end;
end $$;

-- 6. The manager can read the console, and the legacy letter flags round-trip.
select pg_temp.become('manager');
do $$ declare v jsonb; begin
 v:=public.rc_legacy_manageable();
 assert v->>'status'='success','manager must read the access console';
 perform public.rc_legacy_update_access('ZZCOMPAT-admin_b',
  jsonb_build_object('i','Active','j','Yes','m','Yes','s','No'),null);
 assert exists(select 1 from public.user_permissions
   where user_id=(select id from t_ids where label='admin_b') and permission_code='view_analytics'),
  'flag m must grant view_analytics';
 assert not exists(select 1 from public.user_permissions
   where user_id=(select id from t_ids where label='admin_b') and permission_code='bulk_process'),
  'flag s set to No must not grant bulk_process';
 assert exists(select 1 from public.user_depot_access
   where user_id=(select id from t_ids where label='admin_b')),
  'omitting depot codes must preserve the existing depot scope';
end $$;

-- 7. Activity logging records the session actor, never a browser supplied name.
select pg_temp.become('admin_a');
do $$ begin
 perform public.rc_log_activity('Uji kompatibilitas legacy adapter');
 assert exists(select 1 from public.activity_logs
   where actor_id=(select id from t_ids where label='admin_a')
   and details->>'detail'='Uji kompatibilitas legacy adapter'),
  'log must be attributed to the session user';
 begin
  perform public.rc_log_activity('');
  raise exception 'empty detail must be refused';
 exception when others then null;
 end;
end $$;

-- 8. Anonymous callers reach nothing.
reset role;
set local role anon;
do $$ begin
 begin
  perform public.rc_legacy_bootstrap();
  raise exception 'anon must not bootstrap';
 exception when insufficient_privilege then null;
 end;
end $$;

reset role;
rollback;

------------------------------------------------------------------------------------------
-- System Manager melihat seluruh depot lewat perannya, bukan lewat baris pemberian akses
------------------------------------------------------------------------------------------
-- Ini menguji tepat kegagalan senyap yang pernah terjadi: baris user_depot_access hilang,
-- aturan bisnis tetap berbunyi "System Manager melihat semua", dan layar menjadi kosong
-- tanpa satu pun pesan error.
begin;
create temporary table t_sm(id uuid);
insert into t_sm values (gen_random_uuid());

insert into auth.users(id,instance_id,aud,role,email,encrypted_password,
  email_confirmed_at,created_at,updated_at)
select id,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
  'zz-sm-scope@rc-test.invalid','x',now(),now(),now() from t_sm;

insert into public.profiles(id,user_code,full_name,business_email,role,status,suffix_num,
  must_change_password)
select id,'ZZSMSCOPE','Uji SM Scope','zz@contoh.test','system manager','active','998',false
from t_sm;

-- Sengaja TIDAK diberi satu pun depot maupun permission.
do $$ declare uid uuid; begin
 select id into uid from t_sm;
 execute 'set local role authenticated';
 execute format('set local request.jwt.claims=%L',
   json_build_object('sub',uid,'role','authenticated')::text);

 assert (select count(*) from public.user_depot_access where user_id=uid)=0,
  'fixture harus tanpa depot supaya pengujiannya bermakna';
 assert rc_private.can_access(null),
  'System Manager tanpa baris depot tetap harus lolos pemeriksaan akses';
 assert rc_private.can_access(null,'upload_claim'),
  'System Manager tidak dibatasi permission';
 assert rc_private.can_access((select id from public.depots order by depot_code limit 1)),
  'System Manager harus dapat mengakses depot mana pun';
 assert (select count(*) from public.claims)=(select count(*) from public.claims where archived_at is null),
  'RLS harus menampilkan seluruh claim yang belum diarsipkan kepada System Manager';
end $$;

-- Akun non-manager tanpa depot tetap tidak melihat apa pun. Perbaikan ini khusus untuk
-- peran System Manager, bukan pelonggaran umum.
reset role;
create temporary table t_adm(id uuid);
insert into t_adm values (gen_random_uuid());
insert into auth.users(id,instance_id,aud,role,email,encrypted_password,
  email_confirmed_at,created_at,updated_at)
select id,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
  'zz-adm-scope@rc-test.invalid','x',now(),now(),now() from t_adm;
insert into public.profiles(id,user_code,full_name,business_email,role,status,suffix_num,
  must_change_password)
select id,'ZZADMSCOPE','Uji Admin Scope','zza@contoh.test','admin','active','997',false
from t_adm;

do $$ declare uid uuid; begin
 select id into uid from t_adm;
 execute 'set local role authenticated';
 execute format('set local request.jwt.claims=%L',
   json_build_object('sub',uid,'role','authenticated')::text);
 assert not rc_private.can_access(null),
  'admin tanpa depot tidak boleh lolos pemeriksaan akses';
 assert not exists(select 1 from public.claims),
  'admin tanpa depot tidak boleh melihat satu pun claim';
end $$;

reset role;
rollback;
