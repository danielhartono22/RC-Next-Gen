-- PENDING: not applied. This session had no permission on project vvojshgcduqlugngpzkj.
--
-- Replaces the imported-PIN authentication with self registration plus System Manager
-- approval, on the owner's instruction to remove every existing account and start again.
--
-- DESTRUCTIVE. This drops all 63 Auth users, their identities, sessions and profiles, and
-- the permission and depot grants attached to them. Claim rows, campaigns, customers,
-- depots, batches and snapshots are untouched. Audit rows are kept, but the actor link is
-- severed because the account it pointed at no longer exists; the user code is copied into
-- the row first so the history stays readable. Take a pg_dump before running this.

------------------------------------------------------------------------------------------
-- 1. Who bootstraps the system
------------------------------------------------------------------------------------------
-- Owner decision, 17 September 2026: the first account to register becomes the System
-- Manager. There is no allow-list and no password in this file.
--
-- Understand the window this opens. Between the moment this migration finishes and the
-- moment the first person registers, whoever reaches the sign-up form first gets full
-- access to every depot. Register immediately after applying this, and keep the portal off
-- a public URL until that first account exists. The Vercel deployment sits behind Vercel
-- Authentication, and the local server binds to 127.0.0.1 only, so both are safe to use.
--
-- Once one profile exists the window closes by itself: every later registration is pending.

------------------------------------------------------------------------------------------
-- 2. Remove every existing account
------------------------------------------------------------------------------------------
-- Keep the audit trail readable after the profile row disappears.
update public.activity_logs l set details=l.details||jsonb_build_object(
 'former_actor_user_code',(select p.user_code from public.profiles p where p.id=l.actor_id))
where l.actor_id is not null;
update public.claim_status_history h set reason=coalesce(h.reason,'')||
 case when h.reason is null or h.reason='' then '' else ' | ' end||
 'actor sebelum reset: '||coalesce((select p.user_code from public.profiles p where p.id=h.actor_id),'-')
where h.actor_id is not null;

update public.activity_logs set actor_id=null where actor_id is not null;
update public.claim_status_history set actor_id=null where actor_id is not null;

-- profile_change_requests.requester_id is NOT NULL, so those rows cannot survive the wipe.
delete from public.profile_change_requests;
delete from public.user_permissions;
delete from public.user_depot_access;
delete from rc_private.requests;
delete from public.profiles;

-- Auth child tables, then the users themselves, so no cookie or token survives the reset.
-- GoTrue's table list differs between releases, so each one is emptied only if it exists
-- here; a missing table must not abort a destructive step that is already half done.
do $rc_auth_wipe$
declare t text;
begin
 foreach t in array array['refresh_tokens','sessions','mfa_amr_claims','mfa_challenges',
   'mfa_factors','one_time_tokens','flow_state','saml_relay_states','identities'] loop
  if to_regclass('auth.'||t) is not null then
   execute format('delete from auth.%I',t);
  end if;
 end loop;
 -- Storage menyimpan pemilik objek sebagai referensi ke auth.users tanpa ON DELETE CASCADE,
 -- sehingga satu file yang tersisa bisa menggagalkan seluruh penghapusan. Lepaskan dulu
 -- kaitannya; file dan isinya sendiri tidak disentuh.
 if to_regclass('storage.objects') is not null then
  foreach t in array array['owner','owner_id'] loop
   if exists(select 1 from information_schema.columns
             where table_schema='storage' and table_name='objects' and column_name=t) then
    execute format('update storage.objects set %I=null where %I is not null',t,t);
   end if;
  end loop;
 end if;
 delete from auth.users;
end $rc_auth_wipe$;

do $$ begin
 if exists(select 1 from auth.users) or exists(select 1 from public.profiles)
 then raise exception 'Auth reset incomplete'; end if;
end $$;

