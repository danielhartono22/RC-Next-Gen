-- ==========================================================================================
-- Tren mingguan: cukup Qty dan Value
-- ==========================================================================================
-- Pemilik menyederhanakan, 20 September 2026:
--
--   "trend vol dan nilai klaim cukup Qty dan Value / nilai klaim aja (jadi value aja penamaannya)"
--
-- Jadi deret Volume diganti Qty - banyaknya dokumen - dan penamaan "Nilai Klaim" dipendekkan
-- menjadi "Value". Judul bagiannya ikut berubah menjadi "Tren Qty & Value per Minggu".
--
-- Perubahan ini sekaligus MELEPASKAN diagram dari cacat data yang kemarin harus disiasati.
-- Kolom volume tercemar - 172 dokumen memuat nilai rupiah, 134 di antaranya sama persis dengan
-- net_value - sehingga deret volume terpaksa memakai penyaring nisbah harga satuan, lengkap
-- dengan keterangan kaki yang menjelaskan apa yang tidak ikut dijumlahkan.
--
-- Qty tidak punya persoalan itu: ia hanya menghitung baris, dan tidak ada baris yang nilainya
-- salah kolom. Penyaring nisbah dan keterangan kakinya ikut dibuang karena tidak ada lagi yang
-- perlu disiasati. Cacat kolom volume itu sendiri tetap ada di data dan tetap tercatat pada
-- docs/rc-anomali-20-september.md - yang hilang hanya ketergantungan diagram ini kepadanya.
--
-- Sumbu waktunya tidak berubah: minggu pencairan (cleared_at), satu-satunya tanggal pada klaim
-- yang tersebar cukup untuk dijadikan tren. Alasannya tercatat pada migration 20261113010000.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

-- ------------------------------------------------------------------------------------------
-- 1. Diagram: batang untuk Value, garis untuk Qty
-- ------------------------------------------------------------------------------------------
create or replace function rc_private.email_chart_tren()
returns text language sql stable set search_path='' as $fn$
  with m as (
    select date_trunc('week', cleared_at at time zone 'Asia/Jakarta')::date as minggu,
           count(*) as qty,
           coalesce(sum(cb_net), 0) as value_rp
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
          jsonb_build_object('type','bar','label','Value (Juta)','backgroundColor','#4285F4',
            'yAxisID','value',
            'data', (select jsonb_agg(round(value_rp/1000000.0, 1) order by minggu) from m)),
          jsonb_build_object('type','line','label','Qty','borderColor','#FBBC04',
            'backgroundColor','#FBBC04','fill', false, 'lineTension', 0.3, 'yAxisID','qty',
            'data', (select jsonb_agg(qty order by minggu) from m)))),
      'options', jsonb_build_object(
        'title', jsonb_build_object('display', true,
          'text','Tren Qty & Value per Minggu Pencairan', 'fontSize', 13),
        'legend', jsonb_build_object('position','bottom',
          'labels', jsonb_build_object('fontSize', 11, 'boxWidth', 12)),
        'scales', jsonb_build_object(
          'xAxes', jsonb_build_array(jsonb_build_object(
            'ticks', jsonb_build_object('fontSize', 10))),
          'yAxes', jsonb_build_array(
            jsonb_build_object('id','value','position','left',
              'ticks', jsonb_build_object('beginAtZero', true, 'fontSize', 10),
              'scaleLabel', jsonb_build_object('display', true, 'labelString','Value (Juta Rp)')),
            jsonb_build_object('id','qty','position','right',
              'gridLines', jsonb_build_object('drawOnChartArea', false),
              'ticks', jsonb_build_object('beginAtZero', true, 'fontSize', 10, 'precision', 0),
              'scaleLabel', jsonb_build_object('display', true, 'labelString','Qty (dokumen)')))))),
    'Tren Qty dan Value per Minggu Pencairan', 300)
  end;
$fn$;
revoke all on function rc_private.email_chart_tren() from public,anon;

