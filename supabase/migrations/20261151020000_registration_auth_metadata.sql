-- GoTrue Admin writes app_metadata after auth.users INSERT. Handle its UPDATE in the
-- same transaction; a failed scope validation must also roll back the Auth creation.
create or replace function rc_private.registration_plan(p_payload jsonb,p_existing uuid) returns jsonb
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
 if exists(select 1 from public.profiles where upper(user_code)=code and id is distinct from p_existing) then raise exception 'User ID sudah terdaftar'; end if;
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

revoke all on function rc_private.registration_plan(jsonb,uuid) from public,anon,authenticated;
create or replace function rc_private.registration_plan(p_payload jsonb) returns jsonb
language sql security definer set search_path='' as $$ select rc_private.registration_plan(p_payload,null::uuid); $$;
create or replace function rc_private.provision_managed_registration(p_id uuid,p_envelope jsonb) returns void
language plpgsql security definer set search_path='' as $$
declare actor uuid; p jsonb; item text; old_claims text; old_sub text; home uuid;
begin
 actor:=(p_envelope->>'actor_id')::uuid;
 if actor is null then raise exception 'Creator identity missing'; end if;
 old_claims:=current_setting('request.jwt.claims',true); old_sub:=current_setting('request.jwt.claim.sub',true);
 perform set_config('request.jwt.claims',jsonb_build_object('sub',actor,'role','authenticated')::text,true);
 perform set_config('request.jwt.claim.sub',actor::text,true);
 p:=rc_private.registration_plan(p_envelope->'payload',p_id);
 if p ? 'completed_id' then raise exception 'Registration already completed'; end if;
 select id into home from public.depots where depot_code=p->>'home_depot';
 if exists(select 1 from public.profiles where id=p_id) then
  if not exists(select 1 from public.profiles where id=p_id and status='pending' and user_code=p->>'user_code') then
   raise exception 'Managed registration requires a new pending profile'; end if;
  update public.profiles set full_name=p->>'full_name',business_email=p->>'business_email',role=p->>'role',status='active',
   suffix_num=rc_private.next_suffix(),must_change_password=true,requested_role=p->>'role',requested_depot=p->>'home_depot',
   home_depot_id=home,department=p->>'department',reviewed_by=actor,reviewed_at=now() where id=p_id;
  -- This event was produced by the insert trigger earlier in the same Auth Admin transaction.
  delete from public.activity_logs where actor_id=p_id and entity_id=p_id and event_type='registration_submitted';
 else
 insert into public.profiles(id,user_code,full_name,business_email,role,status,suffix_num,must_change_password,
   requested_role,requested_depot,home_depot_id,department,reviewed_by,reviewed_at)
 values(p_id,p->>'user_code',p->>'full_name',p->>'business_email',p->>'role','active',rc_private.next_suffix(),true,
   p->>'role',p->>'home_depot',home,p->>'department',actor,now());
 end if;
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


create or replace function rc_private.finish_managed_registration() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if new.raw_app_meta_data ? 'rc_managed_registration'
  and old.raw_app_meta_data->'rc_managed_registration' is distinct from new.raw_app_meta_data->'rc_managed_registration'
  and not exists(select 1 from rc_private.managed_registrations where profile_id=new.id) then
  perform rc_private.provision_managed_registration(new.id,new.raw_app_meta_data->'rc_managed_registration');
 end if;
 return new;
end $$;
revoke all on function rc_private.finish_managed_registration() from public,anon,authenticated;
drop trigger if exists rc_finish_managed_registration on auth.users;
create trigger rc_finish_managed_registration after update of raw_app_meta_data on auth.users
 for each row execute function rc_private.finish_managed_registration();
notify pgrst,'reload schema';
