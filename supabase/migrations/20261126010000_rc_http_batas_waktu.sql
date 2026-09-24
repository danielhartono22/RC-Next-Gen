-- ==========================================================================================
-- Batas waktu pgsql-http dinaikkan untuk Drive dan Gmail
-- ==========================================================================================
-- Lampiran PDF gagal dibuat, dan pelaporan jujur yang baru dipasang langsung menyebut sebabnya:
--
--   PDF gagal dibuat, email dikirim tanpa lampiran:
--   Operation timed out after 5002 milliseconds with 0 bytes received
--
-- Lima detik adalah bawaan pgsql-http (CURLOPT_TIMEOUT). Itu cukup untuk panggilan ringan,
-- tetapi tidak untuk pekerjaan yang sedang kita lakukan:
--
--   unggah HTML ke Drive lalu dikonversi menjadi Google Doc   beberapa detik
--   ekspor Google Doc menjadi PDF                             beberapa detik
--   kirim Gmail dengan lampiran 111 KB                        beberapa detik
--
-- Batasnya dinaikkan menjadi 60 detik. Angka itu longgar untuk ketiganya dan tetap jauh di bawah
-- ambang yang membuat sebuah pekerjaan cron menggantung tanpa batas.
--
-- PENTING: setelan curl pada pgsql-http berlaku PER SESI, bukan per basis data. Karena itu ia
-- harus dipasang di dalam fungsi yang memakainya, bukan sekali saja saat migration berjalan -
-- sesi migration ini berakhir begitu berkasnya selesai, dan pekerjaan cron berikutnya membuka
-- sesi baru dengan setelan bawaan lagi.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

-- ------------------------------------------------------------------------------------------
-- Satu tempat untuk menyetelnya, dipanggil oleh keduanya
-- ------------------------------------------------------------------------------------------
create or replace function rc_private.http_siapkan()
returns void language plpgsql security definer set search_path='' as $fn$
begin
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT', '60');
  -- Google kadang mengalihkan permintaan unduhan ke host penyimpanannya.
  perform extensions.http_set_curlopt('CURLOPT_FOLLOWLOCATION', 'true');
exception when others then
  -- Setelan yang tidak dikenali tidak boleh menggagalkan pengiriman; batas bawaannya tetap
  -- berlaku dan kegagalannya akan terbaca sebagai timeout biasa.
  null;
end $fn$;
revoke all on function rc_private.http_siapkan() from public,anon;

-- ------------------------------------------------------------------------------------------
-- Dipasang pada pembuat PDF
-- ------------------------------------------------------------------------------------------
do $mig$
declare src text; baru text;
begin
  select pg_get_functiondef(p.oid) into src from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='rc_private' and p.proname='buat_pdf';
  if src is null then raise exception 'rc_private.buat_pdf tidak ditemukan.'; end if;

  if position('http_siapkan' in src) > 0 then
    raise notice 'buat_pdf sudah menyetel batas waktu; dilewati.';
  else
    baru := replace(src,
      '  v_tok := rc_private.gmail_token();',
      '  perform rc_private.http_siapkan();' || chr(10)
        || '  v_tok := rc_private.gmail_token();');
    if baru = src then raise exception 'Pola pada rc_private.buat_pdf tidak ditemukan.'; end if;
    execute baru;
  end if;

  -- ----------------------------------------------------------------------------------------
  select pg_get_functiondef(p.oid) into src from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='rc_private' and p.proname='kirim_satu_email';
  if src is null then raise exception 'rc_private.kirim_satu_email tidak ditemukan.'; end if;

  if position('http_siapkan' in src) > 0 then
    raise notice 'kirim_satu_email sudah menyetel batas waktu; dilewati.';
  else
    baru := replace(src,
      '  v_token := rc_private.gmail_token();',
      '  perform rc_private.http_siapkan();' || chr(10)
        || '  v_token := rc_private.gmail_token();');
    if baru = src then raise exception 'Pola pada rc_private.kirim_satu_email tidak ditemukan.'; end if;
    execute baru;
  end if;
end
$mig$;

-- ------------------------------------------------------------------------------------------
-- Pemeriksaan
-- ------------------------------------------------------------------------------------------
do $periksa$
declare n int;
begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname='rc_private' and p.proname in ('buat_pdf','kirim_satu_email')
     and pg_get_functiondef(p.oid) like '%http_siapkan%';
  if n <> 2 then
    raise exception 'GAGAL: hanya % dari 2 fungsi yang menyetel batas waktu HTTP.', n; end if;
  raise notice 'Pemeriksaan lolos.';
end
$periksa$;
