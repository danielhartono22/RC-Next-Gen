-- ==========================================================================================
-- MIME memakai CRLF, bukan LF - sebab lampiran dan gambar tidak muncul
-- ==========================================================================================
-- Pemilik melaporkan gambar maupun PDF tidak muncul di email yang diterimanya, padahal antrean
-- mencatat status sent dengan messageId asli dari Gmail dan lampiran 111 KB.
--
-- Keduanya berpangkal pada satu hal yang mudah terlewat.
--
-- ------------------------------------------------------------------------------------------
-- SEBABNYA
-- ------------------------------------------------------------------------------------------
-- encode(..., 'base64') pada PostgreSQL memotong keluarannya setiap 76 karakter dan memisahkan
-- barisnya dengan LF tunggal. Terukur:
--
--   base64 sepanjang 405 karakter -> memuat 5 LF, 0 CR
--
-- RFC 2045 menuntut setiap baris MIME berakhir dengan CRLF. Perbedaannya tidak terlihat pada
-- pesan satu bagian - Gmail memaafkannya, dan itulah sebabnya email tanpa lampiran selama ini
-- tampak baik-baik saja. Pada multipart/mixed ia menentukan: batas antar-bagian dikenali dari
-- pola CRLF + "--batas", sehingga dengan LF tunggal batas itu tidak terbaca. Akibatnya bagian
-- lampiran tidak dikenali sebagai lampiran, dan bagian HTML-nya ikut salah tafsir - termasuk
-- tag <img> di dalamnya.
--
-- Gmail tetap menjawab 200 karena pesannya sah sebagai pesan; yang gagal adalah penafsiran
-- strukturnya. Itu sebabnya antrean mencatat berhasil sementara yang diterima tidak utuh.
--
-- ------------------------------------------------------------------------------------------
-- PERBAIKANNYA
-- ------------------------------------------------------------------------------------------
-- Setiap keluaran base64 dilewatkan rc_private.crlf() yang mengubah LF menjadi CRLF. Fungsi itu
-- menjaga diri terhadap CRLF yang sudah ada - LF diubah hanya bila tidak didahului CR - sehingga
-- menjalankannya dua kali tidak menghasilkan CRCRLF.
--
-- Kedua penyusun MIME diperbaiki, yang berlampiran maupun yang tidak. Yang tanpa lampiran ikut
-- dibetulkan meski selama ini tampak bekerja: ia bekerja karena dimaafkan, bukan karena benar.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

create or replace function rc_private.crlf(p text)
returns text language sql immutable set search_path='' as $fn$
  -- LF yang belum didahului CR diubah menjadi CRLF. CRLF yang sudah ada dibiarkan.
  select regexp_replace(coalesce(p,''), '(' || chr(13) || ')?' || chr(10),
                        chr(13) || chr(10), 'g');
$fn$;
revoke all on function rc_private.crlf(text) from public,anon;

-- ------------------------------------------------------------------------------------------
-- 1. MIME tanpa lampiran
-- ------------------------------------------------------------------------------------------
create or replace function rc_private.mime_base64url(
  p_from text, p_to text[], p_cc text[], p_subjek text, p_html text)
returns text language sql immutable set search_path='' as $fn$
  select translate(
    encode(convert_to(
      'From: ' || p_from || E'\r\n' ||
      'To: ' || array_to_string(p_to, ', ') || E'\r\n' ||
      case when coalesce(array_length(p_cc,1),0) > 0
           then 'Cc: ' || array_to_string(p_cc, ', ') || E'\r\n' else '' end ||
      'Subject: =?UTF-8?B?' || translate(encode(convert_to(p_subjek,'UTF8'),'base64'), E'\n','') || '?=' || E'\r\n' ||
      'MIME-Version: 1.0' || E'\r\n' ||
      'Content-Type: text/html; charset="UTF-8"' || E'\r\n' ||
      'Content-Transfer-Encoding: base64' || E'\r\n\r\n' ||
      rc_private.crlf(encode(convert_to(p_html,'UTF8'),'base64')),
      'UTF8'), 'base64'),
    E'+/=\n', '-_');
$fn$;
revoke all on function rc_private.mime_base64url(text,text[],text[],text,text) from public,anon;

-- ------------------------------------------------------------------------------------------
-- 2. MIME berlampiran
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
      rc_private.crlf(encode(convert_to(p_html,'UTF8'),'base64')) || E'\r\n' ||
      '--RCMIX' || E'\r\n' ||
      'Content-Type: application/pdf; name="' || p_nama_pdf || '"' || E'\r\n' ||
      'Content-Disposition: attachment; filename="' || p_nama_pdf || '"' || E'\r\n' ||
      'Content-Transfer-Encoding: base64' || E'\r\n\r\n' ||
      rc_private.crlf(encode(p_pdf,'base64')) || E'\r\n' ||
      '--RCMIX--' || E'\r\n',
      'UTF8'), 'base64'),
    E'+/=\n', '-_');
$fn$;
revoke all on function rc_private.mime_lampiran_base64url(text,text[],text[],text,text,bytea,text) from public,anon;

-- ------------------------------------------------------------------------------------------
-- 3. Pemeriksaan - MIME dibongkar kembali dan diperiksa strukturnya
-- ------------------------------------------------------------------------------------------
do $periksa$
declare v_b64 text; v_mime text; n_lf_telanjang int;
begin
  v_b64 := rc_private.mime_lampiran_base64url(
    'RC <a@b.c>', array['x@y.z'], '{}'::text[], 'Uji',
    '<p>' || repeat('halo ', 60) || '</p>',
    decode('255044462d312e340a' || repeat('41', 200), 'hex'), 'uji.pdf');

  -- Dikembalikan ke bentuk base64 biasa lalu dibongkar, supaya yang diperiksa benar-benar
  -- pesan yang akan diterima Gmail.
  v_mime := convert_from(decode(
    translate(v_b64, '-_', '+/') || repeat('=', (4 - length(v_b64) % 4) % 4), 'base64'), 'UTF8');

  -- LF telanjang: LF yang tidak didahului CR. Harus nol.
  n_lf_telanjang := (length(v_mime) - length(replace(v_mime, chr(10), '')))
                  - (length(v_mime) - length(replace(v_mime, chr(13) || chr(10), '')))
                    / length(chr(13) || chr(10));
  if n_lf_telanjang <> 0 then
    raise exception 'GAGAL: masih ada % LF telanjang di dalam MIME.', n_lf_telanjang; end if;

  if position('multipart/mixed' in v_mime) = 0 then
    raise exception 'GAGAL: bukan multipart.'; end if;
  if position(chr(13)||chr(10)||'--RCMIX'||chr(13)||chr(10) in v_mime) = 0 then
    raise exception 'GAGAL: batas bagian tidak diawali CRLF; lampiran tidak akan dikenali.'; end if;
  if position('Content-Disposition: attachment' in v_mime) = 0 then
    raise exception 'GAGAL: bagian lampiran tidak ada.'; end if;
  if position(chr(13)||chr(10)||'--RCMIX--' in v_mime) = 0 then
    raise exception 'GAGAL: penutup multipart tidak benar.'; end if;

  raise notice 'MIME sah: multipart, batas ber-CRLF, lampiran ada, tidak ada LF telanjang.';
end
$periksa$;
