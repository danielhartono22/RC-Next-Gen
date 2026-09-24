-- ==========================================================================================
-- System Manager dapat menghapus akun
-- ==========================================================================================
-- DUA CARA MENGHAPUS, DIPILIH SERVER MENURUT JEJAK AKUNNYA
--
-- Sebuah akun di sistem ini bukan sekadar baris login. Namanya menempel pada dokumen: siapa
-- yang men-submit, me-release, meng-claim, siapa yang meng-compile, siapa yang menandai
-- Not Achieved. Menghapusnya begitu saja akan menulis ulang masa lalu - kartu "Dikerjakan Oleh"
-- pada Claim Process mendadak kosong untuk dokumen yang jelas-jelas pernah dikerjakan orang.
--
--   TANPA JEJAK  -> baris profilnya benar-benar dihapus, beserta akun login-nya di auth.users.
--                   Dipakai untuk pendaftaran yang ditolak atau akun yang belum sempat bekerja.
--
--   PUNYA JEJAK  -> baris profilnya ditinggalkan sebagai nisan: status 'deleted', seluruh izin,
--                   depot, dan supervisi dilepas, dan login-nya dimatikan permanen lewat
--                   auth.users.banned_until. Namanya tetap terbaca pada riwayat dokumen,
--                   tetapi akunnya tidak dapat dipakai lagi dan hilang dari daftar pengguna.
--
-- User ID-nya DIBEBASKAN pada kedua jalur. profiles.user_code unik, jadi nisan yang masih
-- memegang "IQBAL" akan menghalangi pembuatan ulang akun dengan User ID yang sama. Nisannya
-- diberi nama "IQBAL (dihapus 19-09-2026)" - masih terbaca manusia, tidak lagi bentrok.
-- Alamat login di auth.users ikut diubah karena alamat itu diturunkan dari User ID.
--
-- PENJAGAAN
--   - Hanya System Manager.
--   - Tidak boleh menghapus diri sendiri. Sebuah sistem yang membiarkan administrator terakhir
--     menghapus dirinya sendiri akan terkunci tanpa jalan masuk.
--   - Tidak boleh menghapus System Manager aktif yang terakhir, dengan alasan yang sama.
--   - Penghapusannya dicatat LEBIH DULU di activity_logs atas nama pelakunya, sehingga jejak
--     tindakan itu tetap ada justru ketika akun sasarannya sudah tidak ada.
--
-- p_hapus_jejak hanya menyentuh activity_logs milik akun itu - catatan langkahnya sendiri.
-- Riwayat dokumen (claim_status_history, claims, campaigns, depots ...) TIDAK PERNAH dihapus
-- lewat jalur mana pun; bila ada, akunnya pasti menjadi nisan.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

alter table public.profiles drop constraint if exists profiles_status_check;
alter table public.profiles add constraint profiles_status_check
  check (status in ('pending','active','inactive','rejected','deleted'));

create or replace function public.rc_account_delete(
  p_user_code text, p_alasan text default '', p_hapus_jejak boolean default false)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare
  v public.profiles%rowtype; aku uuid := (select auth.uid());
  n_jejak bigint; v_cara text; v_kode text; v_nisan text;
