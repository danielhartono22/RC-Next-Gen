-- ==========================================================================================
-- Mengurangi data rekayasa dev menjadi 10 ribu klaim
-- ==========================================================================================
-- Diminta pemilik, 30 September 2026: "untuk rc dev datanya kurangin aja jadi 10 ribu".
--
-- CARA MEMILIH. Sampel bertingkat sistematis: klaim diurutkan menurut status, depot, lalu
-- urutan acak yang TERULANG (md5 dari id dan sebuah benih tetap), dan diambil setiap baris
-- ke-k, dengan k = jumlah klaim / 10.000. Hasilnya tepat 10.000 klaim, dan setiap kombinasi
-- status x depot terwakili sebanding dengan porsinya semula (selisih paling banyak satu).
-- Menjalankan ulang dengan data yang sama memilih klaim yang sama.
--
-- YANG IKUT DIHAPUS, mengikuti foreign key dari anak ke induk:
--   claim_status_history, rc_private.claim_sensitive   milik klaim yang tidak terpilih
--   customer_depots, customers                         customer yang tidak lagi dipakai klaim
--                                                      (di data rekayasa: satu customer per klaim)
-- Campaign, depot, pengguna dan pengaturan tidak disentuh.
--
-- HANYA UNTUK DEV. Menolak jalan bila bukan data rekayasa. Bila klaim sudah 10.000 atau
-- kurang, tidak melakukan apa-apa.
--
-- Jalankan: node scripts/apply-sql.mjs --env dev supabase/queries/kurangi-data-dev.sql
-- Sesudahnya: VACUUM (FULL, ANALYZE) pada tabel-tabel di atas, di luar transaksi.
-- ==========================================================================================
do $kurangi$
declare
  v_target constant int := 10000;
  v_total bigint; v_k numeric;
  n_riwayat bigint; n_sensitif bigint; n_klaim bigint; n_cd bigint; n_cust bigint;
begin
  if not exists (select 1 from public.customers where npwp like 'DUMMY-NPWP-%') then
    raise exception 'DITOLAK: ini bukan data rekayasa. Berkas ini hanya untuk dev.';
  end if;

  select count(*) into v_total from public.claims;
  if v_total <= v_target then
    raise notice 'Klaim sudah % (<= %); tidak ada yang dikurangi.', v_total, v_target;
    return;
  end if;
  v_k := v_total::numeric / v_target;

  create temp table _klaim_terpilih(id uuid primary key) on commit drop;
  insert into _klaim_terpilih
  select id from (
    select c.id,
           row_number() over (order by c.status, c.depot_id, md5(c.id::text || 'rc-dev-2026-09-30')) - 1 as urut
      from public.claims c) t
   where floor(urut / v_k) <> floor((urut - 1) / v_k) or urut = 0;

  if (select count(*) from _klaim_terpilih) <> v_target then
    raise exception 'GAGAL: sampel berisi % klaim, bukan %.', (select count(*) from _klaim_terpilih), v_target;
  end if;

  delete from public.claim_status_history h
   where not exists (select 1 from _klaim_terpilih s where s.id = h.claim_id);
  get diagnostics n_riwayat = row_count;

  delete from rc_private.claim_sensitive x
   where not exists (select 1 from _klaim_terpilih s where s.id = x.claim_id);
  get diagnostics n_sensitif = row_count;

  delete from public.claims c
   where not exists (select 1 from _klaim_terpilih s where s.id = c.id);
  get diagnostics n_klaim = row_count;

  delete from public.customer_depots cd
   where not exists (select 1 from public.claims c where c.customer_id = cd.customer_id);
  get diagnostics n_cd = row_count;

  delete from public.customers cu
   where not exists (select 1 from public.claims c where c.customer_id = cu.id);
  get diagnostics n_cust = row_count;

  -- Pemeriksaan keutuhan: tidak ada anak yang kehilangan induknya.
  if exists (select 1 from public.claim_status_history h where not exists (select 1 from public.claims c where c.id = h.claim_id))
     or exists (select 1 from rc_private.claim_sensitive x where not exists (select 1 from public.claims c where c.id = x.claim_id))
     or exists (select 1 from public.claims c where not exists (select 1 from public.customers cu where cu.id = c.customer_id))
     or exists (select 1 from public.customer_depots cd where not exists (select 1 from public.customers cu where cu.id = cd.customer_id)) then
    raise exception 'GAGAL: ada baris yang kehilangan induknya.';
  end if;

  raise notice 'Dihapus: % klaim, % riwayat, % data sensitif, % customer, % customer_depot.',
    n_klaim, n_riwayat, n_sensitif, n_cust, n_cd;
end
$kurangi$;

-- Snapshot dashboard publik dihitung ulang dari data yang baru.
select rc_private.segarkan_dashboard_publik();

select 'klaim' as apa, count(*)::text as nilai from public.claims
union all select 'customer', count(*)::text from public.customers
union all select 'campaign', count(*)::text from public.campaigns
union all select 'depot dipakai klaim', count(distinct depot_id)::text from public.claims
union all select 'riwayat status', count(*)::text from public.claim_status_history
union all select 'data sensitif', count(*)::text from rc_private.claim_sensitive
union all select 'status', string_agg(status || '=' || n || ' (' || round(100.0*n/tot,1) || '%)', ', ' order by n desc)
  from (select status, count(*) n, sum(count(*)) over () tot from public.claims group by status) t
union all select 'menunggu approval', count(*)::text from public.claims where pending_approval is not null
union all select 'klaim per depot (min-maks)', min(n)::text || ' - ' || max(n)::text
  from (select depot_id, count(*) n from public.claims group by depot_id) d;
