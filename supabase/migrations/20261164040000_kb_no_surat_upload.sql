-- ==========================================================================================
-- Knowledge Base: No Surat otomatis, Upload Excel, dokumen PDF
-- ==========================================================================================
-- Pemilik, 17 November 2026 (Index File RS10245_000):
--   "untuk format upload saya mau ada auto generate no surat"
--   "untuk SOP lama biarkan pake cara lama tapi yang baru harus ada slash SOP nya begitu juga
--    dengan yg lainnya buat shorttext jadi 3 aja"
--   Kode: SOP Memo Nasional = SOP, SOP Module SD = SSD, Internal Memo = IMO; nomor urut lanjut terus
--   (tidak kembali ke 1 tiap tahun). "bisa pake pdf bisa pake link, untuk excel link dulu."
--   "untuk penomoran yang sudah ada no nya tetep gunakan no nya", "no 21 yg ganda buat jadi no
--   lainnya yang tidak ada" (diatur di berkas impor, bukan di sini).
--
-- KEPUTUSAN
--  * Nomor baru: {urut}/SAN/{kode 3 huruf jenis}/{bulan romawi Tanggal Terbit}/{tahun Tanggal Terbit},
--    mis. 28/SAN/SOP/IV/2026. Urut per jenis, berlanjut lintas tahun (rc_kb_jenis.nomor_terakhir);
--    jumlah digit per jenis (Internal Memo 3 digit: 003). Kode diatur di Knowledge Management.
--  * No Surat yang diketik / diunggah dipakai apa adanya (nomor lama); kosong = dibuat sistem.
--    Nomor unik tanpa membedakan spasi dan huruf besar; nomor tidak pernah dipakai ulang.
--  * Kode Dokumen berakhiran huruf (001a, 002a) = lampiran: tidak mendapat nomor sendiri dan
--    menampilkan No Surat induknya (kode angkanya, jenis yang sama).
--  * Dokumen = Link dan / atau PDF (bucket privat kb-pdf, maks 10 MB): minimal salah satu, boleh
--    keduanya ("buat bisa attach pdf tapi opsional intinya harus ada salah satu pdf atau link tapi
--    keduanya juga boleh"). Upload Excel hanya mengisi Link; PDF yang sudah terpasang tidak dilepas.
--  * Upload Excel: pratinjau lalu simpan; baris dicocokkan dengan Jenis + Kode Dokumen (aktif).
--    Baris yang sudah ada diperbarui; versi naik (peserta acknowledge ulang) bila link berubah
--    atau ada Tanggal Update baru. Nomor otomatis diberikan berurutan menurut Tanggal Terbit.
--    Log Activity satu baris per upload.
-- Aman dijalankan berulang.
-- ==========================================================================================

create or replace function pg_temp.ganti(p_src text, p_lama text, p_baru text, p_n integer, p_nama text)
returns text language plpgsql as $f$
declare n integer := (length(p_src) - length(replace(p_src, p_lama, ''))) / greatest(length(p_lama), 1);
begin
  if n <> p_n then raise exception '%: pola ditemukan % kali, diharapkan %: %', p_nama, n, p_n, left(p_lama, 120); end if;
  return replace(p_src, p_lama, p_baru);
end $f$;

-- ------------------------------------------------------------------------------------------
-- 1. Tabel
-- ------------------------------------------------------------------------------------------
create table if not exists public.rc_kb_jenis (
  jenis text primary key check (btrim(jenis) <> '' and length(jenis) <= 40),
  kode text not null unique check (kode ~ '^[A-Z]{3}$'),
  digit smallint not null default 0 check (digit between 0 and 4),
  nomor_terakhir integer not null default 0 check (nomor_terakhir >= 0),
  updated_at timestamptz not null default now(),
  updated_by uuid references public.profiles(id)
);
create unique index if not exists rc_kb_jenis_lower on public.rc_kb_jenis(lower(jenis));
alter table public.rc_kb_jenis enable row level security;
revoke all on public.rc_kb_jenis from public, anon, authenticated;

insert into public.rc_kb_jenis(jenis, kode, digit, nomor_terakhir) values
  ('SOP Memo Nasional', 'SOP', 0, 27),   -- nomor lama terakhir 27/SAN/III/2026
  ('SOP Module SD',     'SSD', 0, 0),
  ('Internal Memo',     'IMO', 3, 2)     -- buku nomor: 001 dan 002/SAN/IM/V/2026 sudah terpakai
on conflict do nothing;

alter table public.rc_kb_items add column if not exists no_surat text check (no_surat is null or (btrim(no_surat) <> '' and length(no_surat) <= 60));
alter table public.rc_kb_items add column if not exists no_otomatis boolean not null default false;
alter table public.rc_kb_items add column if not exists kode_dok text check (kode_dok is null or (kode_dok ~ '^[0-9A-Za-z][0-9A-Za-z.-]*$' and length(kode_dok) <= 10));
alter table public.rc_kb_items add column if not exists keyword text check (keyword is null or length(keyword) <= 2000);
alter table public.rc_kb_items add column if not exists tgl_terbit date;
alter table public.rc_kb_items add column if not exists tgl_update date[] not null default '{}';
alter table public.rc_kb_items add column if not exists file_path text check (file_path is null or file_path ~ '^[0-9a-f-]{36}/[A-Za-z0-9._-]+\.pdf$');
alter table public.rc_kb_items add column if not exists file_nama text check (file_nama is null or length(file_nama) <= 200);
alter table public.rc_kb_items alter column url drop not null;
-- Minimal Link atau PDF; boleh keduanya.
alter table public.rc_kb_items drop constraint if exists rc_kb_items_sumber;
alter table public.rc_kb_items add constraint rc_kb_items_sumber check (url is not null or file_path is not null);

-- ------------------------------------------------------------------------------------------
-- 2. Pembantu
-- ------------------------------------------------------------------------------------------
create or replace function rc_private.kb_no_kunci(p text) returns text
language sql immutable set search_path = '' as $f$ select lower(regexp_replace(coalesce(p, ''), '\s+', '', 'g')); $f$;

create unique index if not exists rc_kb_items_no_surat on public.rc_kb_items(rc_private.kb_no_kunci(no_surat)) where no_surat is not null;
create unique index if not exists rc_kb_items_kode_aktif on public.rc_kb_items(lower(jenis), lower(kode_dok))
  where archived_at is null and kode_dok is not null;

create or replace function rc_private.kb_romawi(p integer) returns text
language sql immutable set search_path = '' as $f$
  select (array['I','II','III','IV','V','VI','VII','VIII','IX','X','XI','XII'])[p];
$f$;

-- Lampiran: kode angka diikuti huruf (001a). Induknya = kode angkanya.
create or replace function rc_private.kb_lampiran(p_kode text) returns boolean
language sql immutable set search_path = '' as $f$ select coalesce(p_kode ~* '^[0-9]+[a-z]+$', false); $f$;

-- No Surat yang ditampilkan: milik sendiri, atau milik induknya untuk lampiran.
create or replace function rc_private.kb_no_tampil(p_jenis text, p_kode text, p_no text) returns text
language sql stable security definer set search_path = '' as $f$
  select coalesce(p_no, case when rc_private.kb_lampiran(p_kode) then
    (select i.no_surat from public.rc_kb_items i
      where lower(i.jenis) = lower(p_jenis) and lower(i.kode_dok) = lower(substring(p_kode from '^[0-9]+'))
      order by i.archived_at nulls first limit 1) end, '');
$f$;

-- Nomor baru jenis itu. Baris rc_kb_jenis dikunci sampai transaksi selesai, sehingga dua
-- penyimpanan bersamaan tidak pernah mendapat nomor yang sama.
create or replace function rc_private.kb_no_baru(p_jenis text, p_tgl date) returns text
language plpgsql security definer set search_path = '' as $f$
declare v public.rc_kb_jenis%rowtype; v_no text; n integer;
begin
  select * into v from public.rc_kb_jenis where lower(jenis) = lower(btrim(p_jenis)) for update;
  if not found then raise exception 'Jenis "%" belum punya Kode 3 huruf untuk No Surat. Isi Kode Jenis lebih dulu.', p_jenis; end if;
  if p_tgl is null then raise exception 'Tanggal Terbit wajib diisi untuk membuat No Surat'; end if;
  n := v.nomor_terakhir;
  loop
    n := n + 1;
    v_no := case when v.digit > 0 then lpad(n::text, v.digit, '0') else n::text end
         || '/SAN/' || v.kode || '/' || rc_private.kb_romawi(extract(month from p_tgl)::integer) || '/' || extract(year from p_tgl)::integer;
    exit when not exists(select 1 from public.rc_kb_items where rc_private.kb_no_kunci(no_surat) = rc_private.kb_no_kunci(v_no));
  end loop;
  update public.rc_kb_jenis set nomor_terakhir = n where jenis = v.jenis;
  return v_no;
end $f$;

-- Tanggal ISO (YYYY-MM-DD) yang benar-benar ada; selain itu galat dengan nama kolomnya.
create or replace function rc_private.kb_tgl(p text, p_kolom text) returns date
language plpgsql immutable set search_path = '' as $f$
declare d date;
begin
  if nullif(btrim(coalesce(p, '')), '') is null then return null; end if;
  if btrim(p) !~ '^\d{4}-\d{2}-\d{2}$' then raise exception '% tidak terbaca: %', p_kolom, p; end if;
  begin d := btrim(p)::date; exception when others then raise exception '% tidak ada di kalender: %', p_kolom, p; end;
  return d;
end $f$;

-- Bersihkan teks: spasi khusus (nbsp) jadi spasi biasa, rapikan spasi berlebih.
create or replace function rc_private.kb_teks(p text) returns text
language sql immutable set search_path = '' as $f$
  select nullif(btrim(regexp_replace(replace(coalesce(p, ''), chr(160), ' '), '[ \t]+', ' ', 'g')), '');
$f$;

-- Akses berkas PDF: unggah oleh pengelola; baca oleh pengelola atau peserta dokumen aktif.
create or replace function public.rc_kb_pdf_boleh(p_name text, p_tulis boolean) returns boolean
language plpgsql stable security definer set search_path = '' as $f$
declare v_role text;
begin
  if coalesce(p_name, '') !~ '^[0-9a-f-]{36}/[A-Za-z0-9._-]+\.pdf$' then return false; end if;
  if p_tulis then return rc_private.can_tab('kb.manage'); end if;
  if rc_private.can_tab('kb.manage') then return exists(select 1 from public.rc_kb_items where file_path = p_name); end if;
  if not rc_private.can_tab('kb.resources') then return false; end if;
  select role into v_role from public.profiles where id = auth.uid();
  return exists(select 1 from public.rc_kb_items i where i.file_path = p_name and i.archived_at is null
                  and rc_private.kb_cocok(auth.uid(), v_role, i.peserta, i.regions, i.depot_ids));
end $f$;

-- ------------------------------------------------------------------------------------------
-- 3. Tulis satu dokumen (dipakai formulir dan Upload Excel)
-- ------------------------------------------------------------------------------------------
-- p: id, jenis, kodeJenis, kode, judul, deskripsi, keyword, tglTerbit, tglUpdate[], noSurat,
--    url | filePath + fileNama, pinned, pinDari, pinSampai, peserta[] | pesertaTeks,
--    regions[] | regionTeks, depotIds[] | depotTeks, bacaUlang.
-- p_upload: dicocokkan dengan Jenis + Kode Dokumen; versi naik otomatis bila link berubah atau
-- ada Tanggal Update baru.
create or replace function rc_private.kb_tulis(p jsonb, p_upload boolean) returns jsonb
language plpgsql security definer set search_path = '' as $f$
declare
  v_id uuid; v_jenis text := rc_private.kb_teks(p->>'jenis'); v_kj text := upper(btrim(coalesce(p->>'kodeJenis', '')));
  v_kode text := rc_private.kb_teks(p->>'kode'); v_judul text := rc_private.kb_teks(p->>'judul');
  v_desk text := nullif(btrim(replace(coalesce(p->>'deskripsi', ''), chr(160), ' ')), '');
  v_kw text := rc_private.kb_teks(p->>'keyword'); v_no text := rc_private.kb_teks(p->>'noSurat');
  v_url text := nullif(btrim(coalesce(p->>'url', '')), ''); v_file text := nullif(btrim(coalesce(p->>'filePath', '')), '');
  v_fnama text := left(nullif(btrim(coalesce(p->>'fileNama', '')), ''), 200);
  v_pin boolean := coalesce(jsonb_typeof(p->'pinned') = 'boolean' and (p->>'pinned')::boolean, false);
  v_terbit date; v_upd date[]; v_dari date; v_sampai date; v_hari date := (now() at time zone 'Asia/Jakarta')::date;
  v_peserta text[]; v_reg text[]; v_dep uuid[]; v_salah text[]; v_ada text; v_ulang boolean := false; v_otomatis boolean := false;
  v_lama public.rc_kb_items%rowtype; v_j public.rc_kb_jenis%rowtype; v_lain text;
begin
  if jsonb_typeof(p) is distinct from 'object' then raise exception 'Data dokumen tidak valid'; end if;
  begin v_id := nullif(btrim(coalesce(p->>'id', '')), '')::uuid;
  exception when invalid_text_representation then raise exception 'Dokumen tidak ditemukan'; end;
  if v_jenis is null then raise exception 'Jenis wajib diisi (mis. SOP Memo Nasional, Internal Memo)'; end if;
  if length(v_jenis) > 40 then raise exception 'Jenis maksimal 40 karakter'; end if;
  if v_judul is null then raise exception 'Judul wajib diisi'; end if;
  if length(v_judul) > 150 then raise exception 'Judul maksimal 150 karakter'; end if;
  if length(coalesce(v_desk, '')) > 2000 then raise exception 'Description maksimal 2000 karakter'; end if;
  if length(coalesce(v_kw, '')) > 2000 then raise exception 'Keyword maksimal 2000 karakter'; end if;
  if v_kode is not null and (v_kode !~ '^[0-9A-Za-z][0-9A-Za-z.-]*$' or length(v_kode) > 10) then
    raise exception 'Kode Dokumen hanya huruf / angka, maksimal 10 karakter (mis. 001, 001a): %', v_kode; end if;
  if p_upload and v_kode is null then raise exception 'Kode Dokumen wajib diisi pada upload (mis. 001, 001a)'; end if;
  if length(coalesce(v_no, '')) > 60 then raise exception 'No Surat maksimal 60 karakter'; end if;

  v_terbit := rc_private.kb_tgl(p->>'tglTerbit', 'Tanggal Terbit');
  -- Formulir tanpa Tanggal Terbit: hari ini. Upload wajib mengisinya.
  if v_terbit is null and not p_upload then v_terbit := v_hari; end if;
  if v_terbit is null then raise exception 'Tanggal Terbit wajib diisi'; end if;
  if jsonb_typeof(coalesce(p->'tglUpdate', '[]')) <> 'array' then raise exception 'Tanggal Update tidak valid'; end if;
  v_upd := array(select distinct rc_private.kb_tgl(x, 'Tanggal Update') from jsonb_array_elements_text(coalesce(p->'tglUpdate', '[]')) x
                  where btrim(x) <> '' order by 1);

  -- Link dan PDF masing-masing opsional; pemeriksaan "minimal satu" setelah dokumen lama diketahui.
  if v_url is not null then
    if v_url !~* '^https?://[^[:space:]<>"]+$' then raise exception 'Link harus diawali http:// atau https:// dan tanpa spasi'; end if;
    if length(v_url) > 1000 then raise exception 'Link maksimal 1000 karakter'; end if;
  end if;
  if v_file is not null then
    if v_file !~ '^[0-9a-f-]{36}/[A-Za-z0-9._-]+\.pdf$' then raise exception 'Berkas PDF tidak valid'; end if;
    if not exists(select 1 from storage.objects o where o.bucket_id = 'kb-pdf' and o.name = v_file) then
      raise exception 'Berkas PDF belum terunggah; pilih ulang berkasnya'; end if;
  else v_fnama := null;
  end if;

  v_dari := rc_private.kb_tgl(p->>'pinDari', 'Tanggal pin Dari'); v_sampai := rc_private.kb_tgl(p->>'pinSampai', 'Tanggal pin Sampai');
  if p_upload then v_pin := v_dari is not null or v_sampai is not null; end if;
  if v_pin then
    if v_dari is null or v_sampai is null then raise exception 'Isi tanggal pin Dari dan Sampai'; end if;
    if v_sampai < v_dari then raise exception 'Tanggal pin Sampai tidak boleh sebelum tanggal Dari'; end if;
  else v_dari := null; v_sampai := null;
  end if;

  -- Peserta: kode peran (formulir) atau teks label dipisah koma / "Semua" (upload).
  if p ? 'pesertaTeks' then
    v_peserta := array(select distinct lower(btrim(x)) from regexp_split_to_table(coalesce(p->>'pesertaTeks', ''), '\s*[,;]\s*') x where btrim(x) <> '');
    if 'semua' = any(v_peserta) then v_peserta := rc_private.kb_peran_semua();
    else
      v_salah := array(select x from unnest(v_peserta) x where not exists(select 1 from unnest(rc_private.kb_peran_semua()) r
                         where r = x or lower(rc_private.kb_peran_label(r)) = x));
      if cardinality(v_salah) > 0 then raise exception 'Peserta tidak dikenal: % (pakai Semua, Admin, Kepala Depot, OSC, Supervisor, Finance, Management, Lainnya, System Manager)', array_to_string(v_salah, ', '); end if;
      v_peserta := array(select r from unnest(rc_private.kb_peran_semua()) r where r = any(v_peserta) or lower(rc_private.kb_peran_label(r)) = any(v_peserta));
    end if;
  else
    if jsonb_typeof(coalesce(p->'peserta', '[]')) <> 'array' then raise exception 'Peserta tidak valid'; end if;
    v_peserta := array(select distinct lower(btrim(x)) from jsonb_array_elements_text(coalesce(p->'peserta', '[]')) x where btrim(x) <> '');
    v_salah := array(select r from unnest(v_peserta) r where r <> all(rc_private.kb_peran_semua()));
    if cardinality(v_salah) > 0 then raise exception 'Peserta tidak dikenal: %', array_to_string(v_salah, ', '); end if;
  end if;
  if cardinality(v_peserta) = 0 then raise exception 'Pilih minimal satu peserta (mis. Admin, Kepala Depot, OSC)'; end if;
  v_peserta := array(select r from unnest(rc_private.kb_peran_semua()) with ordinality z(r, o) where r = any(v_peserta) order by o);

  -- Wilayah: region dan depot (id dari formulir, kode depot dari upload). Kosong = semua wilayah.
  if p ? 'regionTeks' then
    v_reg := array(select distinct upper(btrim(x)) from regexp_split_to_table(coalesce(p->>'regionTeks', ''), '\s*[,;]\s*') x where btrim(x) <> '' order by 1);
  else
    if jsonb_typeof(coalesce(p->'regions', '[]')) <> 'array' then raise exception 'Wilayah tidak valid'; end if;
    v_reg := array(select distinct upper(btrim(x)) from jsonb_array_elements_text(coalesce(p->'regions', '[]')) x where btrim(x) <> '' order by 1);
  end if;
  v_salah := array(select r from unnest(v_reg) r
                    where not exists(select 1 from public.depots d where d.archived_at is null and upper(btrim(coalesce(d.region, ''))) = r));
  if cardinality(v_salah) > 0 then raise exception 'Region tidak dikenal: %', array_to_string(v_salah, ', '); end if;
  if p ? 'depotTeks' then
    v_salah := array(select upper(btrim(x)) from regexp_split_to_table(coalesce(p->>'depotTeks', ''), '\s*[,;]\s*') x
                      where btrim(x) <> '' and not exists(select 1 from public.depots d where d.archived_at is null and upper(d.depot_code) = upper(btrim(x))));
    if cardinality(v_salah) > 0 then raise exception 'Kode depot tidak dikenal: %', array_to_string(v_salah, ', '); end if;
    v_dep := array(select distinct d.id from regexp_split_to_table(coalesce(p->>'depotTeks', ''), '\s*[,;]\s*') x
                     join public.depots d on d.archived_at is null and upper(d.depot_code) = upper(btrim(x)));
  else
    if jsonb_typeof(coalesce(p->'depotIds', '[]')) <> 'array' then raise exception 'Wilayah tidak valid'; end if;
    begin
      v_dep := array(select distinct btrim(x)::uuid from jsonb_array_elements_text(coalesce(p->'depotIds', '[]')) x where btrim(x) <> '');
    exception when invalid_text_representation then raise exception 'Depot tidak valid'; end;
    if exists(select 1 from unnest(v_dep) i where not exists(select 1 from public.depots d where d.id = i and d.archived_at is null)) then
      raise exception 'Depot tidak dikenal atau sudah diarsip'; end if;
  end if;

  -- Penulisan jenis yang sudah ada dipakai ulang, supaya tab tidak terbelah.
  select x into v_ada from (select jenis x, 0 u from public.rc_kb_jenis where lower(jenis) = lower(v_jenis)
                            union all select i.jenis, 1 from public.rc_kb_items i where lower(i.jenis) = lower(v_jenis) and i.id is distinct from v_id) z
   order by u limit 1;
  v_jenis := coalesce(v_ada, v_jenis);

  -- Kode 3 huruf jenis: dipakai bila jenis belum punya; bila sudah punya harus sama.
  select * into v_j from public.rc_kb_jenis where lower(jenis) = lower(v_jenis);
  if v_kj <> '' then
    if v_kj !~ '^[A-Z]{3}$' then raise exception 'Kode Jenis harus 3 huruf (mis. SOP, IMO): %', v_kj; end if;
    if v_j.jenis is not null and v_j.kode <> v_kj then
      raise exception 'Jenis % sudah memakai kode %, bukan %', v_j.jenis, v_j.kode, v_kj; end if;
    if v_j.jenis is null then
      select jenis into v_lain from public.rc_kb_jenis where kode = v_kj;
      if found then raise exception 'Kode % sudah dipakai jenis %', v_kj, v_lain; end if;
      insert into public.rc_kb_jenis(jenis, kode, updated_by) values (v_jenis, v_kj, auth.uid());
    end if;
  end if;

  if v_id is not null then
    select * into v_lama from public.rc_kb_items where id = v_id for update;
    if not found then raise exception 'Dokumen tidak ditemukan'; end if;
    if v_lama.archived_at is not null then raise exception 'Dokumen sudah diarsip; pulihkan lebih dulu'; end if;
  elsif p_upload then
    select * into v_lama from public.rc_kb_items
     where archived_at is null and lower(jenis) = lower(v_jenis) and lower(kode_dok) = lower(v_kode) for update;
  end if;
  if v_kode is not null and exists(select 1 from public.rc_kb_items where archived_at is null and lower(jenis) = lower(v_jenis)
                                      and lower(kode_dok) = lower(v_kode) and id is distinct from v_lama.id) then
    raise exception 'Kode Dokumen % sudah dipakai di jenis %', v_kode, v_jenis; end if;

  -- Upload Excel (tanpa kolom PDF) mempertahankan PDF dokumen yang diperbarui; sel Link kosong
  -- mempertahankan link lama (seperti upload Customer Master: sel kosong tidak menghapus).
  if not (p ? 'filePath') and v_lama.id is not null then v_file := v_lama.file_path; v_fnama := v_lama.file_nama; end if;
  if p_upload and v_url is null and v_lama.id is not null then v_url := v_lama.url; end if;
  if v_url is null and v_file is null then
    raise exception 'Isi Link atau lampirkan PDF (minimal salah satu)%', case when p_upload then '; PDF dapat dilampirkan lewat Tambah / Ubah Dokumen' else '' end; end if;

  if v_pin and v_sampai < v_hari and (v_lama.id is null or v_lama.pin_sampai is distinct from v_sampai) and not p_upload then
    raise exception 'Tanggal pin Sampai (%) sudah lewat', to_char(v_sampai, 'DD-Mon-YYYY'); end if;

  -- Acknowledge ulang: diminta di formulir, atau (upload) link berubah / ada Tanggal Update baru.
  if v_lama.id is not null then
    v_ulang := case when p_upload
                 then v_lama.url is distinct from v_url or v_lama.file_path is distinct from v_file
                      or coalesce((select max(x) from unnest(v_upd) x), '-infinity') > coalesce((select max(x) from unnest(v_lama.tgl_update) x), '-infinity')
                 else coalesce(jsonb_typeof(p->'bacaUlang') = 'boolean' and (p->>'bacaUlang')::boolean, false) end;
  end if;

  -- No Surat: diketik = dipakai apa adanya; kosong = tetap nomor lama, atau dibuat sistem
  -- (bukan untuk lampiran).
  if v_no is null then
    v_no := v_lama.no_surat;
    v_otomatis := coalesce(v_lama.no_otomatis, false);
    if v_no is null and not rc_private.kb_lampiran(v_kode) then
      v_no := rc_private.kb_no_baru(v_jenis, v_terbit); v_otomatis := true;
    end if;
  elsif v_lama.id is not null and rc_private.kb_no_kunci(v_no) = rc_private.kb_no_kunci(v_lama.no_surat) then
    v_no := v_lama.no_surat; v_otomatis := v_lama.no_otomatis;
  end if;
  if v_no is not null then
    select judul into v_lain from public.rc_kb_items
     where rc_private.kb_no_kunci(no_surat) = rc_private.kb_no_kunci(v_no) and id is distinct from v_lama.id limit 1;
    if found then raise exception 'No Surat % sudah dipakai dokumen "%"', v_no, v_lain; end if;
  end if;

  if v_lama.id is null then
    insert into public.rc_kb_items(jenis, judul, deskripsi, url, pinned, pin_dari, pin_sampai, peserta, regions, depot_ids, created_by, updated_by,
                                   no_surat, no_otomatis, kode_dok, keyword, tgl_terbit, tgl_update, file_path, file_nama)
    values (v_jenis, v_judul, v_desk, v_url, v_pin, v_dari, v_sampai, v_peserta, v_reg, v_dep, auth.uid(), auth.uid(),
            v_no, v_otomatis, v_kode, v_kw, v_terbit, v_upd, v_file, v_fnama) returning id into v_id;
  else
    v_id := v_lama.id;
    update public.rc_kb_items set jenis = v_jenis, judul = v_judul, deskripsi = v_desk, url = v_url, pinned = v_pin,
           pin_dari = v_dari, pin_sampai = v_sampai, peserta = v_peserta, regions = v_reg, depot_ids = v_dep,
           no_surat = v_no, no_otomatis = v_otomatis, kode_dok = v_kode, keyword = v_kw, tgl_terbit = v_terbit, tgl_update = v_upd,
           file_path = v_file, file_nama = v_fnama,
           versi = versi + case when v_ulang then 1 else 0 end, versi_at = case when v_ulang then now() else versi_at end,
           updated_at = now(), updated_by = auth.uid()
     where id = v_id;
  end if;

  return jsonb_build_object('id', v_id, 'aksi', case when v_lama.id is null then 'tambah' else 'ubah' end,
    'jenis', v_jenis, 'judul', v_judul, 'kode', coalesce(v_kode, ''), 'noSurat', coalesce(v_no, ''),
    'noTampil', rc_private.kb_no_tampil(v_jenis, v_kode, v_no),
    'otomatis', v_otomatis and (v_lama.id is null or v_lama.no_surat is null), 'bacaUlang', v_ulang,
    'peserta', to_jsonb(v_peserta), 'regions', to_jsonb(v_reg), 'depotIds', to_jsonb(v_dep), 'url', v_url, 'file', v_file,
    'pinned', v_pin, 'pinDari', v_dari, 'pinSampai', v_sampai,
    'sebelum', case when v_lama.id is null then null else jsonb_build_object('jenis', v_lama.jenis, 'judul', v_lama.judul,
                 'noSurat', v_lama.no_surat, 'url', v_lama.url, 'file', v_lama.file_path, 'peserta', to_jsonb(v_lama.peserta),
                 'regions', to_jsonb(v_lama.regions), 'depotIds', to_jsonb(v_lama.depot_ids), 'versi', v_lama.versi) end);
end $f$;

revoke all on function rc_private.kb_no_kunci(text), rc_private.kb_romawi(integer), rc_private.kb_lampiran(text),
  rc_private.kb_no_tampil(text, text, text), rc_private.kb_no_baru(text, date), rc_private.kb_tgl(text, text),
  rc_private.kb_teks(text), rc_private.kb_tulis(jsonb, boolean) from public, anon, authenticated;

-- ------------------------------------------------------------------------------------------
-- 4. RPC
-- ------------------------------------------------------------------------------------------
create or replace function public.rc_kb_simpan(p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $f$
declare r jsonb; v_baru boolean;
begin
  perform rc_private.require_tab('kb.manage');
  r := rc_private.kb_tulis(p, false);
  v_baru := r->>'aksi' = 'tambah';
  insert into public.activity_logs(actor_id, event_type, details, module, tab, process_stage)
  values (auth.uid(), case when v_baru then 'kb_tambah' else 'kb_ubah' end,
    jsonb_build_object('detail', case when v_baru then 'Tambah ' else 'Ubah ' end || (r->>'jenis') || ': ' || (r->>'judul')
                                   || coalesce(' [' || nullif(r->>'noTampil', '') || ']', '')
                                   || ' (' || array_to_string(array(select rc_private.kb_peran_label(x) from jsonb_array_elements_text(r->'peserta') x), ', ')
                                   || ' · ' || rc_private.kb_wilayah_teks(array(select jsonb_array_elements_text(r->'regions')),
                                                                          array(select jsonb_array_elements_text(r->'depotIds')::uuid)) || ')'
                                   || case when (r->>'bacaUlang')::boolean then ' - peserta diminta acknowledge ulang' else '' end,
                       'itemId', r->'id', 'jenis', r->'jenis', 'judul', r->'judul', 'noSurat', r->'noSurat', 'noOtomatis', r->'otomatis',
                       'url', r->'url', 'file', r->'file', 'peserta', r->'peserta', 'regions', r->'regions', 'depotIds', r->'depotIds',
                       'pinned', r->'pinned', 'pinDari', r->'pinDari', 'pinSampai', r->'pinSampai', 'bacaUlang', r->'bacaUlang',
                       'sebelum', r->'sebelum'),
    'kb', 'manage', 'manage');
  return jsonb_build_object('status', 'success', 'id', r->'id', 'noSurat', r->'noTampil',
    'message', case when v_baru then 'Dokumen ditambahkan' else 'Dokumen diperbarui' end || ': ' || (r->>'jenis') || ' - ' || (r->>'judul')
               || case when (r->>'otomatis')::boolean then '. No Surat: ' || (r->>'noSurat') else '' end
               || case when (r->>'bacaUlang')::boolean then '. Seluruh peserta diminta membuka dan acknowledge ulang.' else '.' end);
end $f$;

-- Upload Excel: p_simpan = false hanya pratinjau (seluruh tulisan dibatalkan, termasuk nomor).
create or replace function public.rc_kb_unggah(p_rows jsonb, p_simpan boolean, p_nama text default null) returns jsonb
language plpgsql security definer set search_path = '' as $f$
declare x record; r jsonb; v_hasil jsonb := '[]'; n_tambah integer := 0; n_ubah integer := 0; n_galat integer := 0; n_nomor integer := 0;
begin
  perform rc_private.require_tab('kb.manage');
  if jsonb_typeof(p_rows) is distinct from 'array' or jsonb_array_length(p_rows) = 0 then raise exception 'Berkas tidak berisi baris dokumen'; end if;
  if jsonb_array_length(p_rows) > 1000 then raise exception 'Maksimal 1.000 baris sekali upload'; end if;
  begin
    -- Urut Tanggal Terbit supaya nomor otomatis mengikuti urutan terbitnya.
    for x in select e, o from jsonb_array_elements(p_rows) with ordinality t(e, o)
              order by case when e->>'tglTerbit' ~ '^\d{4}-\d{2}-\d{2}$' then e->>'tglTerbit' end nulls last, o loop
      begin
        if jsonb_typeof(x.e) is distinct from 'object' then raise exception 'Baris tidak valid'; end if;
        if coalesce(x.e->>'galat', '') <> '' then raise exception '%', x.e->>'galat'; end if;
        r := rc_private.kb_tulis(x.e - 'id' - 'bacaUlang' - 'peserta' - 'regions' - 'depotIds', true);
        if r->>'aksi' = 'tambah' then n_tambah := n_tambah + 1; else n_ubah := n_ubah + 1; end if;
        if (r->>'otomatis')::boolean then n_nomor := n_nomor + 1; end if;
        v_hasil := v_hasil || jsonb_build_object('baris', coalesce(x.e->'baris', to_jsonb(x.o)), 'status', r->>'aksi',
          'jenis', r->>'jenis', 'kode', r->>'kode', 'judul', r->>'judul', 'noSurat', r->>'noTampil', 'noSendiri', r->>'noSurat', 'otomatis', r->'otomatis',
          'bacaUlang', r->'bacaUlang', 'pesan', '');
      exception when others then
        n_galat := n_galat + 1;
        v_hasil := v_hasil || jsonb_build_object('baris', coalesce(x.e->'baris', to_jsonb(x.o)), 'status', 'galat',
          'jenis', coalesce(x.e->>'jenis', ''), 'kode', coalesce(x.e->>'kode', ''), 'judul', coalesce(x.e->>'judul', ''),
          'noSurat', coalesce(x.e->>'noSurat', ''), 'otomatis', false, 'bacaUlang', false, 'pesan', sqlerrm);
      end;
    end loop;
    -- Lampiran yang terbit lebih dulu dari induknya: No Surat induk dibaca setelah semua baris masuk.
    v_hasil := (select coalesce(jsonb_agg(case when h->>'status' = 'galat' then h
                  else h || jsonb_build_object('noSurat', rc_private.kb_no_tampil(h->>'jenis', nullif(h->>'kode', ''), nullif(h->>'noSendiri', ''))) end
                  - 'noSendiri'), '[]') from jsonb_array_elements(v_hasil) h);
    if not coalesce(p_simpan, false) then raise exception 'KB_PRATINJAU'; end if;
  exception when others then
    if sqlerrm <> 'KB_PRATINJAU' then raise; end if;
  end;

  if coalesce(p_simpan, false) and n_tambah + n_ubah > 0 then
    insert into public.activity_logs(actor_id, event_type, details, module, tab, process_stage)
    values (auth.uid(), 'kb_unggah',
      jsonb_build_object('detail', 'Upload Knowledge Base' || coalesce(' ' || nullif(btrim(coalesce(p_nama, '')), ''), '') || ': '
                                     || n_tambah || ' baru, ' || n_ubah || ' diperbarui, ' || n_galat || ' galat, ' || n_nomor || ' No Surat dibuat',
                         'baru', n_tambah, 'diperbarui', n_ubah, 'galat', n_galat, 'nomorDibuat', n_nomor,
                         'noSurat', (select coalesce(jsonb_agg(h->>'noSurat'), '[]') from jsonb_array_elements(v_hasil) h where (h->>'otomatis')::boolean)),
      'kb', 'manage', 'manage');
  end if;
  return jsonb_build_object('status', 'success', 'simpan', coalesce(p_simpan, false), 'baru', n_tambah, 'diperbarui', n_ubah,
    'galat', n_galat, 'nomorDibuat', n_nomor,
    'baris', (select coalesce(jsonb_agg(h order by (h->>'baris')::integer), '[]') from jsonb_array_elements(v_hasil) h));
end $f$;

create or replace function public.rc_kb_jenis_list() returns jsonb
language plpgsql stable security definer set search_path = '' as $f$
begin
  perform rc_private.require_tab('kb.manage');
  return jsonb_build_object('status', 'success', 'rows', coalesce((select jsonb_agg(jsonb_build_object('jenis', j.jenis, 'kode', j.kode,
      'digit', j.digit, 'nomorTerakhir', j.nomor_terakhir,
      'contoh', (case when j.digit > 0 then lpad((j.nomor_terakhir + 1)::text, j.digit, '0') else (j.nomor_terakhir + 1)::text end)
                || '/SAN/' || j.kode || '/' || rc_private.kb_romawi(extract(month from now() at time zone 'Asia/Jakarta')::integer)
                || '/' || extract(year from now() at time zone 'Asia/Jakarta')::integer,
      'dokumen', (select count(*) from public.rc_kb_items i where lower(i.jenis) = lower(j.jenis) and i.archived_at is null))
      order by lower(j.jenis)) from public.rc_kb_jenis j), '[]'::jsonb));
end $f$;

-- Tambah / ubah kode jenis. Nomor terakhir tidak boleh turun di bawah nomor otomatis yang sudah dipakai.
create or replace function public.rc_kb_jenis_simpan(p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $f$
declare v_jenis text := rc_private.kb_teks(p->>'jenis'); v_kode text := upper(btrim(coalesce(p->>'kode', '')));
  v_digit integer; v_n integer; v_lama public.rc_kb_jenis%rowtype; v_lain text; v_maks integer;
begin
  perform rc_private.require_tab('kb.manage');
  if v_jenis is null or length(v_jenis) > 40 then raise exception 'Jenis wajib diisi, maksimal 40 karakter'; end if;
  if v_kode !~ '^[A-Z]{3}$' then raise exception 'Kode harus 3 huruf (mis. SOP, IMO)'; end if;
  begin v_digit := coalesce(nullif(p->>'digit', '')::integer, 0); v_n := nullif(p->>'nomorTerakhir', '')::integer;
  exception when others then raise exception 'Digit / nomor terakhir harus angka'; end;
  if v_digit not between 0 and 4 then raise exception 'Digit 0 sampai 4'; end if;
  if v_n is not null and v_n < 0 then raise exception 'Nomor terakhir tidak boleh negatif'; end if;
  select * into v_lama from public.rc_kb_jenis where lower(jenis) = lower(v_jenis) for update;
  select jenis into v_lain from public.rc_kb_jenis where kode = v_kode and lower(jenis) <> lower(v_jenis);
  if found then raise exception 'Kode % sudah dipakai jenis %', v_kode, v_lain; end if;
  -- Nomor otomatis terbesar yang sudah terpakai dengan kode ini.
  select max(substring(no_surat from '^0*([0-9]+)/SAN/')::integer) into v_maks from public.rc_kb_items
   where no_surat ~ ('^[0-9]+/SAN/' || v_kode || '/');
  v_n := coalesce(v_n, v_lama.nomor_terakhir, 0);
  if v_n < coalesce(v_maks, 0) then raise exception 'Nomor terakhir % lebih kecil dari nomor yang sudah dipakai (%)', v_n, v_maks; end if;
  if v_lama.jenis is null then
    -- Penulisan jenis mengikuti dokumen yang sudah ada.
    select i.jenis into v_lain from public.rc_kb_items i where lower(i.jenis) = lower(v_jenis) order by i.created_at limit 1;
    insert into public.rc_kb_jenis(jenis, kode, digit, nomor_terakhir, updated_by) values (coalesce(v_lain, v_jenis), v_kode, v_digit, v_n, auth.uid());
  else
    update public.rc_kb_jenis set kode = v_kode, digit = v_digit, nomor_terakhir = v_n, updated_at = now(), updated_by = auth.uid()
     where jenis = v_lama.jenis;
  end if;
  insert into public.activity_logs(actor_id, event_type, details, module, tab, process_stage)
  values (auth.uid(), 'kb_kode_jenis',
    jsonb_build_object('detail', 'Kode Jenis ' || coalesce(v_lama.jenis, v_jenis) || ': ' || v_kode || ', nomor terakhir ' || v_n
                                   || case when v_lama.jenis is not null then ' (sebelumnya ' || v_lama.kode || ', ' || v_lama.nomor_terakhir || ')' else '' end,
                       'jenis', coalesce(v_lama.jenis, v_jenis), 'kode', v_kode, 'digit', v_digit, 'nomorTerakhir', v_n,
                       'sebelum', case when v_lama.jenis is null then null else jsonb_build_object('kode', v_lama.kode, 'digit', v_lama.digit, 'nomorTerakhir', v_lama.nomor_terakhir) end),
    'kb', 'manage', 'manage');
  return jsonb_build_object('status', 'success', 'message', 'Kode Jenis ' || coalesce(v_lama.jenis, v_jenis) || ' disimpan: ' || v_kode || '.');
end $f$;

revoke all on function public.rc_kb_unggah(jsonb, boolean, text), public.rc_kb_jenis_list(), public.rc_kb_jenis_simpan(jsonb),
  public.rc_kb_pdf_boleh(text, boolean) from public, anon;
grant execute on function public.rc_kb_unggah(jsonb, boolean, text), public.rc_kb_jenis_list(), public.rc_kb_jenis_simpan(jsonb),
  public.rc_kb_pdf_boleh(text, boolean) to authenticated;

-- ------------------------------------------------------------------------------------------
-- 5. Daftar: kolom baru
-- ------------------------------------------------------------------------------------------
do $tambal$
declare src text;
begin
  src := replace(pg_get_functiondef('public.rc_kb_list()'::regprocedure), E'\r', '');
  if src !~ '20261164040000' then
    src := pg_temp.ganti(src, $p$jsonb_build_object('id', i.id, 'jenis', i.jenis, 'judul', i.judul, 'deskripsi', coalesce(i.deskripsi, ''), 'url', i.url,$p$,
      $p$jsonb_build_object('id', i.id, 'jenis', i.jenis, 'judul', i.judul, 'deskripsi', coalesce(i.deskripsi, ''), 'url', coalesce(i.url, ''),
             /* 20261164040000 */ 'noSurat', rc_private.kb_no_tampil(i.jenis, i.kode_dok, i.no_surat), 'kode', coalesce(i.kode_dok, ''),
             'keyword', coalesce(i.keyword, ''), 'file', coalesce(i.file_path, ''), 'fileNama', coalesce(i.file_nama, ''),
             'tglUpdate', coalesce((select string_agg(to_char(u, 'DD-Mon-YYYY'), ', ' order by u) from unnest(i.tgl_update) u), ''),$p$, 1, 'list kolom');
    src := pg_temp.ganti(src, $p$'terbit', to_char(i.created_at at time zone 'Asia/Jakarta', 'DD-Mon-YYYY'),$p$,
      $p$'terbit', coalesce(to_char(i.tgl_terbit, 'DD-Mon-YYYY'), to_char(i.created_at at time zone 'Asia/Jakarta', 'DD-Mon-YYYY')),$p$, 1, 'list terbit');
    execute src;
  end if;

  src := replace(pg_get_functiondef('public.rc_kb_kelola_list(boolean)'::regprocedure), E'\r', '');
  if src !~ '20261164040000' then
    src := pg_temp.ganti(src, $p$              'deskripsi', coalesce(i.deskripsi, ''), 'url', i.url,$p$,
      $p$              'deskripsi', coalesce(i.deskripsi, ''), 'url', coalesce(i.url, ''),
              /* 20261164040000 */ 'noSurat', coalesce(i.no_surat, ''), 'noTampil', rc_private.kb_no_tampil(i.jenis, i.kode_dok, i.no_surat),
              'noOtomatis', i.no_otomatis, 'kode', coalesce(i.kode_dok, ''), 'keyword', coalesce(i.keyword, ''),
              'file', coalesce(i.file_path, ''), 'fileNama', coalesce(i.file_nama, ''),
              'tglTerbit', to_char(coalesce(i.tgl_terbit, (i.created_at at time zone 'Asia/Jakarta')::date), 'YYYY-MM-DD'),
              'terbit', to_char(coalesce(i.tgl_terbit, (i.created_at at time zone 'Asia/Jakarta')::date), 'DD-Mon-YYYY'),
              'tglUpdate', to_jsonb(array(select to_char(u, 'YYYY-MM-DD') from unnest(i.tgl_update) u order by u)),
              'tglUpdateTeks', coalesce((select string_agg(to_char(u, 'DD-Mon-YYYY'), ', ' order by u) from unnest(i.tgl_update) u), ''),$p$, 1, 'kelola kolom');
    src := pg_temp.ganti(src, $p$                     select jenis x from public.rc_kb_items
                     union all$p$,
      $p$                     select jenis x from public.rc_kb_items
                     union all select jenis from public.rc_kb_jenis /* 20261164040000 */
                     union all$p$, 1, 'kelola jenis');
    src := pg_temp.ganti(src, $p$    'regions', coalesce((select jsonb_agg(r order by r) from$p$,
      $p$    'kodeJenis', coalesce((select jsonb_object_agg(lower(j.jenis), j.kode) from public.rc_kb_jenis j), '{}'::jsonb), /* 20261164040000 */
    'regions', coalesce((select jsonb_agg(r order by r) from$p$, 1, 'kelola kode jenis');
    src := pg_temp.ganti(src, $p$order by (i.pinned and v_hari between i.pin_dari and i.pin_sampai) desc, i.created_at desc)$p$,
      $p$order by (i.pinned and v_hari between i.pin_dari and i.pin_sampai) desc, lower(i.jenis), i.kode_dok nulls last, i.created_at desc)$p$, 1, 'kelola urut');
    execute src;
  end if;

  src := replace(pg_get_functiondef('public.rc_kb_detail(uuid)'::regprocedure), E'\r', '');
  if src !~ '20261164040000' then
    src := pg_temp.ganti(src, $p$'item', (select jsonb_build_object('id', it.id, 'jenis', it.jenis, 'judul', it.judul, 'url', it.url, 'versi', it.versi,$p$,
      $p$'item', (select jsonb_build_object('id', it.id, 'jenis', it.jenis, 'judul', it.judul, 'url', coalesce(it.url, ''), 'versi', it.versi,
               /* 20261164040000 */ 'noSurat', rc_private.kb_no_tampil(it.jenis, it.kode_dok, it.no_surat), 'file', coalesce(it.file_path, ''),
               'fileNama', coalesce(it.file_nama, ''),$p$, 1, 'detail item');
    execute src;
  end if;
end $tambal$;

-- ------------------------------------------------------------------------------------------
-- 6. Storage PDF
-- ------------------------------------------------------------------------------------------
insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values ('kb-pdf', 'kb-pdf', false, 10485760, array['application/pdf'])
on conflict (id) do nothing;
drop policy if exists kb_pdf_tulis on storage.objects;
create policy kb_pdf_tulis on storage.objects for insert to authenticated
  with check (bucket_id = 'kb-pdf' and public.rc_kb_pdf_boleh(name, true));
drop policy if exists kb_pdf_baca on storage.objects;
create policy kb_pdf_baca on storage.objects for select to authenticated
  using (bucket_id = 'kb-pdf' and public.rc_kb_pdf_boleh(name, false));

-- ------------------------------------------------------------------------------------------
-- 7. Pemeriksaan diri
-- ------------------------------------------------------------------------------------------
do $cek$
declare e text := '';
begin
  if pg_get_functiondef('public.rc_kb_list()'::regprocedure) !~ 'noSurat' then e := e || ' list;'; end if;
  if pg_get_functiondef('public.rc_kb_kelola_list(boolean)'::regprocedure) !~ 'kodeJenis' then e := e || ' kelola;'; end if;
  if pg_get_functiondef('public.rc_kb_detail(uuid)'::regprocedure) !~ 'noSurat' then e := e || ' detail;'; end if;
  if rc_private.kb_romawi(4) <> 'IV' or rc_private.kb_romawi(12) <> 'XII' then e := e || ' romawi;'; end if;
  if rc_private.kb_no_kunci('21 / SAN /VII/ 2023') <> rc_private.kb_no_kunci('21/san/VII/2023') then e := e || ' kunci;'; end if;
  if not rc_private.kb_lampiran('001a') or rc_private.kb_lampiran('001') then e := e || ' lampiran;'; end if;
  if has_table_privilege('authenticated', 'public.rc_kb_jenis', 'select') then e := e || ' hak tabel;'; end if;
  if (select count(*) from public.rc_kb_jenis where kode in ('SOP', 'SSD', 'IMO')) <> 3 then e := e || ' kode awal;'; end if;
  if e <> '' then raise exception 'GAGAL:%', e; end if;
end $cek$;
