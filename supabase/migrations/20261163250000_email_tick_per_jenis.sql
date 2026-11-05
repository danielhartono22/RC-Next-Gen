-- ==========================================================================================
-- Email terjadwal: 'pengajuan' tidak lagi ikut dijadwalkan, satu jenis gagal tidak membatalkan
-- jenis lain, dan kegagalannya tercatat (Laporan Kesehatan RC)
-- ==========================================================================================
-- Temuan 21 Oktober 2026 (prod): jadwal 07:05 gagal "Jenis email "pengajuan" tidak dikenali" dan
-- Daily hari itu tidak terkirim. Baris email_settings 'pengajuan' adalah SAKELAR Email Pengajuan
-- (dikirim saat kejadian), tetapi aktif dan berjam 7 sehingga ikut diulang rc_email_tick; satu
-- exception membatalkan seluruh tick. Sebelumnya tertutup oleh galat akses (20261163220000).
-- Pemilik: "perbaiki"; Daily dimulai besok.
--
--  1. rc_email_tick melewati 'pengajuan', dan menyusun tiap jenis di blok tersendiri: kegagalan
--     dicatat di Log Activity (email_terjadwal_gagal) dan jenis lain tetap berjalan.
--  2. Laporan Kesehatan menampilkan kegagalan itu di "Bugs & Incidents" (tick yang tetap sukses
--     tidak lagi tampak sebagai jadwal gagal di cron).
--  3. Panel Email Otomatis tidak lagi menampilkan / menyimpan baris 'pengajuan': kotak aktifnya
--     sama dengan sakelar Email Pengajuan, sehingga mematikannya di panel jadwal ikut mematikan
--     Email Pengajuan. Sakelarnya tetap di tab Email Pengajuan.
--
-- Penjaga MD5 pra-citra (sama di dev dan prod, 21 Oktober 2026): rc_email_tick 90e53662,
-- rc_email_status a9bd8b9d, rc_email_settings_simpan ee60d8ba, email_kesehatan_isi 4fdd1619.
-- ==========================================================================================

create or replace function pg_temp.ganti(p_src text, p_lama text, p_baru text, p_n integer, p_nama text)
returns text language plpgsql as $f$
declare n integer := (length(p_src) - length(replace(p_src, p_lama, ''))) / greatest(length(p_lama), 1);
begin
  if n <> p_n then raise exception '%: pola ditemukan % kali, diharapkan %: %', p_nama, n, p_n, left(p_lama, 120); end if;
  return replace(p_src, p_lama, p_baru);
end $f$;

do $tambal$
declare src text; f record;
begin
  for f in select * from (values
    ('public.rc_email_tick()', '90e53662c1f5f5db02503be7c02e4af1'),
    ('public.rc_email_status()', 'a9bd8b9dd69e8d740de1ad7225d77149'),
    ('public.rc_email_settings_simpan(jsonb)', 'ee60d8baecdc6d43ea30d7e10b70aa99'),
    ('rc_private.email_kesehatan_isi(timestamptz)', '4fdd1619837e3496c82ed184f731a27b')) x(sig, harapan)
  loop
    src := replace(pg_get_functiondef(f.sig::regprocedure), E'\r', '');
    if src ~ '20261163250000' then raise notice '% sudah ditambal.', f.sig; continue; end if;
    if md5(src) <> f.harapan then raise exception 'DITOLAK: % berbeda dari yang diukur (md5 %).', f.sig, md5(src); end if;

    if f.sig = 'public.rc_email_tick()' then
      src := pg_temp.ganti(src, $p$  for s in select * from public.email_settings where aktif loop$p$,
        $p$  -- 20261163250000: 'pengajuan' adalah sakelar email saat kejadian, bukan email terjadwal.
  for s in select * from public.email_settings where aktif and jenis <> 'pengajuan' loop$p$, 1, 'tick tanpa pengajuan');
      src := pg_temp.ganti(src, $p$    perform public.rc_email_susun(s.jenis, true);
    n := n + 1;$p$,
        $p$    -- 20261163250000: satu jenis yang gagal tidak membatalkan jenis lain; sebabnya dicatat.
    begin
      perform public.rc_email_susun(s.jenis, true);
      n := n + 1;
    exception when others then
      insert into public.activity_logs(event_type, details)
      values ('email_terjadwal_gagal', jsonb_build_object('jenis', s.jenis, 'sebab', left(sqlerrm, 500)));
    end;$p$, 1, 'tick per jenis');
    elsif f.sig = 'public.rc_email_status()' then
      src := pg_temp.ganti(src, $p$      from public.email_settings),$p$,
        $p$      from public.email_settings where jenis <> 'pengajuan' /* 20261163250000 */),$p$, 1, 'status tanpa pengajuan');
    elsif f.sig = 'public.rc_email_settings_simpan(jsonb)' then
      src := pg_temp.ganti(src, $p$  for r in select value from jsonb_array_elements(p_rows) loop$p$,
        $p$  for r in select value from jsonb_array_elements(p_rows) loop
    -- 20261163250000: sakelar Email Pengajuan hanya diatur di tab Email Pengajuan.
    if lower(btrim(coalesce(r->>'jenis', ''))) = 'pengajuan' then continue; end if;$p$, 1, 'simpan tanpa pengajuan');
    else
      src := pg_temp.ganti(src, $p$    select 6, count(*), jsonb_build_array('Accounts suspended (3 wrong PINs)'$p$,
        $p$    -- 20261163250000: jenis email terjadwal yang gagal disusun (tick sendiri tetap sukses).
    select 6, count(*), jsonb_build_array('Scheduled email failed: ' || coalesce(l.details->>'jenis', '-'), rc_private.kes_angka(count(*)),
             to_char(max(l.created_at) at time zone 'Asia/Jakarta', 'DD-Mon-YYYY HH24:MI'), left(max(l.details->>'sebab'), 160))
      from public.activity_logs l where l.event_type = 'email_terjadwal_gagal' and l.created_at >= p_dari
     group by l.details->>'jenis'
    union all
    select 6, count(*), jsonb_build_array('Accounts suspended (3 wrong PINs)'$p$, 1, 'kesehatan email gagal');
    end if;
    execute src;
  end loop;
end $tambal$;

do $cek$
declare e text := '';
begin
  if pg_get_functiondef('public.rc_email_tick()'::regprocedure) !~ 'email_terjadwal_gagal' then e := e || ' tick;'; end if;
  if pg_get_functiondef('public.rc_email_status()'::regprocedure) !~ '20261163250000' then e := e || ' status;'; end if;
  if pg_get_functiondef('public.rc_email_settings_simpan(jsonb)'::regprocedure) !~ '20261163250000' then e := e || ' simpan;'; end if;
  if pg_get_functiondef('rc_private.email_kesehatan_isi(timestamptz)'::regprocedure) !~ 'Scheduled email failed' then e := e || ' isi;'; end if;
  if e <> '' then raise exception 'GAGAL:%', e; end if;
end $cek$;
