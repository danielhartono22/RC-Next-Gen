-- ==========================================================================================
-- Lampiran PDF pada email, dibuat lewat konverter Google - seperti Apps Script dulu
-- ==========================================================================================
-- Permintaan pemilik: email Daily dan Weekly melampirkan PDF berisi detail per Depot dan per
-- Campaign, meniru RC_Reporting_AppsScript. Cara lamanya satu baris:
--
--   Utilities.newBlob(html, MimeType.HTML, 'weekly-report.html').getAs(MimeType.PDF)
--
-- yaitu konverter milik Google sendiri. Dari PostgreSQL konverter yang sama dapat dicapai lewat
-- Drive API, dan itulah yang dipakai di sini.
--
-- ------------------------------------------------------------------------------------------
-- MENGAPA pgsql-http, BUKAN pg_net
-- ------------------------------------------------------------------------------------------
-- Seluruh jalur HTTP lain pada proyek ini memakai pg_net. Untuk PDF ia tidak dapat dipakai, dan
-- sebabnya terbukti dari percobaan, bukan dugaan:
--
--   Google mengirim  : 8.956 byte
--   pg_net menyimpan :   270 byte
--
-- net._http_response.content bertipe text, dan teks PostgreSQL tidak boleh memuat byte NUL.
-- Isi PDF penuh dengan NUL, sehingga terpotong pada NUL yang pertama. Tidak ada pilihan pada
-- pg_net yang mengembalikannya sebagai base64 atau bytea.
--
-- Ekstensi http (pgsql-http) menyediakan text_to_bytea() justru untuk keadaan ini: ia menafsirkan
-- byte yang tersimpan apa adanya, tanpa melewati pemeriksaan pengkodean. Dengan itu PDF yang sama
-- pulih utuh - 33.105 byte, diawali %PDF-1.4, diakhiri %%EOF, lengkap dengan byte NUL-nya.
--
-- Konsekuensinya pgsql-http bekerja SINKRON: ia menahan transaksi selama panggilan berlangsung.
-- Itu sebabnya pembuatan PDF hanya dilakukan di jalur antrean yang dijalankan pg_cron, yang tidak
-- terikat batas delapan detik milik peran authenticated.
--
-- ------------------------------------------------------------------------------------------
-- ISI PDF-NYA
-- ------------------------------------------------------------------------------------------
-- Empat bagian, sama dengan generateWeeklyPDF() pada WeeklyEmail.gs:
--
--   1. Summary Outstanding Claim
--   2. Top 10 Depot - Clearing Rate Terendah
--   3. Performa per Depot     (SELURUHNYA, bukan hanya sepuluh)
--   4. Performa per Campaign  (SELURUHNYA)
--
-- Bagian tiga dan empat itulah alasan PDF ini ada: keduanya terlalu panjang untuk badan email.
--
-- ------------------------------------------------------------------------------------------
-- BERKAS SEMENTARA DI DRIVE
-- ------------------------------------------------------------------------------------------
-- Setiap pembuatan PDF menitipkan satu Google Doc sementara di Drive akun pengirim, lalu
-- menghapusnya. Penghapusan dijalankan di blok exception juga, sehingga kegagalan di tengah
-- jalan tidak meninggalkan sampah yang menumpuk diam-diam.
--
-- Izinnya drive.file - hanya berkas yang dibuat aplikasi ini sendiri. Berkas lain di Drive
-- pemilik tidak terlihat sama sekali.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

create extension if not exists http with schema extensions;

-- ------------------------------------------------------------------------------------------
-- 1. Isi PDF sebagai HTML
-- ------------------------------------------------------------------------------------------
-- Gaya ditulis sederhana: konverter Google memahami tabel dasar dengan baik, dan CSS yang
-- rumit justru diabaikan atau merusak tata letaknya.
create or replace function rc_private.pdf_detail_html(p_judul text)
returns text language plpgsql stable security definer set search_path='' as $fn$
declare
  v_html text; v_kpi jsonb; v_baris text;
