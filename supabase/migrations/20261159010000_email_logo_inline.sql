-- ==========================================================================================
-- Logo email dilampirkan inline (CID), bukan ditautkan
-- ==========================================================================================
-- Logo sebelumnya dirujuk sebagai URL ke halaman yang tayang. URL-nya sendiri hidup dan
-- terbuka - sudah diperiksa, 200 image/png - tetapi logonya tetap tidak muncul, karena Outlook
-- dan sebagian besar klien surel MEMBLOKIR gambar jarak jauh secara bawaan. Yang keliru bukan
-- tautannya, melainkan pilihan cara memasukkan gambarnya.
--
-- Gambar yang dikirim BERSAMA suratnya tidak terkena blokir itu: ia bagian dari surat, bukan
-- permintaan ke server luar. Karena itu kedua logo disimpan di sini dan dikirim sebagai bagian
-- multipart/related dengan Content-ID.
--
-- Gambarnya diperkecil lebih dulu ke 96x96 - ukuran yang benar-benar dipakai kop surat pada
-- layar beresolusi ganda. Berkas asli blobby 196 KB; melampirkan itu pada setiap pengajuan
-- hanya memberati kotak masuk penerimanya tanpa terlihat bedanya.
--
-- Jalur baru ini HANYA dipakai bila isi surat memuat "cid:". Tidak satu pun jenis email yang
-- sudah ada memuatnya, jadi tidak ada yang berubah perilakunya.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

create table if not exists rc_private.email_aset(
  nama text primary key,
  mime text not null,
  data bytea not null,
  diperbarui timestamptz not null default now()
);
revoke all on table rc_private.email_aset from public, anon, authenticated;

insert into rc_private.email_aset(nama, mime, data) values
 ('logo','image/png', decode(
    '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'
    'RK5CYII=', 'base64'))
on conflict(nama) do update set data=excluded.data, mime=excluded.mime, diperbarui=now();

insert into rc_private.email_aset(nama, mime, data) values
 ('blobby','image/png', decode(
    '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', 'base64'))
on conflict(nama) do update set data=excluded.data, mime=excluded.mime, diperbarui=now();

-- ------------------------------------------------------------------------------------------
-- Penyusun MIME multipart/related
-- ------------------------------------------------------------------------------------------
-- Hanya aset yang BENAR-BENAR dirujuk isi suratnya yang ikut dilampirkan. Melampirkan semua
-- yang ada akan membesarkan surat tanpa ada yang menampilkannya.
create or replace function rc_private.mime_related_base64url(
  p_from text, p_to text[], p_cc text[], p_subjek text, p_html text)
returns text language plpgsql immutable set search_path to '' as $fn$
declare v_kepala text; v_bagian text := ''; a record;
begin
  v_kepala :=
    'From: ' || p_from || chr(13)||chr(10) ||
    'To: ' || array_to_string(p_to, ', ') || chr(13)||chr(10) ||
    case when coalesce(array_length(p_cc,1),0) > 0
         then 'Cc: ' || array_to_string(p_cc, ', ') || chr(13)||chr(10) else '' end ||
    'Subject: =?UTF-8?B?' || translate(encode(convert_to(p_subjek,'UTF8'),'base64'), chr(10),'')
      || '?=' || chr(13)||chr(10) ||
    'MIME-Version: 1.0' || chr(13)||chr(10) ||
    'Content-Type: multipart/related; boundary="RCREL"' || chr(13)||chr(10) || chr(13)||chr(10) ||
    '--RCREL' || chr(13)||chr(10) ||
    'Content-Type: text/html; charset="UTF-8"' || chr(13)||chr(10) ||
    'Content-Transfer-Encoding: base64' || chr(13)||chr(10) || chr(13)||chr(10) ||
    rc_private.crlf(encode(convert_to(p_html,'UTF8'),'base64')) || chr(13)||chr(10);

  for a in select * from rc_private.email_aset order by nama loop
    if position('cid:' || a.nama in p_html) > 0 then
      v_bagian := v_bagian ||
        '--RCREL' || chr(13)||chr(10) ||
        'Content-Type: ' || a.mime || '; name="' || a.nama || '.png"' || chr(13)||chr(10) ||
        'Content-Transfer-Encoding: base64' || chr(13)||chr(10) ||
        'Content-ID: <' || a.nama || '>' || chr(13)||chr(10) ||
        'Content-Disposition: inline; filename="' || a.nama || '.png"' || chr(13)||chr(10) || chr(13)||chr(10) ||
        rc_private.crlf(encode(a.data,'base64')) || chr(13)||chr(10);
    end if;
  end loop;

  return translate(encode(convert_to(
    v_kepala || v_bagian || '--RCREL--' || chr(13)||chr(10), 'UTF8'), 'base64'),
    '+/=' || chr(10), '-_');
