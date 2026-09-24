-- ==========================================================================================
-- Arsip akun: penghapusan selalu dapat dibatalkan
-- ==========================================================================================
-- Pemilik menetapkan: akun yang dihapus pindah ke arsip pada tab tersendiri, dan dapat
-- diaktifkan kembali. Itu mengubah rancangan kemarin pada dua titik penting.
--
-- 1. TIDAK ADA LAGI PENGHAPUSAN SUNGGUHAN
--    Kemarin akun tanpa jejak benar-benar dihapus dari profiles dan auth.users. Baris yang
--    sudah hilang tidak dapat diaktifkan kembali, jadi jalur itu ditutup: semua penghapusan
--    kini meninggalkan baris arsip.
--
-- 2. ALAMAT LOGIN TIDAK LAGI DIUBAH
--    Kemarin alamat di auth.users diganti menjadi dihapus-<id>@rc-login.invalid supaya User ID
--    bebas dipakai lagi. Itu membuat pemulihan menjadi tebakan.
--
--    Alamat login adalah SHA-256 atas User ID PERSIS SEPERTI YANG DIKETIK orangnya, lalu
--    ditambah @rc-login.invalid - bukan atas user_code di tabel ini. Keduanya kebetulan sama
--    pada sebagian akun saja. Pemeriksaan atas data yang ada: alamat DANIEL cocok dengan
--    sha256('daniel'), bukan sha256('DANIEL'); begitu pula iqbal, anna_mdn, dan aniadmpti.
--    Satu akun lain tidak cocok dengan bentuk mana pun yang dicoba, yang membuktikan bentuk
--    huruf kecil itu kebiasaan, bukan aturan.
--
--    Karena itu alamatnya kini dibiarkan apa adanya saat menghapus. Hanya alamat yang telanjur
--    teracak oleh versi kemarin - yang berawalan "dihapus-" - yang dibangun ulang saat
--    pemulihan, memakai bentuk huruf kecil. Itu dugaan, dan dinyatakan terbuka pada pesan
--    balasannya alih-alih disembunyikan.
--
--    Membebaskan User ID dan dapat memulihkannya memang dua tujuan yang saling meniadakan.
--    Yang dipilih adalah yang diminta: dapat dipulihkan. Selama sebuah akun ada di arsip,
--    User ID-nya masih miliknya.
--
-- 3. MENGHAPUS AKUN YANG SUDAH DIHAPUS DITOLAK
--    Data yang ada memperlihatkan satu akun bernama "AYISD (dihapus 20-09-2026)
--    (dihapus 20-09-2026)" - imbuhannya menempel dua kali karena penghapusan diulang. Nama
--    seperti itu memanjang tiap kali dan pada akhirnya terpotong pada 60 karakter.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

-- Nama asli disimpan tersendiri, bukan dibaca kembali dari imbuhan pada user_code. Mengurai
-- nama dari teks yang sudah dirangkai adalah cara yang rapuh - satu perubahan format dan
-- pemulihannya menghasilkan User ID yang salah.
alter table public.profiles add column if not exists archived_user_code text;
alter table public.profiles add column if not exists archived_at timestamptz;
alter table public.profiles add column if not exists archived_by uuid references public.profiles(id);

-- Membereskan baris yang telanjur bertumpuk imbuhannya.
update public.profiles
   set archived_user_code = coalesce(archived_user_code,
         btrim(regexp_replace(user_code, '\s*\(dihapus [0-9-]+\)', '', 'g'))),
       archived_at = coalesce(archived_at, now())
 where status = 'deleted';

create or replace function public.rc_account_delete(
  p_user_code text, p_alasan text default '', p_hapus_jejak boolean default false)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare
  v public.profiles%rowtype; aku uuid := (select auth.uid()); v_kode text; v_nisan text;
