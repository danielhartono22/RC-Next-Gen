-- ==========================================================================================
-- Index pencarian (trigram) untuk Document Center dan tab Open, plus kolom unduhan
-- ==========================================================================================
-- Pemilik, 13 Oktober 2026: filter Document Center dan tab Open diterapkan langsung tanpa
-- tombol, penyaringan tetap di server; "ya index pencarian". Juga: unduhan Document Center
-- dengan pilihan kolom seperti tab Open.
--
-- Pencarian teks memakai ILIKE '%kata%' pada No Doc, kode toko dan nama toko. Prod 13 Oktober
-- 2026 (31.906 klaim): 130-650 ms per pencarian, seluruh tabel dipindai karena index btree
-- tidak dapat dipakai untuk '%kata%'. Dengan filter otomatis, pencarian berjalan setiap kali
-- pengguna berhenti mengetik, jadi biaya ini dibayar jauh lebih sering.
--
-- 1. pg_trgm (skema extensions) dan index GIN trigram pada claims.no_doc,
--    claims.source_customer_code, customers.customer_code, customers.customer_name.
-- 2. rc_private.klaim_cocok_cari(kata): id klaim yang cocok, hasilnya SAMA dengan predikat lama
--        no_doc ILIKE x
--        OR coalesce(cu.customer_code, c.source_customer_code) ILIKE x
--        OR coalesce(cu.customer_name, 'Customer Master belum ada') ILIKE x
--    tetapi dipecah per cabang supaya setiap cabang dapat memakai index-nya. Fungsi ini
--    SECURITY INVOKER: RLS pemanggil berlaku persis seperti pada join lama.
-- 3. rc_compilation_list dan rc_open_claims_filtered memakai fungsi itu. rc_compilation_list juga
--    mengirim region, netValue, volume, tglAktual (tanggal transfer/proses aktual clearing),
--    createdOn dan createdBy untuk pilihan kolom dan unduhan.
--
-- Ditambal dengan penjaga MD5 pra-citra (13 Oktober 2026). Harus dipasang SESUDAH
-- 20261163040000 (rc_compilation_list ber-p_depot).
-- ==========================================================================================

create extension if not exists pg_trgm with schema extensions;

create index if not exists claims_no_doc_trgm_idx on public.claims using gin (no_doc extensions.gin_trgm_ops);
create index if not exists claims_source_customer_code_trgm_idx on public.claims using gin (source_customer_code extensions.gin_trgm_ops);
create index if not exists customers_code_trgm_idx on public.customers using gin (customer_code extensions.gin_trgm_ops);
create index if not exists customers_name_trgm_idx on public.customers using gin (customer_name extensions.gin_trgm_ops);

create or replace function rc_private.klaim_cocok_cari(p_cari text)
 returns table(id uuid)
 language sql
 stable
 set search_path to ''
as $function$
  -- 20261163060000: empat cabang, masing-masing dapat memakai index sendiri.
  select k.id from public.claims k
   where k.no_doc ilike '%' || p_cari || '%'
  union
  select k.id from public.customers x join public.claims k on k.customer_id = x.id
   where x.customer_code ilike '%' || p_cari || '%' or x.customer_name ilike '%' || p_cari || '%'
  -- Klaim tanpa Customer Master yang terlihat: kode toko dari sumber, nama "Customer Master belum ada".
  union
  select k.id from public.claims k left join public.customers x on x.id = k.customer_id
   where x.id is null and k.source_customer_code ilike '%' || p_cari || '%'
  union
  select k.id from public.claims k left join public.customers x on x.id = k.customer_id
   where x.id is null and 'Customer Master belum ada' ilike '%' || p_cari || '%';
$function$;
revoke all on function rc_private.klaim_cocok_cari(text) from public, anon;
grant execute on function rc_private.klaim_cocok_cari(text) to authenticated, service_role;

