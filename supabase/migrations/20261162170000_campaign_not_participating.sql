-- ==========================================================================================
-- Campaign Master: Not Participating per depot atau per region
-- ==========================================================================================
-- Diminta pemilik, 9 Oktober 2026:
--   "di master campaign tambahkan exclude depot / not participating depot / region. artinya
--    ketika ditagging not participating di depot atau region nya maka seluruh depot dalam 1
--    region yang di NP atau per depot yg di NP tidak bisa upload di document center dan
--    dianggap cleared / done seperti N/A."
--
-- MODEL
--   public.campaign_not_participating: satu baris = satu campaign x (satu depot ATAU satu
--   region). Region disimpan sebagai teks dan dicocokkan dengan depots.region saat dibaca,
--   sehingga depot yang kemudian dipindah region ikut mengikuti tanda regionnya yang baru.
--   rc_private.np_pasangan(depot, campaign) menjawab apakah sebuah pasangan Not Participating.
--
-- EFEKNYA
--   1. Document Center > Compile: baris untuk pasangan NP ditolak per baris di pratinjau dan
--      saat compile, dengan alasan yang terbaca. Trigger pada claims menjaga jalur lain
--      (mis. pemanggilan RPC langsung).
--   2. Timetable dan People Performance: pasangan NP tanpa dokumen hidup dihitung persis seperti
--      Not Achieved (N/A) - cleared, tidak masuk Not Yet. Di matriks, selnya bertanda "NP"
--      supaya dibedakan dari tanda Not Achieved yang dipasang lewat Timetable.
--   3. Dokumen yang SUDAH ada untuk pasangan itu tidak diubah - data nyata selalu mengalahkan
--      penanda, sama seperti Not Achieved.
--
-- HAK: tab Key Master > Campaign beserta izin Key Master. Yurisdiksi tetap: depot hanya yang
-- terjangkau (can_access); region hanya bila SELURUH depot aktif di region itu terjangkau.
-- Tanda di luar jangkauan seseorang tidak terlihat namanya dan tidak ikut terhapus olehnya.
--
-- Ditambal dengan penjaga MD5 pra-citra (akhir baris dinormalkan), sama di dev dan prod pada
-- 9 Oktober 2026. Aman dijalankan berulang.
-- ==========================================================================================

-- ------------------------------------------------------------------------------------------
-- 1. Tabel
-- ------------------------------------------------------------------------------------------
create table if not exists public.campaign_not_participating (
  id          uuid primary key default gen_random_uuid(),
  campaign_id uuid not null references public.campaigns(id) on delete cascade,
  depot_id    uuid references public.depots(id) on delete cascade,
  region      text,
  catatan     text,
  dibuat_oleh uuid references public.profiles(id),
  dibuat_pada timestamptz not null default now(),
  constraint campaign_np_depot_atau_region check ((depot_id is null) <> (nullif(btrim(coalesce(region,'')),'') is null))
);
create unique index if not exists campaign_np_depot_uq on public.campaign_not_participating(campaign_id, depot_id) where depot_id is not null;
create unique index if not exists campaign_np_region_uq on public.campaign_not_participating(campaign_id, upper(btrim(region))) where region is not null;
alter table public.campaign_not_participating enable row level security;
revoke all on public.campaign_not_participating from anon, authenticated;

-- ------------------------------------------------------------------------------------------
-- 2. Pembantu
-- ------------------------------------------------------------------------------------------
create or replace function rc_private.np_pasangan(p_depot uuid, p_campaign uuid)
returns boolean language sql stable security definer set search_path = '' as $fn$
  select exists(select 1 from public.campaign_not_participating n
                 where n.campaign_id = p_campaign and n.depot_id = p_depot)
      or exists(select 1 from public.campaign_not_participating n
                  join public.depots d on d.id = p_depot
                 where n.campaign_id = p_campaign and n.region is not null
                   and btrim(coalesce(d.region,'')) <> ''
                   and upper(btrim(n.region)) = upper(btrim(d.region)));