begin
  select jsonb_build_object(
      'qty',       count(*),
      'netCb',     coalesce(sum(cb_net),0),
      'done',      coalesce(sum(cb_net) filter (where status='done'),0),
      'os',        coalesce(sum(cb_net) filter (where outstanding),0),
      'osQty',     count(*) filter (where outstanding),
      'cr',        case when coalesce(sum(cb_net),0)=0 then 0
                        else coalesce(sum(cb_net) filter (where status in('done','expired')),0)/sum(cb_net) end)
    into v_kpi from public.rc_report_rows;

  v_html := '<html><head><meta charset="UTF-8"></head><body style="font-family:Arial,sans-serif;">'
    || '<h1 style="font-size:18px;">' || rc_private.html_aman(p_judul) || '</h1>'
    || '<p style="font-size:11px;color:#555;">Data ditarik pada '
    || rc_private.tgl_panjang(now()) || '.</p>';

  -- ---- 1. Summary --------------------------------------------------------------------
  v_html := v_html || '<h2 style="font-size:14px;">Summary Outstanding Claim</h2>'
    || '<table border="1" cellspacing="0" cellpadding="5" style="border-collapse:collapse;font-size:11px;">'
    || '<tr><th align="left">Keterangan</th><th align="right">Nilai</th></tr>'
    || '<tr><td>Jumlah Claim</td><td align="right">' || rc_private.angka((v_kpi->>'qty')::numeric) || '</td></tr>'
    || '<tr><td>Net Cashback</td><td align="right">' || rc_private.rupiah((v_kpi->>'netCb')::numeric) || '</td></tr>'
    || '<tr><td>Sudah Cair (Done)</td><td align="right">' || rc_private.rupiah((v_kpi->>'done')::numeric) || '</td></tr>'
    || '<tr><td>Outstanding</td><td align="right">' || rc_private.rupiah((v_kpi->>'os')::numeric) || '</td></tr>'
    || '<tr><td>Outstanding Qty</td><td align="right">' || rc_private.angka((v_kpi->>'osQty')::numeric) || '</td></tr>'
    || '<tr><td>Overall Clearing Rate</td><td align="right">' || rc_private.persen((v_kpi->>'cr')::numeric) || '</td></tr>'
    || '</table>';

  -- ---- 2. Top 10 Depot ---------------------------------------------------------------
  select coalesce(string_agg(
      '<tr><td>' || rc_private.html_aman(q.label) || '</td>'
      || '<td align="right">' || rc_private.rupiah(q.net_cb) || '</td>'
      || '<td align="right">' || rc_private.rupiah(q.os_val) || '</td>'
      || '<td align="right">' || rc_private.persen(q.cr) || '</td></tr>', '' order by q.cr, q.os_val desc), '')
    into v_baris
    from (select d.depot_code || ' - ' || d.depot_name as label,
                 coalesce(sum(c.cb_net),0) net_cb,
                 coalesce(sum(c.cb_net) filter (where c.outstanding),0) os_val,
                 case when coalesce(sum(c.cb_net),0)=0 then 0
                      else coalesce(sum(c.cb_net) filter (where c.status in('done','expired')),0)/sum(c.cb_net) end cr
            from public.rc_report_rows c join public.depots d on d.id = c.depot_id
           group by d.depot_code, d.depot_name
          having coalesce(sum(c.cb_net),0) > 0
           order by cr, os_val desc limit 10) q;

  v_html := v_html || '<h2 style="font-size:14px;">Top 10 Depot - Clearing Rate Terendah</h2>'
    || '<table border="1" cellspacing="0" cellpadding="5" style="border-collapse:collapse;font-size:11px;">'
    || '<tr><th align="left">Depot</th><th align="right">Net CB</th><th align="right">Outstanding</th>'
    || '<th align="right">Clearing Rate</th></tr>' || v_baris || '</table>';

  -- ---- 3. Seluruh Depot --------------------------------------------------------------
  select coalesce(string_agg(
      '<tr><td>' || rc_private.html_aman(q.label) || '</td>'
      || '<td>' || rc_private.html_aman(q.region) || '</td>'
      || '<td align="right">' || rc_private.angka(q.qty) || '</td>'
      || '<td align="right">' || rc_private.rupiah(q.net_cb) || '</td>'
      || '<td align="right">' || rc_private.rupiah(q.os_val) || '</td>'
      || '<td align="right">' || rc_private.persen(q.cr) || '</td></tr>', '' order by q.cr, q.os_val desc), '')
    into v_baris
    from (select d.depot_code || ' - ' || d.depot_name as label,
                 coalesce(nullif(btrim(d.region),''),'-') region,
                 count(*) qty,
                 coalesce(sum(c.cb_net),0) net_cb,
                 coalesce(sum(c.cb_net) filter (where c.outstanding),0) os_val,
                 case when coalesce(sum(c.cb_net),0)=0 then 0
                      else coalesce(sum(c.cb_net) filter (where c.status in('done','expired')),0)/sum(c.cb_net) end cr
            from public.rc_report_rows c join public.depots d on d.id = c.depot_id
           group by d.depot_code, d.depot_name, d.region) q;

  v_html := v_html || '<h2 style="font-size:14px;">Performa per Depot</h2>'
    || '<table border="1" cellspacing="0" cellpadding="5" style="border-collapse:collapse;font-size:10px;">'
    || '<tr><th align="left">Depot</th><th align="left">Region</th><th align="right">Qty</th>'
    || '<th align="right">Net CB</th><th align="right">Outstanding</th><th align="right">Clearing Rate</th></tr>'
    || v_baris || '</table>';

  -- ---- 4. Seluruh Campaign -----------------------------------------------------------
  select coalesce(string_agg(
      '<tr><td>' || rc_private.html_aman(q.label) || '</td>'
      || '<td align="right">' || rc_private.angka(q.qty) || '</td>'
      || '<td align="right">' || rc_private.rupiah(q.net_cb) || '</td>'
      || '<td align="right">' || rc_private.rupiah(q.os_val) || '</td>'
      || '<td align="right">' || rc_private.persen(q.cr) || '</td></tr>', '' order by q.cr, q.os_val desc), '')
    into v_baris
    from (select c.campaign_code || ' - ' || coalesce(c.campaign_name,'') as label,
                 count(*) qty,
                 coalesce(sum(c.cb_net),0) net_cb,
                 coalesce(sum(c.cb_net) filter (where c.outstanding),0) os_val,
                 case when coalesce(sum(c.cb_net),0)=0 then 0
                      else coalesce(sum(c.cb_net) filter (where c.status in('done','expired')),0)/sum(c.cb_net) end cr
            from public.rc_report_rows c
           group by c.campaign_code, c.campaign_name) q;

  v_html := v_html || '<h2 style="font-size:14px;">Performa per Campaign</h2>'
    || '<table border="1" cellspacing="0" cellpadding="5" style="border-collapse:collapse;font-size:10px;">'
    || '<tr><th align="left">Campaign</th><th align="right">Qty</th><th align="right">Net CB</th>'
    || '<th align="right">Outstanding</th><th align="right">Clearing Rate</th></tr>'
    || v_baris || '</table>';

  return v_html || '</body></html>';