end
$fn$;

revoke all on function rc_private.mime_related_base64url(text,text[],text[],text,text)
  from public, anon, authenticated;

-- ------------------------------------------------------------------------------------------
-- Pengirim memilih jalur itu ketika suratnya memang memuat gambar inline
-- ------------------------------------------------------------------------------------------
do $kait$
declare src text; baru text; pola text; ganti text;
begin
  select pg_get_functiondef(p.oid) into src from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='rc_private' and p.proname='kirim_satu_email';
  if src is null then raise exception 'rc_private.kirim_satu_email tidak ditemukan.'; end if;
  if position('mime_related_base64url' in src) > 0 then
    raise notice 'Jalur gambar inline sudah terpasang; dilewati.'; return; end if;

  pola := '    else' || chr(10) ||
          '      v_raw := rc_private.mime_base64url(v_from, v.tujuan, v.cc, v.subjek, v.isi_html);';
  if position(pola in src) = 0 then
    raise exception 'Pola pemilihan MIME tidak ditemukan pada kirim_satu_email.'; end if;

  ganti := '    elsif position(''cid:'' in v.isi_html) > 0 then' || chr(10) ||
           '      -- Surat bergambar inline dikirim sebagai multipart/related supaya gambarnya' || chr(10) ||
           '      -- ikut DI DALAM surat, bukan diambil dari server luar yang diblokir klien.' || chr(10) ||
           '      v_raw := rc_private.mime_related_base64url(v_from, v.tujuan, v.cc, v.subjek, v.isi_html);' || chr(10) ||
           pola;

  baru := replace(src, pola, ganti);
  execute baru;
  raise notice 'kirim_satu_email: jalur gambar inline terpasang.';
end
$kait$;

-- ------------------------------------------------------------------------------------------
-- Pemeriksaan
-- ------------------------------------------------------------------------------------------
do $periksa$
declare n int; v_raw text; v_mime text;
begin
  select count(*) into n from rc_private.email_aset where nama in ('logo','blobby');
  if n <> 2 then raise exception 'GAGAL: aset logo belum lengkap (%).', n; end if;

  -- Surat tanpa cid tidak boleh membawa lampiran gambar sama sekali.
  v_raw := rc_private.mime_related_base64url('a@b.com', array['c@d.com'], '{}', 'Uji',
             '<p>tanpa gambar</p>');
  v_mime := convert_from(decode(translate(v_raw,'-_','+/') ||
              repeat('=', (4 - length(v_raw) % 4) % 4), 'base64'), 'UTF8');
  if position('Content-ID:' in v_mime) > 0 then
    raise exception 'GAGAL: gambar ikut padahal tidak dirujuk.'; end if;

  v_raw := rc_private.mime_related_base64url('a@b.com', array['c@d.com'], '{}', 'Uji',
             '<img src="cid:logo"><img src="cid:blobby">');
  v_mime := convert_from(decode(translate(v_raw,'-_','+/') ||
              repeat('=', (4 - length(v_raw) % 4) % 4), 'base64'), 'UTF8');
  if position('Content-ID: <logo>' in v_mime) = 0 then
    raise exception 'GAGAL: logo tidak ikut sebagai bagian inline.'; end if;
  if position('Content-ID: <blobby>' in v_mime) = 0 then
    raise exception 'GAGAL: blobby tidak ikut sebagai bagian inline.'; end if;
  if position('multipart/related' in v_mime) = 0 then
    raise exception 'GAGAL: bukan multipart/related.'; end if;
  if position('kirim_satu_email' in
      (select pg_get_functiondef(p.oid) from pg_proc p
         join pg_namespace ns on ns.oid=p.pronamespace
        where ns.nspname='rc_private' and p.proname='kirim_satu_email')) = 0 then
    raise exception 'GAGAL: kirim_satu_email tidak terbaca.'; end if;

  raise notice 'Pemeriksaan lolos: kedua logo terlampir inline hanya ketika dirujuk.';
end
$periksa$;