$fn$;
revoke all on function rc_private.np_pasangan(uuid, uuid) from public, anon;
grant execute on function rc_private.np_pasangan(uuid, uuid) to authenticated;

-- Region boleh diatur bila seluruh depot aktif di region itu terjangkau (System Manager selalu).
create or replace function rc_private.region_terjangkau(p_region text)
returns boolean language sql stable security definer set search_path = '' as $fn$
  select rc_private.is_system_manager() or (
    exists(select 1 from public.depots d where d.archived_at is null and upper(btrim(coalesce(d.region,''))) = upper(btrim(p_region)))
    and not exists(select 1 from public.depots d where d.archived_at is null
                    and upper(btrim(coalesce(d.region,''))) = upper(btrim(p_region)) and not rc_private.can_access(d.id)));
$fn$;
revoke all on function rc_private.region_terjangkau(text) from public, anon;
grant execute on function rc_private.region_terjangkau(text) to authenticated;

-- Ringkasan NP sebuah campaign untuk daftar Campaign Master. SECURITY DEFINER karena
-- rc_campaign_list berjalan dengan hak pemanggil, sedangkan tabelnya tertutup bagi pengguna;
-- depot di luar penglihatan pemanggil hanya dihitung, tidak disebut namanya.
create or replace function rc_private.np_ringkas(p_campaign uuid)
returns jsonb language sql stable security definer set search_path = '' as $fn$
  select jsonb_build_object(
    'npRegion', coalesce((select jsonb_agg(n.region order by n.region) from public.campaign_not_participating n
                           where n.campaign_id = p_campaign and n.region is not null), '[]'::jsonb),
    'npDepot', coalesce((select jsonb_agg(d.depot_code order by d.depot_code) from public.campaign_not_participating n
                           join public.depots d on d.id = n.depot_id
                          where n.campaign_id = p_campaign and rc_private.can_view(d.id)), '[]'::jsonb),
    'npDepotLain', (select count(*) from public.campaign_not_participating n
                     where n.campaign_id = p_campaign and n.depot_id is not null and not rc_private.can_view(n.depot_id)));
$fn$;
revoke all on function rc_private.np_ringkas(uuid) from public, anon;
grant execute on function rc_private.np_ringkas(uuid) to authenticated;

-- ------------------------------------------------------------------------------------------
-- 3. Penjaga pada claims: dokumen baru untuk pasangan NP ditolak dari jalur mana pun.
-- ------------------------------------------------------------------------------------------
create or replace function rc_private.jaga_not_participating()
returns trigger language plpgsql security definer set search_path = '' as $fn$
declare kode_d text; kode_c text;
begin
  if rc_private.np_pasangan(new.depot_id, new.campaign_id) then
    select d.depot_code, c.campaign_code into kode_d, kode_c
      from public.depots d, public.campaigns c where d.id = new.depot_id and c.id = new.campaign_id;
    raise exception 'Depot % tidak berpartisipasi (Not Participating) pada campaign %; dokumen tidak dapat di-compile.',
      kode_d, kode_c using errcode = 'P0001';
  end if;
  return new;
end
$fn$;
drop trigger if exists jaga_not_participating on public.claims;
create trigger jaga_not_participating before insert on public.claims
  for each row execute function rc_private.jaga_not_participating();

