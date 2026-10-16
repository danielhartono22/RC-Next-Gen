-- ==========================================================================================
-- Pencarian Document Center / tab Open: index trigram terpakai juga di bawah RLS
-- ==========================================================================================
-- Ditemukan saat uji pascatransport 13 Oktober 2026 (prod, 31.906 klaim, kata "sinar"):
--   rc_private.klaim_cocok_cari sebagai pemilik tabel (tanpa RLS)   24 ms
--   rc_private.klaim_cocok_cari sebagai pengguna aplikasi            191 ms
--   predikat lama sebagai pengguna aplikasi                          230-244 ms
-- Di bawah RLS, ILIKE (fungsi yang tidak LEAKPROOF) tidak boleh dievaluasi sebelum aturan
-- baris, sehingga index trigram tidak dapat dipakai dan seluruh tabel tetap dipindai.
--
-- SEKARANG dua langkah:
--   1. rc_private.klaim_cocok_cari menjadi SECURITY DEFINER dan mengembalikan KANDIDAT: id klaim
--      yang teksnya cocok, tanpa memandang hak lihat (index terpakai). Kandidat ini adalah
--      superset dari hasil predikat lama:
--        no_doc cocok                              -> cabang No Doc
--        kode/nama customer yang terlihat cocok    -> cabang customer (semua customer)
--        customer tidak terlihat, kode sumber cocok -> cabang kode sumber (semua klaim)
--        customer tidak terlihat, "Customer Master belum ada" cocok -> semua klaim
--   2. Fungsi pemanggil (SECURITY INVOKER, RLS berlaku) memakai kandidat itu DAN predikat lama
--      yang persis sama. Hasil akhir = predikat lama di bawah hak pemanggil, tidak lebih, tidak
--      kurang; aturan hak lihat tidak ditulis ulang di mana pun. Kandidat hanya membuat
--      predikat lama dievaluasi pada sedikit baris.
--
-- Ditambal dengan penjaga MD5 pra-citra (13 Oktober 2026; dev dan prod sama sesudah
-- 20261163060000).
-- ==========================================================================================

do $jaga$
begin
  if md5(replace(pg_get_functiondef('rc_private.klaim_cocok_cari(text)'::regprocedure), E'\r', '')) <> 'ff841d49cf6775ede5fe44e6ec2e980e'
     and pg_get_functiondef('rc_private.klaim_cocok_cari(text)'::regprocedure) !~ '20261163070000' then
    raise exception 'DITOLAK: rc_private.klaim_cocok_cari berbeda dari yang diukur.'; end if;
  if md5(replace(pg_get_functiondef('public.rc_compilation_list(text,text,text,text,integer,integer,text)'::regprocedure), E'\r', '')) <> '866173ba2728285600853e5875998777'
     and pg_get_functiondef('public.rc_compilation_list(text,text,text,text,integer,integer,text)'::regprocedure) !~ '20261163070000' then
    raise exception 'DITOLAK: rc_compilation_list berbeda dari yang diukur.'; end if;
end
$jaga$;

create or replace function rc_private.klaim_cocok_cari(p_cari text)
 returns table(id uuid)
 language sql
 stable
 security definer
 set search_path to ''
as $function$
  -- 20261163060000 / 20261163070000: KANDIDAT pencarian, tanpa memandang hak lihat, supaya
  -- index trigram terpakai. Hanya dipakai bersama predikat lama di fungsi SECURITY INVOKER;
  -- hasil akhirnya tetap ditentukan RLS pemanggil.
  select k.id from public.claims k
   where k.no_doc ilike '%' || p_cari || '%'
  union
  select k.id from public.customers x join public.claims k on k.customer_id = x.id
   where x.customer_code ilike '%' || p_cari || '%' or x.customer_name ilike '%' || p_cari || '%'
  union
  select k.id from public.claims k
   where k.source_customer_code ilike '%' || p_cari || '%'
  union
  select k.id from public.claims k
   where 'Customer Master belum ada' ilike '%' || p_cari || '%';
$function$;
revoke all on function rc_private.klaim_cocok_cari(text) from public, anon;
grant execute on function rc_private.klaim_cocok_cari(text) to authenticated, service_role;

