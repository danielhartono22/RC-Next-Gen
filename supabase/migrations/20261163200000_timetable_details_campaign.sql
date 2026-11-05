-- ==========================================================================================
-- Timetable: tab "Details Campaign" + Variant ZSQ04 / ZSOD / MCSI pada Campaign Master
-- ==========================================================================================
-- Pemilik, 19 Oktober 2026: "di timetable tambahkan 1 tab lagi selain yang saat ini, yakni tab
-- 'Details Campaign', sementara tab yang sekarang namakan aja 'Report'. Details Campaign ini
-- memunculkan: code campaign, nama campaign, periode start dan end SO, periode start dan end
-- billing, Variant ZSQ04, ZSOD, MCSI, PDF untuk memo - dan kesemuanya diambil dari master
-- campaign di key master, sementara untuk variant bisa diisi field-nya di campaign master agar
-- synchronized."
--
-- Revisi pemilik (19 Oktober 2026, sesudah melihat hasilnya):
--   "tampilan pertama: code campaign, nama campaign, status, periode start (so start), periode
--   end (billing end), memo dalam pdf. Ketika di klik baru muncul details-nya hingga variant.
--   Variant ada 2 kolom yakni Variant Name dan Description. Tampilkan semua campaign bahkan yang
--   ga berlaku di daerah tersebut, tapi tandai merah ketika ga berlaku di depo tersebut; ketika
--   di klik, details-nya juga memunculkan berlaku di region atau exclude region berapa."
--   Lalu: "tambah 1 lagi jenis cb dan status pajak keluarkan saja" - tampilan pertama juga memuat
--   Jenis CB dan Status Pajak (dibaca dengan penafsiran status pajak yang sama di seluruh layar).
--
-- KEPUTUSAN
--  * Enam kolom baru di campaigns: Variant Name dan Description untuk ZSQ04, ZSOD, dan MCSI
--    (variant_zsq04 / variant_zsq04_desc, dst.; teks bebas, maks 200 karakter seperti kolom
--    teks Campaign Master lainnya). Diisi lewat Key Master > Campaign Master (formulir Ubah dan
--    template unggah); Details Campaign hanya membaca.
--  * "Berlaku di depot / region" memakai aturan Not Participating Campaign Master yang sudah ada
--    (campaign_not_participating, rc_private.np_pasangan): campaign tidak berlaku di depot yang
--    ditandai langsung atau yang region-nya ditandai. Exclude Campaign di Access Management
--    (excluded_campaigns) adalah pengecualian dari seluruh laporan; ikut ditampilkan sebagai
--    keterangan.
--  * Tab baru timetable.campaign terbuka bagi setiap akun (lihat tambalan tab_rights di bawah);
--    tab lama timetable.matrix berganti judul menjadi "Report" dan tetap mengikuti izin modulnya.
--  * Details Campaign memuat seluruh campaign yang tidak diarsip, langsung dari campaigns -
--    tidak ada salinan, jadi perubahan di Campaign Master langsung terlihat.
--  * Memo dibuka lewat tautan bertanda tangan bucket campaign-memo; kebijakan baca bucket itu
--    sudah terbuka bagi setiap akun aktif (campaign_memo_baca).
--
-- Tambalan memakai penjaga MD5 pra-citra; campaign_upsert dan rc_campaign_list sama di dev dan prod
-- (19 Oktober 2026). Tambalan tab_rights memerlukan 20261163180000 lebih dulu (lihat bagian 4). Tambalannya bertahap:
-- tahap A (variant name) lalu tahap B (description), supaya dev yang sudah memuat versi awal
-- migrasi ini ikut terbarui.
-- ==========================================================================================

create or replace function pg_temp.ganti(p_src text, p_lama text, p_baru text, p_n integer, p_nama text)
returns text language plpgsql as $f$
declare n integer := (length(p_src) - length(replace(p_src, p_lama, ''))) / greatest(length(p_lama), 1);
begin
  if n <> p_n then raise exception '%: pola ditemukan % kali, diharapkan %: %', p_nama, n, p_n, left(p_lama, 120); end if;
  return replace(p_src, p_lama, p_baru);
end $f$;