-- ------------------------------------------------------------------------------------------
-- 4. RPC untuk Key Master > Campaign
-- ------------------------------------------------------------------------------------------
create or replace function public.rc_campaign_np(p_campaign text)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare ca public.campaigns;
begin
  perform rc_private.require_tab('keyMaster.campaign');
  if not rc_private.can_access(null, 'manage_key_master') then
    raise exception 'Anda belum diberi akses Key Master' using errcode = '42501'; end if;
  select * into ca from public.campaigns where campaign_code = btrim(coalesce(p_campaign,''));
  if not found then raise exception 'Campaign "%" tidak ditemukan', p_campaign; end if;

  return jsonb_build_object('status','success','kode',ca.campaign_code,'nama',ca.campaign_name,
    -- Region: hanya yang depotnya terlihat; boleh diubah bila seluruh depotnya terjangkau.
    'regions', coalesce((select jsonb_agg(jsonb_build_object('region', r.region, 'jumlahDepot', r.n,
          'np', exists(select 1 from public.campaign_not_participating n where n.campaign_id = ca.id
                        and upper(btrim(n.region)) = r.region),
          'bolehUbah', rc_private.region_terjangkau(r.region)) order by r.region)
        from (select upper(btrim(d.region)) region, count(*) n from public.depots d
               where d.archived_at is null and btrim(coalesce(d.region,'')) <> '' and rc_private.can_view(d.id)
               group by 1) r), '[]'::jsonb),
    'depots', coalesce((select jsonb_agg(jsonb_build_object('kode', d.depot_code, 'nama', d.depot_name,
          'region', coalesce(d.region,''),
          'np', exists(select 1 from public.campaign_not_participating n where n.campaign_id = ca.id and n.depot_id = d.id),
          'npLewatRegion', exists(select 1 from public.campaign_not_participating n where n.campaign_id = ca.id
                        and n.region is not null and upper(btrim(n.region)) = upper(btrim(coalesce(d.region,'')))),
          'bolehUbah', rc_private.can_access(d.id)) order by d.depot_code)
        from public.depots d where d.archived_at is null and rc_private.can_view(d.id)), '[]'::jsonb),
    -- Tanda yang tidak terlihat oleh akun ini: hanya jumlahnya, tanpa nama.
    'tandaLain', (select count(*) from public.campaign_not_participating n
                   left join public.depots d on d.id = n.depot_id
                  where n.campaign_id = ca.id
                    and ((n.depot_id is not null and not rc_private.can_view(n.depot_id))
                      or (n.region is not null and not exists(select 1 from public.depots x where x.archived_at is null
                            and upper(btrim(coalesce(x.region,''))) = upper(btrim(n.region)) and rc_private.can_view(x.id))))),
    'dokumenAda', (select count(*) from public.claims c where c.campaign_id = ca.id and c.archived_at is null
                    and c.status <> 'expired' and rc_private.np_pasangan(c.depot_id, ca.id)));
end
$fn$;
revoke all on function public.rc_campaign_np(text) from public, anon;
grant execute on function public.rc_campaign_np(text) to authenticated;

