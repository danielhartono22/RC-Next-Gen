-- ==========================================================================================
-- Portal Link: satu modul yang merangkum seluruh link aplikasi / dashboard
-- ==========================================================================================
-- Pemilik, 18 Oktober 2026 (contoh integrated_link_system.html): "buat 1 modul lagi yang
-- merangkum seluruh link ... untuk editor ada tab terpisah ketika access management tick ...
-- penambahan link bisa dilakukan bahkan bisa membuat peraturan akan ditampilkan di region
-- atau depot mana aja."
--
-- KEPUTUSAN
--  * Susunan mengikuti contoh: Tab berisi link langsung, atau Tab berisi Sub Tab. Pin berlaku
--    per Tab (seluruh barisnya ikut); Tab yang di-pin tampil paling atas, sisanya urut abjad.
--  * Tab "Daftar Link" (links.view) terlihat oleh setiap akun - modulnya tanpa izin modul
--    (permission null), seperti Profil Depot. Tab "Editor Link" (links.editor) terpisah.
--    Pemilik, 19 Oktober 2026 (sebelum transport ke prod): "default-nya langsung akses ke semua
--    user, untuk portal link user admin hanya bisa lihat tanpa editor" - Editor Link bawaan
--    terbuka untuk semua peran KECUALI admin; peran admin tidak pernah mendapat Editor Link walau
--    dicentang. System Manager selalu.
--  * Aturan tampil per link: Region dan/atau Depot. Keduanya kosong = semua akun. Bila diisi,
--    link terlihat oleh akun yang jangkauan depotnya (user_depot_access) mencakup salah satu
--    depot terpilih atau salah satu depot di region terpilih. System Manager melihat seluruhnya
--    karena jangkauannya seluruh depot.
--  * Link tidak dihapus permanen: diarsip dan dapat dipulihkan.
--  * URL hanya http:// atau https:// (mencegah javascript: dan sejenisnya).
--  * Log Activity satu baris per proses (simpan, pin, arsip / pulihkan).
--
-- Tambalan tab_rights memakai penjaga MD5 pra-citra: prod 19 Oktober 2026 (503f50a8, tanpa
-- 20261163170000), dev sebelum versi awal migrasi ini (8e2f9b17), dan dev yang sudah memuat versi
-- awal migrasi ini beserta 20261163190000 (9a8316ff; klausa "hanya bila dicentang" yang lama
-- dibuang). Ditransport ke prod 19 Oktober 2026 MENDAHULUI 20261163170000 dan 20261163190000:
-- penjaga MD5 tab_rights di kedua migrasi itu harus diukur ulang sebelum keduanya dipindahkan.
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
create table if not exists public.rc_portal_links (
  id uuid primary key default gen_random_uuid(),
  tab text not null check (btrim(tab) <> '' and length(tab) <= 60),
  sub_tab text check (sub_tab is null or (btrim(sub_tab) <> '' and length(sub_tab) <= 80)),
  url text not null check (url ~* '^https?://[^[:space:]<>"]+$' and length(url) <= 1000),
  keterangan text check (keterangan is null or length(keterangan) <= 300),
  pinned boolean not null default false,
  -- Aturan tampil; keduanya kosong = semua akun.
  regions text[] not null default '{}',
  depot_ids uuid[] not null default '{}',
  created_at timestamptz not null default now(),
  created_by uuid references public.profiles(id),
  updated_at timestamptz not null default now(),
  updated_by uuid references public.profiles(id),
  archived_at timestamptz,
  archived_by uuid references public.profiles(id),
  archive_reason text
);
create index if not exists rc_portal_links_tab on public.rc_portal_links(lower(tab)) where archived_at is null;

-- Hanya lewat RPC.
alter table public.rc_portal_links enable row level security;
revoke all on public.rc_portal_links from public, anon, authenticated;

-- ------------------------------------------------------------------------------------------
-- 2. Aturan tampil
-- ------------------------------------------------------------------------------------------
create or replace function rc_private.link_terlihat(p_regions text[], p_depots uuid[]) returns boolean
language sql stable security definer set search_path = '' as $f$
  select (coalesce(cardinality(p_regions), 0) = 0 and coalesce(cardinality(p_depots), 0) = 0)
      or rc_private.is_system_manager()
      or exists(select 1 from public.user_depot_access a join public.depots d on d.id = a.depot_id
                 where a.user_id = (select auth.uid())
                   and (d.id = any(coalesce(p_depots, '{}'))
                        or upper(btrim(coalesce(d.region, ''))) = any(coalesce(p_regions, '{}'))));