-- ------------------------------------------------------------------------------------------
-- 1. Kolom variant (name + description)
-- ------------------------------------------------------------------------------------------
alter table public.campaigns add column if not exists variant_zsq04 text;
alter table public.campaigns add column if not exists variant_zsod text;
alter table public.campaigns add column if not exists variant_mcsi text;
alter table public.campaigns add column if not exists variant_zsq04_desc text;
alter table public.campaigns add column if not exists variant_zsod_desc text;
alter table public.campaigns add column if not exists variant_mcsi_desc text;
alter table public.campaigns drop constraint if exists campaigns_variant_panjang;
alter table public.campaigns add constraint campaigns_variant_panjang
  check (coalesce(length(variant_zsq04), 0) <= 200 and coalesce(length(variant_zsod), 0) <= 200 and coalesce(length(variant_mcsi), 0) <= 200
     and coalesce(length(variant_zsq04_desc), 0) <= 200 and coalesce(length(variant_zsod_desc), 0) <= 200 and coalesce(length(variant_mcsi_desc), 0) <= 200);

-- ------------------------------------------------------------------------------------------
-- 2. Tambalan Campaign Master: simpan (formulir + unggah) dan daftar membawa variant
-- ------------------------------------------------------------------------------------------
do $tambal$
declare src text; f record;
begin
  for f in select * from (values
    ('rc_private.campaign_upsert(jsonb)', '107366bee061d4148aee264dec43622f'),
    ('public.rc_campaign_list(text,integer,integer)', '2611af1453feb66dda1738ba2464971a')) x(sig, harapan)
  loop
    src := replace(pg_get_functiondef(f.sig::regprocedure), E'\r', '');
    if src ~ 'variant_mcsi_desc' then raise notice '% sudah ditambal.', f.sig; continue; end if;

    -- Tahap A: Variant Name (versi awal migrasi ini). Dilewati bila sudah ada (dev).
    if src !~ '20261163200000' then
      if md5(src) <> f.harapan then raise exception 'DITOLAK: % berbeda dari yang diukur (md5 %).', f.sig, md5(src); end if;
      if f.sig = 'rc_private.campaign_upsert(jsonb)' then
        -- Kolom variant hanya disentuh bila dikirim: unggahan dengan template lama (tanpa kolom
        -- variant) tidak mengosongkan variant yang sudah terisi. Kosong yang dikirim = dikosongkan.
        src := pg_temp.ganti(src, $p$               'soStart','soEnd','billingStart','billingEnd')
   then raise exception 'Kolom tidak dikenali: %',k; end if;$p$,
          $p$               'soStart','soEnd','billingStart','billingEnd',
               'variantZsq04','variantZsod','variantMcsi' /* 20261163200000 */)
   then raise exception 'Kolom tidak dikenali: %',k; end if;$p$, 1, 'upsert kolom');
        src := pg_temp.ganti(src, $p$    billing_end=case when (r ? 'billingEnd') or (r ? 'soEnd') then v_bi_b else billing_end end
   where campaign_code=code;$p$,
          $p$    billing_end=case when (r ? 'billingEnd') or (r ? 'soEnd') then v_bi_b else billing_end end,
    -- 20261163200000: Variant ZSQ04 / ZSOD / MCSI
    variant_zsq04=case when r ? 'variantZsq04' then nullif(btrim(r->>'variantZsq04'),'') else variant_zsq04 end,
    variant_zsod=case when r ? 'variantZsod' then nullif(btrim(r->>'variantZsod'),'') else variant_zsod end,
    variant_mcsi=case when r ? 'variantMcsi' then nullif(btrim(r->>'variantMcsi'),'') else variant_mcsi end
   where campaign_code=code;$p$, 1, 'upsert ubah');
        src := pg_temp.ganti(src, $p$     so_start,so_end,billing_start,billing_end)
   values($p$,
          $p$     so_start,so_end,billing_start,billing_end,variant_zsq04,variant_zsod,variant_mcsi)
   values($p$, 1, 'upsert kolom baru');
        src := pg_temp.ganti(src, $p$     v_so_a,v_so_b,v_bi_a,v_bi_b);$p$,
          $p$     v_so_a,v_so_b,v_bi_a,v_bi_b,
     nullif(btrim(coalesce(r->>'variantZsq04','')),''),nullif(btrim(coalesce(r->>'variantZsod','')),''),
     nullif(btrim(coalesce(r->>'variantMcsi','')),''));$p$, 1, 'upsert nilai baru');
      else
        src := pg_temp.ganti(src, $p$   'memoSize',coalesce(ca.memo_size,0),$p$,
          $p$   'memoSize',coalesce(ca.memo_size,0),
   -- 20261163200000: Variant ZSQ04 / ZSOD / MCSI
   'variantZsq04',coalesce(ca.variant_zsq04,''),'variantZsod',coalesce(ca.variant_zsod,''),'variantMcsi',coalesce(ca.variant_mcsi,''),$p$, 1, 'list');
      end if;
    end if;

    -- Tahap B: Description tiap variant (revisi pemilik).
    if f.sig = 'rc_private.campaign_upsert(jsonb)' then
      src := pg_temp.ganti(src, $p$'variantZsq04','variantZsod','variantMcsi' /* 20261163200000 */)$p$,
        $p$'variantZsq04','variantZsod','variantMcsi',
               'variantZsq04Desc','variantZsodDesc','variantMcsiDesc' /* 20261163200000 */)$p$, 1, 'upsert kolom desc');
      src := pg_temp.ganti(src, $p$    variant_mcsi=case when r ? 'variantMcsi' then nullif(btrim(r->>'variantMcsi'),'') else variant_mcsi end
   where campaign_code=code;$p$,
        $p$    variant_mcsi=case when r ? 'variantMcsi' then nullif(btrim(r->>'variantMcsi'),'') else variant_mcsi end,
    variant_zsq04_desc=case when r ? 'variantZsq04Desc' then nullif(btrim(r->>'variantZsq04Desc'),'') else variant_zsq04_desc end,
    variant_zsod_desc=case when r ? 'variantZsodDesc' then nullif(btrim(r->>'variantZsodDesc'),'') else variant_zsod_desc end,
    variant_mcsi_desc=case when r ? 'variantMcsiDesc' then nullif(btrim(r->>'variantMcsiDesc'),'') else variant_mcsi_desc end
   where campaign_code=code;$p$, 1, 'upsert ubah desc');
      src := pg_temp.ganti(src, $p$billing_end,variant_zsq04,variant_zsod,variant_mcsi)$p$,
        $p$billing_end,variant_zsq04,variant_zsod,variant_mcsi,variant_zsq04_desc,variant_zsod_desc,variant_mcsi_desc)$p$, 1, 'upsert kolom baru desc');
      src := pg_temp.ganti(src, $p$     nullif(btrim(coalesce(r->>'variantMcsi','')),''));$p$,
        $p$     nullif(btrim(coalesce(r->>'variantMcsi','')),''),
     nullif(btrim(coalesce(r->>'variantZsq04Desc','')),''),nullif(btrim(coalesce(r->>'variantZsodDesc','')),''),
     nullif(btrim(coalesce(r->>'variantMcsiDesc','')),''));$p$, 1, 'upsert nilai baru desc');
    else
      src := pg_temp.ganti(src, $p$'variantMcsi',coalesce(ca.variant_mcsi,''),$p$,
        $p$'variantMcsi',coalesce(ca.variant_mcsi,''),
   'variantZsq04Desc',coalesce(ca.variant_zsq04_desc,''),'variantZsodDesc',coalesce(ca.variant_zsod_desc,''),'variantMcsiDesc',coalesce(ca.variant_mcsi_desc,''),$p$, 1, 'list desc');
    end if;
    execute src;
  end loop;
