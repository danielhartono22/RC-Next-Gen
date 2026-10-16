-- ==========================================================================================
-- Pencarian Document Center / tab Open: rencana query selalu sesuai kata kunci
-- ==========================================================================================
-- Ditemukan saat uji prod sesudah 20261163070000 (13 Oktober 2026). Dalam satu koneksi,
-- PL/pgSQL memakai rencana query KHUSUS untuk lima panggilan pertama, lalu beralih ke rencana
-- GENERIK yang tidak mengetahui kata kuncinya:
--     panggilan 2 "CB/BKT"  28 ms   ->  panggilan 8 "CB/BKT"  324 ms
--     panggilan 1 "sinar"  139 ms   ->  panggilan 7 "sinar"   359 ms
-- Koneksi API dipakai ulang antar permintaan, jadi rencana generik itulah yang dialami
-- pengguna; sebagian pencarian bahkan lebih lambat daripada sebelum index dipasang.
-- Kata yang merupakan bagian dari "Customer Master belum ada" (mas, ada, ...) juga membuat
-- kandidat = seluruh klaim.
--
-- SEKARANG
--   - rc_compilation_list dan rc_open_claims_filtered: SET plan_cache_mode = force_custom_plan,
--     sehingga setiap panggilan direncanakan dengan kata kuncinya sendiri.
--   - Kandidat dihitung SEKALI menjadi daftar id (v_ids), lalu dipakai lewat c.id = any(v_ids)
--     yang memakai primary key. Bila kata kunci termasuk dalam "Customer Master belum ada",
--     kandidat tidak dipakai dan pencarian berjalan seperti sebelum index (sama cepatnya).
--   - Predikat akhir tetap predikat lama di bawah RLS pemanggil: hasil tidak berubah.
--   - rc_private.klaim_cocok_cari: cabang konstanta "Customer Master belum ada" dicabut,
--     karena kasus itu kini ditangani pemanggil.
--
-- Ditambal dengan penjaga MD5 pra-citra (13 Oktober 2026; dev dan prod sama sesudah
-- 20261163070000).
-- ==========================================================================================

do $jaga$
begin
  if md5(replace(pg_get_functiondef('rc_private.klaim_cocok_cari(text)'::regprocedure), E'\r', '')) <> 'b6efbd680e53324d1667a4221c6a7bd7'
     and pg_get_functiondef('rc_private.klaim_cocok_cari(text)'::regprocedure) !~ '20261163080000' then
    raise exception 'DITOLAK: rc_private.klaim_cocok_cari berbeda dari yang diukur.'; end if;
  if md5(replace(pg_get_functiondef('public.rc_compilation_list(text,text,text,text,integer,integer,text)'::regprocedure), E'\r', '')) <> '0ea8030d56fbbe4e0fe923f0cfa5d246'
     and pg_get_functiondef('public.rc_compilation_list(text,text,text,text,integer,integer,text)'::regprocedure) !~ '20261163080000' then
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
  -- 20261163060000 / 20261163070000 / 20261163080000: KANDIDAT pencarian, tanpa memandang hak
  -- lihat, supaya index trigram terpakai. Hanya dipakai bersama predikat lama di fungsi
  -- SECURITY INVOKER; hasil akhirnya tetap ditentukan RLS pemanggil. Kata yang termasuk dalam
  -- "Customer Master belum ada" tidak memakai kandidat sama sekali (ditangani pemanggil).
  select k.id from public.claims k
   where k.no_doc ilike '%' || p_cari || '%'
  union
  select k.id from public.customers x join public.claims k on k.customer_id = x.id
   where x.customer_code ilike '%' || p_cari || '%' or x.customer_name ilike '%' || p_cari || '%'
  union
  select k.id from public.claims k
   where k.source_customer_code ilike '%' || p_cari || '%';
$function$;
revoke all on function rc_private.klaim_cocok_cari(text) from public, anon;
grant execute on function rc_private.klaim_cocok_cari(text) to authenticated, service_role;

