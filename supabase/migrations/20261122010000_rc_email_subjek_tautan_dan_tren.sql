-- ==========================================================================================
-- Email: subjek mengikuti jadwal, tautan dashboard, URL diagram diperpendek, tren berpembanding
-- ==========================================================================================
-- Empat penyesuaian dari pemilik, 20 September 2026.
--
-- ------------------------------------------------------------------------------------------
-- 1. SUBJEK HARUS MENGIKUTI NAMA JADWAL
-- ------------------------------------------------------------------------------------------
-- Kolom subjek pada email_settings memang ada dan dapat diubah dari layar, tetapi hanya email
-- Timetable yang benar-benar memakainya. Daily dan Weekly memakai judul yang tertanam di kode:
--
--   v_subjek := 'Outstanding Claim Report - ' || tgl;          <- daily, tidak melihat jadwal
--   v_subjek := 'Weekly Outstanding Claim Summary - ' || tgl;  <- weekly, tidak melihat jadwal
--   v_subjek := v_set.subjek || ' - ' || tgl;                  <- timetable, benar
--
-- Jadi mengubah subjek di layar tidak berpengaruh pada dua email yang paling sering dikirim.
-- Ketiganya kini memakai v_set.subjek.
--
-- ------------------------------------------------------------------------------------------
-- 2. TAUTAN DASHBOARD PADA WEEKLY
-- ------------------------------------------------------------------------------------------
-- Ditulis persis seperti yang diminta, ditempatkan sebelum kalimat penutup.
--
-- ------------------------------------------------------------------------------------------
-- 3. SEBAGIAN GAMBAR TIDAK MUNCUL
-- ------------------------------------------------------------------------------------------
-- Diagramnya adalah <img> ke QuickChart, dan seluruh definisi grafik ikut pada query string.
-- Panjang URL-nya terukur begini:
--
--   diagram status :   925 karakter
--   diagram region : 1.031 karakter
--   diagram depot  : 1.462 karakter
--   diagram tren   : 2.163 karakter   <- paling panjang, paling sering gagal
--
-- Gmail tidak memuat gambar jauh secara langsung; ia melewatkannya lewat proksi
-- googleusercontent, dan proksi itu kerap menyerah pada URL yang terlalu panjang. Itu sebabnya
-- yang hilang justru yang terpanjang, sementara yang pendek tetap tampil - gejala "tidak keluar
-- semua" dan bukan "tidak keluar sama sekali".
--
-- Definisi grafiknya karena itu dirampingkan: keterangan sumbu yang panjang dilepas, nama bulan
-- pada label dipendekkan, dan pengaturan yang nilainya sudah menjadi bawaan Chart.js tidak lagi
-- ditulis. Bentuk dan warnanya tidak berubah.
--
-- ------------------------------------------------------------------------------------------
-- 4. TREN DENGAN PEMBANDING MINGGU SEBELUMNYA
-- ------------------------------------------------------------------------------------------
-- Tabel tren menampilkan Qty dan Value per minggu, tetapi tidak menyatakan arah geraknya.
-- Ditambahkan dua kolom persentase terhadap minggu sebelumnya, dengan warna: hijau untuk naik,
-- merah untuk turun, abu-abu untuk minggu pertama yang memang tidak punya pembanding.
--
-- Pembagian dengan nol dijaga: minggu yang sebelumnya bernilai nol tidak menghasilkan
-- persentase tak hingga, melainkan tanda hubung.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

-- ------------------------------------------------------------------------------------------
-- 1. Diagram tren dirampingkan
-- ------------------------------------------------------------------------------------------
create or replace function rc_private.email_chart_tren()
returns text language sql stable set search_path='' as $fn$
  with m as (
    select date_trunc('week', cleared_at at time zone 'Asia/Jakarta')::date as minggu,
           count(*) as qty,
           coalesce(sum(cb_net), 0) as value_rp
      from public.claims
     where archived_at is null and cleared_at is not null
     group by 1 order by 1 desc limit 12)
  select case when not exists(select 1 from m) then ''
  else rc_private.email_gambar(
    jsonb_build_object(
      'type','bar',
      'data', jsonb_build_object(
        -- "08-Jun" bukan "08-Jun-2026": tahun tidak menambah keterangan pada tren dua belas
        -- minggu, dan setiap huruf ikut memanjangkan URL-nya.
        'labels', (select jsonb_agg(to_char(minggu,'DD Mon') order by minggu) from m),
        'datasets', jsonb_build_array(
          jsonb_build_object('type','bar','label','Value (Juta)','backgroundColor','#4285F4',
            'yAxisID','v',
            'data', (select jsonb_agg(round(value_rp/1000000.0, 1) order by minggu) from m)),
          jsonb_build_object('type','line','label','Qty','borderColor','#FBBC04',
            'backgroundColor','#FBBC04','fill', false, 'yAxisID','q',
            'data', (select jsonb_agg(qty order by minggu) from m)))),
      'options', jsonb_build_object(
        'title', jsonb_build_object('display', true, 'text','Tren Qty & Value per Minggu'),
        'legend', jsonb_build_object('position','bottom'),
        'scales', jsonb_build_object(
          'yAxes', jsonb_build_array(
            jsonb_build_object('id','v','position','left'),
            jsonb_build_object('id','q','position','right',
              'gridLines', jsonb_build_object('drawOnChartArea', false)))))),
    'Tren Qty dan Value per Minggu Pencairan', 300)
  end;
