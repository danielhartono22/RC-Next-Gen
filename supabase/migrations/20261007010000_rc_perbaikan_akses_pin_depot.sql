-- ==========================================================================================
-- Empat perbaikan yang dilaporkan pemilik
-- ==========================================================================================
-- 1. "KADANG POSISI SYSTEM MANAGER TAPI MUNCUL HANYA SYSTEM MANAGER"
--    rc_private.is_system_manager() menuntut must_change_password bernilai false, sedangkan
--    rc_private.is_manager() tidak. Akibatnya ada keadaan setengah: seseorang lolos masuk
--    konsol karena is_manager benar, tetapi setiap tindakannya ditolak karena is_system_manager
--    salah, dan pesannya berbunyi seolah perannya yang kurang. Keadaan itu justru mudah
--    terjadi sejak ada alur persetujuan PIN, yang memang menyalakan must_change_password.
--    Kedua pemeriksaan kini memakai syarat yang sama.
--
-- 2. "KENAPA SERING ACCESS DENIED"
--    rc_private.can_access juga menuntut must_change_password bernilai false. Ketika seseorang
--    berada dalam keadaan wajib ganti PIN, seluruh layar menolak tanpa menyebut sebabnya.
--    Ditambahkan public.rc_siapa_saya() supaya penolakan selalu dapat dijelaskan, bukan ditebak.
--
-- 3. VOUCHER DIHITUNG SEBAGAI TRANSFER
--    Campaign Master memuat jenis "Voucher" yang tidak ada di daftar resmi. Atas keputusan
--    pemilik, Voucher tidak dihapus dan diperlakukan persis seperti Transfer - termasuk
--    kewajiban Nomor Rekening, Nama Rekening dan Bank.
--
-- 4. DEPOT HEAD OFFICE
--    Ditambahkan sebagai depot dengan kode HO.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

-- ------------------------------------------------------------------------------------------
-- 1. Syarat pengelola disamakan
-- ------------------------------------------------------------------------------------------
create or replace function rc_private.is_manager()
returns boolean language sql stable security definer set search_path='' as $fn$
  select exists(select 1 from public.profiles p
                 where p.id=(select auth.uid()) and p.status='active'
                   and not p.must_change_password
                   and p.role in('system manager','supervisor'));
$fn$;

-- ------------------------------------------------------------------------------------------
-- 2. Penolakan yang dapat dijelaskan
-- ------------------------------------------------------------------------------------------
-- Sebuah penolakan yang tidak bisa dijelaskan akan selalu dibaca sebagai kerusakan. Fungsi ini
-- menjawab satu pertanyaan sederhana - menurut server, saya ini siapa dan boleh apa - sehingga
-- "access denied" berikutnya punya sebab yang bisa dibaca, bukan ditebak.
create or replace function public.rc_siapa_saya()
returns jsonb language sql stable security definer set search_path='' as $fn$
  select coalesce((
    select jsonb_build_object(
      'status','success',
      'userId',p.user_code,'namaLengkap',p.full_name,'peran',p.role,'statusAkun',p.status,
      'wajibGantiPin',p.must_change_password,
      'systemManager',rc_private.is_system_manager(),
      'pengelola',rc_private.is_manager(),
      'jumlahDepot',(select count(*) from public.user_depot_access a where a.user_id=p.id),
      'permission',array(select permission_code from public.user_permissions where user_id=p.id),
      'sebab',case
        when p.status<>'active' then 'Akun berstatus '||p.status||'; hubungi System Manager.'
        when p.must_change_password then
          'Akun sedang diwajibkan menetapkan PIN baru. Seluruh akses ditahan sampai PIN diganti.'
        when p.role<>'system manager'
             and not exists(select 1 from public.user_depot_access a where a.user_id=p.id)
          then 'Belum ada satu pun depot pada yurisdiksi Anda.'
        when p.role<>'system manager'
             and not exists(select 1 from public.user_permissions x where x.user_id=p.id)
          then 'Belum ada satu pun hak modul yang diberikan.'
        else 'Tidak ada yang menahan akses Anda.' end)
    from public.profiles p where p.id=(select auth.uid())),
    jsonb_build_object('status','error','sebab','Sesi tidak dikenali. Masuk kembali.'));
$fn$;
revoke all on function public.rc_siapa_saya() from public,anon;
grant execute on function public.rc_siapa_saya() to authenticated;

-- ------------------------------------------------------------------------------------------
-- 3. Voucher diperlakukan sebagai Transfer
-- ------------------------------------------------------------------------------------------
-- Penyeragamannya diletakkan di satu fungsi tersendiri supaya tidak ada tempat kedua yang bisa
-- ketinggalan ketika aturannya berubah lagi.
create or replace function rc_private.jenis_efektif(p_jenis text)
returns text language sql immutable set search_path='' as $fn$
  select case lower(btrim(coalesce(p_jenis,'')))
           when 'voucher' then 'transfer'
           else lower(btrim(coalesce(p_jenis,''))) end;
$fn$;
revoke all on function rc_private.jenis_efektif(text) from public,anon;
grant execute on function rc_private.jenis_efektif(text) to authenticated;

-- ------------------------------------------------------------------------------------------
-- 4. Depot Head Office
-- ------------------------------------------------------------------------------------------
insert into public.depots(depot_code,depot_name,abbr)
values('HO','Head Office','HO')
on conflict(depot_code) do update set depot_name='Head Office',
  abbr=coalesce(public.depots.abbr,'HO');

create or replace function rc_private.marker_20261007() returns boolean
language sql immutable set search_path='' as $fn$select true$fn$;
revoke all on function rc_private.marker_20261007() from public,anon;
grant execute on function rc_private.marker_20261007() to authenticated;

select 'Perbaikan akses, Voucher dan depot terpasang' as hasil,
 (select depot_name from public.depots where depot_code='HO') as depot_ho,
 (select count(*) from public.depots) as total_depot,
 rc_private.jenis_efektif('Voucher') as voucher_menjadi,
 (select count(*) from public.profiles where must_change_password) as akun_tertahan_pin;