create or replace function public.rc_compilation_list(p_campaign text DEFAULT ''::text, p_batch text DEFAULT ''::text, p_status text DEFAULT ''::text, p_search text DEFAULT ''::text, p_offset integer DEFAULT 0, p_limit integer DEFAULT 100, p_depot text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
-- 20261163040000: p_depot (kode depot, '' = semua depot yang terlihat).
-- 20261163060000: kolom tambahan untuk Pilih Kolom dan unduhan.
-- 20261163070000: pencarian = kandidat (index trigram) DAN predikat lama di bawah RLS pemanggil.
declare v jsonb; jml bigint;
begin
 perform rc_private.require_tab('compilation.list');
 if not rc_private.can_access(null,'view_compilation') then
  raise exception 'Access denied' using errcode='42501'; end if;

 select count(*) into jml from public.claims c
  join public.campaigns ca on ca.id=c.campaign_id
  left join public.customers cu on cu.id=c.customer_id
  left join public.depots d on d.id=c.depot_id
  where (coalesce(btrim(p_campaign),'')='' or ca.campaign_code=btrim(p_campaign))
    and (coalesce(btrim(p_depot),'')='' or d.depot_code=btrim(p_depot))
    and (coalesce(btrim(p_status),'')='' or c.status=btrim(p_status))
    and (coalesce(btrim(p_batch),'')='' or btrim(p_batch) in
         (c.batch_upload,c.batch_release,c.batch_claim,c.batch_clearing))
    and (coalesce(btrim(p_search),'')='' or (c.id in (select k.id from rc_private.klaim_cocok_cari(btrim(p_search)) k)
         and (c.no_doc ilike '%'||btrim(p_search)||'%'
              or coalesce(cu.customer_code,c.source_customer_code) ilike '%'||btrim(p_search)||'%'
              or coalesce(cu.customer_name,'Customer Master belum ada') ilike '%'||btrim(p_search)||'%')));

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
    and (coalesce(btrim(p_search),'')='' or (c.id in (select k.id from rc_private.klaim_cocok_cari(btrim(p_search)) k)
         and (c.no_doc ilike '%'||btrim(p_search)||'%'
              or coalesce(cu.customer_code,c.source_customer_code) ilike '%'||btrim(p_search)||'%'
              or coalesce(cu.customer_name,'Customer Master belum ada') ilike '%'||btrim(p_search)||'%')))
  order by ca.campaign_code,c.no_doc
  limit least(greatest(coalesce(p_limit,100),1),500) offset greatest(coalesce(p_offset,0),0)) t;

 return jsonb_build_object('status','success','rows',v,'total',jml,
  'canArchive',rc_private.boleh_arsip_compilation() /* 20261162130000 */);
end $function$;
revoke all on function public.rc_compilation_list(text, text, text, text, integer, integer, text) from public, anon;
grant execute on function public.rc_compilation_list(text, text, text, text, integer, integer, text) to authenticated, service_role;

do $tambal$
declare src text; baru text; n int;
  lama text := $p$    and (coalesce(btrim(p_search),'')='' or c.id in (select k.id from rc_private.klaim_cocok_cari(btrim(p_search)) k)) /* 20261163060000 */$p$;
  ganti text := $p$    and (coalesce(btrim(p_search),'')='' or (c.id in (select k.id from rc_private.klaim_cocok_cari(btrim(p_search)) k) /* 20261163070000 */
         and (c.no_doc ilike '%'||btrim(p_search)||'%'
              or coalesce(cu.customer_code,c.source_customer_code) ilike '%'||btrim(p_search)||'%'
              or coalesce(cu.customer_name,'Customer Master belum ada') ilike '%'||btrim(p_search)||'%')))$p$;