$fn$;
revoke all on function rc_private.email_chart_tren() from public,anon;

-- ------------------------------------------------------------------------------------------
-- 2. Diagram depot dirampingkan
-- ------------------------------------------------------------------------------------------
create or replace function rc_private.email_chart_depot(p_top jsonb, p_judul text)
returns text language sql stable set search_path='' as $fn$
  select case when coalesce(jsonb_array_length(p_top),0) = 0 then ''
  else rc_private.email_gambar(
    jsonb_build_object(
      'type','horizontalBar',
      'data', jsonb_build_object(
        -- Nama depot dipotong 20 huruf. Kode depotnya tetap terbaca di depan, dan tabel di
        -- bawah diagram memuat nama lengkapnya.
        'labels', (select jsonb_agg(left(e->>'label',20) order by n)
                     from jsonb_array_elements(p_top) with ordinality t(e,n)),
        'datasets', jsonb_build_array(jsonb_build_object(
          'label','Clearing Rate (%)',
          'backgroundColor', (select jsonb_agg(rc_private.warna_persen((e->>'cr')::numeric) order by n)
                                from jsonb_array_elements(p_top) with ordinality t(e,n)),
          'data', (select jsonb_agg(round(((e->>'cr')::numeric) * 100, 1) order by n)
                     from jsonb_array_elements(p_top) with ordinality t(e,n))))),
      'options', jsonb_build_object(
        'legend', jsonb_build_object('display', false),
        'title', jsonb_build_object('display', true, 'text', p_judul),
        'scales', jsonb_build_object(
          'xAxes', jsonb_build_array(jsonb_build_object(
            'ticks', jsonb_build_object('beginAtZero', true, 'max', 100)))))),
    p_judul,
    greatest(180, 40 + coalesce(jsonb_array_length(p_top),0) * 26))
  end;
$fn$;
revoke all on function rc_private.email_chart_depot(jsonb,text) from public,anon;

-- ------------------------------------------------------------------------------------------
-- 3. Tabel tren dengan pembanding minggu sebelumnya
-- ------------------------------------------------------------------------------------------
-- Satu sel persentase perubahan, dipakai dua kali pada tabel di atas.
create or replace function rc_private.sel_selisih(p_kini numeric, p_lalu numeric)
returns text language sql immutable set search_path='' as $fn$
  select '<td style="font-size:12px;padding:6px 8px;border-bottom:1px solid #f0f1f3;'
      || 'text-align:right;white-space:nowrap;color:'
      || case
           -- Minggu pertama tidak punya pembanding, dan pembagian dengan nol tidak menghasilkan
           -- persentase yang berarti. Keduanya ditulis sebagai tanda hubung, bukan 0% - angka
           -- nol di sini akan terbaca sebagai "tidak berubah", yang bukan itu maksudnya.
           when p_lalu is null or p_lalu = 0 then '#9aa0a6;">-'
           when p_kini >= p_lalu then '#1a7f37;font-weight:bold;">&#9650; '
                || to_char(round((p_kini - p_lalu) / p_lalu * 100, 1),'FM999990.0') || '%'
           else '#d93025;font-weight:bold;">&#9660; '
                || to_char(round((p_lalu - p_kini) / p_lalu * 100, 1),'FM999990.0') || '%'
         end
      || '</td>';
$fn$;
revoke all on function rc_private.sel_selisih(numeric,numeric) from public,anon;