------------------------------------------------------------------------------------------
-- 3. Profile shape for self registration
------------------------------------------------------------------------------------------
-- Constraint CHECK inline diberi nama otomatis oleh PostgreSQL, dan namanya bisa berakhiran
-- angka bila pernah ada bentrokan. Cari berdasarkan kolom yang dibatasinya, jangan menebak.
do $rc_status_check$
declare c text;
begin
 for c in
  select con.conname from pg_constraint con
  join pg_class rel on rel.oid=con.conrelid
  join pg_namespace ns on ns.oid=rel.relnamespace
  where ns.nspname='public' and rel.relname='profiles' and con.contype='c'
    and pg_get_constraintdef(con.oid) ilike '%status%'
 loop
  execute format('alter table public.profiles drop constraint %I',c);
 end loop;
end $rc_status_check$;
alter table public.profiles add constraint profiles_status_check
 check(status in('pending','active','inactive','rejected'));
alter table public.profiles alter column status set default 'pending';

-- What the applicant asked for. It is a request, never a grant: real role, permissions and
-- depot scope are set by the System Manager at approval.
alter table public.profiles add column requested_role text;
alter table public.profiles add column requested_depot text;
alter table public.profiles add column registered_at timestamptz not null default now();
alter table public.profiles add column reviewed_by uuid references public.profiles(id);
alter table public.profiles add column reviewed_at timestamptz;
alter table public.profiles add column review_note text;

-- Self registered accounts choose their own password, so nothing needs forcing on first use.
alter table public.profiles alter column must_change_password set default false;

-- The owner must be able to see that the account is waiting, so drop the active-only rule.
alter policy profiles_self on public.profiles
 using(id=(select auth.uid()));

------------------------------------------------------------------------------------------
-- 4. Registration trigger
------------------------------------------------------------------------------------------
-- auth.users is written by GoTrue, so the profile is created from a trigger rather than by
-- the browser. Everything the applicant typed arrives in raw_user_meta_data and is treated
-- as untrusted input: it is validated, length limited, and never used to grant anything.
create or replace function rc_private.handle_new_user() returns trigger
language plpgsql security definer set search_path='' as $$
declare meta jsonb:=coalesce(new.raw_user_meta_data,'{}'::jsonb);
 v_code text; v_name text; v_email text; v_role text; v_depot text; is_first boolean;
