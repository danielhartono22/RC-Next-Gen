-- ==========================================================================================
-- Grafik email disematkan sebagai gambar di dalam surat, bukan tautan ke server luar
-- ==========================================================================================
-- Pemilik, 27 Oktober 2026: "email untuk chart nya ada beberapa user tidak bisa buka karena ada
-- protection dari privacy, buat jadi gambar aja jangan langsung html / link".
--
-- Sebelumnya grafik di email (Daily, Weekly, Timetable) berupa <img src="https://quickchart.io/
-- chart?..."> yang diambil klien email saat surat dibuka; klien dengan proteksi privasi memblokir
-- gambar luar sehingga grafiknya tidak tampil. Kini, SAAT DIKIRIM, server mengunduh setiap gambar
-- grafik itu dan menyematkannya sebagai bagian inline (Content-ID) di dalam surat - baik surat
-- berlampiran PDF maupun tidak. Isi email_outbox tidak diubah (pratinjau di aplikasi tetap
-- memakai tautan). Bila satu grafik gagal diunduh, grafik itu tetap memakai tautannya dan
-- catatannya ditulis di kolom galat; suratnya tetap terkirim.
-- ==========================================================================================

create or replace function pg_temp.ganti(p_src text, p_lama text, p_baru text, p_n integer, p_nama text)
returns text language plpgsql as $f$
declare n integer := (length(p_src) - length(replace(p_src, p_lama, ''))) / greatest(length(p_lama), 1);
begin
  if n <> p_n then raise exception '%: pola ditemukan % kali, diharapkan %: %', p_nama, n, p_n, left(p_lama, 120); end if;
  return replace(p_src, p_lama, p_baru);
end $f$;

-- Unduh setiap gambar QuickChart di HTML; ganti src-nya dengan cid:rcgrafikN.
create or replace function rc_private.email_sematkan_gambar(p_html text)
 returns jsonb
 language plpgsql
 volatile
 security definer
 set search_path = ''
as $function$
declare v_html text := coalesce(p_html, ''); m text[]; v_src text; v_url text; r extensions.http_response;
  v_png bytea; v_gambar jsonb := '[]'::jsonb; n int := 0; v_gagal int := 0;
begin
  for m in select regexp_matches(coalesce(p_html, ''), 'src="(https://quickchart\.io/chart\?[^"]+)"', 'g') loop
    v_src := m[1];
    -- Grafik yang sama dua kali sudah terganti pada putaran sebelumnya.
    if position('src="' || v_src || '"' in v_html) = 0 then continue; end if;
    -- Kebalikan rc_private.html_aman.
    v_url := replace(replace(replace(replace(v_src, '&quot;', '"'), '&gt;', '>'), '&lt;', '<'), '&amp;', '&');
    v_png := null;
    begin
      select * into r from extensions.http_get(v_url);
      if r.status = 200 then v_png := extensions.text_to_bytea(r.content); end if;
    exception when others then v_png := null;
    end;
    if v_png is null or octet_length(v_png) < 100 or encode(substring(v_png from 1 for 4), 'hex') <> '89504e47' then
      v_gagal := v_gagal + 1; continue;
    end if;
    n := n + 1;
    v_html := replace(v_html, 'src="' || v_src || '"', 'src="cid:rcgrafik' || n || '"');
    v_gambar := v_gambar || jsonb_build_object('cid', 'rcgrafik' || n, 'data', encode(v_png, 'base64'));
  end loop;
  return jsonb_build_object('html', v_html, 'gambar', v_gambar, 'gagal', v_gagal);
end $function$;
revoke all on function rc_private.email_sematkan_gambar(text) from public, anon, authenticated;

-- Surat lengkap: multipart/mixed { multipart/related { HTML, gambar inline }, PDF (bila ada) }.
create or replace function rc_private.mime_email_base64url(p_from text, p_to text[], p_cc text[], p_subjek text, p_html text,
  p_gambar jsonb, p_pdf bytea, p_nama_pdf text)
 returns text
 language plpgsql
 stable
 set search_path = ''
