-- ==========================================================================================
-- Variant lebih dari satu per T-code, dan link publik (tanpa login) Details Campaign
-- ==========================================================================================
-- Pemilik, 27 Oktober 2026:
--   "untuk variant bisa lebih dari 1 untuk 1 campaign dan 1 tcode, saya mau tampilkan yg ada
--    tcode nya aja. jika tidak ada tidak usah ditampilkan."
--   "buat general link tanpa login untuk details campaign / Modul Timetable"
--
-- VARIANT. Kolom variant_<tcode> / _desc di Campaign Master kini boleh memuat beberapa variant,
-- dipisah titik koma atau baris baru; Name dan Description berpasangan menurut urutan. Details
-- Campaign hanya menerima T-code yang punya Variant Name (rc_private.variant_daftar). Batas
-- panjang kolom variant di campaign_upsert dinaikkan dari 200 ke 2.000 karakter.
--
-- LINK PUBLIK. Badan kueri Details Campaign pindah ke rc_private.timetable_campaigns_isi(p_publik)
-- dan dibungkus dua kali, sama seperti Claim Dashboard publik:
--   public.rc_timetable_campaigns()         portal; tab timetable.campaign; jangkauan akun
--   public.rc_publik_timetable_campaigns()  halaman /details-campaign; anon; seluruh depot
-- Mode publik tidak memuat data pengguna (depot asal, Resource Partner) maupun path memo; yang
-- dikirim hanya tanda bahwa memo ada (adaMemo). Tidak ada data pelanggan di Details Campaign.
-- ==========================================================================================

create or replace function pg_temp.ganti(p_src text, p_lama text, p_baru text, p_n integer, p_nama text)
returns text language plpgsql as $f$
declare n integer := (length(p_src) - length(replace(p_src, p_lama, ''))) / greatest(length(p_lama), 1);
begin
  if n <> p_n then raise exception '%: pola ditemukan % kali, diharapkan %: %', p_nama, n, p_n, left(p_lama, 120); end if;
  return replace(p_src, p_lama, p_baru);
end $f$;

-- ---- Variant ------------------------------------------------------------------------------
create or replace function rc_private.variant_daftar(p_zsq04 text, p_zsq04_desc text, p_zsod text, p_zsod_desc text,
  p_mcsi text, p_mcsi_desc text)
 returns jsonb
 language sql
 immutable
 set search_path = ''
as $function$
  select coalesce(jsonb_agg(jsonb_build_object('laporan', x.kode, 'nama', x.nama, 'deskripsi', x.deskripsi) order by x.urut, x.i), '[]'::jsonb)
    from (select t.urut, t.kode, n.i, btrim(n.v) nama,
                 coalesce((select btrim(d.v) from unnest(regexp_split_to_array(coalesce(t.deskripsi, ''), '\s*[;\n]\s*')) with ordinality as d(v, i)
                            where d.i = n.i), '') deskripsi
            from (values (1, 'ZSQ04', p_zsq04, p_zsq04_desc), (2, 'ZSOD', p_zsod, p_zsod_desc), (3, 'MCSI', p_mcsi, p_mcsi_desc)) t(urut, kode, nama, deskripsi)
           cross join lateral unnest(regexp_split_to_array(coalesce(t.nama, ''), '\s*[;\n]\s*')) with ordinality as n(v, i)
           where btrim(n.v) <> '') x;
$function$;

-- Batas tabel ikut dinaikkan (constraint lama 200 karakter per kolom variant).
alter table public.campaigns drop constraint if exists campaigns_variant_panjang;
alter table public.campaigns add constraint campaigns_variant_panjang check (
  coalesce(length(variant_zsq04), 0) <= 2000 and coalesce(length(variant_zsod), 0) <= 2000 and coalesce(length(variant_mcsi), 0) <= 2000
  and coalesce(length(variant_zsq04_desc), 0) <= 2000 and coalesce(length(variant_zsod_desc), 0) <= 2000 and coalesce(length(variant_mcsi_desc), 0) <= 2000);

do $tambal$
declare src text; f text;
begin
  f := 'rc_private.campaign_upsert(jsonb)';
  src := replace(pg_get_functiondef(f::regprocedure), E'\r', '');
  if src !~ '20261163470000' then
    src := pg_temp.ganti(src, $p$   if jsonb_typeof(r->k)<>'string' or length(r->>k)>200 then
    raise exception 'Nilai kolom % harus teks maksimal 200 karakter',k; end if;$p$,
      $p$   if jsonb_typeof(r->k)<>'string' or length(r->>k)>(case when k like 'variant%' then 2000 else 200 end) /* 20261163470000 */ then
    raise exception 'Nilai kolom % harus teks maksimal % karakter',k,(case when k like 'variant%' then 2000 else 200 end); end if;$p$, 1, f);
    execute src;
  end if;