-- Menetapkan daftar NP sebuah campaign. Yang dikirim adalah keadaan AKHIR untuk depot/region
-- dalam jangkauan pemanggil; tanda di luar jangkauannya tidak disentuh.
create or replace function public.rc_campaign_np_simpan(p_campaign text, p_depots jsonb, p_regions jsonb, p_catatan text default '')
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare ca public.campaigns; v_kode text; v_id uuid; n_dep int; n_reg int; n_doc int; v_tambah int := 0; v_buang int := 0; n int;
begin
  perform rc_private.require_tab('keyMaster.campaign');
  if not rc_private.can_access(null, 'manage_key_master') then
    raise exception 'Anda belum diberi akses Key Master' using errcode = '42501'; end if;
  if jsonb_typeof(coalesce(p_depots,'[]')) <> 'array' or jsonb_typeof(coalesce(p_regions,'[]')) <> 'array' then
    raise exception 'Depot dan region harus berupa daftar'; end if;
  select * into ca from public.campaigns where campaign_code = btrim(coalesce(p_campaign,'')) for update;
  if not found then raise exception 'Campaign "%" tidak ditemukan', p_campaign; end if;

  -- Validasi seluruh isian lebih dulu.
  for v_kode in select upper(btrim(value)) from jsonb_array_elements_text(coalesce(p_depots,'[]')) where btrim(value) <> '' loop
    select id into v_id from public.depots where depot_code = v_kode and archived_at is null;
    if v_id is null then raise exception 'Depot % tidak dikenal', v_kode; end if;
    if not rc_private.can_access(v_id) then raise exception 'Depot % di luar jangkauan Anda', v_kode using errcode = '42501'; end if;
  end loop;
  for v_kode in select upper(btrim(value)) from jsonb_array_elements_text(coalesce(p_regions,'[]')) where btrim(value) <> '' loop
    if not exists(select 1 from public.depots where archived_at is null and upper(btrim(coalesce(region,''))) = v_kode) then
      raise exception 'Region % tidak dikenal', v_kode; end if;
    if not rc_private.region_terjangkau(v_kode) then
      raise exception 'Region % memuat depot di luar jangkauan Anda', v_kode using errcode = '42501'; end if;
  end loop;

  -- Depot: buang yang terjangkau tetapi tidak lagi dipilih, tambah yang baru.
  delete from public.campaign_not_participating n
   where n.campaign_id = ca.id and n.depot_id is not null and rc_private.can_access(n.depot_id)
     and n.depot_id not in (select d.id from public.depots d
                             where d.depot_code in (select upper(btrim(value)) from jsonb_array_elements_text(coalesce(p_depots,'[]'))));
  get diagnostics n = row_count; v_buang := v_buang + n;
  insert into public.campaign_not_participating(campaign_id, depot_id, catatan, dibuat_oleh)
  select ca.id, d.id, nullif(left(btrim(coalesce(p_catatan,'')),300),''), (select auth.uid())
    from public.depots d
   where d.depot_code in (select upper(btrim(value)) from jsonb_array_elements_text(coalesce(p_depots,'[]')))
     and d.archived_at is null
  on conflict do nothing;
  get diagnostics n = row_count; v_tambah := v_tambah + n;

  -- Region: sama.
  delete from public.campaign_not_participating n
   where n.campaign_id = ca.id and n.region is not null and rc_private.region_terjangkau(n.region)
     and upper(btrim(n.region)) not in (select upper(btrim(value)) from jsonb_array_elements_text(coalesce(p_regions,'[]')));
  get diagnostics n = row_count; v_buang := v_buang + n;
  insert into public.campaign_not_participating(campaign_id, region, catatan, dibuat_oleh)
  select ca.id, r, nullif(left(btrim(coalesce(p_catatan,'')),300),''), (select auth.uid())
    from (select distinct upper(btrim(value)) r from jsonb_array_elements_text(coalesce(p_regions,'[]')) where btrim(value) <> '') x
  on conflict do nothing;
  get diagnostics n = row_count; v_tambah := v_tambah + n;

  select count(*) filter (where depot_id is not null), count(*) filter (where region is not null)
    into n_dep, n_reg from public.campaign_not_participating where campaign_id = ca.id;
  select count(*) into n_doc from public.claims c where c.campaign_id = ca.id and c.archived_at is null
     and c.status <> 'expired' and rc_private.np_pasangan(c.depot_id, ca.id);

  insert into public.activity_logs(actor_id, event_type, details)
  values ((select auth.uid()), 'campaign_np_diubah', jsonb_build_object('campaign', ca.campaign_code,
    'depot', n_dep, 'region', n_reg, 'ditambah', v_tambah, 'dibuang', v_buang, 'dokumenAda', n_doc,
    'catatan', left(btrim(coalesce(p_catatan,'')),300)));

  return jsonb_build_object('status','success','depot',n_dep,'region',n_reg,'dokumenAda',n_doc,
    'message', 'Not Participating campaign ' || ca.campaign_code || ': ' || n_reg || ' region, ' || n_dep || ' depot.'
      || case when n_doc > 0 then ' ' || n_doc || ' dokumen yang sudah ada tetap diproses seperti biasa; yang diblokir hanya compile baru.' else '' end);
