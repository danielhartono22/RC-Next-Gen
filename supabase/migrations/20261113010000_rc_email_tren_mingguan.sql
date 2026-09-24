-- ==========================================================================================
-- Email Weekly: Tren Volume & Nilai Klaim per Minggu
-- ==========================================================================================
-- Permintaan pemilik, 20 September 2026: "di weekly belum memasukan Tren Volume & Nilai Klaim
-- per Minggu seperti folder yang saya kirim".
--
-- Bagian ini memang belum ada. Migration 20261110010000 menambahkan tiga diagram - Top 10 Depot,
-- Distribusi Status dan Value per Region - karena ketiganya punya JUDUL yang sudah tercetak di
-- badan email, sehingga tempatnya tidak perlu ditebak. Tren mingguan tidak punya judul itu, jadi
-- ia terlewat. Sekarang bagiannya dibuat utuh: judul, diagram, lalu tabel angkanya.
--
-- ------------------------------------------------------------------------------------------
-- SUMBU WAKTUNYA: cleared_at, DAN INI PERLU DIKETAHUI
-- ------------------------------------------------------------------------------------------
-- Sebuah tren perlu tanggal yang tersebar. Dari empat tanggal pada klaim, hanya satu yang
-- memenuhinya:
--
--   created_at    2.754 terisi, TETAPI seluruhnya 15-Sep-2026 - tanggal impor, bukan kejadian
--   uploaded_at     171 terisi  - terlalu sedikit, 94% dokumen tidak punya
--   paid_on          33 terisi  - jauh terlalu sedikit
--   cleared_at    1.111 terisi, tersebar 23-Agu-2025 sampai 20-Sep-2026
--
-- Maka trennya disusun menurut MINGGU PENCAIRAN, dan judulnya menyebutkan itu terang-terangan
-- supaya tidak ada yang membacanya sebagai minggu pengajuan. Ketika kelak uploaded_at terisi
-- untuk sebagian besar dokumen, sumbunya dapat dipindahkan dengan mengubah satu baris di sini.
--
-- ------------------------------------------------------------------------------------------
-- PERINGATAN TENTANG KOLOM VOLUME
-- ------------------------------------------------------------------------------------------
-- Kolom volume tidak bersih. Dari 1.122 klaim yang volumenya di atas nol, sebagian memuat NILAI
-- RUPIAH, bukan kuantitas:
--
--   134  bernilainya PERSIS SAMA dengan net_value - Net Value tersalin ke kolom Volume
--   172  nisbah net_value terhadap volume di bawah 100 - mustahil bagi harga satuan
--   703  nisbahnya wajar, jelas kuantitas
--
-- Yang terbesar mencapai 24.651.571.597, sama persis dengan net_value dokumennya. Ada pula yang
-- dibulatkan: 1.800.000.000 pada dokumen ber-net_value 1.822.313.193.
--
-- AMBANG MUTLAK TIDAK DAPAT DIPAKAI, dan ini sempat saya salah duga. Baris ber-volume 10.795
-- terlihat besar, tetapi net_value-nya Rp 781 juta - harga satuannya sekitar Rp 72.000, jadi ia
-- kuantitas yang sah. Memotong pada sepuluh ribu akan membuang data yang benar.
--
-- Yang membedakan adalah NISBAH: net_value dibagi volume. Pada baris yang sah, nisbah itu adalah
-- harga satuan dan selalu di atas seratus rupiah. Pada baris yang tercemar, volume kira-kira
-- sebesar net_value sendiri sehingga nisbahnya mendekati satu. Itulah penyaring yang dipakai.
--
-- Barisnya disaring, bukan disembunyikan: batasnya disebut di keterangan bawah tabel. Menyaring
-- diam-diam sama buruknya dengan tidak menyaring - yang satu berbohong tentang angkanya, yang
-- lain berbohong tentang bentuknya. Perbaikan sesungguhnya ada di data, dan dilaporkan terpisah.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