end $tambal$;

-- ------------------------------------------------------------------------------------------
-- 3. RPC Details Campaign
-- ------------------------------------------------------------------------------------------
-- Satu kali muat: seluruh campaign (tidak diarsip) + keberlakuannya per depot dalam jangkauan
-- pemanggil, daftar region, dan depot jangkauan (untuk pilihan "Berlaku di depot" di layar).
-- Catatan di detail ditulis untuk akun yang login (pemilik, 19 Oktober 2026): depot asalnya
-- (profiles.home_depot_id) dan, bila ada, depot Resource Partner-nya (user_depot_grants kind rp).
create or replace function public.rc_timetable_campaigns() returns jsonb
language plpgsql stable security definer set search_path = '' as $f$
declare v_rumah uuid; v_rp uuid[];
begin
  perform rc_private.require_tab('timetable.campaign');
  select p.home_depot_id into v_rumah from public.profiles p where p.id = auth.uid();
  v_rp := array(select g.depot_id from public.user_depot_grants g join public.depots d on d.id = g.depot_id
                 where g.user_id = auth.uid() and g.kind = 'rp' and d.archived_at is null and g.depot_id is distinct from v_rumah);
  return jsonb_build_object('status', 'success',
    'depotSaya', coalesce((select d.depot_code from public.depots d where d.id = v_rumah), ''),
    'depotRp', coalesce((select jsonb_agg(d.depot_code order by d.depot_code) from public.depots d where d.id = any(v_rp)), '[]'::jsonb),
    'regions', coalesce((select jsonb_agg(r order by r) from (select distinct upper(btrim(d.region)) r from public.depots d
                 where d.archived_at is null and btrim(coalesce(d.region, '')) <> '') x), '[]'::jsonb),
    'depots', coalesce((select jsonb_agg(jsonb_build_object('kode', d.depot_code, 'nama', coalesce(nullif(d.depot_name, ''), d.depot_code),
                 'region', coalesce(upper(btrim(d.region)), '')) order by d.depot_code)
               from public.depots d cross join rc_private.lingkup_depot_saya() l
              where d.archived_at is null and (l.semua or d.id = any(l.depot) or d.id = v_rumah or d.id = any(v_rp))), '[]'::jsonb),
    'rows', coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', ca.id, 'kode', ca.campaign_code, 'nama', coalesce(ca.campaign_name, ''), 'status', coalesce(ca.status, 'active'),
             'jenisCb', rc_private.cb_label(ca.cashback_type), 'statusPajak', coalesce(ca.tax_status, ''),
             'soStart', coalesce(to_char(ca.so_start, 'DD-Mon-YYYY'), ''), 'soEnd', coalesce(to_char(ca.so_end, 'DD-Mon-YYYY'), ''),
             'billingStart', coalesce(to_char(ca.billing_start, 'DD-Mon-YYYY'), ''), 'billingEnd', coalesce(to_char(ca.billing_end, 'DD-Mon-YYYY'), ''),
             -- Tanggal ISO untuk pengurutan dan penyaring tahun di layar.
             'soStartIso', coalesce(to_char(ca.so_start, 'YYYY-MM-DD'), ''), 'soEndIso', coalesce(to_char(ca.so_end, 'YYYY-MM-DD'), ''),
             'billingStartIso', coalesce(to_char(ca.billing_start, 'YYYY-MM-DD'), ''), 'billingEndIso', coalesce(to_char(ca.billing_end, 'YYYY-MM-DD'), ''),
             'variant', jsonb_build_array(
               jsonb_build_object('laporan', 'ZSQ04', 'nama', coalesce(ca.variant_zsq04, ''), 'deskripsi', coalesce(ca.variant_zsq04_desc, '')),
               jsonb_build_object('laporan', 'ZSOD', 'nama', coalesce(ca.variant_zsod, ''), 'deskripsi', coalesce(ca.variant_zsod_desc, '')),
               jsonb_build_object('laporan', 'MCSI', 'nama', coalesce(ca.variant_mcsi, ''), 'deskripsi', coalesce(ca.variant_mcsi_desc, ''))),
             'memoPath', coalesce(ca.memo_path, ''), 'memoName', coalesce(ca.memo_name, ''), 'memoSize', coalesce(ca.memo_size, 0),
             -- Depot dalam jangkauan yang TIDAK berlaku (Not Participating langsung atau lewat region).
             'tidakBerlakuDepot', coalesce((select jsonb_agg(d.depot_code order by d.depot_code)
                 from public.depots d cross join rc_private.lingkup_depot_saya() l
                where d.archived_at is null and (l.semua or d.id = any(l.depot) or d.id = v_rumah or d.id = any(v_rp))
                  and rc_private.np_pasangan(d.id, ca.id)), '[]'::jsonb),
             'dikecualikan', ex.campaign_id is not null, 'alasanDikecualikan', coalesce(ex.reason, ''))
             || rc_private.np_ringkas(ca.id)
             order by ca.so_start desc nulls last, ca.campaign_code)
      from public.campaigns ca
      left join public.excluded_campaigns ex on ex.campaign_id = ca.id
     where ca.archived_at is null), '[]'::jsonb));