as $function$
declare NL constant text := chr(13) || chr(10); v text; g jsonb; a record;
begin
  v := 'From: ' || p_from || NL
    || 'To: ' || array_to_string(p_to, ', ') || NL
    || case when coalesce(array_length(p_cc, 1), 0) > 0 then 'Cc: ' || array_to_string(p_cc, ', ') || NL else '' end
    || 'Subject: =?UTF-8?B?' || translate(encode(convert_to(p_subjek, 'UTF8'), 'base64'), chr(10), '') || '?=' || NL
    || 'MIME-Version: 1.0' || NL
    || 'Content-Type: multipart/mixed; boundary="RCMIX"' || NL || NL
    || '--RCMIX' || NL
    || 'Content-Type: multipart/related; boundary="RCREL"' || NL || NL
    || '--RCREL' || NL
    || 'Content-Type: text/html; charset="UTF-8"' || NL
    || 'Content-Transfer-Encoding: base64' || NL || NL
    || rc_private.crlf(encode(convert_to(p_html, 'UTF8'), 'base64')) || NL;
  for g in select value from jsonb_array_elements(coalesce(p_gambar, '[]'::jsonb)) loop
    v := v || '--RCREL' || NL
      || 'Content-Type: image/png; name="' || (g->>'cid') || '.png"' || NL
      || 'Content-Transfer-Encoding: base64' || NL
      || 'Content-ID: <' || (g->>'cid') || '>' || NL
      || 'Content-Disposition: inline; filename="' || (g->>'cid') || '.png"' || NL || NL
      || rc_private.crlf(g->>'data') || NL;
  end loop;
  -- Aset tetap (logo dsb.) yang dirujuk cid: di HTML, sama dengan mime_related_base64url.
  for a in select * from rc_private.email_aset order by nama loop
    if position('cid:' || a.nama in p_html) > 0 then
      v := v || '--RCREL' || NL
        || 'Content-Type: ' || a.mime || '; name="' || a.nama || '.png"' || NL
        || 'Content-Transfer-Encoding: base64' || NL
        || 'Content-ID: <' || a.nama || '>' || NL
        || 'Content-Disposition: inline; filename="' || a.nama || '.png"' || NL || NL
        || rc_private.crlf(encode(a.data, 'base64')) || NL;
    end if;
  end loop;
  v := v || '--RCREL--' || NL;
  if p_pdf is not null then
    v := v || '--RCMIX' || NL
      || 'Content-Type: application/pdf; name="' || p_nama_pdf || '"' || NL
      || 'Content-Disposition: attachment; filename="' || p_nama_pdf || '"' || NL
      || 'Content-Transfer-Encoding: base64' || NL || NL
      || rc_private.crlf(encode(p_pdf, 'base64')) || NL;
  end if;
  v := v || '--RCMIX--' || NL;
  return translate(encode(convert_to(v, 'UTF8'), 'base64'), '+/=' || chr(10), '-_');
end $function$;
revoke all on function rc_private.mime_email_base64url(text, text[], text[], text, text, jsonb, bytea, text) from public, anon, authenticated;

do $tambal$
declare src text; f text := 'rc_private.kirim_satu_email(uuid)';
begin
  src := replace(pg_get_functiondef(f::regprocedure), E'\r', '');
  if src !~ '20261163460000' then
    src := pg_temp.ganti(src, $p$v_pdf bytea; v_nama_pdf text; v_catatan text := '';$p$,
      $p$v_pdf bytea; v_nama_pdf text; v_catatan text := '';
  v_semat jsonb; -- 20261163460000$p$, 1, f || ' deklarasi');
    src := pg_temp.ganti(src, $p$    if v_pdf is not null then
      v_raw := rc_private.mime_lampiran_base64url(v_from, v.tujuan, v.cc, v.subjek, v.isi_html,
                                                  v_pdf, v_nama_pdf);
    elsif position('cid:' in v.isi_html) > 0 then$p$,
      $p$    -- 20261163460000: grafik QuickChart diunduh lalu disematkan sebagai gambar inline, supaya
    -- tampil di klien yang memblokir gambar dari server luar.
    v_semat := rc_private.email_sematkan_gambar(v.isi_html);
    if coalesce((v_semat->>'gagal')::int, 0) > 0 then
      v_catatan := concat_ws('; ', nullif(v_catatan, ''), (v_semat->>'gagal') || ' grafik gagal disematkan, memakai tautan gambar');
    end if;
    if v_pdf is not null or jsonb_array_length(v_semat->'gambar') > 0 then
      v_raw := rc_private.mime_email_base64url(v_from, v.tujuan, v.cc, v.subjek, v_semat->>'html',
                                               v_semat->'gambar', v_pdf, v_nama_pdf);
    elsif position('cid:' in v.isi_html) > 0 then$p$, 1, f || ' mime');
    execute src;
  end if;
end $tambal$;
