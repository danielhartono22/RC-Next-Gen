-- ==========================================================================================
-- Weekly menautkan dashboard publik dan tidak lagi melampirkan PDF
-- ==========================================================================================
-- Keputusan pemilik: tautan Claim Dashboard dapat dibuka tanpa login, dan karena itu email
-- Weekly tidak lagi memerlukan PDF - detail per Depot dan per Campaign sudah dapat dibaca
-- langsung di halaman.
--
--   "untuk data report dashboard ini apa bisa ketika di klik link langsung muncul ke laman
--    tanpa login? ... jika bisa seharusnya untuk weekly tidak memerlukan pdf."
--
-- Yang berubah:
--
--   1. Tautannya menunjuk /dashboard, halaman yang memang tidak meminta login.
--   2. Kalimat tentang PDF diganti kalimat tentang halaman itu.
--   3. Weekly tidak lagi membuat maupun melampirkan PDF.
--
-- PDF TIDAK DIHAPUS DARI SISTEM. Daily dan Timetable tetap melampirkannya, dan seluruh
-- mesinnya - pdf_detail_html, buat_pdf, mime_lampiran_base64url, penyapu Drive - tetap
-- terpasang. Yang berubah hanya: Weekly melewatinya.
--
-- Alasannya menghemat sesuatu yang nyata. Pembuatan satu PDF menuntut tiga panggilan ke Drive
-- dan memakan beberapa detik; bagi email yang detailnya sudah tersedia lewat tautan, pekerjaan
-- itu tidak memberi tambahan apa pun.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

-- ------------------------------------------------------------------------------------------
-- 1. Blok tautan: menunjuk /dashboard, kalimat PDF diganti
-- ------------------------------------------------------------------------------------------
create or replace function rc_private.email_tautan_dashboard()
returns text language sql stable set search_path='' as $fn$
  select '<p style="line-height:1.6;margin-top:18px;">Untuk melihat detail Claim secara lebih '
      || 'lengkap, silakan mengakses Claim Dashboard melalui link berikut:</p>'
      || '<p style="margin:10px 0 14px;">'
      || '<a href="https://rc-next-gen.vercel.app/dashboard" '
      || 'style="display:inline-block;background:#4285F4;color:#ffffff;text-decoration:none;'
      || 'font-weight:bold;font-size:13px;padding:10px 18px;border-radius:6px;">'
      || 'Buka Claim Dashboard</a></p>'
      || '<p style="line-height:1.6;">Detail performa per Depot dan per Campaign tersedia pada '
      || 'halaman tersebut, dan dapat dibuka langsung tanpa perlu masuk ke aplikasi.</p>'
      || '<p style="line-height:1.6;">Thank you for your attention and cooperation.</p>';
$fn$;
revoke all on function rc_private.email_tautan_dashboard() from public,anon;

-- ------------------------------------------------------------------------------------------
-- 2. Weekly melewati pembuatan PDF
-- ------------------------------------------------------------------------------------------
-- Penandanya satu fungsi kecil, supaya keputusan "jenis mana yang berlampiran" berada di satu
-- tempat dan dapat diubah tanpa menyentuh badan kirim_satu_email yang panjang.
create or replace function rc_private.email_perlu_pdf(p_jenis text)
returns boolean language sql immutable set search_path='' as $fn$
  -- Weekly sudah menautkan dashboard publik yang memuat detail yang sama, jadi lampirannya
  -- tidak menambah apa pun.
  select lower(coalesce(p_jenis,'')) <> 'weekly';
$fn$;
revoke all on function rc_private.email_perlu_pdf(text) from public,anon;

do $mig$
declare src text; baru text;
begin
  select pg_get_functiondef(p.oid) into src from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='rc_private' and p.proname='kirim_satu_email';
  if src is null then raise exception 'rc_private.kirim_satu_email tidak ditemukan.'; end if;

  if position('email_perlu_pdf' in src) > 0 then
    raise notice 'kirim_satu_email sudah memeriksa jenis; dilewati.';
    return;
  end if;

  baru := replace(src,
    '    begin' || chr(10)
      || '      v_nama_pdf := ''RC_'' || initcap(v.jenis) || ''_Report_''',
    '    begin' || chr(10)
      || '      if not rc_private.email_perlu_pdf(v.jenis) then' || chr(10)
      || '        v_pdf := null;' || chr(10)
      || '      else' || chr(10)
      || '      v_nama_pdf := ''RC_'' || initcap(v.jenis) || ''_Report_''');

  baru := replace(baru,
    '        replace(v_nama_pdf, ''.pdf'', ''''));' || chr(10)
      || '    exception when others then',
    '        replace(v_nama_pdf, ''.pdf'', ''''));' || chr(10)
      || '      end if;' || chr(10)
      || '    exception when others then');

  if baru = src then
    raise exception 'Pola pembuatan PDF tidak ditemukan pada rc_private.kirim_satu_email. '
      'Sumbernya sudah berubah - periksa dan perbarui migration ini.';
  end if;

  execute baru;
  raise notice 'kirim_satu_email: Weekly tidak lagi melampirkan PDF.';
end
$mig$;

-- ------------------------------------------------------------------------------------------
-- 3. Pemeriksaan
-- ------------------------------------------------------------------------------------------
do $periksa$
declare src text;
begin
  select pg_get_functiondef(p.oid) into src from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='rc_private' and p.proname='email_tautan_dashboard';
  if src not like '%/dashboard%' then
    raise exception 'GAGAL: tautan belum menunjuk halaman dashboard publik.'; end if;
  if src like '%terlampir pada email ini%' then
    raise exception 'GAGAL: kalimat tentang lampiran PDF masih ada pada Weekly.'; end if;

  select pg_get_functiondef(p.oid) into src from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='rc_private' and p.proname='kirim_satu_email';
  if src not like '%email_perlu_pdf%' then
    raise exception 'GAGAL: kirim_satu_email belum memeriksa jenis sebelum membuat PDF.'; end if;

  -- Jalur lampiran harus TETAP ada untuk jenis lain.
  if src not like '%mime_lampiran_base64url%' then
    raise exception 'GAGAL: kemampuan melampirkan hilang seluruhnya.'; end if;

  if rc_private.email_perlu_pdf('weekly') then
    raise exception 'GAGAL: weekly masih dianggap perlu PDF.'; end if;
  if not rc_private.email_perlu_pdf('daily') then
    raise exception 'GAGAL: daily seharusnya tetap berlampiran.'; end if;

  raise notice 'Pemeriksaan lolos.';
end
$periksa$;
