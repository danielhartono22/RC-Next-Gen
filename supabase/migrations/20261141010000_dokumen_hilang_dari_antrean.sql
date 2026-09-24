-- ==========================================================================================
-- Dokumen yang hilang dari antrean karena pelanggannya tidak terlihat
-- ==========================================================================================
-- Pemilik melaporkan: "kok ini saya cek release tidak ada doc yang di approve?" Lima dokumen
-- memang sudah berstatus Approved, riwayatnya tercatat, tetapi antrean Release kosong.
--
-- ------------------------------------------------------------------------------------------
-- SEBABNYA, DAN MENGAPA IA LEBIH TUA DARI MODUL APPROVAL
-- ------------------------------------------------------------------------------------------
-- rc_legacy_workflow menyusun barisnya dengan INNER JOIN ke public.customers. Kebijakan RLS
-- customers_scoped hanya menampilkan pelanggan yang punya sedikitnya satu baris pada
-- public.customer_depots. Pelanggan tanpa baris itu tidak terlihat, dan INNER JOIN membuat
-- KLAIMNYA ikut lenyap - bukan tampil tanpa nama, melainkan hilang sama sekali.
--
-- Terukur saat ini: 97 klaim memiliki pelanggan yang tidak tertaut ke depot klaim itu. Jadi ini
-- bukan akibat tahap approval; tahap approval hanya membuatnya terlihat, karena kelima dokumen
-- itu kebetulan yang pertama disetujui.
--
-- ------------------------------------------------------------------------------------------
-- DUA PERBAIKAN, KEDUANYA PERLU
-- ------------------------------------------------------------------------------------------
-- 1. DATANYA. Sebuah klaim adalah bukti bahwa pelanggan itu memang ditangani depot itu -
--    dokumennya ada, nilainya ada, dan seseorang mengunggahnya dari sana. Tautan yang hilang
--    diisi dari klaim yang sudah ada. Ini menambah baris, tidak menghapus apa pun.
--
-- 2. STRUKTURNYA. Tautan yang hilang tidak boleh lagi MENYEMBUNYIKAN dokumen. Join ke
--    customers, campaigns, depots dan claim_sensitive diubah menjadi LEFT JOIN, sehingga master
--    yang belum lengkap menghasilkan kolom kosong - keadaan yang terlihat dan dapat diperbaiki -
--    bukan dokumen yang raib tanpa jejak. Perbaikan pertama saja tidak cukup: ia membereskan
--    hari ini, sementara yang kedua membereskan besok.
--
-- ------------------------------------------------------------------------------------------
-- BULK PROCESS MENGIKUTI TAHAP APPROVAL
-- ------------------------------------------------------------------------------------------
-- Pemilik menegaskan: "release dan bulk ini stage selanjutnya setelah approve yaa sesuai dengan
-- jenis cb nya". Rebate karena itu juga harus melewati persetujuan lebih dulu; antrean Bulk
-- tidak lagi menampilkan dokumen yang masih Submitted.
--
-- Yang SUDAH melewati tahap itu - Approved, Released, Claimed - tetap tampil, supaya dokumen
-- yang terlanjur berjalan sebelum tahap ini ada tidak tertahan di tengah jalan.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

-- ------------------------------------------------------------------------------------------
-- 1. Tautan pelanggan-depot yang hilang, diisi dari klaim yang sudah ada
-- ------------------------------------------------------------------------------------------
do $mig$
declare n int;
begin
  with kurang as (
    select distinct c.customer_id, c.depot_id
      from public.claims c
     where c.customer_id is not null and c.depot_id is not null
       and not exists (select 1 from public.customer_depots cd
                        where cd.customer_id = c.customer_id and cd.depot_id = c.depot_id)
  ), masuk as (
    insert into public.customer_depots(customer_id, depot_id)
    select customer_id, depot_id from kurang
    on conflict do nothing
    returning 1
  )
  select count(*) into n from masuk;
  raise notice 'Tautan pelanggan-depot ditambahkan: %', n;
end
$mig$;