$f$;
revoke all on function rc_private.link_terlihat(text[], uuid[]) from public, anon;
grant execute on function rc_private.link_terlihat(text[], uuid[]) to authenticated;

-- Ringkasan aturan untuk layar Editor ("Semua akun" / "Region 2A, 3 · Depot 4F, 4D").
create or replace function rc_private.link_aturan_teks(p_regions text[], p_depots uuid[]) returns text
language sql stable security definer set search_path = '' as $f$
  select case when coalesce(cardinality(p_regions), 0) = 0 and coalesce(cardinality(p_depots), 0) = 0 then 'Semua akun'
    else concat_ws(' · ',
      case when cardinality(p_regions) > 0 then 'Region ' || array_to_string(p_regions, ', ') end,
      case when cardinality(p_depots) > 0 then 'Depot ' || (select string_agg(d.depot_code, ', ' order by d.depot_code)
                                                               from public.depots d where d.id = any(p_depots)) end) end;
$f$;
revoke all on function rc_private.link_aturan_teks(text[], uuid[]) from public, anon, authenticated;

-- ------------------------------------------------------------------------------------------
-- 3. RPC
-- ------------------------------------------------------------------------------------------
-- Daftar Link: hanya link yang aturan tampilnya mencakup akun ini.
create or replace function public.rc_link_list() returns jsonb
language plpgsql stable security definer set search_path = '' as $f$
begin
  perform rc_private.require_tab('links.view');
  return jsonb_build_object('status', 'success',
    'rows', coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'tab', l.tab, 'subTab', coalesce(l.sub_tab, ''),
              'url', l.url, 'keterangan', coalesce(l.keterangan, ''), 'pinned', l.pinned)
              order by l.pinned desc, lower(l.tab), lower(coalesce(l.sub_tab, '')), l.created_at)
       from public.rc_portal_links l
      where l.archived_at is null and rc_private.link_terlihat(l.regions, l.depot_ids)), '[]'::jsonb));
end $f$;

-- Editor: seluruh link (aktif atau arsip) beserta pilihan Region dan Depot.
create or replace function public.rc_link_editor_list(p_arsip boolean default false) returns jsonb
language plpgsql stable security definer set search_path = '' as $f$
begin
  perform rc_private.require_tab('links.editor');
  return jsonb_build_object('status', 'success',
    'rows', coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'tab', l.tab, 'subTab', coalesce(l.sub_tab, ''),
              'url', l.url, 'keterangan', coalesce(l.keterangan, ''), 'pinned', l.pinned,
              'regions', to_jsonb(l.regions), 'depotIds', to_jsonb(l.depot_ids),
              'aturan', rc_private.link_aturan_teks(l.regions, l.depot_ids),
              'diubahOleh', coalesce(nullif(p.full_name, ''), p.user_code, '-'),
              'diubahPada', to_char(l.updated_at at time zone 'Asia/Jakarta', 'DD-Mon-YYYY HH24:MI'),
              'arsip', l.archived_at is not null, 'alasanArsip', coalesce(l.archive_reason, ''),
              'diarsipPada', coalesce(to_char(l.archived_at at time zone 'Asia/Jakarta', 'DD-Mon-YYYY HH24:MI'), ''))
              order by l.pinned desc, lower(l.tab), lower(coalesce(l.sub_tab, '')), l.created_at)
       from public.rc_portal_links l
       left join public.profiles p on p.id = coalesce(l.updated_by, l.created_by)
      where (l.archived_at is not null) = coalesce(p_arsip, false)), '[]'::jsonb),
    'jumlahAktif', (select count(*) from public.rc_portal_links where archived_at is null),
    'jumlahArsip', (select count(*) from public.rc_portal_links where archived_at is not null),
    'regions', coalesce((select jsonb_agg(r order by r) from (select distinct upper(btrim(d.region)) r from public.depots d
                 where d.archived_at is null and btrim(coalesce(d.region, '')) <> '') x), '[]'::jsonb),
    'depots', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'kode', d.depot_code,
                 'nama', coalesce(nullif(d.depot_name, ''), d.depot_code), 'region', coalesce(upper(btrim(d.region)), ''))
                 order by d.depot_code) from public.depots d where d.archived_at is null), '[]'::jsonb));
end $f$;