end $tambal$;

-- ---- Not Participating: mode seluruh depot -------------------------------------------------
create or replace function rc_private.np_ringkas(p_campaign uuid, p_semua boolean)
 returns jsonb
 language sql
 stable security definer
 set search_path to ''
as $function$
  select jsonb_build_object(
    'npRegion', coalesce((select jsonb_agg(n.region order by n.region) from public.campaign_not_participating n
                           where n.campaign_id = p_campaign and n.region is not null), '[]'::jsonb),
    'npDepot', coalesce((select jsonb_agg(d.depot_code order by d.depot_code) from public.campaign_not_participating n
                           join public.depots d on d.id = n.depot_id
                          where n.campaign_id = p_campaign and (p_semua or rc_private.can_view(d.id))), '[]'::jsonb),
    'npDepotLain', (select count(*) from public.campaign_not_participating n
                     where n.campaign_id = p_campaign and n.depot_id is not null and not p_semua and not rc_private.can_view(n.depot_id)));
$function$;
create or replace function rc_private.np_ringkas(p_campaign uuid)
 returns jsonb
 language sql
 stable security definer
 set search_path to ''
as $function$
  select rc_private.np_ringkas(p_campaign, false);
$function$;
revoke all on function rc_private.np_ringkas(uuid, boolean) from public, anon;

-- ---- Satu badan kueri Details Campaign -----------------------------------------------------
do $isi$
declare src text;
begin
  if to_regprocedure('rc_private.timetable_campaigns_isi(boolean)') is null then
    src := replace(pg_get_functiondef('public.rc_timetable_campaigns()'::regprocedure), E'\r', '');
    src := pg_temp.ganti(src, 'CREATE OR REPLACE FUNCTION public.rc_timetable_campaigns()',
      'CREATE OR REPLACE FUNCTION rc_private.timetable_campaigns_isi(p_publik boolean)', 1, 'isi kepala');
    src := pg_temp.ganti(src, $p$  perform rc_private.require_tab('timetable.campaign');
$p$, $p$  -- 20261163470000: hak akses diperiksa pembungkus. p_publik = halaman /details-campaign tanpa
  -- login: seluruh depot, tanpa depot asal / Resource Partner (auth.uid() kosong), tanpa path memo.
$p$, 1, 'isi tab');
    src := pg_temp.ganti(src, '(l.semua or d.id = any(l.depot)', '(p_publik or l.semua or d.id = any(l.depot)', 2, 'isi jangkauan');
    src := pg_temp.ganti(src, '|| rc_private.np_ringkas(ca.id)', '|| rc_private.np_ringkas(ca.id, p_publik)', 1, 'isi np');
    src := pg_temp.ganti(src, $p$             'variant', jsonb_build_array(
               jsonb_build_object('laporan', 'ZSQ04', 'nama', coalesce(ca.variant_zsq04, ''), 'deskripsi', coalesce(ca.variant_zsq04_desc, '')),
               jsonb_build_object('laporan', 'ZSOD', 'nama', coalesce(ca.variant_zsod, ''), 'deskripsi', coalesce(ca.variant_zsod_desc, '')),
               jsonb_build_object('laporan', 'MCSI', 'nama', coalesce(ca.variant_mcsi, ''), 'deskripsi', coalesce(ca.variant_mcsi_desc, ''))),$p$,
      $p$             -- 20261163470000: hanya T-code yang terisi; beberapa variant per T-code.
             'variant', rc_private.variant_daftar(ca.variant_zsq04, ca.variant_zsq04_desc, ca.variant_zsod, ca.variant_zsod_desc,
                                                  ca.variant_mcsi, ca.variant_mcsi_desc),$p$, 1, 'isi variant');
    src := pg_temp.ganti(src, $p$'memoPath', coalesce(ca.memo_path, ''),$p$,
      $p$'memoPath', case when p_publik then '' else coalesce(ca.memo_path, '') end, 'adaMemo', coalesce(ca.memo_path, '') <> '',$p$, 1, 'isi memo');
    execute src;
  end if;
end $isi$;
revoke all on function rc_private.timetable_campaigns_isi(boolean) from public, anon, authenticated;

create or replace function public.rc_timetable_campaigns()
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to ''
as $function$
begin
  perform rc_private.require_tab('timetable.campaign');
  return rc_private.timetable_campaigns_isi(false); -- 20261163470000
end $function$;

create or replace function public.rc_publik_timetable_campaigns()
 returns jsonb
 language sql
 stable security definer
 set search_path to ''
as $function$
  -- Halaman /details-campaign (tanpa login), 20261163470000. Badan kueri sama dengan portal.
  select rc_private.timetable_campaigns_isi(true);
$function$;
revoke all on function public.rc_publik_timetable_campaigns() from public;
grant execute on function public.rc_publik_timetable_campaigns() to anon, authenticated;