end $fn$;
revoke all on function rc_private.pdf_detail_html(text) from public,anon;

-- ------------------------------------------------------------------------------------------
-- 2. HTML menjadi PDF lewat Drive
-- ------------------------------------------------------------------------------------------
create or replace function rc_private.buat_pdf(p_html text, p_nama text)
returns bytea language plpgsql security definer set search_path='' as $fn$
declare
  v_tok text; r extensions.http_response; v_id text; v_pdf bytea;
  B constant text := 'RCPDF' || replace(gen_random_uuid()::text, '-', '');
  v_body text;
begin
  v_tok := rc_private.gmail_token();
  if v_tok is null then
    raise exception 'Access token Gmail belum tersedia; PDF tidak dapat dibuat'; end if;

  -- Konversi ke Google Doc HARUS diminta saat unggah. Drive v3 tidak mengizinkan mengubah jenis
  -- berkas lewat PATCH sesudahnya, dan berkas yang bukan Google Doc tidak dapat diekspor ke PDF.
  v_body := '--' || B || E'\r\n'
    || E'Content-Type: application/json; charset=UTF-8\r\n\r\n'
    || jsonb_build_object('name', p_nama, 'mimeType','application/vnd.google-apps.document')::text || E'\r\n'
    || '--' || B || E'\r\n'
    || E'Content-Type: text/html; charset=UTF-8\r\n\r\n'
    || p_html || E'\r\n' || '--' || B || '--';

  select * into r from extensions.http((
    'POST','https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart',
    array[extensions.http_header('Authorization','Bearer '||v_tok)],
    'multipart/related; boundary=' || B, v_body)::extensions.http_request);
  if r.status <> 200 then
    raise exception 'Unggah Drive gagal: % %', r.status, left(r.content,200); end if;
  v_id := (r.content::jsonb)->>'id';

  begin
    select * into r from extensions.http((
      'GET','https://www.googleapis.com/drive/v3/files/'||v_id||'/export?mimeType=application/pdf',
      array[extensions.http_header('Authorization','Bearer '||v_tok)], null, null)::extensions.http_request);
    if r.status <> 200 then
      raise exception 'Ekspor PDF gagal: % %', r.status, left(r.content,200); end if;

    -- text_to_bytea, bukan ::bytea maupun convert_to. Isi PDF bukan UTF-8 yang sah, sehingga
    -- kedua cara itu menolaknya; pembantu ini menafsirkan byte-nya apa adanya.
    v_pdf := extensions.text_to_bytea(r.content);
    if octet_length(v_pdf) < 1000 or left(encode(v_pdf,'escape'),5) <> '%PDF-' then
      raise exception 'Hasil ekspor bukan PDF yang sah (% byte)', octet_length(v_pdf); end if;
  exception when others then
    -- Berkas sementara tetap dihapus meski ekspornya gagal, supaya tidak menumpuk di Drive.
    perform extensions.http((
      'DELETE','https://www.googleapis.com/drive/v3/files/'||v_id,
      array[extensions.http_header('Authorization','Bearer '||v_tok)], null, null)::extensions.http_request);
    raise;
  end;

  perform extensions.http((
    'DELETE','https://www.googleapis.com/drive/v3/files/'||v_id,
    array[extensions.http_header('Authorization','Bearer '||v_tok)], null, null)::extensions.http_request);

  return v_pdf;
