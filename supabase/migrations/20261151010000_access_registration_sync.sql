-- Registration contract, atomic Auth/profile provisioning and scoped access management.
alter table public.profiles add column if not exists department text;
create table if not exists rc_private.managed_registrations (
 request_id uuid primary key, actor_id uuid not null references public.profiles(id),
 profile_id uuid not null references public.profiles(id) on delete cascade,
 payload jsonb not null, created_at timestamptz not null default now()
);
revoke all on rc_private.managed_registrations from public,anon,authenticated;

create or replace function rc_private.registration_roles() returns jsonb
language sql immutable set search_path='' as $$
 select '[{"code":"admin","label":"Admin Depot","scope":"depot"},
 {"code":"osc","label":"OSC","scope":"depot"},
 {"code":"others","label":"Non-OSC","scope":"depot"},
 {"code":"finance","label":"Finance","scope":"depot"},
 {"code":"depot head","label":"Depot Head","scope":"depot"},
 {"code":"management","label":"Management","scope":"region"},
 {"code":"supervisor","label":"Supervisor","scope":"osc"},
 {"code":"system manager","label":"System Manager","scope":"global"}]'::jsonb;
$$;

create or replace function rc_private.registration_options() returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object(
 'roles',(select jsonb_agg(x) from jsonb_array_elements(rc_private.registration_roles()) x
   where x->>'code'<>'system manager' or rc_private.is_system_manager()),
 'regions',coalesce((select jsonb_agg(r.region order by r.region) from (
   select distinct upper(btrim(d.region)) region from public.depots d
   where d.archived_at is null and btrim(coalesce(d.region,''))<>''
   and not exists(select 1 from public.depots e where e.archived_at is null
     and upper(btrim(e.region))=upper(btrim(d.region)) and not rc_private.can_access(e.id))
 ) r),'[]'::jsonb), 'minPasswordLength',8,'maxPasswordBytes',72);
$$;