begin
  if not rc_private.is_system_manager() then
    raise exception 'Hanya System Manager yang dapat menghapus akun' using errcode='42501'; end if;

  v_kode := upper(btrim(coalesce(p_user_code,'')));
  if v_kode = '' then raise exception 'User ID wajib diisi'; end if;
  select * into v from public.profiles where upper(user_code) = v_kode;
  if not found then raise exception 'Akun "%" tidak ditemukan', p_user_code; end if;

  if v.status = 'deleted' then
    raise exception 'Akun ini sudah ada di Arsip Hapus; pulihkan lebih dulu bila ingin mengubahnya'
      using errcode='42501'; end if;
  if v.id = aku then
    raise exception 'Anda tidak dapat menghapus akun Anda sendiri' using errcode='42501'; end if;
  if lower(v.role) = 'system manager'
     and (select count(*) from public.profiles
           where lower(role)='system manager' and status='active' and id <> v.id) = 0 then
    raise exception 'Ini satu-satunya System Manager aktif yang tersisa; sistem akan terkunci tanpa jalan masuk'
      using errcode='42501'; end if;

  insert into public.activity_logs(actor_id,event_type,entity_id,details)
  values(aku,'akun_dihapus',v.id,jsonb_build_object(
    'userCode',v.user_code,'nama',v.full_name,'peran',v.role,'statusLama',v.status,
    'alasan',left(btrim(coalesce(p_alasan,'')),300)));

  -- Semua yang memberi wewenang dilepas. Pemulihan TIDAK mengembalikannya: akun yang kembali
  -- harus diberi hak lagi secara sadar, bukan menghidupkan kembali kewenangan lama diam-diam.
  delete from public.user_permissions   where user_id = v.id;
  delete from public.user_depot_access  where user_id = v.id;
  delete from public.user_depot_grants  where user_id = v.id or granted_by = v.id;
  delete from public.user_supervision   where osc_id = v.id or supervisor_id = v.id;
  delete from public.pin_requests       where requester_id = v.id;
  if coalesce(p_hapus_jejak,false) then
    delete from public.activity_logs where actor_id = v.id;
  end if;

  v_nisan := left(v.user_code || ' (dihapus ' || to_char(now() at time zone 'Asia/Jakarta','DD-MM-YYYY') || ')', 60);

  update public.profiles
     set status = 'deleted',
         archived_user_code = v.user_code,
         archived_at = now(),
         archived_by = aku,
         user_code = v_nisan,
         requested_role = null, requested_depot = null,
         must_change_password = false,
         review_note = left('Akun dihapus System Manager. ' || btrim(coalesce(p_alasan,'')), 300)
   where id = v.id;

  -- Login dimatikan. Alamatnya SENGAJA tidak disentuh, supaya pemulihannya nanti benar-benar
  -- dapat dipakai masuk kembali.
  update auth.users set banned_until = 'infinity'::timestamptz where id = v.id;

  return jsonb_build_object('status','success','cara','diarsipkan',
    'message','Akun ' || v.user_code || ' dipindahkan ke Arsip Hapus: login dimatikan, seluruh izin '
      || 'dan depotnya dilepas, dan akunnya hilang dari daftar. Dapat diaktifkan kembali kapan saja '
      || 'lewat tab Arsip Hapus, tetapi izin dan depotnya harus diberikan lagi.');
end $fn$;
revoke all on function public.rc_account_delete(text,text,boolean) from public,anon;
grant execute on function public.rc_account_delete(text,text,boolean) to authenticated;

-- ------------------------------------------------------------------------------------------
-- Isi arsip
-- ------------------------------------------------------------------------------------------
create or replace function public.rc_account_archive()
returns jsonb language plpgsql stable security definer set search_path='' as $fn$
declare v jsonb; nama jsonb;
begin
  if not rc_private.is_system_manager() then
    raise exception 'Hanya System Manager yang dapat membuka Arsip Hapus' using errcode='42501'; end if;
  nama := rc_private.peta_nama_pelaku();
  select coalesce(jsonb_agg(x order by x->>'diarsipkanPada' desc),'[]'::jsonb) into v from (
    select jsonb_build_object(
      'id',p.id,
      'userId',coalesce(p.archived_user_code, p.user_code),
      'namaLengkap',p.full_name,'peran',p.role,
      'email',coalesce(p.business_email,''),
      'diarsipkanPada',case when p.archived_at is null then ''
        else to_char(p.archived_at at time zone 'Asia/Jakarta','DD/MM/YYYY HH24:MI') end,
      'diarsipkanOleh',coalesce(nama->>(p.archived_by::text),''),
      'catatan',coalesce(p.review_note,''),
      -- Benar bila User ID aslinya sementara dipakai akun lain; pemulihannya akan ditolak
      -- sampai bentrokan itu dibereskan, dan lebih baik terbaca sebelum tombolnya ditekan.
      'bentrok',exists(select 1 from public.profiles q
                        where q.id <> p.id and q.status <> 'deleted'
                          and upper(q.user_code) = upper(coalesce(p.archived_user_code, p.user_code)))
    ) as x
    from public.profiles p where p.status = 'deleted') t;
  return jsonb_build_object('status','success','rows',v);