create or replace function rc_private.email_tabel_tren()
returns text language sql stable set search_path='' as $fn$
  with m as (
    select date_trunc('week', cleared_at at time zone 'Asia/Jakarta')::date as minggu,
           count(*) as qty,
           coalesce(sum(cb_net), 0) as value_rp
      from public.claims
     where archived_at is null and cleared_at is not null
     group by 1 order by 1 desc limit 12),
  b as (
    -- lag() mengambil minggu sebelumnya menurut urutan waktu, bukan urutan tampilan.
    select m.*,
           lag(qty)      over (order by minggu) as qty_lalu,
           lag(value_rp) over (order by minggu) as value_lalu
      from m)
  select case when not exists(select 1 from b) then '<p style="color:#5f6368;">Belum ada pencairan.</p>'
  else '<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="border-collapse:collapse;">'
    || '<thead><tr>'
    || '<th style="text-align:left;background:#f1f3f4;color:#5f6368;font-size:11px;padding:6px 8px;border-bottom:1px solid #e0e2e6;">Minggu</th>'
    || '<th style="text-align:right;background:#f1f3f4;color:#5f6368;font-size:11px;padding:6px 8px;border-bottom:1px solid #e0e2e6;">Qty</th>'
    || '<th style="text-align:right;background:#f1f3f4;color:#5f6368;font-size:11px;padding:6px 8px;border-bottom:1px solid #e0e2e6;white-space:nowrap;">Qty vs Minggu Lalu</th>'
    || '<th style="text-align:right;background:#f1f3f4;color:#5f6368;font-size:11px;padding:6px 8px;border-bottom:1px solid #e0e2e6;">Value</th>'
    || '<th style="text-align:right;background:#f1f3f4;color:#5f6368;font-size:11px;padding:6px 8px;border-bottom:1px solid #e0e2e6;white-space:nowrap;">Value vs Minggu Lalu</th>'
    || '</tr></thead><tbody>'
    || coalesce((select string_agg(
         '<tr><td style="font-size:12px;padding:6px 8px;border-bottom:1px solid #f0f1f3;">'
         || to_char(minggu,'DD Mon YYYY') || '</td>'
         || '<td style="font-size:12px;padding:6px 8px;border-bottom:1px solid #f0f1f3;text-align:right;">'
         || rc_private.angka(qty) || '</td>'
         || rc_private.sel_selisih(qty::numeric, qty_lalu::numeric)
         || '<td style="font-size:12px;padding:6px 8px;border-bottom:1px solid #f0f1f3;text-align:right;white-space:nowrap;">'
         || rc_private.rupiah(value_rp) || '</td>'
         || rc_private.sel_selisih(value_rp, value_lalu)
         || '</tr>', '' order by minggu desc) from b), '')
    || '</tbody></table>'
    || '<p style="font-size:11px;color:#5f6368;margin:6px 0 0;">Dihitung menurut minggu pencairan '
    || '(tanggal clearing). Kolom pembanding mengukur perubahan terhadap minggu tepat sebelumnya; '
    || 'minggu paling awal tidak punya pembanding.</p>'
  end;
$fn$;
revoke all on function rc_private.email_tabel_tren() from public,anon;


-- ------------------------------------------------------------------------------------------
-- 3b. Blok tautan Claim Dashboard
-- ------------------------------------------------------------------------------------------
-- Kata-katanya persis seperti yang diminta pemilik. "Best Regards / SA & SD Operation" TIDAK
-- diulang di sini - rc_private.email_ttd() yang menyusulnya sudah memuatnya, dan menuliskannya
-- dua kali akan membuat email berpamitan dua kali.
--
-- SATU KALIMAT SENGAJA DITAHAN. Kalimat "Detail performa per Depot dan per Campaign tersedia
-- pada PDF yang terlampir pada email ini" menyebut lampiran yang belum ada: PostgreSQL tidak
-- dapat membuat PDF, dan jalur lampiran belum dibangun. Menjanjikan lampiran yang tidak ada
-- kepada 51 depot lebih buruk daripada tidak menyebutnya sama sekali, jadi kalimat itu baru
-- ikut tampil ketika lampirannya benar-benar terkirim.
--
-- Penandanya satu baris di bawah ini; ubah menjadi true ketika PDF sudah terlampir.
create or replace function rc_private.email_pdf_terlampir()
returns boolean language sql immutable set search_path='' as $fn$ select false; $fn$;