begin
  if not rc_private.is_system_manager() then
    raise exception 'Hanya System Manager yang dapat menghapus akun' using errcode='42501'; end if;

  v_kode := upper(btrim(coalesce(p_user_code,'')));
  if v_kode = '' then raise exception 'User ID wajib diisi'; end if;
  select * into v from public.profiles where upper(user_code) = v_kode;
  if not found then raise exception 'Akun "%" tidak ditemukan', p_user_code; end if;

  if v.id = aku then
    raise exception 'Anda tidak dapat menghapus akun Anda sendiri' using errcode='42501'; end if;
  if lower(v.role) = 'system manager'
     and (select count(*) from public.profiles
           where lower(role)='system manager' and status='active' and id <> v.id) = 0 then
    raise exception 'Ini satu-satunya System Manager aktif yang tersisa; sistem akan terkunci tanpa jalan masuk'
      using errcode='42501'; end if;

  -- Dicatat lebih dulu, atas nama pelakunya. Bila dicatat belakangan, penghapusan yang gagal
  -- di tengah jalan akan meninggalkan catatan tentang sesuatu yang tidak terjadi.
  insert into public.activity_logs(actor_id,event_type,entity_id,details)
  values(aku,'akun_dihapus',v.id,jsonb_build_object(
    'userCode',v.user_code,'nama',v.full_name,'peran',v.role,'statusLama',v.status,
    'alasan',left(btrim(coalesce(p_alasan,'')),300)));

  -- Semua yang memberi wewenang dilepas lebih dulu, apa pun jalur yang nanti ditempuh.
  delete from public.user_permissions   where user_id = v.id;
  delete from public.user_depot_access  where user_id = v.id;
  delete from public.user_depot_grants  where user_id = v.id or granted_by = v.id;
  delete from public.user_supervision   where osc_id = v.id or supervisor_id = v.id;
  delete from public.pin_requests       where requester_id = v.id;

  if coalesce(p_hapus_jejak,false) then
    delete from public.activity_logs where actor_id = v.id;
  end if;

  -- Jejak yang menjadikan akunnya tidak boleh hilang. Dihitung SESUDAH pelepasan di atas,
  -- supaya hak akses yang tadi dicabut tidak ikut terhitung sebagai jejak.
  select
    (select count(*) from public.activity_logs        where actor_id = v.id)
  + (select count(*) from public.claim_status_history where actor_id = v.id)
  + (select count(*) from public.claims               where created_by = v.id or archived_by = v.id)
  + (select count(*) from public.campaigns            where created_by = v.id or memo_uploaded_by = v.id)
  + (select count(*) from public.customers            where updated_by = v.id)
  + (select count(*) from public.depots               where updated_by = v.id)
  + (select count(*) from public.depot_profiles       where updated_by = v.id)
  + (select count(*) from public.depot_profile_requests where requester_id = v.id or reviewer_id = v.id)
  + (select count(*) from public.profile_change_requests where requester_id = v.id or reviewer_id = v.id)
  + (select count(*) from public.excluded_campaigns   where excluded_by = v.id)
  + (select count(*) from public.timetable_not_achieved where marked_by = v.id)
  + (select count(*) from public.email_settings       where diubah_oleh = v.id)
  + (select count(*) from public.profiles             where reviewed_by = v.id and id <> v.id)
  into n_jejak;

  v_nisan := left(v.user_code || ' (dihapus ' || to_char(now() at time zone 'Asia/Jakarta','DD-MM-YYYY') || ')', 60);

  if n_jejak = 0 then
    -- Benar-benar hilang. Urutannya penting: profiles.id menunjuk auth.users tanpa CASCADE,
    -- jadi barisnya harus dilepas lebih dulu.
    delete from public.profiles where id = v.id;
    delete from auth.users where id = v.id;
    v_cara := 'dihapus';
  else
    -- Nisan. Namanya dipertahankan supaya riwayat dokumen tetap terbaca.
    update public.profiles
       set status = 'deleted',
           user_code = v_nisan,
           requested_role = null, requested_depot = null,
           must_change_password = false,
           review_note = left('Akun dihapus System Manager. ' || btrim(coalesce(p_alasan,'')), 300)
     where id = v.id;

    -- Login dimatikan permanen, dan alamatnya diubah supaya User ID-nya bebas dipakai lagi.
    update auth.users
       set banned_until = 'infinity'::timestamptz,
           email = 'dihapus-' || v.id::text || '@rc-login.invalid',
           email_change = null, email_change_token_new = '', email_change_token_current = ''
     where id = v.id;
    v_cara := 'dinonaktifkan permanen';
  end if;

  return jsonb_build_object('status','success','cara',v_cara,'jejak',n_jejak,
    'message', case when n_jejak = 0
      then 'Akun ' || v.user_code || ' dihapus sepenuhnya. User ID-nya dapat dipakai lagi.'
      else 'Akun ' || v.user_code || ' dihapus: login dimatikan permanen, seluruh izin dan depot dilepas, '
        || 'dan akunnya hilang dari daftar. ' || n_jejak || ' jejak pekerjaannya pada dokumen tetap '
        || 'tersimpan atas namanya, dan User ID-nya bebas dipakai lagi.' end);
end $fn$;
revoke all on function public.rc_account_delete(text,text,boolean) from public,anon;
grant execute on function public.rc_account_delete(text,text,boolean) to authenticated;

-- Akun yang sudah dihapus tidak boleh muncul lagi di daftar pengguna.
--
-- Yang diganti adalah rc_private.list_users, bukan pembungkusnya public.rc_list_users. Bentuk
-- kembaliannya dipertahankan persis - kolom, urutan, batas 50 baris dan offset-nya - karena
-- layar Access Management membacanya apa adanya. Satu-satunya perubahan adalah baris berstatus
-- 'deleted' tidak lagi ikut.
create or replace function rc_private.list_users(p_offset integer)
returns jsonb language plpgsql stable security definer set search_path='' as $fn$
declare v jsonb; begin
 if not rc_private.is_manager() then raise exception 'Manager required' using errcode='42501'; end if;
 select coalesce(jsonb_agg(x),'[]') into v from (
 select p.id,p.user_code,p.full_name,p.role,p.status,p.must_change_password,
 array(select permission_code from public.user_permissions where user_id=p.id) as permissions,
 array(select depot_id from public.user_depot_access where user_id=p.id) as depots
 from public.profiles p where p.status <> 'deleted'
 order by user_code limit 50 offset greatest(p_offset,0)) x;
 return v;
end $fn$;

create or replace function rc_private.marker_20261104() returns boolean
language sql immutable set search_path='' as $fn$select true$fn$;
revoke all on function rc_private.marker_20261104() from public,anon;
grant execute on function rc_private.marker_20261104() to authenticated;

select 'Penghapusan akun terpasang' as hasil,
 (select count(*) from public.profiles where status <> 'deleted') as akun_aktif,
 (select count(*) from public.profiles where status = 'deleted') as nisan;