-- ------------------------------------------------------------------------------------------
-- 2. Master yang belum lengkap tidak lagi menyembunyikan dokumen
-- ------------------------------------------------------------------------------------------
do $mig$
declare src text; baru text; i int; n int := 0;
  pola text[][] := array[
    [$q$  join public.depots d on d.id=c.depot_id$q$,
     $q$  left join public.depots d on d.id=c.depot_id$q$],
    [$q$  join public.customers cu on cu.id=c.customer_id$q$,
     $q$  left join public.customers cu on cu.id=c.customer_id$q$],
    [$q$  join public.campaigns ca on ca.id=c.campaign_id$q$,
     $q$  left join public.campaigns ca on ca.id=c.campaign_id$q$]
  ];
begin
  select pg_get_functiondef(p.oid) into src from pg_proc p
    join pg_namespace n2 on n2.oid = p.pronamespace
   where n2.nspname='public' and p.proname='rc_legacy_workflow';
  if src is null then raise exception 'public.rc_legacy_workflow tidak ditemukan.'; end if;

  baru := src;
  for i in 1 .. array_length(pola,1) loop
    if position(pola[i][1] in baru) > 0 then
      baru := replace(baru, pola[i][1], pola[i][2]);
      n := n + 1;
    end if;
  end loop;

  -- Antrean Bulk: Rebate juga melewati approval lebih dulu.
  if position($q$where (v->>'rebate')::boolean));$q$ in baru) > 0 then
    baru := replace(baru, $q$where (v->>'rebate')::boolean));$q$,
      $q$where (v->>'rebate')::boolean and v->>'status' <> 'Submitted'));$q$);
    n := n + 1;
  end if;

  if n = 0 then
    raise notice 'rc_legacy_workflow sudah dalam bentuk yang diinginkan; dilewati.';
  else
    execute baru;
    raise notice 'rc_legacy_workflow diperbarui (% pola).', n;
  end if;
end
$mig$;

-- ------------------------------------------------------------------------------------------
-- Pemeriksaan
-- ------------------------------------------------------------------------------------------
do $periksa$
declare v_uid uuid; r jsonb; n_approved int; n_tanpa_link int; src text;
begin
  select count(*) into n_tanpa_link from public.claims c
   where c.archived_at is null and c.customer_id is not null and c.depot_id is not null
     and not exists (select 1 from public.customer_depots cd
                      where cd.customer_id=c.customer_id and cd.depot_id=c.depot_id);
  if n_tanpa_link > 0 then
    raise exception 'GAGAL: masih ada % klaim tanpa tautan pelanggan-depot.', n_tanpa_link; end if;

  select pg_get_functiondef(p.oid) into src from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='rc_legacy_workflow';
  if position($q$  join public.customers cu$q$ in src) > 0 then
    raise exception 'GAGAL: join ke customers masih INNER, dokumen masih bisa raib.'; end if;

  select count(*) into n_approved from public.claims c
    join public.campaigns ca on ca.id = c.campaign_id
   where c.status='approved' and lower(btrim(coalesce(ca.cashback_type,''))) <> 'rebate';

  select id into v_uid from public.profiles
   where lower(coalesce(role,'')) like '%system%' and coalesce(status,'')='active'
   order by user_code limit 1;

  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_uid::text,'role','authenticated')::text, true);
  r := public.rc_legacy_workflow();
  reset role;

  if jsonb_array_length(r->'releaseData') <> n_approved then
    raise exception 'GAGAL: antrean Release memuat % dokumen, seharusnya %.',
      jsonb_array_length(r->'releaseData'), n_approved;
  end if;

  -- Tidak ada dokumen Submitted yang menyelinap ke Bulk.
  if exists (select 1 from jsonb_array_elements(r->'bulkRebateData') v
              where v->>'status' = 'Submitted') then
    raise exception 'GAGAL: dokumen Submitted masih muncul di antrean Bulk.'; end if;

  raise notice 'Release memuat % dokumen approved; Bulk % dokumen.',
    jsonb_array_length(r->'releaseData'), jsonb_array_length(r->'bulkRebateData');
  raise notice 'Pemeriksaan lolos.';
exception when others then
  reset role; raise;
end
$periksa$;