-- Tambah (id kosong) atau ubah satu link. Pin berlaku untuk seluruh baris Tab yang sama.
create or replace function public.rc_link_simpan(p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $f$
declare
  v_id uuid; v_tab text := regexp_replace(btrim(coalesce(p->>'tab', '')), '\s+', ' ', 'g');
  v_sub text := nullif(regexp_replace(btrim(coalesce(p->>'subTab', '')), '\s+', ' ', 'g'), '');
  v_url text := btrim(coalesce(p->>'url', '')); v_ket text := nullif(btrim(coalesce(p->>'keterangan', '')), '');
  v_reg text[]; v_dep uuid[]; v_salah text[]; v_pin boolean; v_ada text; v_lama public.rc_portal_links%rowtype;
begin
  perform rc_private.require_tab('links.editor');
  if jsonb_typeof(p) is distinct from 'object' then raise exception 'Data link tidak valid'; end if;
  begin v_id := nullif(btrim(coalesce(p->>'id', '')), '')::uuid;
  exception when invalid_text_representation then raise exception 'Link tidak ditemukan'; end;
  if v_tab = '' then raise exception 'Nama Tab wajib diisi'; end if;
  if length(v_tab) > 60 then raise exception 'Nama Tab maksimal 60 karakter'; end if;
  if length(coalesce(v_sub, '')) > 80 then raise exception 'Nama Sub Tab maksimal 80 karakter'; end if;
  if v_url !~* '^https?://[^[:space:]<>"]+$' then raise exception 'URL harus diawali http:// atau https:// dan tanpa spasi'; end if;
  if length(v_url) > 1000 then raise exception 'URL maksimal 1000 karakter'; end if;
  if length(coalesce(v_ket, '')) > 300 then raise exception 'Keterangan maksimal 300 karakter'; end if;
  if jsonb_typeof(coalesce(p->'regions', '[]')) <> 'array' or jsonb_typeof(coalesce(p->'depotIds', '[]')) <> 'array' then
    raise exception 'Aturan tampil tidak valid'; end if;

  v_reg := array(select distinct upper(btrim(x)) from jsonb_array_elements_text(coalesce(p->'regions', '[]')) x
                  where btrim(x) <> '' order by 1);
  v_salah := array(select r from unnest(v_reg) r
                    where not exists(select 1 from public.depots d where d.archived_at is null and upper(btrim(coalesce(d.region, ''))) = r));
  if cardinality(v_salah) > 0 then raise exception 'Region tidak dikenal: %', array_to_string(v_salah, ', '); end if;
  begin
    v_dep := array(select distinct btrim(x)::uuid from jsonb_array_elements_text(coalesce(p->'depotIds', '[]')) x where btrim(x) <> '');
  exception when invalid_text_representation then raise exception 'Depot tidak valid'; end;
  if exists(select 1 from unnest(v_dep) i where not exists(select 1 from public.depots d where d.id = i and d.archived_at is null)) then
    raise exception 'Depot tidak dikenal atau sudah diarsip'; end if;

  if v_id is not null then
    select * into v_lama from public.rc_portal_links where id = v_id for update;
    if not found then raise exception 'Link tidak ditemukan'; end if;
    if v_lama.archived_at is not null then raise exception 'Link sudah diarsip; pulihkan lebih dulu'; end if;
  end if;

  -- Tab yang sudah ada dipakai dengan penulisan yang sama, supaya tidak terbelah karena huruf besar/kecil.
  select l.tab into v_ada from public.rc_portal_links l
   where lower(l.tab) = lower(v_tab) and l.archived_at is null and l.id is distinct from v_id order by l.created_at limit 1;
  v_tab := coalesce(v_ada, v_tab);
  v_pin := case when jsonb_typeof(p->'pinned') = 'boolean' then (p->>'pinned')::boolean
                else coalesce((select bool_or(l.pinned) from public.rc_portal_links l
                                where lower(l.tab) = lower(v_tab) and l.archived_at is null and l.id is distinct from v_id), v_lama.pinned, false) end;

  if v_id is null then
    insert into public.rc_portal_links(tab, sub_tab, url, keterangan, pinned, regions, depot_ids, created_by, updated_by)
    values (v_tab, v_sub, v_url, v_ket, v_pin, v_reg, v_dep, auth.uid(), auth.uid()) returning id into v_id;
  else
    update public.rc_portal_links set tab = v_tab, sub_tab = v_sub, url = v_url, keterangan = v_ket, pinned = v_pin,
           regions = v_reg, depot_ids = v_dep, updated_at = now(), updated_by = auth.uid()
     where id = v_id;
  end if;
  update public.rc_portal_links set pinned = v_pin
   where lower(tab) = lower(v_tab) and archived_at is null and pinned <> v_pin;

  insert into public.activity_logs(actor_id, event_type, details, module, tab, process_stage)
  values (auth.uid(), case when v_lama.id is null then 'link_tambah' else 'link_ubah' end,
    jsonb_build_object('detail', case when v_lama.id is null then 'Tambah link: ' else 'Ubah link: ' end
                                   || v_tab || coalesce(' > ' || v_sub, '') || ' (' || rc_private.link_aturan_teks(v_reg, v_dep) || ')',
                       'linkId', v_id, 'tab', v_tab, 'subTab', v_sub, 'url', v_url, 'regions', to_jsonb(v_reg),
                       'depotIds', to_jsonb(v_dep), 'pinned', v_pin,
                       'sebelum', case when v_lama.id is null then null else jsonb_build_object('tab', v_lama.tab, 'subTab', v_lama.sub_tab,
                                    'url', v_lama.url, 'regions', to_jsonb(v_lama.regions), 'depotIds', to_jsonb(v_lama.depot_ids)) end),
    'links', 'editor', 'editor');
  return jsonb_build_object('status', 'success', 'id', v_id,
    'message', case when v_lama.id is null then 'Link ditambahkan' else 'Link diperbarui' end || ': ' || v_tab || coalesce(' > ' || v_sub, '') || '.');
end $f$;

-- Pin / lepas pin satu Tab beserta seluruh barisnya.
create or replace function public.rc_link_pin(p_tab text, p_pinned boolean) returns jsonb
language plpgsql security definer set search_path = '' as $f$
declare n integer; v_tab text := btrim(coalesce(p_tab, ''));
begin
  perform rc_private.require_tab('links.editor');
  if p_pinned is null then raise exception 'Status pin wajib diisi'; end if;
  update public.rc_portal_links set pinned = p_pinned, updated_at = now(), updated_by = auth.uid()
   where lower(tab) = lower(v_tab) and archived_at is null;
  get diagnostics n = row_count;
  if n = 0 then raise exception 'Tab % tidak ditemukan', v_tab; end if;
  insert into public.activity_logs(actor_id, event_type, details, module, tab, process_stage)
  values (auth.uid(), case when p_pinned then 'link_pin' else 'link_lepas_pin' end,
    jsonb_build_object('detail', case when p_pinned then 'Pin Tab: ' else 'Lepas pin Tab: ' end || v_tab || ' (' || n || ' link)',
                       'tab', v_tab, 'jumlah', n), 'links', 'editor', 'editor');
  return jsonb_build_object('status', 'success', 'jumlah', n,
    'message', 'Tab ' || v_tab || case when p_pinned then ' di-pin ke atas.' else ' dilepas dari pin.' end);
end $f$;

-- Arsip (dengan alasan) atau pulihkan beberapa link sekaligus.
create or replace function public.rc_link_arsip(p_ids uuid[], p_arsip boolean, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = '' as $f$
declare n integer; v_alasan text := left(btrim(coalesce(p_reason, '')), 300); v_ids uuid[] := array(select distinct x from unnest(coalesce(p_ids, '{}')) x where x is not null);
begin
  perform rc_private.require_tab('links.editor');
  if p_arsip is null then raise exception 'Pilih arsip atau pulihkan'; end if;
  if cardinality(v_ids) = 0 then raise exception 'Pilih link lebih dulu'; end if;
  if cardinality(v_ids) > 500 then raise exception 'Maksimal 500 link sekali proses'; end if;
  if p_arsip and length(v_alasan) < 3 then raise exception 'Alasan arsip wajib diisi'; end if;

  if p_arsip then
    update public.rc_portal_links set archived_at = now(), archived_by = auth.uid(), archive_reason = v_alasan
     where id = any(v_ids) and archived_at is null;
    get diagnostics n = row_count;
  else
    -- Link yang dipulihkan mengikuti status pin Tab-nya yang masih aktif.
    update public.rc_portal_links l set archived_at = null, archived_by = null, archive_reason = null,
           updated_at = now(), updated_by = auth.uid(),
           pinned = coalesce((select bool_or(x.pinned) from public.rc_portal_links x
                               where lower(x.tab) = lower(l.tab) and x.archived_at is null), l.pinned)
     where l.id = any(v_ids) and l.archived_at is not null;
    get diagnostics n = row_count;
  end if;
  if n = 0 then raise exception 'Tidak ada link yang dapat %', case when p_arsip then 'diarsip' else 'dipulihkan' end; end if;

  insert into public.activity_logs(actor_id, event_type, details, module, tab, process_stage)
  values (auth.uid(), case when p_arsip then 'link_arsip' else 'link_pulihkan' end,
    jsonb_build_object('detail', case when p_arsip then 'Arsip link: ' else 'Pulihkan link: ' end || n || ' link'
                                   || case when p_arsip then ' (' || v_alasan || ')' else '' end,
                       'jumlah', n, 'alasan', nullif(v_alasan, ''), 'linkIds', to_jsonb(v_ids)), 'links', 'editor', 'editor');
  return jsonb_build_object('status', 'success', 'jumlah', n,
    'message', n || ' link ' || case when p_arsip then 'diarsip.' else 'dipulihkan.' end);
end $f$;

revoke all on function public.rc_link_list(), public.rc_link_editor_list(boolean), public.rc_link_simpan(jsonb),
  public.rc_link_pin(text, boolean), public.rc_link_arsip(uuid[], boolean, text) from public, anon;
grant execute on function public.rc_link_list(), public.rc_link_editor_list(boolean), public.rc_link_simpan(jsonb),
  public.rc_link_pin(text, boolean), public.rc_link_arsip(uuid[], boolean, text) to authenticated;

-- ------------------------------------------------------------------------------------------
-- 4. Katalog tab dan tambalan tab_rights
-- ------------------------------------------------------------------------------------------
insert into rc_private.tab_catalog(code, module, tab, permission, title, label, key)
select x.code, 'links', x.tab, null, x.title, 'Portal Link', 'links'
  from (values ('links.view', 'view', 'Daftar Link'), ('links.editor', 'editor', 'Editor Link')) x(code, tab, title)
 where not exists(select 1 from rc_private.tab_catalog c where c.code = x.code);

do $tambal$
declare src text;
begin
  src := replace(pg_get_functiondef('rc_private.tab_rights(uuid)'::regprocedure), E'\r', '');
  if src ~ 'Admin Depot hanya Daftar Link' then raise notice 'tab_rights sudah ditambal.';
  else
    if md5(src) not in ('503f50a8170ee9b5f90b7ba6bb5c6c6a', '8e2f9b17818fadec3b571d8dbb688bfb', '9a8316ff3396e265722e555a32c8dd21') then
      raise exception 'DITOLAK: tab_rights berbeda dari yang diukur (md5 %).', md5(src); end if;
    -- Versi awal migrasi ini (dev): Editor Link "hanya bila dicentang" - dibuang.
    if src ~ '20261163180000: hanya bila dicentang' then
      src := pg_temp.ganti(src, $p$ or t.code='links.editor' /* 20261163180000: hanya bila dicentang */$p$, '', 1, 'tab_rights buang opt-in');
    end if;
    -- Peran admin tidak pernah mendapat Editor Link; peran lain bawaannya terbuka.
    src := pg_temp.ganti(src, $p$select coalesce(jsonb_object_agg(t.code,p.role='system manager' or$p$,
      $p$select coalesce(jsonb_object_agg(t.code,not (t.code='links.editor' and p.role='admin') /* 20261163180000: Admin Depot hanya Daftar Link */ and (p.role='system manager' or$p$, 1, 'tab_rights admin');
    src := pg_temp.ganti(src, $p$)))),'{}') from rc_private.tab_catalog t$p$, $p$))))),'{}') from rc_private.tab_catalog t$p$, 1, 'tab_rights tutup');
    execute src;
  end if;
end $tambal$;

-- ------------------------------------------------------------------------------------------
-- 5. Pemeriksaan diri
-- ------------------------------------------------------------------------------------------
do $cek$
declare e text := '';
begin
  if pg_get_functiondef('rc_private.tab_rights(uuid)'::regprocedure) !~ 'links\.editor' then e := e || ' tab_rights;'; end if;
  if (select count(*) from rc_private.tab_catalog where code in ('links.view', 'links.editor') and permission is null) <> 2 then
    e := e || ' katalog tab;'; end if;
  if not (select relrowsecurity from pg_class where oid = 'public.rc_portal_links'::regclass) then e := e || ' RLS;'; end if;
  if has_table_privilege('authenticated', 'public.rc_portal_links', 'select') then e := e || ' hak tabel;'; end if;
  if rc_private.link_terlihat('{}', '{}') is not true then e := e || ' aturan kosong;'; end if;
  if e <> '' then raise exception 'GAGAL:%', e; end if;
end $cek$;