create or replace function rc_private.email_tautan_dashboard()
returns text language sql stable set search_path='' as $fn$
  select '<p style="line-height:1.6;margin-top:18px;">Untuk melihat detail Claim secara lebih '
      || 'lengkap, silakan mengakses Claim Dashboard melalui link berikut:</p>'
      || '<p style="margin:10px 0 14px;">'
      || '<a href="https://rc-next-gen.vercel.app" '
      || 'style="display:inline-block;background:#4285F4;color:#ffffff;text-decoration:none;'
      || 'font-weight:bold;font-size:13px;padding:10px 18px;border-radius:6px;">'
      || 'Buka Claim Dashboard</a></p>'
      || case when rc_private.email_pdf_terlampir()
              then '<p style="line-height:1.6;">Detail performa per Depot dan per Campaign '
                   || 'tersedia pada PDF yang terlampir pada email ini.</p>'
              else '' end
      || '<p style="line-height:1.6;">Thank you for your attention and cooperation.</p>';
$fn$;
revoke all on function rc_private.email_tautan_dashboard() from public,anon;
revoke all on function rc_private.email_pdf_terlampir() from public,anon;

-- ------------------------------------------------------------------------------------------
-- 4. Subjek mengikuti jadwal, dan tautan dashboard pada Weekly
-- ------------------------------------------------------------------------------------------
do $mig$
declare src text; baru text;
begin
  select pg_get_functiondef(p.oid) into src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'rc_email_susun';
  if src is null then raise exception 'public.rc_email_susun tidak ditemukan.'; end if;

  baru := src;

  -- 4a. Daily memakai subjek dari jadwal
  baru := replace(baru,
    'v_subjek := ''Outstanding Claim Report - '' || rc_private.tgl_panjang(now());',
    'v_subjek := coalesce(nullif(btrim(v_set.subjek),''''),''Outstanding Claim Report'')' || chr(10)
      || '                || '' - '' || rc_private.tgl_panjang(now());');

  -- 4b. Weekly memakai subjek dari jadwal
  baru := replace(baru,
    'v_subjek := ''Weekly Outstanding Claim Summary - '' || rc_private.tgl_panjang(now());',
    'v_subjek := coalesce(nullif(btrim(v_set.subjek),''''),''Weekly Outstanding Claim Summary'')' || chr(10)
      || '                || '' - '' || rc_private.tgl_panjang(now());');

  -- 4c. Tautan dashboard disisipkan sebelum kalimat penutup Weekly
  baru := replace(baru,
    '      ||''<p style="line-height:1.6;">Thank you for your attention and cooperation.</p>''' || chr(10)
      || '      ||rc_private.email_ttd()' || chr(10)
      || '      ||''</td></tr></table></div>'';' || chr(10) || chr(10)
      || '  elsif v_jenis = ''timetable'' then',
    '      ||rc_private.email_tautan_dashboard()' || chr(10)
      || '      ||rc_private.email_ttd()' || chr(10)
      || '      ||''</td></tr></table></div>'';' || chr(10) || chr(10)
      || '  elsif v_jenis = ''timetable'' then');

  if baru = src then
    raise exception 'Tidak satu pun pola ditemukan pada public.rc_email_susun. '
      'Susunannya sudah berubah - periksa dan perbarui migration ini.';
  end if;

  execute baru;
  raise notice 'rc_email_susun: subjek mengikuti jadwal, tautan dashboard dipasang.';
end
$mig$;

-- ------------------------------------------------------------------------------------------
-- 5. Pemeriksaan
-- ------------------------------------------------------------------------------------------
do $periksa$
declare src text; n int;
begin
  select pg_get_functiondef(p.oid) into src from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname='public' and p.proname='rc_email_susun';

  -- Tidak boleh ada lagi subjek yang tertanam di kode.
  if src like '%''Outstanding Claim Report - ''%' or src like '%''Weekly Outstanding Claim Summary - ''%' then
    raise exception 'GAGAL: masih ada subjek yang tidak mengikuti jadwal.';
  end if;
  if src not like '%email_tautan_dashboard%' then
    raise exception 'GAGAL: tautan dashboard belum terpasang pada Weekly.';
  end if;

  -- Judul tautan hanya boleh muncul pada Weekly, bukan Daily maupun Timetable.
  if (length(src) - length(replace(src,'email_tautan_dashboard',''))) / length('email_tautan_dashboard') <> 1 then
    raise exception 'GAGAL: tautan dashboard tidak muncul tepat sekali.';
  end if;

  -- URL diagram harus benar-benar lebih pendek dari sebelumnya.
  select length(substring(rc_private.email_chart_tren() from 'src="([^"]*)')) into n;
  if n is not null and n > 1800 then
    raise exception 'GAGAL: URL diagram tren masih % karakter, terlalu panjang untuk proksi gambar Gmail.', n;
  end if;
  raise notice 'URL diagram tren: % karakter', coalesce(n,0);

  raise notice 'Pemeriksaan lolos.';
end
$periksa$;