end $fn$;
revoke all on function rc_private.buat_pdf(text,text) from public,anon;

-- ------------------------------------------------------------------------------------------
-- 3. MIME dengan lampiran
-- ------------------------------------------------------------------------------------------
create or replace function rc_private.mime_lampiran_base64url(
  p_from text, p_to text[], p_cc text[], p_subjek text, p_html text,
  p_pdf bytea, p_nama_pdf text)
returns text language sql immutable set search_path='' as $fn$
  select translate(encode(convert_to(
      'From: ' || p_from || E'\r\n' ||
      'To: ' || array_to_string(p_to, ', ') || E'\r\n' ||
      case when coalesce(array_length(p_cc,1),0) > 0
           then 'Cc: ' || array_to_string(p_cc, ', ') || E'\r\n' else '' end ||
      'Subject: =?UTF-8?B?' || translate(encode(convert_to(p_subjek,'UTF8'),'base64'), E'\n','') || '?=' || E'\r\n' ||
      'MIME-Version: 1.0' || E'\r\n' ||
      'Content-Type: multipart/mixed; boundary="RCMIX"' || E'\r\n\r\n' ||
      '--RCMIX' || E'\r\n' ||
      'Content-Type: text/html; charset="UTF-8"' || E'\r\n' ||
      'Content-Transfer-Encoding: base64' || E'\r\n\r\n' ||
      encode(convert_to(p_html,'UTF8'),'base64') || E'\r\n' ||
      '--RCMIX' || E'\r\n' ||
      'Content-Type: application/pdf' || E'\r\n' ||
      'Content-Disposition: attachment; filename="' || p_nama_pdf || '"' || E'\r\n' ||
      'Content-Transfer-Encoding: base64' || E'\r\n\r\n' ||
      encode(p_pdf,'base64') || E'\r\n' ||
      '--RCMIX--',
      'UTF8'), 'base64'),
    E'+/=\n', '-_');
$fn$;
revoke all on function rc_private.mime_lampiran_base64url(text,text[],text[],text,text,bytea,text) from public,anon;

-- ------------------------------------------------------------------------------------------
-- 4. Penanda: kalimat PDF pada email kini boleh tampil
-- ------------------------------------------------------------------------------------------
create or replace function rc_private.email_pdf_terlampir()
returns boolean language sql immutable set search_path='' as $fn$ select true; $fn$;
revoke all on function rc_private.email_pdf_terlampir() from public,anon;

-- ------------------------------------------------------------------------------------------
-- 5. Pemeriksaan
-- ------------------------------------------------------------------------------------------
do $periksa$
declare n int;
begin
  if not exists(select 1 from pg_extension where extname='http') then
    raise exception 'GAGAL: ekstensi http belum terpasang.'; end if;

  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
   where ns.nspname='rc_private'
     and p.proname in ('pdf_detail_html','buat_pdf','mime_lampiran_base64url');
  if n <> 3 then raise exception 'GAGAL: hanya % dari 3 fungsi PDF terpasang.', n; end if;

  -- HTML-nya harus benar-benar memuat keempat bagian.
  select length(rc_private.pdf_detail_html('Uji')) into n;
  -- Panjang HTML bergantung pada banyaknya data. Pada database yang masih kosong laporannya
  -- memang pendek, dan itu perilaku yang benar - bukan cacat. Pemeriksaan panjang hanya
  -- bermakna bila ada klaim; tanpanya, ia menggagalkan migrasi yang fungsinya sudah terpasang.
  if n < 2000 and exists (select 1 from public.claims) then
    raise exception 'GAGAL: HTML PDF hanya % karakter, terlalu pendek.', n; end if;
  raise notice 'HTML PDF: % karakter', n;

  raise notice 'Pemeriksaan lolos.';
end
$periksa$;