begin
 -- Membuat user lewat tombol Add user di Dashboard tidak mengirim metadata apa pun, dan
 -- akun tanpa User ID tidak akan pernah bisa login. Tolak dengan pesan yang menjelaskan
 -- caranya, bukan kegagalan yang tidak bisa dibaca.
 if meta->>'user_code' is null then
  raise exception 'Akun harus dibuat lewat portal RC (tombol Daftar), atau lewat SQL/Admin API yang menyertakan user_metadata berisi user_code, full_name, business_email dan requested_role. Tombol Add user pada Dashboard tidak menyertakan data itu.';
 end if;
 v_code:=upper(btrim(coalesce(meta->>'user_code','')));
 v_name:=btrim(coalesce(meta->>'full_name',''));
 v_email:=lower(btrim(coalesce(meta->>'business_email','')));
 v_role:=lower(btrim(coalesce(meta->>'requested_role','')));
 v_depot:=btrim(coalesce(meta->>'requested_depot',''));

 if v_code='' or length(v_code)>100 or v_code !~ '^[A-Z0-9._-]+$' then
  raise exception 'User ID wajib diisi, maksimal 100 karakter, hanya huruf, angka, titik, garis bawah dan strip';
 end if;
 if v_name='' or length(v_name)>200 then raise exception 'Nama lengkap wajib diisi'; end if;
 if v_email='' or length(v_email)>320 or v_email !~ '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$'
  then raise exception 'Email kantor tidak valid'; end if;
 if v_role not in('admin','osc','non-osc','finance','supervisor') then
  raise exception 'Role yang diminta tidak dikenali'; end if;
 if length(v_depot)>200 then raise exception 'Depot terlalu panjang'; end if;
 if exists(select 1 from public.profiles where user_code=v_code) then
  raise exception 'User ID sudah terdaftar'; end if;

 -- Lock the table so two simultaneous registrations cannot both see an empty profiles
 -- table and both become System Manager.
 lock table public.profiles in exclusive mode;
 select not exists(select 1 from public.profiles) into is_first;

 if is_first then
  insert into public.profiles(id,user_code,full_name,business_email,role,status,suffix_num,
    must_change_password,requested_role,requested_depot,reviewed_at,review_note)
  values(new.id,v_code,v_name,v_email,'system manager','active','001',
    false,v_role,v_depot,now(),'Pendaftar pertama; otomatis menjadi System Manager.');
  insert into public.user_permissions(user_id,permission_code) select new.id,code from public.permissions;
  insert into public.user_depot_access(user_id,depot_id) select new.id,id from public.depots;
  insert into public.activity_logs(actor_id,event_type,entity_id,details)
  values(new.id,'bootstrap_manager',new.id,
    jsonb_build_object('user_code',v_code,'alasan','pendaftar pertama'));
 else
  -- suffix_num is NOT NULL but has no meaning until the account is approved; '000' is the
  -- unassigned marker and rc_private.next_suffix() replaces it at approval.
  insert into public.profiles(id,user_code,full_name,business_email,role,status,suffix_num,
    must_change_password,requested_role,requested_depot)
  values(new.id,v_code,v_name,v_email,v_role,'pending','000',false,v_role,v_depot);
  insert into public.activity_logs(actor_id,event_type,entity_id,details)
  values(new.id,'registration_submitted',new.id,
    jsonb_build_object('user_code',v_code,'requested_role',v_role,'requested_depot',v_depot));
 end if;
 return new;
end $$;
revoke all on function rc_private.handle_new_user() from public,anon,authenticated;

create trigger on_auth_user_created after insert on auth.users
 for each row execute function rc_private.handle_new_user();

------------------------------------------------------------------------------------------
-- 5. Approval
------------------------------------------------------------------------------------------
-- Batch numbers are built from the suffix, so two active accounts must never share one.
create or replace function rc_private.next_suffix() returns text
language plpgsql security definer set search_path='' as $$
declare n integer;
begin
 for n in 1..999 loop
  if not exists(select 1 from public.profiles where suffix_num=lpad(n::text,3,'0') and status='active')
   and not exists(select 1 from rc_private.batch_counters where suffix=lpad(n::text,3,'0'))
  then return lpad(n::text,3,'0'); end if;
 end loop;
 raise exception 'Tidak ada suffix batch tersisa';
end $$;
revoke all on function rc_private.next_suffix() from public,anon,authenticated;