-- ---- rc_compilation_list ------------------------------------------------------------------
do $jaga$
declare m text := md5(replace(pg_get_functiondef(to_regprocedure('public.rc_compilation_list(text,text,text,text,integer,integer,text)')), E'\r', ''));
begin
  if m is null then raise exception 'DITOLAK: rc_compilation_list ber-p_depot belum ada; pasang 20261163040000 lebih dulu.'; end if;
  if m <> '4f121b72adf9a3b01fd4191ffa329884'
     and pg_get_functiondef(to_regprocedure('public.rc_compilation_list(text,text,text,text,integer,integer,text)')) !~ '20261163060000' then
    raise exception 'DITOLAK: rc_compilation_list berbeda dari yang diukur (md5 %).', m; end if;
end
$jaga$;

create or replace function public.rc_compilation_list(p_campaign text DEFAULT ''::text, p_batch text DEFAULT ''::text, p_status text DEFAULT ''::text, p_search text DEFAULT ''::text, p_offset integer DEFAULT 0, p_limit integer DEFAULT 100, p_depot text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
-- 20261163040000: p_depot (kode depot, '' = semua depot yang terlihat).
-- 20261163060000: pencarian lewat rc_private.klaim_cocok_cari (index trigram); kolom tambahan
--                 untuk Pilih Kolom dan unduhan.
declare v jsonb; jml bigint;
begin
 perform rc_private.require_tab('compilation.list');
 if not rc_private.can_access(null,'view_compilation') then
  raise exception 'Access denied' using errcode='42501'; end if;

 select count(*) into jml from public.claims c
  join public.campaigns ca on ca.id=c.campaign_id
  left join public.depots d on d.id=c.depot_id
  where (coalesce(btrim(p_campaign),'')='' or ca.campaign_code=btrim(p_campaign))
    and (coalesce(btrim(p_depot),'')='' or d.depot_code=btrim(p_depot))
    and (coalesce(btrim(p_status),'')='' or c.status=btrim(p_status))
    and (coalesce(btrim(p_batch),'')='' or btrim(p_batch) in
         (c.batch_upload,c.batch_release,c.batch_claim,c.batch_clearing))
    and (coalesce(btrim(p_search),'')='' or c.id in (select k.id from rc_private.klaim_cocok_cari(btrim(p_search)) k));

 select coalesce(jsonb_agg(x),'[]'::jsonb) into v from (
  select jsonb_build_object(
   'id',c.id,'noDoc',c.no_doc,'status',rc_private.legacy_status(c.status),
   'depot',d.depot_name,'kodeDepot',d.depot_code,'region',coalesce(d.region,''),
   'kodeToko',coalesce(cu.customer_code,c.source_customer_code),'namaToko',coalesce(cu.customer_name,'Customer Master belum ada'),
   'contactPerson',coalesce(cu.contact_person,''),
   'codeCampaign',ca.campaign_code,'campaignName',ca.campaign_name,
   'jenisCb',rc_private.cb_label(coalesce(nullif(c.cashback_type_override,''),ca.cashback_type)),'soStart',coalesce(c.extend_so_start,ca.so_start),'soEnd',coalesce(c.extend_so_end,ca.so_end),
   'billingStart',coalesce(c.extend_billing_start,ca.billing_start),
   'billingEnd',coalesce(c.extend_billing_end,ca.billing_end),
   'statusPajak',coalesce(ca.tax_status,''),
   'subyekPajak',coalesce(c.tax_subject,coalesce(cu.tax_subject,'')),
   'netValue',c.net_value,'volume',c.volume,
   'cbNet',c.cb_net,'grossUpCb',c.gross_up,'totTagih',c.total_billing,
   'batchUpload',coalesce(c.batch_upload,''),'batchRelease',coalesce(c.batch_release,''),
   'batchClaim',coalesce(c.batch_claim,''),'batchClearing',coalesce(c.batch_clearing,''),
   'tglUpload',rc_private.legacy_ts(c.uploaded_at),'tglClearing',rc_private.legacy_ts(c.cleared_at),
   'tglAktual',rc_private.legacy_date(c.cleared_actual_on),
   'tglProses',case when c.status='done' and c.cleared_at is not null
                    then rc_private.legacy_ts(c.cleared_at) else '-' end,
   'createdOn',to_char(c.created_at at time zone 'Asia/Jakarta','DD-Mon-YYYY'),
   'createdBy',coalesce(p.user_code,''),
   'versionNo',c.version_no) as x
  from public.claims c
  join public.depots d on d.id=c.depot_id
  left join public.customers cu on cu.id=c.customer_id
  join public.campaigns ca on ca.id=c.campaign_id
  left join public.profiles p on p.id=c.created_by
  where (coalesce(btrim(p_campaign),'')='' or ca.campaign_code=btrim(p_campaign))
    and (coalesce(btrim(p_depot),'')='' or d.depot_code=btrim(p_depot))
    and (coalesce(btrim(p_status),'')='' or c.status=btrim(p_status))
    and (coalesce(btrim(p_batch),'')='' or btrim(p_batch) in
         (c.batch_upload,c.batch_release,c.batch_claim,c.batch_clearing))
    and (coalesce(btrim(p_search),'')='' or c.id in (select k.id from rc_private.klaim_cocok_cari(btrim(p_search)) k))
  order by ca.campaign_code,c.no_doc
  limit least(greatest(coalesce(p_limit,100),1),500) offset greatest(coalesce(p_offset,0),0)) t;

 return jsonb_build_object('status','success','rows',v,'total',jml,
  'canArchive',rc_private.boleh_arsip_compilation() /* 20261162130000 */);
end $function$;
revoke all on function public.rc_compilation_list(text, text, text, text, integer, integer, text) from public, anon;
grant execute on function public.rc_compilation_list(text, text, text, text, integer, integer, text) to authenticated, service_role;

-- ---- rc_open_claims_filtered --------------------------------------------------------------
do $tambal$
declare src text; baru text; n int;
  lama text := $p$    and (coalesce(btrim(p_search),'')='' or c.no_doc ilike '%'||btrim(p_search)||'%'
         or coalesce(cu.customer_code,c.source_customer_code) ilike '%'||btrim(p_search)||'%'
         or coalesce(cu.customer_name,'Customer Master belum ada') ilike '%'||btrim(p_search)||'%')$p$;
  ganti text := $p$    and (coalesce(btrim(p_search),'')='' or c.id in (select k.id from rc_private.klaim_cocok_cari(btrim(p_search)) k)) /* 20261163060000 */$p$;
begin
  src := pg_get_functiondef(to_regprocedure('public.rc_open_claims_filtered(text,text,integer,integer,text)'));
  if src is null then raise exception 'DITOLAK: rc_open_claims_filtered tidak ada.'; end if;
  if src ~ '20261163060000' then raise notice 'rc_open_claims_filtered sudah ditambal.'; return; end if;
  if md5(replace(src, E'\r', '')) <> 'b6296fe18c1f97406a948ac4d415f9e6' then
    raise exception 'DITOLAK: rc_open_claims_filtered berbeda dari yang diukur (md5 %).', md5(replace(src, E'\r', '')); end if;
  baru := replace(src, E'\r', '');
  n := (length(baru) - length(replace(baru, lama, ''))) / length(lama);
  if n <> 2 then raise exception 'rc_open_claims_filtered: predikat pencarian ditemukan % kali, diharapkan 2.', n; end if;
  execute replace(baru, lama, ganti);
end
$tambal$;

notify pgrst, 'reload schema';

-- ------------------------------------------------------------------------------------------
-- Pemeriksaan (dibatalkan seluruhnya)
-- ------------------------------------------------------------------------------------------
do $uji$
declare v_sm uuid; kata text; lama bigint; baru bigint; r jsonb; o jsonb; e text := ''; rencana text;
  daftar text[];
begin
  select id into v_sm from public.profiles where role = 'system manager' and status = 'active' and not must_change_password order by user_code limit 1;
  -- Kata uji diambil dari data: potongan No Doc, kode toko, nama toko, kode sumber tanpa master,
  -- teks "belum ada", satu huruf, dan kata yang pasti tidak ada.
  daftar := array[
    (select substr(no_doc, 5, 6) from public.claims order by no_doc limit 1),
    (select substr(customer_code, 2, 4) from public.customers order by customer_code limit 1),
    (select lower(split_part(customer_name, ' ', 1)) from public.customers where customer_name like '% %' order by customer_code limit 1),
    coalesce((select source_customer_code from public.claims where customer_id is null and source_customer_code is not null limit 1), 'tanpa-sumber'),
    'belum ada', 'a', 'zzqx-tidak-ada'];

  begin
    foreach kata in array daftar loop
      continue when kata is null;
      -- Tanpa RLS (pemilik tabel) dan dengan RLS System Manager: hasil sama dengan predikat lama.
      select count(*) into lama from public.claims c left join public.customers cu on cu.id = c.customer_id
       where c.no_doc ilike '%'||kata||'%' or coalesce(cu.customer_code,c.source_customer_code) ilike '%'||kata||'%'
          or coalesce(cu.customer_name,'Customer Master belum ada') ilike '%'||kata||'%';
      select count(*) into baru from public.claims c where c.id in (select k.id from rc_private.klaim_cocok_cari(kata) k);
      if lama <> baru then e := e || format(' "%s": lama %s baru %s;', kata, lama, baru); end if;
    end loop;

    perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    foreach kata in array daftar loop
      continue when kata is null;
      select count(*) into lama from public.claims c join public.campaigns ca on ca.id = c.campaign_id
        left join public.customers cu on cu.id = c.customer_id
       where c.no_doc ilike '%'||kata||'%' or coalesce(cu.customer_code,c.source_customer_code) ilike '%'||kata||'%'
          or coalesce(cu.customer_name,'Customer Master belum ada') ilike '%'||kata||'%';
      r := public.rc_compilation_list(p_search => kata, p_limit => 500);
      if (r->>'total')::bigint <> lama then e := e || format(' Document Center "%s": %s, harap %s;', kata, r->>'total', lama); end if;
      select count(*) into lama from public.claims c join public.campaigns ca on ca.id = c.campaign_id
        left join public.customers cu on cu.id = c.customer_id
       where c.status = 'not_yet' and c.pending_approval is null and c.archived_at is null
         and (c.no_doc ilike '%'||kata||'%' or coalesce(cu.customer_code,c.source_customer_code) ilike '%'||kata||'%'
          or coalesce(cu.customer_name,'Customer Master belum ada') ilike '%'||kata||'%');
      o := public.rc_open_claims_filtered(p_search => kata, p_limit => 500);
      if (o->>'total')::bigint <> lama then e := e || format(' Open "%s": %s, harap %s;', kata, o->>'total', lama); end if;
    end loop;
    r := public.rc_compilation_list(p_limit => 1);
    if not (r->'rows'->0 ?& array['region','netValue','volume','tglAktual','createdOn','createdBy']) then
      e := e || ' kolom tambahan Document Center tidak lengkap;'; end if;
    execute 'reset role';

    -- Index benar-benar dapat dipakai (tabel dev kecil, jadi pemindaian penuh dimatikan dulu).
    set local enable_seqscan = off;
    execute 'explain (format json) select id from public.claims where no_doc ilike ''%abc%''' into rencana;
    if rencana !~ 'claims_no_doc_trgm_idx' then e := e || ' index No Doc tidak dipakai: ' || rencana || ';'; end if;
    execute 'explain (format json) select id from public.customers where customer_name ilike ''%abc%''' into rencana;
    if rencana !~ 'customers_name_trgm_idx' then e := e || ' index nama toko tidak dipakai;'; end if;
    raise exception 'UJI_SELESAI';
  exception when others then
    if sqlerrm <> 'UJI_SELESAI' then e := e || ' galat: ' || sqlerrm; end if;
  end;
  perform set_config('request.jwt.claims', '', true);
  if e <> '' then raise exception 'GAGAL:%', e; end if;
end
$uji$;