end $f$;
revoke all on function public.rc_timetable_campaigns() from public, anon;
grant execute on function public.rc_timetable_campaigns() to authenticated;

-- ------------------------------------------------------------------------------------------
-- 4. Katalog tab: Report (lama) dan Details Campaign (baru)
-- ------------------------------------------------------------------------------------------
update rc_private.tab_catalog set title = 'Report' where code = 'timetable.matrix' and title <> 'Report';
insert into rc_private.tab_catalog(code, module, tab, permission, title, label, key)
select 'timetable.campaign', t.module, 'campaign', t.permission, 'Details Campaign', t.label, t.key
  from rc_private.tab_catalog t where t.code = 'timetable.matrix'
   and not exists(select 1 from rc_private.tab_catalog where code = 'timetable.campaign');

-- Pemilik, 19 Oktober 2026 (sebelum transport ke prod): "default-nya langsung akses ke semua
-- user" - tab Details Campaign terbuka bagi setiap akun walau tidak memegang izin modul Timetable
-- (manage_timetable). Tab Report tetap mengikuti izin modulnya. Centang yang sengaja dimatikan di
-- Access Management tetap dihormati (user_tab_access).
-- Pra-citra tab_rights: prod sesudah 20261163180000 (afd80f5c) dan dev sesudah 20261163170000 -
-- 20261163190000 + 20261163180000 versi akhir (40743c02).
do $tambal_tab$
declare src text;
begin
  src := replace(pg_get_functiondef('rc_private.tab_rights(uuid)'::regprocedure), E'\r', '');
  if src ~ 'Details Campaign untuk semua akun' then raise notice 'tab_rights sudah ditambal.';
  else
    if md5(src) not in ('afd80f5c48ae958e672475983fd67218', '40743c0226b90b2b40f2ceb90adf959c') then
      raise exception 'DITOLAK: tab_rights berbeda dari yang diukur (md5 %). Terapkan 20261163180000 lebih dulu.', md5(src); end if;
    src := pg_temp.ganti(src, $p$((t.permission is null or p.role in('depot head','management')$p$,
      $p$((t.permission is null or t.code='timetable.campaign' /* 20261163200000: Details Campaign untuk semua akun */ or p.role in('depot head','management')$p$, 1, 'tab_rights timetable.campaign');
    execute src;
  end if;
end $tambal_tab$;

-- ------------------------------------------------------------------------------------------
-- 5. Pemeriksaan diri
-- ------------------------------------------------------------------------------------------
do $cek$
declare e text := '';
begin
  if pg_get_functiondef('rc_private.campaign_upsert(jsonb)'::regprocedure) !~ 'variant_mcsi_desc=case' then e := e || ' upsert;'; end if;
  if pg_get_functiondef('public.rc_campaign_list(text,integer,integer)'::regprocedure) !~ 'variantMcsiDesc' then e := e || ' list;'; end if;
  if (select title from rc_private.tab_catalog where code = 'timetable.matrix') <> 'Report' then e := e || ' judul Report;'; end if;
  if pg_get_functiondef('rc_private.tab_rights(uuid)'::regprocedure) !~ 'Details Campaign untuk semua akun' then e := e || ' tab_rights;'; end if;
  if not exists(select 1 from rc_private.tab_catalog c join rc_private.tab_catalog m on m.code = 'timetable.matrix'
                 where c.code = 'timetable.campaign' and c.permission is not distinct from m.permission and c.module = m.module) then
    e := e || ' katalog Details Campaign;'; end if;
  if e <> '' then raise exception 'GAGAL:%', e; end if;
end $cek$;
