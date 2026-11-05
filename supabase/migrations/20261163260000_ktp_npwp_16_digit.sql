-- ==========================================================================================
-- Customer Master: No KTP dan No NPWP wajib tepat 16 digit angka; spasi dibuang otomatis
-- ==========================================================================================
-- Pemilik, 21 Oktober 2026: "NPWP ataupun KTP harus 16 digit gaboleh lebih atau kurang, jika
-- terbaca karena spasi jadi karakternya nambah hapus aja spasinya."
--
--  * Seluruh spasi (termasuk tab, spasi tak terputus, dan karakter tak terlihat dari Excel)
--    dibuang lebih dulu; sisanya harus tepat 16 digit angka. Lebih, kurang, atau berisi huruf /
--    titik / strip ditolak dengan pesan per customer (unggahan maupun form Ubah, termasuk
--    Pratinjau unggahan yang memanggil fungsi yang sama secara dibatalkan).
--  * Aturan kosong tidak berubah: sel kosong = nilai lama tetap; "-" = dikosongkan.
--  * Satu-satunya jalur yang menulis KTP / NPWP ke Customer Master adalah rc_private.customer_upsert
--    (Claim Upload hanya memperbarui rekening). Data lama tidak diubah. Prod 21 Oktober 2026:
--    23.159 KTP seluruhnya 16 digit; NPWP 1.411 dari 1.412 (satu NPWP 15 digit, akan ditolak
--    bila customer itu disimpan ulang tanpa diperbaiki).
--
-- Penjaga MD5 pra-citra rc_private.customer_upsert: ee90ccad (sama di dev dan prod).
-- ==========================================================================================

create or replace function pg_temp.ganti(p_src text, p_lama text, p_baru text, p_n integer, p_nama text)
returns text language plpgsql as $f$
declare n integer := (length(p_src) - length(replace(p_src, p_lama, ''))) / greatest(length(p_lama), 1);
begin
  if n <> p_n then raise exception '%: pola ditemukan % kali, diharapkan %: %', p_nama, n, p_n, left(p_lama, 120); end if;
  return replace(p_src, p_lama, p_baru);
end $f$;

-- Nomor identitas 16 digit: spasi apa pun dibuang; kosong atau "-" berarti dikosongkan (null).
create or replace function rc_private.identitas_16(p_nilai text, p_label text, p_kode text)
returns text language plpgsql immutable set search_path = '' as $f$
declare v text := regexp_replace(coalesce(p_nilai, ''), '[[:space:] ​‌‍⁠﻿]', '', 'g');
begin
  if v = '' or v = '-' then return null; end if;
  if v !~ '^[0-9]{16}$' then
    raise exception 'Customer %: % harus tepat 16 digit angka (terbaca % karakter: "%")',
      p_kode, p_label, length(v), left(v, 40) using errcode = '22023';
  end if;
  return v;
end $f$;
revoke all on function rc_private.identitas_16(text, text, text) from public, anon, authenticated;

do $tambal$
declare src text;
begin
  src := replace(pg_get_functiondef('rc_private.customer_upsert(jsonb)'::regprocedure), E'\r', '');
  if src ~ 'identitas_16' then raise notice 'customer_upsert sudah ditambal.'; return; end if;
  if md5(src) <> 'ee90ccad73fa1abd635311bbb1c25772' then
    raise exception 'DITOLAK: customer_upsert berbeda dari yang diukur (md5 %).', md5(src); end if;
  src := pg_temp.ganti(src, $p$    ktp=case when r ? 'ktp' then nullif(btrim(r->>'ktp'),'') else ktp end,
    npwp=case when r ? 'npwp' then nullif(btrim(r->>'npwp'),'') else npwp end,$p$,
    $p$    -- 20261163260000: KTP / NPWP tepat 16 digit angka, spasi dibuang.
    ktp=case when r ? 'ktp' then rc_private.identitas_16(r->>'ktp','No KTP',code) else ktp end,
    npwp=case when r ? 'npwp' then rc_private.identitas_16(r->>'npwp','No NPWP',code) else npwp end,$p$, 1, 'upsert ubah');
  src := pg_temp.ganti(src, $p$     nullif(btrim(coalesce(r->>'ktp','')),''),nullif(btrim(coalesce(r->>'npwp','')),''),$p$,
    $p$     rc_private.identitas_16(r->>'ktp','No KTP',code),rc_private.identitas_16(r->>'npwp','No NPWP',code), -- 20261163260000$p$, 1, 'upsert baru');
  execute src;
end $tambal$;

do $cek$
begin
  if pg_get_functiondef('rc_private.customer_upsert(jsonb)'::regprocedure) !~ 'identitas_16' then
    raise exception 'GAGAL: customer_upsert belum ditambal'; end if;
  if rc_private.identitas_16(' 3201 0101 0101 0001 ', 'No KTP', 'X') <> '3201010101010001' then
    raise exception 'GAGAL: spasi tidak dibuang'; end if;
end $cek$;