create or replace function public.rc_compilation_list(p_campaign text DEFAULT ''::text, p_batch text DEFAULT ''::text, p_status text DEFAULT ''::text, p_search text DEFAULT ''::text, p_offset integer DEFAULT 0, p_limit integer DEFAULT 100, p_depot text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
 SET plan_cache_mode TO 'force_custom_plan'
AS $function$
-- 20261163040000: p_depot (kode depot, '' = semua depot yang terlihat).
-- 20261163060000: kolom tambahan untuk Pilih Kolom dan unduhan.
-- 20261163070000 / 20261163080000: pencarian = kandidat (index trigram, dihitung sekali) DAN
-- predikat lama di bawah RLS pemanggil; rencana query selalu sesuai kata kuncinya.
declare v jsonb; jml bigint;
 v_cari text := btrim(coalesce(p_search,'')); v_ids uuid[];
begin
 perform rc_private.require_tab('compilation.list');
 if not rc_private.can_access(null,'view_compilation') then
  raise exception 'Access denied' using errcode='42501'; end if;

 if v_cari <> '' and not ('Customer Master belum ada' ilike '%'||v_cari||'%') then
  v_ids := array(select k.id from rc_private.klaim_cocok_cari(v_cari) k);
 end if;

 select count(*) into jml from public.claims c
  join public.campaigns ca on ca.id=c.campaign_id
  left join public.customers cu on cu.id=c.customer_id
  left join public.depots d on d.id=c.depot_id
  where (coalesce(btrim(p_campaign),'')='' or ca.campaign_code=btrim(p_campaign))
    and (coalesce(btrim(p_depot),'')='' or d.depot_code=btrim(p_depot))
    and (coalesce(btrim(p_status),'')='' or c.status=btrim(p_status))
    and (coalesce(btrim(p_batch),'')='' or btrim(p_batch) in
         (c.batch_upload,c.batch_release,c.batch_claim,c.batch_clearing))
    and (v_cari='' or ((v_ids is null or c.id = any(v_ids))
         and (c.no_doc ilike '%'||v_cari||'%'
              or coalesce(cu.customer_code,c.source_customer_code) ilike '%'||v_cari||'%'
              or coalesce(cu.customer_name,'Customer Master belum ada') ilike '%'||v_cari||'%')));

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
    and (v_cari='' or ((v_ids is null or c.id = any(v_ids))
         and (c.no_doc ilike '%'||v_cari||'%'
              or coalesce(cu.customer_code,c.source_customer_code) ilike '%'||v_cari||'%'
              or coalesce(cu.customer_name,'Customer Master belum ada') ilike '%'||v_cari||'%')))
  order by ca.campaign_code,c.no_doc
  limit least(greatest(coalesce(p_limit,100),1),500) offset greatest(coalesce(p_offset,0),0)) t;

 return jsonb_build_object('status','success','rows',v,'total',jml,
  'canArchive',rc_private.boleh_arsip_compilation() /* 20261162130000 */);
end $function$;
revoke all on function public.rc_compilation_list(text, text, text, text, integer, integer, text) from public, anon;
grant execute on function public.rc_compilation_list(text, text, text, text, integer, integer, text) to authenticated, service_role;

do $tambal$
declare src text; baru text; n int; r record;
begin
  src := pg_get_functiondef('public.rc_open_claims_filtered(text,text,integer,integer,text)'::regprocedure);
  if src ~ '20261163080000' then raise notice 'rc_open_claims_filtered sudah ditambal.'; return; end if;
  if md5(replace(src, E'\r', '')) <> 'd5a29d58babc30939e65f2cf9c8c5adc' then
    raise exception 'DITOLAK: rc_open_claims_filtered berbeda dari yang diukur (md5 %).', md5(replace(src, E'\r', '')); end if;
  baru := replace(src, E'\r', '');
  for r in select * from (values
    (1, $p$declare v jsonb; jml bigint; v_opsi jsonb;$p$,
        $p$declare v jsonb; jml bigint; v_opsi jsonb;
 v_cari text := btrim(coalesce(p_search,'')); v_ids uuid[]; -- 20261163080000$p$, 1),
    (2, $p$ if not rc_private.can_access(null,'upload_claim') then
  raise exception 'Access denied' using errcode='42501'; end if;$p$,
        $p$ if not rc_private.can_access(null,'upload_claim') then
  raise exception 'Access denied' using errcode='42501'; end if;

 -- Kandidat dihitung sekali (index trigram); kata yang termasuk dalam "Customer Master belum
 -- ada" tidak memakai kandidat. Predikat akhir tetap predikat lama di bawah RLS pemanggil.
 if v_cari <> '' and not ('Customer Master belum ada' ilike '%'||v_cari||'%') then
  v_ids := array(select k.id from rc_private.klaim_cocok_cari(v_cari) k);
 end if;$p$, 1),
    (3, $p$    and (coalesce(btrim(p_search),'')='' or (c.id in (select k.id from rc_private.klaim_cocok_cari(btrim(p_search)) k) /* 20261163070000 */
         and (c.no_doc ilike '%'||btrim(p_search)||'%'
              or coalesce(cu.customer_code,c.source_customer_code) ilike '%'||btrim(p_search)||'%'
              or coalesce(cu.customer_name,'Customer Master belum ada') ilike '%'||btrim(p_search)||'%')))$p$,
        $p$    and (v_cari='' or ((v_ids is null or c.id = any(v_ids))
         and (c.no_doc ilike '%'||v_cari||'%'
              or coalesce(cu.customer_code,c.source_customer_code) ilike '%'||v_cari||'%'
              or coalesce(cu.customer_name,'Customer Master belum ada') ilike '%'||v_cari||'%')))$p$, 2)
  ) t(urut, lama, ganti, harap) order by urut loop
    n := (length(baru) - length(replace(baru, r.lama, ''))) / length(r.lama);
    if n <> r.harap then raise exception 'rc_open_claims_filtered: pola % ditemukan % kali, diharapkan %.', r.urut, n, r.harap; end if;
    baru := replace(baru, r.lama, r.ganti);
  end loop;
  execute baru;