-- ------------------------------------------------------------------------------------------
-- 1. Diagram tren - batang untuk nilai, garis untuk volume, dua sumbu tegak
-- ------------------------------------------------------------------------------------------
create or replace function rc_private.email_chart_tren()
returns text language sql stable set search_path='' as $fn$
  with m as (
    select date_trunc('week', cleared_at at time zone 'Asia/Jakarta')::date as minggu,
           coalesce(sum(cb_net), 0) as nilai,
           -- Hanya volume yang masuk akal sebagai kuantitas; lihat catatan kepala berkas.
           -- Pembedanya NISBAH net_value terhadap volume, bukan besaran volume itu sendiri.
           coalesce(sum(volume) filter (
             where volume > 0
               and (net_value is null or net_value <= 0 or net_value / volume >= 100)), 0) as vol
      from public.claims
     where archived_at is null and cleared_at is not null
     group by 1
     order by 1 desc
     limit 12)
  select case when not exists(select 1 from m) then ''
  else rc_private.email_gambar(
    jsonb_build_object(
      'type','bar',
      'data', jsonb_build_object(
        'labels', (select jsonb_agg(to_char(minggu,'DD-Mon') order by minggu) from m),
        'datasets', jsonb_build_array(
          jsonb_build_object('type','bar','label','Nilai Klaim (Juta)','backgroundColor','#4285F4',
            'yAxisID','nilai',
            'data', (select jsonb_agg(round(nilai/1000000.0, 1) order by minggu) from m)),
          jsonb_build_object('type','line','label','Volume','borderColor','#FBBC04',
            'backgroundColor','#FBBC04','fill', false, 'lineTension', 0.3, 'yAxisID','volume',
            'data', (select jsonb_agg(round(vol, 1) order by minggu) from m)))),
      'options', jsonb_build_object(
        'title', jsonb_build_object('display', true,
          'text','Tren Volume & Nilai Klaim per Minggu Pencairan', 'fontSize', 13),
        'legend', jsonb_build_object('position','bottom',
          'labels', jsonb_build_object('fontSize', 11, 'boxWidth', 12)),
        'scales', jsonb_build_object(
          'xAxes', jsonb_build_array(jsonb_build_object(
            'ticks', jsonb_build_object('fontSize', 10))),
          'yAxes', jsonb_build_array(
            jsonb_build_object('id','nilai','position','left',
              'ticks', jsonb_build_object('beginAtZero', true, 'fontSize', 10),
              'scaleLabel', jsonb_build_object('display', true, 'labelString','Nilai (Juta Rp)')),
            jsonb_build_object('id','volume','position','right',
              'gridLines', jsonb_build_object('drawOnChartArea', false),
              'ticks', jsonb_build_object('beginAtZero', true, 'fontSize', 10),
              'scaleLabel', jsonb_build_object('display', true, 'labelString','Volume')))))),
    'Tren Volume dan Nilai Klaim per Minggu Pencairan', 300)
  end;
$fn$;
revoke all on function rc_private.email_chart_tren() from public,anon;

-- ------------------------------------------------------------------------------------------
-- 2. Tabel angkanya, seperti bagian lain: diagram di atas, angka di bawah
-- ------------------------------------------------------------------------------------------
-- Pembaca yang mail client-nya memblokir gambar jauh tetap memperoleh seluruh angkanya di sini,
-- sama seperti pada tiga bagian bergambar yang lain.
create or replace function rc_private.email_tabel_tren()
returns text language sql stable set search_path='' as $fn$
  with m as (
    select date_trunc('week', cleared_at at time zone 'Asia/Jakarta')::date as minggu,
           count(*) as jml,
           coalesce(sum(cb_net), 0) as nilai,
           coalesce(sum(volume) filter (
             where volume > 0
               and (net_value is null or net_value <= 0 or net_value / volume >= 100)), 0) as vol
      from public.claims
     where archived_at is null and cleared_at is not null
     group by 1 order by 1 desc limit 12)
  select case when not exists(select 1 from m) then '<p style="color:#5f6368;">Belum ada pencairan.</p>'
  else '<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="border-collapse:collapse;">'
    || '<thead><tr>'
    || '<th style="text-align:left;background:#f1f3f4;color:#5f6368;font-size:11px;padding:6px 8px;border-bottom:1px solid #e0e2e6;">Minggu</th>'
    || '<th style="text-align:right;background:#f1f3f4;color:#5f6368;font-size:11px;padding:6px 8px;border-bottom:1px solid #e0e2e6;">Dokumen</th>'
    || '<th style="text-align:right;background:#f1f3f4;color:#5f6368;font-size:11px;padding:6px 8px;border-bottom:1px solid #e0e2e6;">Volume</th>'
    || '<th style="text-align:right;background:#f1f3f4;color:#5f6368;font-size:11px;padding:6px 8px;border-bottom:1px solid #e0e2e6;">Nilai Klaim</th>'
    || '</tr></thead><tbody>'
    || coalesce((select string_agg(
         '<tr><td style="font-size:12px;padding:6px 8px;border-bottom:1px solid #f0f1f3;">'
         || to_char(minggu,'DD Mon YYYY') || '</td>'
         || '<td style="font-size:12px;padding:6px 8px;border-bottom:1px solid #f0f1f3;text-align:right;">'
         || rc_private.angka(jml) || '</td>'
         || '<td style="font-size:12px;padding:6px 8px;border-bottom:1px solid #f0f1f3;text-align:right;">'
         || rc_private.angka(vol) || '</td>'
         || '<td style="font-size:12px;padding:6px 8px;border-bottom:1px solid #f0f1f3;text-align:right;white-space:nowrap;">'
         || rc_private.rupiah(nilai) || '</td></tr>', '' order by minggu desc) from m), '')
    || '</tbody></table>'
    || '<p style="font-size:11px;color:#5f6368;margin:6px 0 0;">Dihitung menurut minggu pencairan '
    || '(tanggal clearing). Kolom Volume hanya menjumlahkan baris yang harga satuannya masuk akal '
    || '(Net Value dibagi Volume paling sedikit Rp 100); sebagian baris pada basis data memuat '
    || 'nilai rupiah di kolom Volume dan sengaja tidak ikut dijumlahkan.</p>'
  end;