-- Passwords never reach SQL or the idempotency ledger. The Edge Function validates them.
create or replace function rc_private.registration_plan(p_payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare p jsonb; code text; peran text; home uuid; item text; target uuid; r record; rid uuid;
begin
 if not rc_private.is_manager() then raise exception 'Supervisor atau System Manager diperlukan' using errcode='42501'; end if;
 if p_payload is null or jsonb_typeof(p_payload)<>'object' or octet_length(p_payload::text)>8000 then raise exception 'Payload registrasi tidak sah'; end if;
 rid:=(p_payload->>'request_id')::uuid;
 if rid is null then raise exception 'Request ID wajib diisi'; end if;
 code:=upper(btrim(coalesce(p_payload->>'user_code','')));
 peran:=lower(btrim(coalesce(p_payload->>'role','')));
 if peran='non-osc' then peran:='others'; end if;
 if code !~ '^[A-Z0-9._-]{1,100}$' then raise exception 'User ID tidak sah'; end if;
 if length(btrim(coalesce(p_payload->>'full_name',''))) not between 1 and 200 then raise exception 'Nama lengkap wajib diisi (maksimal 200 karakter)'; end if;
 if length(coalesce(p_payload->>'business_email',''))>320 or btrim(coalesce(p_payload->>'business_email','')) !~ '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$' then raise exception 'Email kantor tidak sah'; end if;
 if not exists(select 1 from jsonb_array_elements(rc_private.registration_roles()) x where x->>'code'=peran) then raise exception 'Role tidak dikenali'; end if;
 if peran='system manager' and not rc_private.is_system_manager() then raise exception 'Hanya System Manager dapat membuat System Manager' using errcode='42501'; end if;
 if length(coalesce(p_payload->>'department',''))>200 then raise exception 'Departemen terlalu panjang'; end if;
 foreach item in array array['depot_codes','osc_codes','regions'] loop
  if p_payload ? item and jsonb_typeof(p_payload->item)<>'array' then raise exception 'Mapping % harus berupa array',item; end if;
  if exists(select 1 from jsonb_array_elements(coalesce(p_payload->item,'[]')) x where jsonb_typeof(x)<>'string') then raise exception 'Mapping % harus berupa teks',item; end if;
 end loop;
 p:=jsonb_build_object('request_id',rid,'user_code',code,'role',peran,
  'full_name',btrim(p_payload->>'full_name'),'business_email',lower(btrim(p_payload->>'business_email')),
  'department',btrim(coalesce(p_payload->>'department','')),'home_depot',upper(btrim(coalesce(p_payload->>'home_depot',''))),
  'depot_codes',coalesce((select jsonb_agg(v order by v) from (select distinct upper(btrim(value)) v from jsonb_array_elements_text(coalesce(p_payload->'depot_codes','[]'))) t where v<>''),'[]'),
  'osc_codes',coalesce((select jsonb_agg(v order by v) from (select distinct upper(btrim(value)) v from jsonb_array_elements_text(coalesce(p_payload->'osc_codes','[]'))) t where v<>''),'[]'),
  'regions',coalesce((select jsonb_agg(v order by v) from (select distinct upper(btrim(value)) v from jsonb_array_elements_text(coalesce(p_payload->'regions','[]'))) t where v<>''),'[]'));
 select * into r from rc_private.managed_registrations where request_id=rid;
 if found then
  if r.actor_id<>(select auth.uid()) or r.payload<>p then raise exception 'Request ID sudah digunakan untuk data lain'; end if;
  return p||jsonb_build_object('completed_id',r.profile_id);
 end if;
 if exists(select 1 from public.profiles where upper(user_code)=code) then raise exception 'User ID sudah terdaftar'; end if;
 select id into home from public.depots where depot_code=p->>'home_depot' and archived_at is null;
 if home is null then raise exception 'Pilih depot asal yang valid'; end if;
 if not rc_private.can_access(home) then raise exception 'Depot asal di luar yurisdiksi Anda' using errcode='42501'; end if;
 if peran in('admin','osc','others','finance','depot head') then
  if jsonb_array_length(p->'depot_codes')=0 then raise exception 'Pilih minimal satu depot yurisdiksi'; end if;
  if jsonb_array_length(p->'osc_codes')+jsonb_array_length(p->'regions')>0 then raise exception 'Mapping tidak sesuai role'; end if;
 elsif peran='supervisor' then
  if jsonb_array_length(p->'osc_codes')=0 then raise exception 'Pilih minimal satu OSC binaan'; end if;
  if jsonb_array_length(p->'depot_codes')+jsonb_array_length(p->'regions')>0 then raise exception 'Supervisor memperoleh depot melalui OSC'; end if;
 elsif peran='management' then
  if jsonb_array_length(p->'regions')=0 then raise exception 'Pilih minimal satu region'; end if;
  if jsonb_array_length(p->'depot_codes')+jsonb_array_length(p->'osc_codes')>0 then raise exception 'Management memperoleh depot melalui region'; end if;
 elsif jsonb_array_length(p->'depot_codes')+jsonb_array_length(p->'osc_codes')+jsonb_array_length(p->'regions')>0 then raise exception 'System Manager tidak memerlukan mapping';
 end if;
 for item in select jsonb_array_elements_text(p->'depot_codes') loop
  select id into target from public.depots where depot_code=item and archived_at is null;
  if target is null or not rc_private.can_access(target) then raise exception 'Depot % tidak valid atau di luar yurisdiksi',item using errcode='42501'; end if;
 end loop;
 for item in select jsonb_array_elements_text(p->'osc_codes') loop
  select id into target from public.profiles where user_code=item and role='osc' and status='active';
  if target is null or not rc_private.can_manage_user(target) then raise exception 'OSC % tidak valid atau di luar yurisdiksi',item using errcode='42501'; end if;
 end loop;
 for item in select jsonb_array_elements_text(p->'regions') loop
  if not exists(select 1 from public.depots where upper(btrim(region))=item and archived_at is null)
   or exists(select 1 from public.depots where upper(btrim(region))=item and archived_at is null and not rc_private.can_access(id)) then
   raise exception 'Region % tidak valid atau di luar yurisdiksi',item using errcode='42501'; end if;
 end loop;
 return p;
end $$;
create or replace function public.rc_prepare_registration(p_payload jsonb) returns jsonb
language sql security invoker set search_path='' as $$ select rc_private.registration_plan(p_payload); $$;
revoke all on function public.rc_prepare_registration(jsonb) from public,anon;
grant execute on function public.rc_prepare_registration(jsonb) to authenticated;
revoke all on function rc_private.registration_plan(jsonb) from public,anon;
grant execute on function rc_private.registration_plan(jsonb) to authenticated;

-- Only Auth Admin may set app_metadata. Browser-controlled user_metadata is never trusted
-- for activation, creator identity, module permissions or assignment.
create or replace function rc_private.provision_managed_registration(p_id uuid,p_envelope jsonb) returns void
language plpgsql security definer set search_path='' as $$
declare actor uuid; p jsonb; item text; old_claims text; old_sub text; home uuid;
begin
 actor:=(p_envelope->>'actor_id')::uuid;
 if actor is null then raise exception 'Creator identity missing'; end if;
 old_claims:=current_setting('request.jwt.claims',true); old_sub:=current_setting('request.jwt.claim.sub',true);
 perform set_config('request.jwt.claims',jsonb_build_object('sub',actor,'role','authenticated')::text,true);
 perform set_config('request.jwt.claim.sub',actor::text,true);
 p:=rc_private.registration_plan(p_envelope->'payload');
 if p ? 'completed_id' then raise exception 'Registration already completed'; end if;
 select id into home from public.depots where depot_code=p->>'home_depot';
 insert into public.profiles(id,user_code,full_name,business_email,role,status,suffix_num,must_change_password,
   requested_role,requested_depot,home_depot_id,department,reviewed_by,reviewed_at)
 values(p_id,p->>'user_code',p->>'full_name',p->>'business_email',p->>'role','active',rc_private.next_suffix(),true,
   p->>'role',p->>'home_depot',home,p->>'department',actor,now());
 for item in select jsonb_array_elements_text(p->'depot_codes') loop
  insert into public.user_depot_grants(user_id,depot_id,kind,granted_by)
   select p_id,id,case when p->>'role'='admin' then 'rp' else 'assigned' end,actor from public.depots where depot_code=item;
 end loop;
 for item in select jsonb_array_elements_text(p->'osc_codes') loop
  insert into public.user_supervision(supervisor_id,osc_id) select p_id,id from public.profiles where user_code=item;
 end loop;
 for item in select jsonb_array_elements_text(p->'regions') loop
  insert into public.user_region_access(user_id,region,granted_by) values(p_id,item,actor);
 end loop;
 if p->>'role'='system manager' then insert into public.user_permissions select p_id,code from public.permissions; end if;
 perform rc_private.rebuild_with_supervisors(p_id);
 insert into rc_private.managed_registrations(request_id,actor_id,profile_id,payload) values((p->>'request_id')::uuid,actor,p_id,p);
 insert into public.activity_logs(actor_id,event_type,entity_id,details) values(actor,'account_created',p_id,
   jsonb_build_object('user_code',p->>'user_code','role',p->>'role','request_id',p->>'request_id'));
 perform set_config('request.jwt.claims',coalesce(old_claims,''),true);
 perform set_config('request.jwt.claim.sub',coalesce(old_sub,''),true);
exception when others then
 perform set_config('request.jwt.claims',coalesce(old_claims,''),true);
 perform set_config('request.jwt.claim.sub',coalesce(old_sub,''),true); raise;
end $$;
revoke all on function rc_private.provision_managed_registration(uuid,jsonb) from public,anon,authenticated;

create or replace function rc_private.can_manage_user(p_target uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select p_target is not null and rc_private.is_manager() and (
  rc_private.is_system_manager() or (
   exists(select 1 from public.profiles p where p.id=p_target and p.role<>'system manager' and p.status<>'deleted')
   and (
    (exists(select 1 from rc_private.effective_depots(p_target)) and not exists(
      select 1 from rc_private.effective_depots(p_target) d where not rc_private.can_access(d)))
    or exists(select 1 from public.profiles p join public.depots d on d.depot_code=p.requested_depot
      where p.id=p_target and p.status='pending' and rc_private.can_access(d.id))
    or (not exists(select 1 from rc_private.effective_depots(p_target)) and exists(
      select 1 from public.profiles p where p.id=p_target and p.home_depot_id is not null and rc_private.can_access(p.home_depot_id)))
   )
  )
 );
$$;

create or replace function rc_private.can_view_managed_user(p_target uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select (rc_private.is_manager() or rc_private.can_access(null,'manage_access')) and (
   p_target=(select auth.uid()) or rc_private.can_manage_user(p_target)
   or (not rc_private.is_manager() and exists(select 1 from rc_private.effective_depots(p_target) d where rc_private.can_access(d)))
 );
$$;
revoke all on function rc_private.can_view_managed_user(uuid) from public,anon;
grant execute on function rc_private.can_view_managed_user(uuid) to authenticated;

create or replace function rc_private.review_registration(p_profile uuid,p_approve boolean,p_note text default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare target public.profiles%rowtype; assigned text; peran text; depot uuid;
begin
 if not rc_private.is_manager() or not rc_private.can_manage_user(p_profile) then raise exception 'Pendaftaran di luar kewenangan Anda' using errcode='42501'; end if;
 if p_profile=(select auth.uid()) then raise exception 'Tidak dapat menyetujui akun sendiri'; end if;
 if p_approve is null then raise exception 'Keputusan wajib diisi'; end if;
 select * into target from public.profiles where id=p_profile for update;
 if not found or target.status<>'pending' then raise exception 'Pendaftaran tidak ditemukan atau sudah diproses'; end if;
 if length(coalesce(p_note,''))>1000 then raise exception 'Catatan terlalu panjang'; end if;
 if p_approve then
  select id into depot from public.depots where depot_code=target.requested_depot and archived_at is null;
  if depot is null or not rc_private.can_access(depot) then raise exception 'Depot pendaftaran tidak valid atau di luar yurisdiksi' using errcode='42501'; end if;
  peran:=case when target.requested_role='non-osc' then 'others' when target.requested_role='system manager' then 'admin' else target.requested_role end;
  if not exists(select 1 from jsonb_array_elements(rc_private.registration_roles()) x where x->>'code'=peran) then raise exception 'Role pendaftaran tidak valid'; end if;
  assigned:=rc_private.next_suffix();
  update public.profiles set status='active',role=peran,suffix_num=assigned,home_depot_id=depot,
    reviewed_by=(select auth.uid()),reviewed_at=now(),review_note=p_note where id=p_profile;
  if peran in('admin','osc','others','finance','depot head') then
   insert into public.user_depot_grants(user_id,depot_id,kind,granted_by)
    values(p_profile,depot,case when peran='admin' then 'rp' else 'assigned' end,(select auth.uid())) on conflict do nothing;
  end if;
  -- Supervisor/Management require explicit OSC/region selection in Edit Access.
  perform rc_private.rebuild_with_supervisors(p_profile);
 else
  update public.profiles set status='rejected',reviewed_by=(select auth.uid()),reviewed_at=now(),review_note=p_note where id=p_profile;
 end if;
 insert into public.activity_logs(actor_id,event_type,entity_id,details) values((select auth.uid()),
  case when p_approve then 'registration_approved' else 'registration_rejected' end,p_profile,jsonb_build_object('role',peran,'suffix_num',assigned));
 return jsonb_build_object('status','success','suffix_num',assigned,'role',peran,
  'message',case when p_approve then 'Pendaftaran disetujui. Lengkapi hak modul dan yurisdiksi melalui Edit Akses.' else 'Pendaftaran ditolak.' end);
end $$;

CREATE OR REPLACE FUNCTION rc_private.handle_new_user()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare meta jsonb:=coalesce(new.raw_user_meta_data,'{}'::jsonb);
 v_code text; v_name text; v_email text; v_role text; v_depot text; is_first boolean;
 v_depot_id uuid;
begin
 if new.raw_app_meta_data ? 'rc_managed_registration' then
  perform rc_private.provision_managed_registration(new.id,new.raw_app_meta_data->'rc_managed_registration');
  return new;
 end if;
 if meta->>'user_code' is null then
  raise exception 'Akun harus dibuat lewat portal RC (tombol Daftar), atau lewat SQL/Admin API yang menyertakan user_metadata berisi user_code, full_name, business_email dan requested_role. Tombol Add user pada Dashboard tidak menyertakan data itu.';
 end if;
 v_code:=upper(btrim(coalesce(meta->>'user_code','')));
 v_name:=btrim(coalesce(meta->>'full_name',''));
 v_email:=lower(btrim(coalesce(meta->>'business_email','')));
 v_role:=lower(btrim(coalesce(meta->>'requested_role','')));
 if v_role='non-osc' then v_role:='others'; end if;
 v_depot:=btrim(coalesce(meta->>'requested_depot',''));

 if v_code='' or length(v_code)>100 or v_code !~ '^[A-Z0-9._-]+$' then
  raise exception 'User ID wajib diisi, maksimal 100 karakter, hanya huruf, angka, titik, garis bawah dan strip';
 end if;
 if v_name='' or length(v_name)>200 then raise exception 'Nama lengkap wajib diisi'; end if;
 if v_email='' or length(v_email)>320 or v_email !~ '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$'
  then raise exception 'Email kantor tidak valid'; end if;
 if v_role not in('admin','osc','others','finance','supervisor','system manager','depot head','management') then
  raise exception 'Role yang diminta tidak dikenali'; end if;
 if exists(select 1 from public.profiles where user_code=v_code) then
  raise exception 'User ID sudah terdaftar'; end if;

 lock table public.profiles in exclusive mode;
 select not exists(select 1 from public.profiles) into is_first;

 -- Pendaftar pertama boleh tanpa depot, karena ia menjadi System Manager atas seluruh depot.
 if not is_first then
  select id into v_depot_id from public.depots where depot_code=v_depot;
  if v_depot_id is null then
   raise exception 'Depot "%" tidak ada di master depot. Pilih depot dari daftar yang tersedia.',v_depot;
  end if;
 end if;

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
  insert into public.profiles(id,user_code,full_name,business_email,role,status,suffix_num,
    must_change_password,requested_role,requested_depot)
  values(new.id,v_code,v_name,v_email,v_role,'pending','000',false,v_role,v_depot);
  insert into public.activity_logs(actor_id,event_type,entity_id,details)
  values(new.id,'registration_submitted',new.id,
    jsonb_build_object('user_code',v_code,'requested_role',v_role,'requested_depot',v_depot));
 end if;
 return new;
end $function$
;
CREATE OR REPLACE FUNCTION rc_private.next_suffix()
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare n integer;
begin
 perform pg_advisory_xact_lock(hashtextextended('rc_suffix_allocation',0));
 for n in 1..999 loop
  if not exists(select 1 from public.profiles where suffix_num=lpad(n::text,3,'0') and status='active')
   and not exists(select 1 from rc_private.batch_counters where suffix=lpad(n::text,3,'0'))
  then return lpad(n::text,3,'0'); end if;
 end loop;
 raise exception 'Tidak ada suffix batch tersisa';
end $function$
;
CREATE OR REPLACE FUNCTION rc_private.set_role(p_user uuid, p_role text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_role text; v_lama text;
begin
  v_role:=lower(btrim(coalesce(p_role,'')));
  if v_role not in('admin','osc','others','finance','supervisor','system manager','depot head','management') then
    raise exception 'Role "%" tidak dikenali',p_role; end if;
  -- Hanya System Manager yang boleh mengangkat System Manager. Ini aturan yang diminta
  -- pemilik sejak awal dan tidak dilonggarkan oleh perluasan wewenang supervisor.
  if v_role='system manager' and not rc_private.is_system_manager() then
    raise exception 'Hanya System Manager yang dapat memberikan peran System Manager'
      using errcode='42501'; end if;
  if not rc_private.can_manage_user(p_user) then
    raise exception 'Pengguna ini di luar wilayah Anda' using errcode='42501'; end if;

  select role into v_lama from public.profiles where id=p_user for update;
  if not found then raise exception 'User tidak ditemukan'; end if;
  if v_lama=v_role then return; end if;
  if p_user=(select auth.uid()) then raise exception 'Tidak dapat mengubah peran sendiri'; end if;

  update public.profiles set role=v_role where id=p_user;
  insert into public.activity_logs(actor_id,event_type,entity_id,details)
  values((select auth.uid()),'role_changed',p_user,jsonb_build_object('dari',v_lama,'menjadi',v_role));
end $function$
;
CREATE OR REPLACE FUNCTION public.rc_update_access(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_target uuid; v_kode text; v_role text; v_role_lama text; v_status text;
  v_perms text[]; v_depot uuid; c text; n_rp int:=0; n_as int:=0; n_osc int:=0;
  v_tersisip int;
  v_diri boolean;
begin
  if not rc_private.is_manager() then
    raise exception 'Hanya System Manager atau Supervisor yang dapat mengubah akses'
      using errcode='42501'; end if;
  if p_payload is null or jsonb_typeof(p_payload)<>'object' then
    raise exception 'Payload tidak sah'; end if;

  v_kode:=upper(btrim(coalesce(p_payload->>'userId','')));
  if v_kode='' then raise exception 'User ID wajib diisi'; end if;
  select id, role into v_target, v_role_lama from public.profiles where user_code=v_kode for update;
  if v_target is null then
    raise exception 'Pengguna "%" tidak ada di daftar akun',v_kode; end if;

  v_diri := (v_target = (select auth.uid()));

  -- Menyunting diri sendiri kini diizinkan, tetapi HANYA untuk System Manager dan HANYA pada
  -- bagian identitas. Seorang supervisor tetap tidak dapat menyunting dirinya sendiri.
  if v_diri and not rc_private.is_system_manager() then
    raise exception 'Tidak dapat mengubah akses sendiri'; end if;
  if not v_diri and not rc_private.can_manage_user(v_target) then
    raise exception 'Pengguna "%" berada di luar wilayah Anda',v_kode using errcode='42501'; end if;
  if (select status from public.profiles where id=v_target)='pending' then
    raise exception 'Setujui pendaftaran ini lebih dahulu di kotak masuk approval'; end if;

  -- Validate every proposed scope before any write, including direct RPC callers.
  if not v_diri then
   for c in select value from jsonb_array_elements_text(coalesce(p_payload->'rpDepots','[]')||coalesce(p_payload->'assignedDepots','[]')) loop
    v_depot:=public.rc_legacy_depot_id(btrim(c));
    if v_depot is null or not rc_private.can_access(v_depot) then raise exception 'Depot di luar yurisdiksi Anda' using errcode='42501'; end if;
   end loop;
   for c in select jsonb_array_elements_text(coalesce(p_payload->'assignedOsc','[]')) loop
    if not exists(select 1 from public.profiles p where p.user_code=upper(btrim(c)) and p.role='osc' and p.status='active' and rc_private.can_manage_user(p.id)) then
     raise exception 'OSC tidak valid atau di luar yurisdiksi Anda' using errcode='42501'; end if;
   end loop;
  end if;
  -- ---- Identitas, satu-satunya bagian yang boleh disunting atas diri sendiri --------------
  if coalesce(btrim(p_payload->>'fullName'),'')<>'' then
    update public.profiles set full_name=btrim(p_payload->>'fullName') where id=v_target;
  end if;
  if coalesce(btrim(p_payload->>'email'),'')<>'' then
    update public.profiles set business_email=lower(btrim(p_payload->>'email')) where id=v_target;
  end if;
  if coalesce(btrim(p_payload->>'suffix'),'')<>'' then
    perform rc_private.set_suffix(v_kode,btrim(p_payload->>'suffix'));
  end if;

  if v_diri then
    -- Berhenti di sini. Peran, status, hak modul dan yurisdiksi sendiri tidak disentuh sama
    -- sekali, sehingga tidak ada jalan untuk mengunci diri keluar lewat layar ini.
    insert into public.activity_logs(actor_id,event_type,entity_id,details)
    values((select auth.uid()),'identity_self_updated',v_target,
           jsonb_build_object('user',v_kode));
    return jsonb_build_object('status','success','role',v_role_lama,
      'jumlahPermission',(select count(*) from public.user_permissions where user_id=v_target),
      'jumlahDepot',(select count(*) from public.user_depot_access where user_id=v_target),
      'pesan','Identitas Anda diperbarui. Peran, hak modul dan yurisdiksi sendiri sengaja tidak dapat diubah dari sini.');
  end if;

  -- ---- Selebihnya hanya berlaku untuk pengguna lain ----------------------------------------
  v_role:=lower(btrim(coalesce(p_payload->>'role','')));
  if v_role<>'' and v_role<>v_role_lama then
    perform rc_private.set_role(v_target,v_role);
  else
    v_role:=v_role_lama;
  end if;

  v_status:=case when not coalesce(p_payload->'auth','{}') ? 'i' then (select status from public.profiles where id=v_target)
    when lower(coalesce(p_payload->'auth'->>'i','')) in('active','approved','ok') then 'active' else 'inactive' end;
  if v_role<>'admin' and jsonb_array_length(coalesce(p_payload->'rpDepots','[]'))>0 then raise exception 'RP hanya untuk Admin'; end if;
  if v_role not in('osc','others','finance','depot head') and jsonb_array_length(coalesce(p_payload->'assignedDepots','[]'))>0 then raise exception 'Mapping depot tidak sesuai role'; end if;
  if v_role<>'supervisor' and jsonb_array_length(coalesce(p_payload->'assignedOsc','[]'))>0 then raise exception 'Mapping OSC hanya untuk Supervisor'; end if;
  if v_role<>'management' and jsonb_array_length(coalesce(p_payload->'regions','[]'))>0 then raise exception 'Region hanya untuk Management'; end if;
  if v_role<>'management' then delete from public.user_region_access where user_id=v_target; end if;

  -- Yurisdiksi milik peran LAIN selalu dilepas, pada setiap penyimpanan. Inilah yang
  -- memastikan sebuah akun tidak pernah memegang dua yurisdiksi sekaligus, termasuk
  -- ketika perannya baru saja berubah dan layar hanya mengirim yurisdiksi yang baru.
  if v_role <> 'supervisor' then
    delete from public.user_supervision where supervisor_id=v_target;
  end if;
  if v_role <> 'admin' then
    delete from public.user_depot_grants where user_id=v_target and kind='rp';
  end if;
  if v_role not in ('osc','others','finance','depot head') then
    delete from public.user_depot_grants where user_id=v_target and kind='assigned';
  end if;
  -- System Manager dan Supervisor memperoleh depot lewat perannya, jadi grant apa pun
  -- pada keduanya hanya menjadi sumber kebenaran kedua yang akan menyimpang.
  if v_role in ('system manager','supervisor') then
    delete from public.user_depot_grants where user_id=v_target;
  end if;

  begin
    if p_payload ? 'homeDepot' then
      -- Depot rumah adalah keterangan identitas, bukan pemberian wewenang, sehingga ia
      -- tidak lagi menjadi baris grant dan tidak ikut menentukan yurisdiksi.
      if coalesce(btrim(p_payload->>'homeDepot'),'')='' then
        update public.profiles set home_depot_id=null where id=v_target;
      else
        update public.profiles
           set home_depot_id=public.rc_legacy_depot_id(btrim(p_payload->>'homeDepot'))
         where id=v_target;
      end if;
    end if;

    if p_payload ? 'rpDepots' then
      delete from public.user_depot_grants where user_id=v_target and kind='rp';
      for c in select jsonb_array_elements_text(p_payload->'rpDepots') loop
        if btrim(c)<>'' then
          v_depot:=public.rc_legacy_depot_id(btrim(c));
          insert into public.user_depot_grants(user_id,depot_id,kind,granted_by)
          values(v_target,v_depot,'rp',(select auth.uid()))
          on conflict(user_id,depot_id) do nothing;
          n_rp:=n_rp+1;
        end if;
      end loop;
    end if;

    if p_payload ? 'assignedDepots' then
      delete from public.user_depot_grants where user_id=v_target and kind='assigned';
      for c in select jsonb_array_elements_text(p_payload->'assignedDepots') loop
        if btrim(c)<>'' then
          v_depot:=public.rc_legacy_depot_id(btrim(c));
          insert into public.user_depot_grants(user_id,depot_id,kind,granted_by)
          values(v_target,v_depot,'assigned',(select auth.uid()))
          on conflict(user_id,depot_id) do nothing;
          n_as:=n_as+1;
        end if;
      end loop;
    end if;

    if p_payload ? 'assignedOsc' then
      delete from public.user_supervision where supervisor_id=v_target;
      for c in select jsonb_array_elements_text(p_payload->'assignedOsc') loop
        if btrim(c)<>'' then
          insert into public.user_supervision(supervisor_id,osc_id)
          select v_target,p2.id from public.profiles p2
           where p2.user_code=upper(btrim(c)) and p2.id<>v_target and p2.role = 'osc'
          on conflict do nothing;
          -- "insert ... select" TIDAK gagal ketika select-nya kosong; ia hanya menyisipkan
          -- nol baris. Tanpa pemeriksaan ini, kode yang tidak dikenal dilaporkan sebagai
          -- keberhasilan dan tidak ada yang tersimpan.
          get diagnostics v_tersisip = row_count;
          if v_tersisip = 0 then
            if upper(btrim(c)) = v_kode then
              raise exception 'Akun % tidak dapat membina dirinya sendiri sebagai OSC.', btrim(c);
            else
              raise exception 'Akun % tidak dapat dibina: ia harus ada dan berperan OSC. Supervisor hanya membina OSC di bawahnya.', btrim(c);
            end if;
          end if;
          n_osc:=n_osc+v_tersisip;
        end if;
      end loop;
    end if;
  end;

  if v_role='system manager' then
    v_perms:=array(select code from public.permissions);
  else
    v_perms:=array(select code from (values
      ('j','upload_claim'),('k','release_claim'),('l','process_claim'),('m','view_analytics'),
      ('n','manage_access'),('p','view_master_depot'),('s','bulk_process'),('logs','view_logs'),
      ('keyMaster','manage_key_master'),('compilation','view_compilation'),
      ('archiveCompilation','archive_compilation'),
      ('report','view_report'),('timetable','manage_timetable'),('approval','approve_claim')
    ) as m(letter,code)
    where lower(coalesce(p_payload->'auth'->>m.letter,'no')) in('yes','true','approved','visible')
      or (not coalesce(p_payload->'auth','{}') ? m.letter and exists(select 1 from public.user_permissions up where up.user_id=v_target and up.permission_code=m.code)));
  end if;

  delete from public.user_permissions where user_id=v_target;
  insert into public.user_permissions select v_target,x from unnest(v_perms) x group by x;
  update public.profiles set status=v_status where id=v_target;

  if p_payload ? 'regions' then
   perform rc_private.tetapkan_region(v_target, p_payload->'regions');
 end if;
 perform rc_private.rebuild_with_supervisors(v_target);

  if coalesce((p_payload->>'approvePin')::boolean,false) then
    update public.profiles set must_change_password=true where id=v_target;
  end if;

  insert into public.activity_logs(actor_id,event_type,entity_id,details)
  values((select auth.uid()),'access_changed',v_target,jsonb_build_object(
    'status',v_status,'role',v_role,'permissions',coalesce(array_length(v_perms,1),0),
    'rp',n_rp,'assigned',n_as,'osc',n_osc));

  return jsonb_build_object('status','success','role',v_role,
    'jumlahPermission',coalesce(array_length(v_perms,1),0),
    'jumlahDepot',(select count(*) from public.user_depot_access where user_id=v_target),
    'pesan','Akses '||v_kode||' berhasil diperbarui');
end $function$
;
CREATE OR REPLACE FUNCTION rc_private.tetapkan_region(p_user uuid, p_regions jsonb)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare n int := 0; v text;
begin
  if p_regions is null or jsonb_typeof(p_regions) <> 'array' then return 0; end if;
  if not rc_private.boleh_tetapkan_region() then
    raise exception 'Hanya Supervisor atau System Manager yang dapat menetapkan region'
      using errcode='42501';
  end if;

  if p_user=(select auth.uid()) or not rc_private.can_manage_user(p_user) then raise exception 'Pengguna di luar kewenangan Anda' using errcode='42501'; end if;
  if (select role from public.profiles where id=p_user)<>'management' and jsonb_array_length(p_regions)>0 then raise exception 'Region hanya untuk Management'; end if;
  if exists(select 1 from public.depots d where upper(btrim(d.region)) in(select upper(btrim(value)) from jsonb_array_elements_text(p_regions)) and not rc_private.can_access(d.id)) then raise exception 'Region di luar yurisdiksi Anda' using errcode='42501'; end if;
  delete from public.user_region_access where user_id = p_user;
  for v in select upper(btrim(x #>> '{}')) from jsonb_array_elements(p_regions) x loop
    if v is null or v = '' then continue; end if;
    -- Hanya region yang benar-benar ada di Depot Master. Menetapkan region yang tidak dipakai
    -- depot mana pun hanya menghasilkan jangkauan kosong, dan kekosongan itu jauh lebih sulit
    -- dilacak daripada penolakan di sini.
    if not exists (select 1 from public.depots d
                    where upper(btrim(coalesce(d.region,''))) = v) then
      raise exception 'Region "%" tidak ada pada Depot Master', v;
    end if;
    insert into public.user_region_access(user_id, region, granted_by)
    values (p_user, v, (select auth.uid()))
    on conflict (user_id, region) do nothing;
    n := n + 1;
  end loop;

  -- Jangkauan depot dihitung ulang, karena ia disimpan - bukan dihitung setiap kali dibaca.
  perform rc_private.rebuild_depot_access(p_user);
  return n;
end $function$
;
CREATE OR REPLACE FUNCTION rc_private.legacy_users()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 select coalesce(jsonb_agg(jsonb_build_object(
   'id',p.id,'userId',p.user_code,
   'nama',p.full_name,'namaLengkap',p.full_name,'fullName',p.full_name,
   'email',p.business_email,
   'department',coalesce(p.department,''),'role',p.role,'sysRole',p.role,'suffix',p.suffix_num,
   'activation',case p.status when 'active' then 'Active' when 'pending' then 'Pending'
     when 'rejected' then 'Rejected' else 'Nonactive' end,
   'mustChangePin',p.must_change_password,
   'requestedRole',coalesce(p.requested_role,''),'requestedDepot',coalesce(p.requested_depot,''),
   'permissions',array(select permission_code from public.user_permissions where user_id=p.id),
   'auth',(select jsonb_object_agg(m.letter,
             case when exists(select 1 from public.user_permissions up
                               where up.user_id=p.id and up.permission_code=m.code)
                  then 'Yes' else 'No' end)
           from (values ('j','upload_claim'),('k','release_claim'),('l','process_claim'),
                        ('m','view_analytics'),('n','manage_access'),('p','view_master_depot'),
                        ('s','bulk_process'),('logs','view_logs'),('keyMaster','manage_key_master'),
                        ('compilation','view_compilation'),('archiveCompilation','archive_compilation'),
                        ('report','view_report'),('timetable','manage_timetable'),('approval','approve_claim')
                ) as m(letter,code))
         || jsonb_build_object('i',case p.status when 'active' then 'Active' else 'Inactive' end),
   'kodeDepot',coalesce((select d.depot_code from public.depots d where d.id=p.home_depot_id),''),
   'namaDepot',coalesce((select d.depot_name from public.depots d where d.id=p.home_depot_id),''),
   'depotName',coalesce((select d.depot_name from public.depots d where d.id=p.home_depot_id),''),
   'rpDepots',array(select d.depot_code from public.user_depot_grants g
      join public.depots d on d.id=g.depot_id where g.user_id=p.id and g.kind='rp' order by d.depot_code),
   'assignedDepots',array(select d.depot_code from public.user_depot_grants g
      join public.depots d on d.id=g.depot_id where g.user_id=p.id and g.kind='assigned' order by d.depot_code),
   'assignedOsc',array(select o.user_code from public.user_supervision s
      join public.profiles o on o.id=s.osc_id where s.supervisor_id=p.id order by o.user_code),
   'regions',array(select region from public.user_region_access where user_id=p.id order by region),
   'depotCodes',array(select d.depot_code from public.user_depot_access a
      join public.depots d on d.id=a.depot_id where a.user_id=p.id order by d.depot_code),
   'depotIds',array(select depot_id from public.user_depot_access where user_id=p.id))
   order by p.status,p.user_code),'[]'::jsonb)
 from public.profiles p
 where p.status<>'deleted' and rc_private.can_view_managed_user(p.id);
$function$
;
CREATE OR REPLACE FUNCTION rc_private.legacy_profile_requests()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 select coalesce(jsonb_agg(x order by x->>'tglRequest' desc),'[]'::jsonb) from (
  select jsonb_build_object(
    'id','signup:'||p.id,'namaDepot',coalesce(nullif(p.requested_depot,''),'Depot belum ditentukan'),
    'kodeDepot','','requesterId',p.user_code,
    'changes',jsonb_strip_nulls(jsonb_build_object(
      'Pendaftaran akun baru',p.full_name,'Email kantor',p.business_email,
      'Role diminta',p.requested_role,'Depot diminta',nullif(p.requested_depot,''))),
    'tglRequest',to_char(p.registered_at at time zone 'Asia/Jakarta','DD/MM/YYYY HH24:MI')) as x
  from public.profiles p where p.status='pending' and rc_private.can_view_managed_user(p.id)
  union all
  select jsonb_build_object(
    'id','profile:'||r.id,'namaDepot',d.depot_name,'kodeDepot',d.depot_code,
    'requesterId',coalesce(p.user_code,''),'changes',r.changes,
    'tglRequest',to_char(r.created_at at time zone 'Asia/Jakarta','DD/MM/YYYY HH24:MI')) as x
  from public.profile_change_requests r
  join public.depots d on d.id=r.depot_id
  left join public.profiles p on p.id=r.requester_id
  where r.status='pending' and rc_private.can_access(r.depot_id)) t;
$function$
;
CREATE OR REPLACE FUNCTION public.rc_legacy_manageable()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
begin
 if not rc_private.is_manager() and not rc_private.can_access(null,'manage_access') then
   raise exception 'Manager required' using errcode='42501'; end if;
 return jsonb_build_object('status','success',
  'users',rc_private.legacy_users(),
  'allDepots',coalesce((select jsonb_agg(jsonb_build_object('kode',depot_code,'nama',depot_name,'link',coalesce(master_link,'')) order by depot_code) from public.depots where archived_at is null and rc_private.can_access(id)),'[]'::jsonb),
  'managedDepots',coalesce((select jsonb_agg(jsonb_build_object('kode',depot_code,'nama',depot_name,'link',coalesce(master_link,'')) order by depot_code) from public.depots where archived_at is null and rc_private.can_access(id)),'[]'::jsonb),
  'isSystemManager',rc_private.is_system_manager(),'canEdit',rc_private.is_manager(),
  'registrationOptions',rc_private.registration_options(),
  'profileRequests',rc_private.legacy_profile_requests());
end $function$
;
CREATE OR REPLACE FUNCTION rc_private.review_profile(p_id uuid, p_approve boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r public.profile_change_requests%rowtype; begin
 if not rc_private.is_manager() then raise exception 'Manager required' using errcode='42501'; end if;
 select * into strict r from public.profile_change_requests where id=p_id for update;
 if not rc_private.can_access(r.depot_id,'manage_access') or r.requester_id=auth.uid() then raise exception 'Independent approver required' using errcode='42501'; end if;
 if r.status<>'pending' or p_approve is null then raise exception 'Request already reviewed or decision missing'; end if;
 if p_approve then update public.depots set address=coalesce(r.changes->>'address',address),
 master_link=coalesce(r.changes->>'master_link',master_link),depot_name=coalesce(r.changes->>'depot_name',depot_name) where id=r.depot_id; end if;
 update public.profile_change_requests set status=case when p_approve then 'approved' else 'rejected' end,reviewer_id=auth.uid(),reviewed_at=now() where id=r.id;
 insert into public.activity_logs(actor_id,depot_id,event_type,entity_id) values(auth.uid(),r.depot_id,'profile_review',r.id);
end $function$
;
CREATE OR REPLACE FUNCTION rc_private.manage_user(p_user uuid, p_status text, p_permissions text[], p_depots uuid[])
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare luar text;
begin
 if not rc_private.is_manager() then raise exception 'Manager required' using errcode='42501'; end if;
 if not rc_private.can_manage_user(p_user) then raise exception 'Target outside jurisdiction' using errcode='42501'; end if;
 if (select status from public.profiles where id=p_user)='pending' then raise exception 'Review registration first'; end if;
 if p_user=auth.uid() then raise exception 'Tidak dapat mengubah akses sendiri'; end if;
 if p_status not in('active','inactive','rejected') or p_status is null
  or p_permissions is null or p_depots is null then raise exception 'Invalid access values'; end if;
 if exists(select 1 from unnest(p_permissions) x where not exists(select 1 from public.permissions where code=x))
 then raise exception 'Permission tidak dikenali'; end if;
 select string_agg(d.depot_code,', ') into luar from unnest(p_depots) x
  join public.depots d on d.id=x where not rc_private.can_access(x);
 if luar is not null then
  raise exception 'Depot di luar akses Anda: %',luar using errcode='42501'; end if;
 perform 1 from public.profiles where id=p_user for update;
 if not found then raise exception 'User not found'; end if;
 update public.profiles set status=p_status where id=p_user;
 delete from public.user_permissions where user_id=p_user;
 insert into public.user_permissions select p_user,x from unnest(p_permissions) x group by x;
 if (select role from public.profiles where id=p_user) in('supervisor','management','system manager') then raise exception 'Use rc_update_access for role-specific jurisdiction'; end if;
 delete from public.user_depot_grants where user_id=p_user;
 insert into public.user_depot_grants(user_id,depot_id,kind,granted_by)
 select p_user,x,case when (select role from public.profiles where id=p_user)='admin' then 'rp' else 'assigned' end,auth.uid() from unnest(p_depots) x group by x;
 perform rc_private.rebuild_with_supervisors(p_user);
 insert into public.activity_logs(actor_id,event_type,entity_id,details)
 values(auth.uid(),'access_changed',p_user,jsonb_build_object('status',p_status,
   'permissions',coalesce(array_length(p_permissions,1),0),
   'depots',coalesce(array_length(p_depots,1),0)));
end $function$
;
CREATE OR REPLACE FUNCTION public.rc_permission_catalog()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
begin
 if not rc_private.can_access(null) then raise exception 'Access denied' using errcode='42501'; end if;
 return jsonb_build_object('status','success','rows',jsonb_build_array(
  jsonb_build_object('key','j','code','upload_claim','modul','Claim Upload','sub','Mass, Manual, Open'),
  jsonb_build_object('key','k','code','release_claim','modul','Release','sub','Antrean Approved'),
  jsonb_build_object('key','l','code','process_claim','modul','Claim Process','sub','Claim to Finance dan Clearing'),
  jsonb_build_object('key','s','code','bulk_process','modul','Bulk Process','sub','Rebate langsung Done'),
  jsonb_build_object('key','m','code','view_analytics','modul','Analytics','sub','History dan Summary'),
  jsonb_build_object('key','p','code','view_master_depot','modul','Master Depot','sub','Link master per depot'),
  jsonb_build_object('key','n','code','manage_access','modul','Kelola Akses','sub','Akun, permission, depot'),
  jsonb_build_object('key','keyMaster','code','manage_key_master','modul','Key Master','sub','Customer, Campaign, dan Depot Master'),
  jsonb_build_object('key','compilation','code','view_compilation','modul','Document Center','sub','Lihat dan compile'),
  jsonb_build_object('key','archiveCompilation','code','archive_compilation','modul','Document Center','sub','Arsipkan baris'),
  jsonb_build_object('key','approval','code','approve_claim','modul','Management of Approval','sub','Approve dan reject sebelum Release'),
  jsonb_build_object('key','report','code','view_report','modul','Report','sub','Dashboard, Cost Center 1 dan 2'),
  jsonb_build_object('key','timetable','code','manage_timetable','modul','Timetable','sub','Tandai Not Achieved dan exclude campaign'),
  jsonb_build_object('key','logs','code','view_logs','modul','Log Aktivitas','sub','Riwayat tindakan')));
end $function$
;

notify pgrst,'reload schema';
