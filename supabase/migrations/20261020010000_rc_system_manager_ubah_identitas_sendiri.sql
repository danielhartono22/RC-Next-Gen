-- ==========================================================================================
-- System Manager dapat mengubah identitasnya sendiri
-- ==========================================================================================
-- rc_update_access menolak setiap penyuntingan atas diri sendiri dengan "Tidak dapat mengubah
-- akses sendiri". Penjagaan itu ada karena alasan yang benar: seorang pengelola yang tidak
-- sengaja mencabut haknya sendiri, menonaktifkan akunnya, atau menurunkan perannya akan
-- mengunci dirinya keluar, dan tidak ada siapa pun lagi yang bisa mengembalikannya.
--
-- Tetapi larangan itu terlalu luas. Memperbaiki salah ketik pada nama atau alamat email sendiri
-- sama sekali tidak berisiko mengunci siapa pun. Atas keputusan pemilik, System Manager kini
-- boleh menyunting identitasnya sendiri.
--
-- YANG DIIZINKAN DAN YANG TETAP DITOLAK ATAS DIRI SENDIRI
--   boleh    nama lengkap, email bisnis, suffix batch
--   ditolak  peran, status aktivasi, hak modul, yurisdiksi, dan persetujuan ganti PIN
--
-- Pembatasan itu bukan formalitas. Justru lima hal terakhir itulah yang dapat mengunci
-- seseorang keluar dari sistemnya sendiri, dan hanya itu yang memang tidak boleh disentuh.
-- Untuk pengguna lain, tidak ada yang berubah.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

create or replace function public.rc_update_access(p_payload jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare
  v_target uuid; v_kode text; v_role text; v_role_lama text; v_status text;
  v_perms text[]; v_depot uuid; c text; n_rp int:=0; n_as int:=0; n_osc int:=0;
  v_diri boolean;
begin
  if not rc_private.is_manager() then
    raise exception 'Hanya System Manager atau Supervisor yang dapat mengubah akses'
      using errcode='42501'; end if;
  if p_payload is null or jsonb_typeof(p_payload)<>'object' then
    raise exception 'Payload tidak sah'; end if;

  v_kode:=upper(btrim(coalesce(p_payload->>'userId','')));
  if v_kode='' then raise exception 'User ID wajib diisi'; end if;
  select id, role into v_target, v_role_lama from public.profiles where user_code=v_kode;
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

  v_status:=case when lower(coalesce(p_payload->'auth'->>'i','')) in('active','approved','ok')
                 then 'active' else 'inactive' end;

  if v_role='system manager' then
    delete from public.user_depot_grants where user_id=v_target;
    delete from public.user_supervision where supervisor_id=v_target;
  else
    if p_payload ? 'homeDepot' then
      delete from public.user_depot_grants where user_id=v_target and kind='home';
      if coalesce(btrim(p_payload->>'homeDepot'),'')<>'' then
        v_depot:=public.rc_legacy_depot_id(btrim(p_payload->>'homeDepot'));
        insert into public.user_depot_grants(user_id,depot_id,kind,granted_by)
        values(v_target,v_depot,'home',(select auth.uid()))
        on conflict(user_id,depot_id) do update set kind='home';
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
          select v_target,id from public.profiles where user_code=upper(btrim(c)) and id<>v_target
          on conflict do nothing;
          n_osc:=n_osc+1;
        end if;
      end loop;
    end if;
  end if;

  if v_role='system manager' then
    v_perms:=array(select code from public.permissions);
  else
    v_perms:=array(select code from (values
      ('j','upload_claim'),('k','release_claim'),('l','process_claim'),('m','view_analytics'),
      ('n','manage_access'),('p','view_master_depot'),('s','bulk_process'),('logs','view_logs'),
      ('keyMaster','manage_key_master'),('compilation','view_compilation'),
      ('archiveCompilation','archive_compilation'),
      ('report','view_report'),('timetable','manage_timetable')
    ) as m(letter,code)
    where lower(coalesce(p_payload->'auth'->>m.letter,'no')) in('yes','true','approved','visible'));
  end if;

  delete from public.user_permissions where user_id=v_target;
  insert into public.user_permissions select v_target,x from unnest(v_perms) x group by x;
  update public.profiles set status=v_status where id=v_target;

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
end $fn$;

create or replace function rc_private.marker_20261020() returns boolean
language sql immutable set search_path='' as $fn$select true$fn$;
revoke all on function rc_private.marker_20261020() from public,anon;
grant execute on function rc_private.marker_20261020() to authenticated;

select 'System Manager dapat mengubah identitas sendiri' as hasil,
 (select count(*) from public.profiles where role='system manager') as jumlah_system_manager;
