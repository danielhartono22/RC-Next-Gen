-- ==========================================================================================
-- Email terjadwal selalu terkirim: Pratinjau dan Test Email tidak lagi menghalangi
-- ==========================================================================================
-- Pemilik, 20 Oktober 2026: "always send by email and send to and cc email".
--
-- rc_email_tick menyusun satu jenis email sekali per hari, dan "sudah ada hari ini" dulu dihitung
-- dari SETIAP baris email_outbox jenis itu - termasuk Pratinjau (status skipped, preview) dan
-- Test Email (konteks uji). Akibatnya Pratinjau yang dibuka sebelum jam kirim membatalkan email
-- terjadwal hari itu (Daily 20 Oktober 2026 tidak terkirim karena Pratinjau 08:05).
--
-- Kini yang dihitung hanya email sungguhan ke penerimanya (To + CC): baris pending / sent /
-- failed yang bukan pratinjau dan bukan uji. Kirim Manual tetap dihitung, sehingga email yang
-- sudah dikirim manual hari itu tidak terkirim dua kali.
--
-- Penjaga MD5 pra-citra rc_email_tick: 33f38909 (sama di dev dan prod, 20 Oktober 2026).
-- ==========================================================================================

create or replace function pg_temp.ganti(p_src text, p_lama text, p_baru text, p_n integer, p_nama text)
returns text language plpgsql as $f$
declare n integer := (length(p_src) - length(replace(p_src, p_lama, ''))) / greatest(length(p_lama), 1);
begin
  if n <> p_n then raise exception '%: pola ditemukan % kali, diharapkan %: %', p_nama, n, p_n, left(p_lama, 120); end if;
  return replace(p_src, p_lama, p_baru);
end $f$;

-- Sudahkah jenis email ini benar-benar dikirim / diantrekan ke penerimanya hari ini (WIB)?
create or replace function rc_private.email_terkirim_hari_ini(p_jenis text, p_sekarang timestamptz default now())
returns boolean language sql stable security definer set search_path = '' as $f$
  select exists(select 1 from public.email_outbox o
                 where o.jenis = p_jenis
                   and o.dibuat_pada >= date_trunc('day', p_sekarang at time zone 'Asia/Jakarta') at time zone 'Asia/Jakarta'
                   and o.status in ('pending', 'sent', 'failed')
                   and coalesce(o.konteks->>'preview', '') <> 'true'
                   and coalesce(o.konteks->>'uji', '') <> 'true');
$f$;
revoke all on function rc_private.email_terkirim_hari_ini(text, timestamptz) from public, anon, authenticated;

do $tambal$
declare src text;
begin
  src := replace(pg_get_functiondef('public.rc_email_tick()'::regprocedure), E'\r', '');
  if src ~ '20261163240000' then raise notice 'rc_email_tick sudah ditambal.'; return; end if;
  if md5(src) <> '33f389095f8dd1ccfa859a92a16afc6f' then
    raise exception 'DITOLAK: rc_email_tick berbeda dari yang diukur (md5 %).', md5(src); end if;
  src := pg_temp.ganti(src, $p$    -- Satu jenis email hanya sekali per hari, walau tick berjalan setiap jam.
    select exists(select 1 from public.email_outbox o
                   where o.jenis = s.jenis
                     and o.dibuat_pada >= date_trunc('day', sekarang at time zone 'Asia/Jakarta')
                         at time zone 'Asia/Jakarta') into sudah;$p$,
    $p$    -- Satu jenis email hanya sekali per hari, walau tick berjalan setiap jam. 20261163240000:
    -- yang dihitung hanya email sungguhan ke To + CC; Pratinjau dan Test Email tidak menghalangi.
    sudah := rc_private.email_terkirim_hari_ini(s.jenis, sekarang);$p$, 1, 'tick sekali sehari');
  execute src;
end $tambal$;

do $cek$
begin
  if pg_get_functiondef('public.rc_email_tick()'::regprocedure) !~ 'email_terkirim_hari_ini' then
    raise exception 'GAGAL: rc_email_tick belum ditambal'; end if;
end $cek$;