end
$tambal$;
alter function public.rc_open_claims_filtered(text, text, integer, integer, text) set plan_cache_mode to 'force_custom_plan';

notify pgrst, 'reload schema';

-- ------------------------------------------------------------------------------------------
-- Pemeriksaan (dibatalkan): hasil = predikat lama di bawah hak pemanggil (System Manager dan
-- pengguna depot), termasuk kata yang termasuk dalam "Customer Master belum ada"; dan sembilan
-- panggilan beruntun tetap memakai rencana yang sesuai kata kunci.
-- ------------------------------------------------------------------------------------------
do $uji$
declare u record; kata text; lama bigint; r jsonb; o jsonb; e text := ''; daftar text[]; t timestamptz; i int;
  ms_awal numeric; ms_akhir numeric; v_sm uuid;
begin
  daftar := array[
    (select substr(no_doc, 5, 6) from public.claims order by no_doc limit 1),
    (select substr(customer_code, 2, 4) from public.customers order by customer_code limit 1),
    (select lower(split_part(customer_name, ' ', 1)) from public.customers where customer_name like '% %' order by customer_code limit 1),
    coalesce((select source_customer_code from public.claims where source_customer_code is not null order by no_doc limit 1), 'tanpa-sumber'),
    'belum ada', 'mas', 'ada', 'zzqx-tidak-ada'];
  for u in (select id, role from public.profiles where status = 'active' and not must_change_password and role = 'system manager' order by user_code limit 1)
           union all
           (select id, role from public.profiles where status = 'active' and not must_change_password and role in ('admin','depot head','supervisor') order by user_code limit 2) loop
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
        exception when insufficient_privilege then null;
        end;
        select count(*) into lama from public.claims c join public.campaigns ca on ca.id = c.campaign_id
          left join public.customers cu on cu.id = c.customer_id
         where c.status = 'not_yet' and c.pending_approval is null and c.archived_at is null
           and (c.no_doc ilike '%'||kata||'%' or coalesce(cu.customer_code,c.source_customer_code) ilike '%'||kata||'%'
            or coalesce(cu.customer_name,'Customer Master belum ada') ilike '%'||kata||'%');
        begin
          o := public.rc_open_claims_filtered(p_search => kata, p_limit => 1);
          if (o->>'total')::bigint <> lama then e := e || format(' %s Open "%s": %s, harap %s;', u.role, kata, o->>'total', lama); end if;
        exception when insufficient_privilege then null;
        end;
      end loop;
      execute 'reset role';
      raise exception 'UJI_SELESAI';
    exception when others then
      if sqlerrm <> 'UJI_SELESAI' then e := e || format(' %s galat: %s;', u.role, sqlerrm); end if;
    end;
  end loop;

  -- Sembilan panggilan beruntun dengan kata yang sama: panggilan terakhir tidak boleh jauh lebih
  -- lambat dari yang pertama (dulu 28 ms -> 324 ms setelah beralih ke rencana generik).
  select id into v_sm from public.profiles where role = 'system manager' and status = 'active' and not must_change_password order by user_code limit 1;
  begin
    perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    kata := (select substr(no_doc, 5, 6) from public.claims order by no_doc limit 1);
    for i in 1..9 loop
      t := clock_timestamp(); r := public.rc_compilation_list(p_search => kata, p_limit => 100);
      if i = 2 then ms_awal := extract(epoch from clock_timestamp() - t) * 1000; end if;
      if i = 9 then ms_akhir := extract(epoch from clock_timestamp() - t) * 1000; end if;
    end loop;
    execute 'reset role';
    if ms_akhir > greatest(ms_awal * 3, ms_awal + 100) then
      e := e || format(' rencana generik: panggilan 2 %s ms, panggilan 9 %s ms;', round(ms_awal), round(ms_akhir)); end if;
    raise exception 'UJI_SELESAI';
  exception when others then
    if sqlerrm <> 'UJI_SELESAI' then e := e || ' uji beruntun galat: ' || sqlerrm; end if;
  end;
  perform set_config('request.jwt.claims', '', true);
  if e <> '' then raise exception 'GAGAL:%', e; end if;
end
$uji$;