-- ------------------------------------------------------------------------------------------
-- 2. Tabel angkanya - dua kolom saja, sesuai diagramnya
-- ------------------------------------------------------------------------------------------
create or replace function rc_private.email_tabel_tren()
returns text language sql stable set search_path='' as $fn$
  with m as (
    select date_trunc('week', cleared_at at time zone 'Asia/Jakarta')::date as minggu,
           count(*) as qty,
           coalesce(sum(cb_net), 0) as value_rp
      from public.claims
     where archived_at is null and cleared_at is not null
     group by 1 order by 1 desc limit 12)
  select case when not exists(select 1 from m) then '<p style="color:#5f6368;">Belum ada pencairan.</p>'
  else '<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="border-collapse:collapse;">'
    || '<thead><tr>'
    || '<th style="text-align:left;background:#f1f3f4;color:#5f6368;font-size:11px;padding:6px 8px;border-bottom:1px solid #e0e2e6;">Minggu</th>'
    || '<th style="text-align:right;background:#f1f3f4;color:#5f6368;font-size:11px;padding:6px 8px;border-bottom:1px solid #e0e2e6;">Qty</th>'
    || '<th style="text-align:right;background:#f1f3f4;color:#5f6368;font-size:11px;padding:6px 8px;border-bottom:1px solid #e0e2e6;">Value</th>'
    || '</tr></thead><tbody>'
    || coalesce((select string_agg(
         '<tr><td style="font-size:12px;padding:6px 8px;border-bottom:1px solid #f0f1f3;">'
         || to_char(minggu,'DD Mon YYYY') || '</td>'
         || '<td style="font-size:12px;padding:6px 8px;border-bottom:1px solid #f0f1f3;text-align:right;">'
         || rc_private.angka(qty) || '</td>'
         || '<td style="font-size:12px;padding:6px 8px;border-bottom:1px solid #f0f1f3;text-align:right;white-space:nowrap;">'
         || rc_private.rupiah(value_rp) || '</td></tr>', '' order by minggu desc) from m), '')
    || '</tbody></table>'
    || '<p style="font-size:11px;color:#5f6368;margin:6px 0 0;">Dihitung menurut minggu pencairan '
    || '(tanggal clearing).</p>'
  end;
$fn$;
revoke all on function rc_private.email_tabel_tren() from public,anon;

-- ------------------------------------------------------------------------------------------
-- 3. Judul bagiannya ikut berubah
-- ------------------------------------------------------------------------------------------
do $judul$
declare src text; baru text;
begin
  select pg_get_functiondef(p.oid) into src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'rc_email_susun';
  if src is null then raise exception 'public.rc_email_susun tidak ditemukan.'; end if;

  if position('Tren Qty &amp; Value per Minggu' in src) > 0 then
    raise notice 'Judul sudah diperbarui; dilewati.';
    return;
  end if;

  baru := replace(src, 'Tren Volume &amp; Nilai Klaim per Minggu', 'Tren Qty &amp; Value per Minggu');
  if baru = src then
    raise exception 'Judul lama "Tren Volume &amp; Nilai Klaim per Minggu" tidak ditemukan pada '
      'rc_email_susun; periksa dan perbarui migration ini.';
  end if;
  execute baru;
  raise notice 'rc_email_susun: judul bagian tren diperbarui.';
end
$judul$;

-- ------------------------------------------------------------------------------------------
-- 4. Pemeriksaan
-- ------------------------------------------------------------------------------------------
do $periksa$
declare src text;
begin
  select pg_get_functiondef(p.oid) into src from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname='public' and p.proname='rc_email_susun';

  if position('Tren Qty &amp; Value per Minggu' in src) = 0 then
    raise exception 'GAGAL: judul tren belum berubah menjadi Qty & Value.';
  end if;
  if position('Tren Volume' in src) > 0 then
    raise exception 'GAGAL: judul lama masih tersisa di rc_email_susun.';
  end if;

  -- Diagram dan tabelnya tidak boleh lagi menyentuh kolom volume.
  select pg_get_functiondef(p.oid) into src from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname='rc_private' and p.proname='email_chart_tren';
  if position('volume' in src) > 0 then
    raise exception 'GAGAL: diagram tren masih memakai kolom volume.';
  end if;

  select pg_get_functiondef(p.oid) into src from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname='rc_private' and p.proname='email_tabel_tren';
  if position('volume' in src) > 0 then
    raise exception 'GAGAL: tabel tren masih memakai kolom volume.';
  end if;

  raise notice 'Pemeriksaan lolos.';
end
$periksa$;