end
$fn$;
revoke all on function public.rc_campaign_np_simpan(text, jsonb, jsonb, text) from public, anon;
grant execute on function public.rc_campaign_np_simpan(text, jsonb, jsonb, text) to authenticated;

-- ------------------------------------------------------------------------------------------
-- 5. Tambalan pada fungsi yang hidup
-- ------------------------------------------------------------------------------------------
do $tambal$
declare f record; r record; src text; baru text; n int;
begin
  create temp table _tambal(urut serial, sig text, harapan text, lama text, ganti text, n int) on commit drop;
  insert into _tambal(sig, harapan, lama, ganti, n) values
  -- Timetable: NP tanpa dokumen hidup = Not Achieved untuk seluruh hitungan; sel bertanda NP.
  ('public.rc_timetable_matrix(jsonb)', '80fc1ddd8b3036dd10c15d9dce9da46d',
   $p$                     where na.depot_id=d.id and na.campaign_id=k.id) then 'Not Achieved'$p$,
   $p$                     where na.depot_id=d.id and na.campaign_id=k.id) then 'Not Achieved'
               -- 20261162170000: Not Participating dari Campaign Master dihitung seperti Not Achieved.
               when coalesce(r.n_hidup,0) = 0 and rc_private.np_pasangan(d.id, k.id) then 'Not Achieved'$p$, 1),
  ('public.rc_timetable_matrix(jsonb)', '80fc1ddd8b3036dd10c15d9dce9da46d',
   $p$             end as status$p$,
   $p$             end as status,
             (coalesce(r.n_hidup,0) = 0 and rc_private.np_pasangan(d.id, k.id)) as np$p$, 1),
  ('public.rc_timetable_matrix(jsonb)', '80fc1ddd8b3036dd10c15d9dce9da46d',
   $p$jsonb_object_agg(campaign_code, status) sel$p$,
   $p$jsonb_object_agg(campaign_code, case when np then 'Not Participating' else status end) sel$p$, 1),

  -- People Performance: sama.
  ('rc_private.people_metrics(uuid[],date)', '8b1ff1eb676e492f44e67fdbb2bf0df8',
   $p$n.marked_at<(p_asof+1)::timestamp at time zone 'Asia/Jakarta') then 'Not Achieved'$p$,
   $p$n.marked_at<(p_asof+1)::timestamp at time zone 'Asia/Jakarta') then 'Not Achieved'
 when coalesce(r.alive,0)=0 and rc_private.np_pasangan(x.depot_id,x.campaign_id) /* 20261162170000 */ then 'Not Achieved'$p$, 1),

  -- Compile: pratinjau dan unggahan menolak baris NP satu per satu, dengan alasan.
  ('public.rc_compile_preview(jsonb)', 'abf96bddb62f8b69c6214fdaca2b7aa4',
   $p$  kunci:=v_code||'|'||v_custcode;$p$,
   $p$  if rc_private.np_pasangan(v_depot.id, v_camp.id) then /* 20261162170000 */
   ditolak:=ditolak||jsonb_build_array(jsonb_build_object('baris',baris,
     'alasan','Depot '||v_depot.depot_code||' Not Participating pada campaign '||v_code||' (Campaign Master)')); continue; end if;
  kunci:=v_code||'|'||v_custcode;$p$, 1),
  ('rc_private.compile_upload(jsonb,uuid)', 'ca3aeca2eb441f3423adc583ea1a1a67',
   $p$  -- Duplikat di dalam file itu sendiri, sebelum menyentuh database.$p$,
   $p$  if rc_private.np_pasangan(v_depot.id, v_camp.id) then /* 20261162170000 */
   ditolak:=ditolak||jsonb_build_array(jsonb_build_object('baris',baris,
     'alasan','Depot '||v_depot.depot_code||' Not Participating pada campaign '||v_code||' (Campaign Master)'));
   continue; end if;

  -- Duplikat di dalam file itu sendiri, sebelum menyentuh database.$p$, 1),

  -- Daftar campaign: ringkasan NP per baris (hanya depot yang terlihat; sisanya jumlah).
  ('public.rc_campaign_list(text,integer,integer)', '642ed04d2421a3811f9852c1a1fdf2a3',
   $p$                  where c.campaign_id=ca.id and c.archived_at is null)) as x$p$,
   $p$                  where c.campaign_id=ca.id and c.archived_at is null)) || rc_private.np_ringkas(ca.id) /* 20261162170000 */ as x$p$, 1);

  for f in select sig, min(harapan) harapan from _tambal group by sig order by min(urut) loop
    src := pg_get_functiondef(to_regprocedure(f.sig));
    if src is null then raise exception 'DITOLAK: fungsi % tidak ada.', f.sig; end if;
    if src ~ '20261162170000' then raise notice '% sudah ditambal.', f.sig; continue; end if;
    if md5(replace(src, E'\r', '')) <> f.harapan then
      raise exception 'DITOLAK: definisi % berbeda dari yang diukur (md5 %).', f.sig, md5(replace(src, E'\r', '')); end if;
    baru := src;
    for r in select * from _tambal where sig = f.sig order by urut loop
      n := (length(baru) - length(replace(baru, r.lama, ''))) / length(r.lama);
      if n <> r.n then
        raise exception '%: pola "%" ditemukan % kali, diharapkan %.', f.sig, left(r.lama, 80), n, r.n; end if;
      baru := replace(baru, r.lama, r.ganti);
    end loop;
    if baru !~ '20261162170000' then raise exception '%: tambalan tidak memuat penanda.', f.sig; end if;
    execute baru;
  end loop;