-- Approving grants the requested role but no permissions and no depots. The System Manager
-- then opens the Otorisasi Matrix and assigns scope explicitly, so approval alone can never
-- hand someone another depot's claims.
create or replace function rc_private.review_registration(p_profile uuid,p_approve boolean,p_note text default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare target public.profiles%rowtype; assigned text;
begin
 if not rc_private.is_manager() then raise exception 'Manager required' using errcode='42501'; end if;
 if p_profile=(select auth.uid()) then raise exception 'Tidak dapat menyetujui akun sendiri'; end if;
 select * into target from public.profiles where id=p_profile for update;
 if not found then raise exception 'Pendaftaran tidak ditemukan'; end if;
 if target.status<>'pending' then raise exception 'Pendaftaran ini sudah diproses'; end if;
 if length(coalesce(p_note,''))>1000 then raise exception 'Catatan terlalu panjang'; end if;

 if p_approve then
  assigned:=rc_private.next_suffix();
  update public.profiles set status='active',suffix_num=assigned,
   reviewed_by=(select auth.uid()),reviewed_at=now(),review_note=p_note where id=p_profile;
 else
  update public.profiles set status='rejected',
   reviewed_by=(select auth.uid()),reviewed_at=now(),review_note=p_note where id=p_profile;
 end if;

 insert into public.activity_logs(actor_id,event_type,entity_id,details)
 values((select auth.uid()),case when p_approve then 'registration_approved' else 'registration_rejected' end,
   p_profile,jsonb_build_object('user_code',target.user_code,'suffix_num',assigned));
 return jsonb_build_object('status','success','suffix_num',assigned);
end $$;

create or replace function public.rc_review_registration(p_profile uuid,p_approve boolean,p_note text default null)
returns jsonb language sql security invoker set search_path='' as $$
 select rc_private.review_registration(p_profile,p_approve,p_note);$$;
revoke all on function rc_private.review_registration(uuid,boolean,text),
 public.rc_review_registration(uuid,boolean,text) from public,anon;
grant execute on function rc_private.review_registration(uuid,boolean,text),
 public.rc_review_registration(uuid,boolean,text) to authenticated;

------------------------------------------------------------------------------------------
-- 6. Surface pending registrations in the screen that already exists
------------------------------------------------------------------------------------------
-- The Kelola Akses inbox already renders a list of requests with Approve and Reject
-- buttons. Pending registrations are emitted into that same list with a prefixed id, so no
-- markup changes and the manager reviews accounts and depot profile changes in one place.
create or replace function rc_private.legacy_profile_requests() returns jsonb
language sql stable security definer set search_path='' as $$
 select coalesce(jsonb_agg(x order by x->>'tglRequest' desc),'[]'::jsonb) from (
  select jsonb_build_object(
    'id','signup:'||p.id,'namaDepot',coalesce(nullif(p.requested_depot,''),'Depot belum ditentukan'),
    'kodeDepot','','requesterId',p.user_code,
    'changes',jsonb_strip_nulls(jsonb_build_object(
      'Pendaftaran akun baru',p.full_name,'Email kantor',p.business_email,
      'Role diminta',p.requested_role,'Depot diminta',nullif(p.requested_depot,''))),
    'tglRequest',to_char(p.registered_at at time zone 'Asia/Jakarta','DD/MM/YYYY HH24:MI')) as x
  from public.profiles p where p.status='pending'
  union all
  select jsonb_build_object(
    'id','profile:'||r.id,'namaDepot',d.depot_name,'kodeDepot',d.depot_code,
    'requesterId',coalesce(p.user_code,''),'changes',r.changes,
    'tglRequest',to_char(r.created_at at time zone 'Asia/Jakarta','DD/MM/YYYY HH24:MI')) as x
  from public.profile_change_requests r
  join public.depots d on d.id=r.depot_id
  left join public.profiles p on p.id=r.requester_id
  where r.status='pending') t;
$$;

-- One entry point for both kinds of request, so the old approveProfileRequest route keeps
-- working unchanged.
create or replace function public.rc_review_request(p_id text,p_approve boolean)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare kind text; ref uuid;
begin
 if p_id is null or p_id !~ '^(signup|profile):[0-9a-f-]{36}$' then raise exception 'Request id tidak valid'; end if;
 kind:=split_part(p_id,':',1); ref:=split_part(p_id,':',2)::uuid;
 if kind='signup' then return rc_private.review_registration(ref,p_approve,null); end if;
 perform rc_private.review_profile(ref,p_approve);
 return jsonb_build_object('status','success');
end $$;
revoke all on function public.rc_review_request(text,boolean) from public,anon;
grant execute on function public.rc_review_request(text,boolean) to authenticated;

------------------------------------------------------------------------------------------
-- 7. Tell a waiting applicant what is happening
------------------------------------------------------------------------------------------
-- rc_legacy_bootstrap refuses anyone who is not active. Give the three non-active states a
-- message the login form can show, instead of a generic failure.
create or replace function public.rc_legacy_bootstrap() returns jsonb
language plpgsql stable security invoker set search_path='' as $$
declare me public.profiles%rowtype; flags jsonb; depot_ids uuid[]; home public.depots%rowtype;
 may_read_contacts boolean; result jsonb;
begin
 select * into me from public.profiles where id=(select auth.uid());
 if not found then raise exception 'Profile not found' using errcode='42501'; end if;
 if me.status='pending' then
  return jsonb_build_object('status','error','pendingApproval',true,
   'message','Pendaftaran Anda sudah diterima dan menunggu persetujuan System Manager.');
 end if;
 if me.status='rejected' then
  return jsonb_build_object('status','error','message',
   coalesce(nullif(me.review_note,''),'Pendaftaran Anda tidak disetujui. Hubungi System Manager.'));
 end if;
 if me.status<>'active' then
  return jsonb_build_object('status','error','message','Akun dinonaktifkan administrator.');
 end if;
 if me.must_change_password then
  return jsonb_build_object('status','error','message','Ganti PIN sebelum mengakses sistem.','mustChangePassword',true);
 end if;
 flags:=rc_private.legacy_auth_flags();
 select array_agg(depot_id) into depot_ids from public.user_depot_access where user_id=me.id;
 depot_ids:=coalesce(depot_ids,'{}'::uuid[]);
 select * into home from public.depots where id=any(depot_ids) order by depot_code limit 1;
 may_read_contacts:=rc_private.can_access(null,'upload_claim');

 result:=jsonb_build_object(
  'status','success',
  'data',jsonb_build_object(
   'userId',me.user_code,'namaLengkap',me.full_name,'role',me.role,'sysRole',me.role,
   'email',me.business_email,'activation','active','suffix',me.suffix_num,
   'kodeDepot',coalesce(home.depot_code,''),'depot',coalesce(home.depot_name,''),
   'regional','','auth',flags,
   'managedDepots',coalesce((select jsonb_agg(depot_code order by depot_code)
     from public.depots where id=any(depot_ids)),'[]'::jsonb),
   'depotDetail',jsonb_build_object(
    'kode',coalesce(home.depot_code,''),'nama',coalesce(home.depot_name,''),
    'alamat',coalesce(home.address,''),'link',coalesce(home.master_link,''))),
  'depots',coalesce((select jsonb_agg(jsonb_build_object(
     'kode',depot_code,'nama',depot_name,'link',coalesce(master_link,''))
     order by depot_code) from public.depots where id=any(depot_ids)),'[]'::jsonb),
  'campaigns',coalesce((select jsonb_agg(jsonb_build_object(
     'codeCampaign',campaign_code,'campaignName',campaign_name,
     'jenisCb',coalesce(cashback_type,''),'statusPajak',coalesce(tax_status,''),
     'masterCode','','masterCodeName','',
     'periodStart',coalesce(period_start_text,''),'periodEnd',coalesce(period_end_text,''))
     order by campaign_code) from public.campaigns),'[]'::jsonb),
  'documents',rc_private.legacy_documents(),
  'customers',rc_private.legacy_customers(may_read_contacts));
 return result;
end $$;

------------------------------------------------------------------------------------------
-- 8. The manager list must show the new states
------------------------------------------------------------------------------------------
create or replace function rc_private.legacy_users() returns jsonb
language sql stable security definer set search_path='' as $$
 select coalesce(jsonb_agg(jsonb_build_object(
   'id',p.id,'userId',p.user_code,'nama',p.full_name,'email',p.business_email,
   'role',p.role,'sysRole',p.role,'suffix',p.suffix_num,
   'activation',case p.status when 'active' then 'Active' when 'pending' then 'Pending'
     when 'rejected' then 'Rejected' else 'Nonactive' end,
   'mustChangePin',p.must_change_password,
   'requestedRole',coalesce(p.requested_role,''),'requestedDepot',coalesce(p.requested_depot,''),
   'permissions',array(select permission_code from public.user_permissions where user_id=p.id),
   'depotCodes',array(select d.depot_code from public.user_depot_access a
     join public.depots d on d.id=a.depot_id where a.user_id=p.id),
   'depotIds',array(select depot_id from public.user_depot_access where user_id=p.id),
   'depotName',coalesce((select d.depot_name from public.user_depot_access a
     join public.depots d on d.id=a.depot_id where a.user_id=p.id order by d.depot_code limit 1),''))
   order by p.status,p.user_code),'[]'::jsonb)
 from public.profiles p;
$$;

-- rc_legacy_update_access mapped anything that was not Active to 'inactive'. Keep that, but
-- refuse to run it against an account still waiting for approval, which belongs in the
-- registration inbox rather than the authorization matrix.
create or replace function public.rc_legacy_update_access(p_user_code text,p_auth jsonb,p_depot_codes text default null)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare target uuid; target_status text; perms text[]; depot_ids uuid[]; new_status text; code text;
begin
 if not rc_private.is_manager() then raise exception 'Manager required' using errcode='42501'; end if;
 if p_auth is null or jsonb_typeof(p_auth)<>'object' then raise exception 'Invalid authorization payload'; end if;
 select id,status into target,target_status from public.profiles where user_code=btrim(coalesce(p_user_code,''));
 if target is null then raise exception 'User not found'; end if;
 if target_status='pending' then raise exception 'Setujui pendaftaran ini lebih dahulu di kotak masuk approval'; end if;

 new_status:=case when lower(coalesce(p_auth->>'i','')) in('active','approved','ok') then 'active' else 'inactive' end;

 perms:=array(select code from (values
  ('j','upload_claim'),('k','release_claim'),('l','process_claim'),('m','view_analytics'),
  ('n','manage_access'),('p','view_master_depot'),('s','bulk_process')
 ) as m(letter,code) where lower(coalesce(p_auth->>m.letter,'no')) in('yes','true','approved','visible'));

 if p_depot_codes is null or btrim(p_depot_codes)='' then
  depot_ids:=array(select depot_id from public.user_depot_access where user_id=target);
 else
  depot_ids:='{}'::uuid[];
  foreach code in array string_to_array(p_depot_codes,',') loop
   if btrim(code)<>'' then depot_ids:=depot_ids||public.rc_legacy_depot_id(btrim(code)); end if;
  end loop;
 end if;

 perform rc_private.manage_user(target,new_status,perms,depot_ids);
 return jsonb_build_object('status','success');
end $$;

-- rc_private.manage_user() checks status against a two value list; widen it to match.
create or replace function rc_private.manage_user(p_user uuid,p_status text,p_permissions text[],p_depots uuid[])
returns void language plpgsql security definer set search_path='' as $$
begin
 if not rc_private.is_manager() then raise exception 'Manager required' using errcode='42501'; end if;
 if p_user=auth.uid() then raise exception 'Cannot change own access'; end if;
 if p_status not in('active','inactive','rejected') or p_status is null
  or p_permissions is null or p_depots is null then raise exception 'Invalid access values'; end if;
 if exists(select 1 from unnest(p_permissions) x where not exists(select 1 from public.permissions where code=x))
 or exists(select 1 from unnest(p_depots) x where not rc_private.can_access(x)) then
  raise exception 'Invalid permission or depot outside scope'; end if;
 perform 1 from public.profiles where id=p_user for update;
 if not found then raise exception 'User not found'; end if;
 update public.profiles set status=p_status where id=p_user;
 delete from public.user_permissions where user_id=p_user;
 insert into public.user_permissions select p_user,x from unnest(p_permissions) x group by x;
 delete from public.user_depot_access where user_id=p_user;
 insert into public.user_depot_access select p_user,x from unnest(p_depots) x group by x;
 insert into public.activity_logs(actor_id,event_type,entity_id,details)
 values(auth.uid(),'access_changed',p_user,jsonb_build_object('status',p_status));
end $$;