$fn$;
revoke all on function rc_private.email_tabel_tren() from public,anon;

-- ------------------------------------------------------------------------------------------
-- 3. Menyisipkan bagiannya ke email Weekly
-- ------------------------------------------------------------------------------------------
-- Diletakkan tepat sebelum "Top 10 Depot": kartu KPI memberi keadaan hari ini, tren memberi
-- arah geraknya, lalu bagian-bagian berikutnya merinci di mana masalahnya.
do $sisip$
declare src text; baru text;
begin
  select pg_get_functiondef(p.oid) into src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'rc_email_susun';
  if src is null then raise exception 'public.rc_email_susun tidak ditemukan.'; end if;

  if position('email_chart_tren' in src) > 0 then
    raise notice 'rc_email_susun sudah memuat tren mingguan; dilewati.';
    return;
  end if;

  baru := replace(src,
    '||''<h3 style="font-size:15px;margin:26px 0 8px;border-left:4px solid #4285F4;padding-left:8px;">Top 10 Depot dengan Clearing Rate Terendah</h3>''',
    '||''<h3 style="font-size:15px;margin:26px 0 8px;border-left:4px solid #4285F4;padding-left:8px;">Tren Volume &amp; Nilai Klaim per Minggu</h3>''' || chr(10)
      || '      ||rc_private.email_chart_tren()' || chr(10)
      || '      ||rc_private.email_tabel_tren()' || chr(10)
      || '      ||''<h3 style="font-size:15px;margin:26px 0 8px;border-left:4px solid #4285F4;padding-left:8px;">Top 10 Depot dengan Clearing Rate Terendah</h3>''');

  if baru = src then
    raise exception 'Judul "Top 10 Depot" tidak ditemukan pada rc_email_susun; '
      'susunannya sudah berubah - periksa dan perbarui migration ini.';
  end if;

  execute baru;
  raise notice 'rc_email_susun: bagian tren mingguan disisipkan.';
end
$sisip$;

-- ------------------------------------------------------------------------------------------
-- 4. Pemeriksaan
-- ------------------------------------------------------------------------------------------
do $periksa$
declare src text;
begin
  select pg_get_functiondef(p.oid) into src from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname='public' and p.proname='rc_email_susun';

  if position('email_chart_tren' in src) = 0 or position('email_tabel_tren' in src) = 0 then
    raise exception 'GAGAL: rc_email_susun belum memanggil tren mingguan.';
  end if;

  -- Bagian ini hanya untuk Weekly. Judulnya harus muncul tepat sekali.
  if (length(src) - length(replace(src,'Tren Volume',''))) / length('Tren Volume') <> 1 then
    raise exception 'GAGAL: judul tren tidak muncul tepat sekali.';
  end if;

  raise notice 'Pemeriksaan lolos.';
end
$periksa$;