end
$tambal$;

-- ------------------------------------------------------------------------------------------
-- 6. Pemeriksaan di dalam subtransaksi yang dibatalkan
-- ------------------------------------------------------------------------------------------
do $uji$
declare v_sm uuid; v_ca public.campaigns; v_dep public.depots; v_dep2 public.depots; v_cu uuid;
  h jsonb; hasil jsonb := '{}'; e text := ''; v_galat text;
begin
  select id into v_sm from public.profiles where role='system manager' and status='active' and not must_change_password order by user_code limit 1;
  select * into v_ca from public.campaigns where archived_at is null and status='active' order by campaign_code limit 1;
  select * into v_dep from public.depots where archived_at is null and btrim(coalesce(region,'')) <> '' order by depot_code limit 1;
  select * into v_dep2 from public.depots where archived_at is null and btrim(coalesce(region,'')) <> ''
     and upper(btrim(region)) <> upper(btrim(v_dep.region)) order by depot_code limit 1;
  select id into v_cu from public.customers where archived_at is null order by customer_code limit 1;
  if v_sm is null or v_ca.id is null or v_dep.id is null or v_dep2.id is null or v_cu is null then
    raise notice 'Data uji tidak lengkap; dilewati.'; return; end if;

  begin
    perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);
    -- Tandai depot pertama secara langsung dan region depot kedua.
    h := public.rc_campaign_np_simpan(v_ca.campaign_code, jsonb_build_array(v_dep.depot_code), jsonb_build_array(v_dep2.region), 'uji');
    hasil := hasil || jsonb_build_object('simpan', h->>'status', 'depot', (h->>'depot')::int, 'region', (h->>'region')::int);
    hasil := hasil || jsonb_build_object('npDepot', rc_private.np_pasangan(v_dep.id, v_ca.id),
      'npRegion', rc_private.np_pasangan(v_dep2.id, v_ca.id),
      'jumlahDepotRegion', (select count(*) from public.depots d where d.archived_at is null and upper(btrim(coalesce(d.region,''))) = upper(btrim(v_dep2.region))
                              and rc_private.np_pasangan(d.id, v_ca.id)),
      'daftarNp', (select x->'npRegion' from jsonb_array_elements(public.rc_campaign_list(v_ca.campaign_code, 0, 5)->'rows') x
                    where x->>'codeCampaign' = v_ca.campaign_code));
    -- Sebagai pengguna sungguhan: rc_campaign_list berjalan dengan hak pemanggil, dan tabel NP
    -- tertutup baginya - ringkasannya harus tetap terbaca lewat np_ringkas.
    set local role authenticated;
    h := public.rc_campaign_list(v_ca.campaign_code, 0, 5);
    reset role;
    hasil := hasil || jsonb_build_object('daftarNpPengguna', (select x->'npRegion' from jsonb_array_elements(h->'rows') x
                    where x->>'codeCampaign' = v_ca.campaign_code));
    -- Pratinjau compile menolak barisnya.
    h := public.rc_compile_preview(jsonb_build_array(jsonb_build_object('kodeDepot', v_dep.depot_code,
           'codeCampaign', v_ca.campaign_code, 'custCode', (select customer_code from public.customers where id = v_cu))));
    hasil := hasil || jsonb_build_object('pratinjauDitolak', h->'ditolak'->0->>'alasan');
    -- Trigger menolak dokumen baru.
    begin
      insert into public.claims(no_doc, campaign_id, customer_id, depot_id, status, cb_net)
      values ('UJI-NP-20261162170000', v_ca.id, v_cu, v_dep2.id, 'not_yet', 1);
      v_galat := 'LOLOS';
    exception when others then v_galat := sqlerrm; end;
    hasil := hasil || jsonb_build_object('trigger', v_galat);
    -- Timetable: sel bertanda Not Participating bila belum ada dokumen.
    hasil := hasil || jsonb_build_object('timetable',
      (select d->'sel'->>v_ca.campaign_code from jsonb_array_elements(public.rc_timetable_matrix(jsonb_build_object('campaign', v_ca.campaign_code))->'depots') d
        where d->>'kodeDepot' = v_dep.depot_code));
    -- Membatalkan seluruhnya.
    h := public.rc_campaign_np_simpan(v_ca.campaign_code, '[]'::jsonb, '[]'::jsonb, '');
    hasil := hasil || jsonb_build_object('sesudahDibatalkan', rc_private.np_pasangan(v_dep.id, v_ca.id) or rc_private.np_pasangan(v_dep2.id, v_ca.id));
    raise exception 'UJI_SELESAI';
  exception when raise_exception then reset role; if sqlerrm <> 'UJI_SELESAI' then raise; end if; end;
  perform set_config('request.jwt.claims', '', true);

  if hasil->>'simpan' <> 'success' or (hasil->>'depot')::int <> 1 or (hasil->>'region')::int <> 1 then e := e || ' simpan;'; end if;
  if hasil->'daftarNpPengguna' is distinct from hasil->'daftarNp' or jsonb_array_length(coalesce(hasil->'daftarNp','[]')) <> 1 then
    e := e || ' ringkasan NP di daftar campaign;'; end if;
  if not (hasil->>'npDepot')::boolean or not (hasil->>'npRegion')::boolean or (hasil->>'jumlahDepotRegion')::int < 1 then e := e || ' np_pasangan;'; end if;
  if coalesce(hasil->>'pratinjauDitolak','') !~ 'Not Participating' then e := e || ' pratinjau compile;'; end if;
  if hasil->>'trigger' !~ 'Not Participating' then e := e || ' trigger;'; end if;
  if hasil ? 'timetable' and hasil->>'timetable' is not null and hasil->>'timetable' not in ('Not Participating','Compiled','Completed') then e := e || ' timetable;'; end if;
  if (hasil->>'sesudahDibatalkan')::boolean then e := e || ' pembatalan;'; end if;
  if e <> '' then raise exception 'GAGAL:% Hasil: %', e, hasil; end if;
  if exists(select 1 from public.campaign_not_participating where catatan = 'uji') then raise exception 'GAGAL: uji meninggalkan data.'; end if;
  raise notice 'Not Participating teruji: %', hasil;
end
$uji$;