begin
  src := pg_get_functiondef('public.rc_open_claims_filtered(text,text,integer,integer,text)'::regprocedure);
  if src ~ '20261163070000' then raise notice 'rc_open_claims_filtered sudah ditambal.'; return; end if;
  if md5(replace(src, E'\r', '')) <> '3fc09bd1b0c5792a811b3fa4f8be0bad' then
    raise exception 'DITOLAK: rc_open_claims_filtered berbeda dari yang diukur (md5 %).', md5(replace(src, E'\r', '')); end if;
  baru := replace(src, E'\r', '');
  n := (length(baru) - length(replace(baru, lama, ''))) / length(lama);
  if n <> 2 then raise exception 'rc_open_claims_filtered: predikat ditemukan % kali, diharapkan 2.', n; end if;
  execute replace(baru, lama, ganti);
end
$tambal$;

notify pgrst, 'reload schema';

-- ------------------------------------------------------------------------------------------
-- Pemeriksaan (dibatalkan): hasil = predikat lama di bawah hak pemanggil, untuk System Manager
-- dan untuk pengguna depot (yang hak lihat customernya terbatas).
-- ------------------------------------------------------------------------------------------
do $uji$
declare u record; kata text; lama bigint; r jsonb; o jsonb; e text := ''; daftar text[]; n_user int := 0;
begin
  daftar := array[
    (select substr(no_doc, 5, 6) from public.claims order by no_doc limit 1),
    (select substr(customer_code, 2, 4) from public.customers order by customer_code limit 1),
    (select lower(split_part(customer_name, ' ', 1)) from public.customers where customer_name like '% %' order by customer_code limit 1),
    coalesce((select source_customer_code from public.claims where source_customer_code is not null order by no_doc limit 1), 'tanpa-sumber'),
    'belum ada', 'zzqx-tidak-ada'];
  for u in (select id, role from public.profiles where status = 'active' and not must_change_password and role = 'system manager' order by user_code limit 1)
           union all
           (select id, role from public.profiles where status = 'active' and not must_change_password and role in ('admin','depot head','supervisor') order by user_code limit 2) loop
    n_user := n_user + 1;
    begin
      perform set_config('request.jwt.claims', json_build_object('sub', u.id::text, 'role', 'authenticated')::text, true);
      execute 'set local role authenticated';
      foreach kata in array daftar loop
        continue when kata is null;
        select count(*) into lama from public.claims c join public.campaigns ca on ca.id = c.campaign_id
          left join public.customers cu on cu.id = c.customer_id
         where c.no_doc ilike '%'||kata||'%' or coalesce(cu.customer_code,c.source_customer_code) ilike '%'||kata||'%'
            or coalesce(cu.customer_name,'Customer Master belum ada') ilike '%'||kata||'%';
        begin
          r := public.rc_compilation_list(p_search => kata, p_limit => 1);
          if (r->>'total')::bigint <> lama then e := e || format(' %s DC "%s": %s, harap %s;', u.role, kata, r->>'total', lama); end if;
        exception when insufficient_privilege then null;   -- akun tanpa tab Document Center
        end;
        select count(*) into lama from public.claims c join public.campaigns ca on ca.id = c.campaign_id
          left join public.customers cu on cu.id = c.customer_id
         where c.status = 'not_yet' and c.pending_approval is null and c.archived_at is null
           and (c.no_doc ilike '%'||kata||'%' or coalesce(cu.customer_code,c.source_customer_code) ilike '%'||kata||'%'
            or coalesce(cu.customer_name,'Customer Master belum ada') ilike '%'||kata||'%');
        begin
          o := public.rc_open_claims_filtered(p_search => kata, p_limit => 1);
          if (o->>'total')::bigint <> lama then e := e || format(' %s Open "%s": %s, harap %s;', u.role, kata, o->>'total', lama); end if;
        exception when insufficient_privilege then null;   -- akun tanpa tab Open
        end;
      end loop;
      execute 'reset role';
      raise exception 'UJI_SELESAI';
    exception when others then
      if sqlerrm <> 'UJI_SELESAI' then e := e || format(' %s galat: %s;', u.role, sqlerrm); end if;
    end;
  end loop;
  perform set_config('request.jwt.claims', '', true);
  if n_user = 0 then raise notice 'Tidak ada pengguna aktif; uji dilewati.'; end if;
  if e <> '' then raise exception 'GAGAL:%', e; end if;
end
$uji$;