end $fn$;
revoke all on function public.rc_account_archive() from public,anon;
grant execute on function public.rc_account_archive() to authenticated;

-- ------------------------------------------------------------------------------------------
-- Pengaktifan kembali
-- ------------------------------------------------------------------------------------------
create or replace function public.rc_account_restore(p_id uuid, p_alasan text default '')
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare v public.profiles%rowtype; aku uuid := (select auth.uid()); v_kode text; v_teracak boolean;
begin
  if not rc_private.is_system_manager() then
    raise exception 'Hanya System Manager yang dapat mengaktifkan kembali akun' using errcode='42501'; end if;
  select * into v from public.profiles where id = p_id for update;
  if not found then raise exception 'Akun tidak ditemukan'; end if;
  if v.status <> 'deleted' then raise exception 'Akun ini tidak ada di Arsip Hapus'; end if;

  v_kode := coalesce(nullif(btrim(v.archived_user_code),''), v.user_code);
  if exists(select 1 from public.profiles q
             where q.id <> v.id and q.status <> 'deleted' and upper(q.user_code) = upper(v_kode)) then
    raise exception 'User ID "%" sekarang dipakai akun lain; ganti dulu salah satunya', v_kode;
  end if;

  update public.profiles
     set status = 'active',
         user_code = v_kode,
         archived_user_code = null, archived_at = null, archived_by = null,
         review_note = left('Diaktifkan kembali. ' || btrim(coalesce(p_alasan,'')), 300)
   where id = v.id;

  -- Alamat login dipulihkan HANYA bila ia teracak oleh versi kemarin (berawalan "dihapus-").
  -- Alamat itu diturunkan dari SHA-256 User ID PERSIS SEPERTI YANG DIKETIK orangnya, bukan dari
  -- user_code di tabel ini. Pemeriksaan atas akun yang ada memperlihatkan keempatnya mengetik
  -- dengan huruf kecil, jadi bentuk itulah yang dipakai membangun ulang - sebuah DUGAAN yang
  -- dinyatakan terbuka pada pesan balasan, bukan diam-diam. Akun yang alamatnya tidak teracak
  -- tidak disentuh sama sekali, karena menimpanya justru akan mematikan login yang masih sehat.
  update auth.users
     set banned_until = null,
         email = case when email like 'dihapus-%'
                   then encode(extensions.digest(lower(v_kode),'sha256'),'hex') || '@rc-login.invalid'
                   else email end
   where id = v.id;
  select (email like 'dihapus-%') into v_teracak from auth.users where id = v.id;

  insert into public.activity_logs(actor_id,event_type,entity_id,details)
  values(aku,'akun_dipulihkan',v.id,jsonb_build_object(
    'userCode',v_kode,'nama',v.full_name,'alasan',left(btrim(coalesce(p_alasan,'')),300)));

  return jsonb_build_object('status','success','userId',v_kode,'alamatDibangunUlang',coalesce(v_teracak,false),
    'message','Akun ' || v_kode || ' aktif kembali dan dapat masuk memakai PIN lamanya. '
      || 'Izin dan depotnya TIDAK ikut kembali - berikan lagi lewat tombol Kelola.');
end $fn$;
revoke all on function public.rc_account_restore(uuid,text) from public,anon;
grant execute on function public.rc_account_restore(uuid,text) to authenticated;

create or replace function rc_private.marker_20261105() returns boolean
language sql immutable set search_path='' as $fn$select true$fn$;
revoke all on function rc_private.marker_20261105() from public,anon;
grant execute on function rc_private.marker_20261105() to authenticated;

select 'Arsip akun terpasang' as hasil,
 (select count(*) from public.profiles where status <> 'deleted') as akun_aktif,
 (select count(*) from public.profiles where status = 'deleted') as di_arsip;
