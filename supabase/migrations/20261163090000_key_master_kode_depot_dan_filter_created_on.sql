-- ==========================================================================================
-- Key Master: Kode Depot pada Customer Master, Abbr wajib pada depot baru; Document Center:
-- filter tanggal Created On
-- ==========================================================================================
-- Pemilik, 14 Oktober 2026: "Key Master, Customer Master template dan upload serta yang
-- penambahan toko kenapa tidak bisa? apa karena kode depot tidak ada? Tambahkan kode depot di
-- penambahan toko dan atau yang mass upload, cek juga tab lainnya seperti campaign master dan
-- depo master agar case seperti ini tidak terulang lagi" dan "untuk document center buat bisa
-- difilter berdasarkan tanggal created on".
--
-- SEBABNYA (diuji di dev): rc_customer_upsert menyimpan baris customers tetapi tidak pernah
-- mengisi customer_depots. Tidak ada satu pun fungsi aplikasi yang mengisinya; selama ini tabel
-- itu hanya terisi lewat muat ulang data. RLS customers_scoped mensyaratkan customer punya
-- kaitan depot yang terlihat, jadi toko baru "tersimpan" (dibuat 1) tetapi tidak muncul di
-- daftar - bahkan bagi System Manager. Prod 14 Oktober 2026: customer 653964 (PT. LANGGENG JAYA
-- NIRMALA, ditambah 09:45) dalam keadaan ini.
--
-- SEKARANG
--   Customer Master (rc_private.customer_upsert)
--     - kolom kodeDepot: satu atau lebih kode depot, dipisah koma / titik koma / garis miring /
--       spasi; setiap kode harus ada di Depot Master, aktif, dan dalam jangkauan pemanggil.
--     - customer BARU wajib punya Kode Depot.
--     - customer lama: Kode Depot diisi -> kaitan depot DALAM JANGKAUAN pemanggil disamakan
--       dengan daftar itu (depot di luar jangkauan tidak disentuh); kosong -> tidak berubah.
--       Customer yang telanjur tanpa depot (seperti 653964) dipulihkan dengan menyimpan ulang
--       kodenya beserta Kode Depot, lewat Tambah maupun unggah.
--     - jawaban membawa tanpaDepot: kode yang masih belum punya depot sesudah disimpan.
--   rc_customer_list membawa tanpaDepot {jumlah, kode} supaya layar dapat memperingatkan
--     customer yang tidak terlihat itu (hanya bagi yang berhak mengelola Key Master).
--   Campaign Master: total di bawah tabel mengikuti pencarian (dulu selalu seluruh campaign,
--     sehingga pager menulis "1 - 1 dari 102"). Campaign tidak butuh kaitan depot: seluruh
--     pengguna dapat melihatnya (diuji: campaign baru langsung muncul).
--   Depot Master (rc_depot_upsert)
--     - depot BARU wajib punya Abbr (dipakai pada No Doc; tanpa Abbr compile ditolak - prod: 5S,
--       5T).
--     - Abbr diperiksa per baris: format 2-10 huruf/angka dan tidak boleh dipakai depot lain.
--       Dulu keduanya hanya dijaga constraint, sehingga satu baris salah menggagalkan seluruh
--       unggahan dengan pesan teknis.
--     - Abbr kosong pada unggahan/ubah tidak lagi menghapus Abbr yang sudah ada.
--   rc_depot_list membawa tanpaAbbr (kode depot aktif tanpa Abbr) untuk peringatan di layar.
--   Document Center (rc_compilation_list): p_dibuat_dari / p_dibuat_sampai (tanggal Created On,
--     zona Asia/Jakarta, inklusif). Tanpa nilai = tidak disaring; pemanggil lama tetap jalan.
--
-- Ditambal dengan penjaga MD5 pra-citra (14 Oktober 2026; dev dan prod sama).
-- ==========================================================================================

do $jaga$
declare x record;
begin
  for x in select * from (values
    ('rc_private.customer_upsert(jsonb)', '68bfe0f3603cbb4c66b2109c65046add'),
    ('public.rc_compilation_list(text,text,text,text,integer,integer,text)', '232424f3f309b5dfeb4a4ff31d958767')) t(sig, m) loop
    if to_regprocedure(x.sig) is null then
      if x.sig like 'public.rc_compilation_list%' and to_regprocedure('public.rc_compilation_list(text,text,text,text,integer,integer,text,date,date)') is not null then continue; end if;
      raise exception 'DITOLAK: % tidak ada.', x.sig; end if;
    if md5(replace(pg_get_functiondef(to_regprocedure(x.sig)), E'\r', '')) <> x.m
       and pg_get_functiondef(to_regprocedure(x.sig)) !~ '20261163090000' then
      raise exception 'DITOLAK: % berbeda dari yang diukur.', x.sig; end if;
  end loop;
end
$jaga$;

-- ---- Customer Master -----------------------------------------------------------------------
create or replace function rc_private.customer_upsert(p_rows jsonb)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
-- 20261163090000: Kode Depot (customer_depots). Lihat kepala migrasi.
declare r jsonb; code text; k text; dibuat integer:=0; diperbarui integer:=0; hasil jsonb:='[]';
 sudah boolean; v_cust uuid; v_kode_teks text; v_kode text; v_depots uuid[]; v_dep public.depots%rowtype;
 tanpa_depot jsonb := '[]'; n_kait integer := 0; n integer;
begin
 if not rc_private.can_access(null,'manage_key_master') then
  raise exception 'Access denied' using errcode='42501'; end if;
 if p_rows is null or jsonb_typeof(p_rows)<>'array' then raise exception 'Data harus berupa array'; end if;
 if jsonb_array_length(p_rows) not between 1 and 2000 then raise exception 'Satu unggahan maksimal 2000 baris'; end if;
 if octet_length(p_rows::text)>4194304 then raise exception 'Payload melebihi 4 MiB'; end if;

 for r in select value from jsonb_array_elements(p_rows) loop
  if jsonb_typeof(r)<>'object' then raise exception 'Setiap baris harus berupa objek'; end if;
  for k in select key from jsonb_each(r) loop
   if k not in('custCode','custName','kodeDepot','top','ktp','npwp','namaRek','noRek','bank','contactPerson')
   then raise exception 'Kolom tidak dikenali: %',k; end if;
   if jsonb_typeof(r->k)<>'string' or length(r->>k)>200 then
    raise exception 'Nilai kolom % harus teks maksimal 200 karakter',k; end if;
  end loop;
  code:=upper(btrim(coalesce(r->>'custCode','')));
  if code='' then raise exception 'Customer Code wajib diisi pada setiap baris'; end if;

  -- Kode Depot dibaca dan diperiksa sebelum apa pun ditulis.
  v_kode_teks := upper(btrim(coalesce(r->>'kodeDepot','')));
  v_depots := '{}';
  if v_kode_teks <> '' then
   for v_kode in select distinct x from regexp_split_to_table(v_kode_teks, '[,;/[:space:]]+') x where x <> '' loop
    select * into v_dep from public.depots where depot_code = v_kode and archived_at is null;
    if not found then
     raise exception 'Customer %: Kode Depot "%" tidak ada di Depot Master, atau sudah diarsipkan', code, v_kode; end if;
    if not rc_private.can_access(v_dep.id) then
     raise exception 'Customer %: depot % di luar akses Anda', code, v_kode; end if;
    v_depots := v_depots || v_dep.id;
   end loop;
  end if;

  select id into v_cust from public.customers where customer_code=code;
  sudah := found;
  if not sudah then
   if btrim(coalesce(r->>'custName',''))='' then
    raise exception 'Nama pelanggan wajib diisi untuk kode baru: %',code; end if;
   if coalesce(array_length(v_depots,1),0) = 0 then
    raise exception 'Kode Depot wajib diisi untuk customer baru %: tanpa depot, customer tidak terlihat di aplikasi', code; end if;
  end if;

  if sudah then
   update public.customers set
    customer_name=case when r ? 'custName' and btrim(r->>'custName')<>'' then btrim(r->>'custName') else customer_name end,
    top_text=case when r ? 'top' then nullif(btrim(r->>'top'),'') else top_text end,
    ktp=case when r ? 'ktp' then nullif(btrim(r->>'ktp'),'') else ktp end,
    npwp=case when r ? 'npwp' then nullif(btrim(r->>'npwp'),'') else npwp end,
    account_name=case when r ? 'namaRek' then nullif(btrim(r->>'namaRek'),'') else account_name end,
    account_number=case when r ? 'noRek' then nullif(btrim(r->>'noRek'),'') else account_number end,
    bank=case when r ? 'bank' then nullif(btrim(r->>'bank'),'') else bank end,
    contact_person=case when r ? 'contactPerson' then nullif(btrim(r->>'contactPerson'),'') else contact_person end,
    updated_at=now(),updated_by=(select auth.uid())
   where id=v_cust;
   diperbarui:=diperbarui+1;
  else
   insert into public.customers(customer_code,customer_name,top_text,ktp,npwp,
     account_name,account_number,bank,contact_person,updated_by)
   values(code,btrim(r->>'custName'),nullif(btrim(coalesce(r->>'top','')),''),
     nullif(btrim(coalesce(r->>'ktp','')),''),nullif(btrim(coalesce(r->>'npwp','')),''),
     nullif(btrim(coalesce(r->>'namaRek','')),''),nullif(btrim(coalesce(r->>'noRek','')),''),
     nullif(btrim(coalesce(r->>'bank','')),''),nullif(btrim(coalesce(r->>'contactPerson','')),''),
     (select auth.uid()))
   returning id into v_cust;
   dibuat:=dibuat+1;
  end if;

  -- Kaitan depot: hanya depot dalam jangkauan pemanggil yang disamakan dengan daftar.
  if coalesce(array_length(v_depots,1),0) > 0 then
   delete from public.customer_depots cd
    where cd.customer_id = v_cust and cd.depot_id <> all(v_depots) and rc_private.can_access(cd.depot_id);
   insert into public.customer_depots(customer_id, depot_id)
   select v_cust, x from unnest(v_depots) x on conflict do nothing;
   get diagnostics n = row_count; n_kait := n_kait + n;
  end if;
  if not exists(select 1 from public.customer_depots where customer_id = v_cust) then
   tanpa_depot := tanpa_depot || to_jsonb(code); end if;
  hasil:=hasil||jsonb_build_array(code);
 end loop;

 insert into public.activity_logs(actor_id,event_type,details)
 values((select auth.uid()),'customer_master_upsert',
   jsonb_build_object('dibuat',dibuat,'diperbarui',diperbarui,'kaitanDepotBaru',n_kait,'tanpaDepot',tanpa_depot));
 return jsonb_build_object('status','success','dibuat',dibuat,'diperbarui',diperbarui,'kode',hasil,
   'kaitanDepotBaru',n_kait,'tanpaDepot',tanpa_depot);
end $function$;
revoke all on function rc_private.customer_upsert(jsonb) from public, anon;

-- Customer aktif tanpa kaitan depot: tidak terlihat oleh siapa pun lewat RLS, jadi layar hanya
-- dapat mengetahuinya dari sini. Hanya untuk yang berhak mengelola Key Master.
create or replace function rc_private.customer_tanpa_depot()
 returns jsonb
 language sql
 stable
 security definer
 set search_path to ''
as $function$
  -- 20261163090000
  select case when not rc_private.can_access(null,'manage_key_master') then jsonb_build_object('jumlah',0,'kode','[]'::jsonb)
    else jsonb_build_object(
      'jumlah', (select count(*) from public.customers c where c.archived_at is null
                  and not exists(select 1 from public.customer_depots d where d.customer_id = c.id)),
      'kode', coalesce((select jsonb_agg(x.customer_code || ' - ' || x.customer_name order by x.customer_code) from (
                select c.customer_code, c.customer_name from public.customers c where c.archived_at is null
                   and not exists(select 1 from public.customer_depots d where d.customer_id = c.id)
                 order by c.customer_code limit 20) x), '[]'::jsonb)) end;
$function$;
revoke all on function rc_private.customer_tanpa_depot() from public, anon;
grant execute on function rc_private.customer_tanpa_depot() to authenticated, service_role;

-- ---- Tambalan berpenjaga MD5 ---------------------------------------------------------------
do $tambal$
declare f record; r record; src text; baru text; n int;
begin
  create temp table _tambal(urut serial, sig text, harapan text, lama text, ganti text, n int) on commit drop;
  insert into _tambal(sig, harapan, lama, ganti, n) values
  ('public.rc_customer_list(text,integer,integer)', '3da2c436353fc57d13de29915f1e3b07',
   $p$ return jsonb_build_object('status','success','rows',v,$p$,
   $p$ return jsonb_build_object('status','success','rows',v,'tanpaDepot',rc_private.customer_tanpa_depot() /* 20261163090000 */,$p$, 1),

  ('public.rc_campaign_list(text,integer,integer)', '1ba17cfb5a34ec59078f87715f9d056f',
   $p$  'total',(select count(*) from public.campaigns where archived_at is null));$p$,
   $p$  'total',(select count(*) from public.campaigns ca where ca.archived_at is null /* 20261163090000: mengikuti pencarian */
     and (coalesce(btrim(p_search),'')='' or ca.campaign_code ilike '%'||btrim(p_search)||'%'
          or ca.campaign_name ilike '%'||btrim(p_search)||'%')));$p$, 1),

  ('public.rc_depot_list(text,integer,integer)', 'd9c348b981a5dbc5513f85ed1bf0f59e',
   $p$    'bolehLangsung', rc_private.can_tab('access.req') /* 20261162130000 */,$p$,
   $p$    'bolehLangsung', rc_private.can_tab('access.req') /* 20261162130000 */,
    'tanpaAbbr', coalesce((select jsonb_agg(x.depot_code order by x.depot_code) from public.depots x
       where x.archived_at is null and coalesce(btrim(x.abbr),'') = ''), '[]'::jsonb) /* 20261163090000 */,$p$, 1),

  ('public.rc_depot_upsert(jsonb)', 'bac7b11f9bed38cc8a2c48ff96e5308c',
   $p$declare r jsonb; v_kode text; n_baru integer := 0; n_ubah integer := 0; salah text[] := '{}';$p$,
   $p$declare r jsonb; v_kode text; n_baru integer := 0; n_ubah integer := 0; salah text[] := '{}';
  v_abbr text; -- 20261163090000$p$, 1),
  ('public.rc_depot_upsert(jsonb)', 'bac7b11f9bed38cc8a2c48ff96e5308c',
   $p$    if exists(select 1 from public.depots where depot_code=v_kode) then$p$,
   $p$    -- 20261163090000: Abbr diperiksa per baris, bukan lewat constraint yang menggagalkan
    -- seluruh unggahan. Abbr dipakai pada No Doc, jadi formatnya dijaga dan tidak boleh kembar.
    v_abbr := upper(btrim(coalesce(r->>'abbr','')));
    if v_abbr <> '' and v_abbr !~ '^[A-Z0-9]{2,10}$' then
      salah := salah || (v_kode||': Abbr "'||v_abbr||'" harus 2-10 huruf atau angka'); continue; end if;
    if v_abbr <> '' and exists(select 1 from public.depots where abbr = v_abbr and depot_code <> v_kode) then
      salah := salah || (v_kode||': Abbr "'||v_abbr||'" sudah dipakai depot '
        ||(select depot_code from public.depots where abbr = v_abbr and depot_code <> v_kode limit 1)); continue; end if;

    if exists(select 1 from public.depots where depot_code=v_kode) then$p$, 1),
  ('public.rc_depot_upsert(jsonb)', 'bac7b11f9bed38cc8a2c48ff96e5308c',
   $p$        abbr         = case when r ? 'abbr'   then nullif(upper(btrim(coalesce(r->>'abbr',''))),'') else abbr end,$p$,
   $p$        abbr         = case when v_abbr <> '' then v_abbr else abbr end, /* 20261163090000: kosong = tetap */$p$, 1),
  ('public.rc_depot_upsert(jsonb)', 'bac7b11f9bed38cc8a2c48ff96e5308c',
   $p$        salah := salah || (v_kode||': depot baru wajib punya nama'); continue; end if;$p$,
   $p$        salah := salah || (v_kode||': depot baru wajib punya nama'); continue; end if;
      if v_abbr = '' then
        salah := salah || (v_kode||': depot baru wajib punya Abbr (dipakai pada No Doc; tanpa Abbr compile ditolak)'); continue; end if;$p$, 1),
  ('public.rc_depot_upsert(jsonb)', 'bac7b11f9bed38cc8a2c48ff96e5308c',
   $p$      values(v_kode, btrim(r->>'nama'), nullif(upper(btrim(coalesce(r->>'abbr',''))),''),$p$,
   $p$      values(v_kode, btrim(r->>'nama'), v_abbr,$p$, 1);

  for f in select sig, min(harapan) harapan from _tambal group by sig order by min(urut) loop
    src := pg_get_functiondef(to_regprocedure(f.sig));
    if src is null then raise exception 'DITOLAK: fungsi % tidak ada.', f.sig; end if;
    if src ~ '20261163090000' then raise notice '% sudah ditambal.', f.sig; continue; end if;
    if md5(replace(src, E'\r', '')) <> f.harapan then
      raise exception 'DITOLAK: definisi % berbeda dari yang diukur (md5 %).', f.sig, md5(replace(src, E'\r', '')); end if;
    baru := replace(src, E'\r', '');
    for r in select * from _tambal where sig = f.sig order by urut loop
      n := (length(baru) - length(replace(baru, r.lama, ''))) / length(r.lama);
      if n <> r.n then
        raise exception '%: pola "%" ditemukan % kali, diharapkan %.', f.sig, left(r.lama, 80), n, r.n; end if;
      baru := replace(baru, r.lama, r.ganti);
    end loop;
    execute baru;
  end loop;
end
$tambal$;

-- ---- Document Center: filter Created On ----------------------------------------------------
drop function if exists public.rc_compilation_list(text, text, text, text, integer, integer, text);
create or replace function public.rc_compilation_list(p_campaign text DEFAULT ''::text, p_batch text DEFAULT ''::text, p_status text DEFAULT ''::text, p_search text DEFAULT ''::text, p_offset integer DEFAULT 0, p_limit integer DEFAULT 100, p_depot text DEFAULT ''::text, p_dibuat_dari date DEFAULT NULL::date, p_dibuat_sampai date DEFAULT NULL::date)
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
-- 20261163090000: p_dibuat_dari / p_dibuat_sampai = tanggal Created On (Asia/Jakarta, inklusif).
declare v jsonb; jml bigint;
 v_cari text := btrim(coalesce(p_search,'')); v_ids uuid[];
 v_dari timestamptz := case when p_dibuat_dari is null then null else p_dibuat_dari::timestamp at time zone 'Asia/Jakarta' end;
 v_sampai timestamptz := case when p_dibuat_sampai is null then null else (p_dibuat_sampai + 1)::timestamp at time zone 'Asia/Jakarta' end;
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
    and (v_dari is null or c.created_at >= v_dari)
    and (v_sampai is null or c.created_at < v_sampai)
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
    and (v_dari is null or c.created_at >= v_dari)
    and (v_sampai is null or c.created_at < v_sampai)
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
revoke all on function public.rc_compilation_list(text, text, text, text, integer, integer, text, date, date) from public, anon;
grant execute on function public.rc_compilation_list(text, text, text, text, integer, integer, text, date, date) to authenticated, service_role;

notify pgrst, 'reload schema';

-- ------------------------------------------------------------------------------------------
-- Pemeriksaan (dibatalkan seluruhnya)
-- ------------------------------------------------------------------------------------------
do $uji$
declare v_sm uuid; r jsonb; l jsonb; e text := ''; d1 record; d2 record; v_hari date; n bigint; v_galat text;
begin
  select id into v_sm from public.profiles where role = 'system manager' and status = 'active' and not must_change_password order by user_code limit 1;
  if v_sm is null then raise notice 'Tidak ada System Manager aktif; uji dilewati.'; return; end if;
  select depot_code into d1 from public.depots where archived_at is null and abbr is not null order by depot_code limit 1;
  select depot_code into d2 from public.depots where archived_at is null and abbr is not null order by depot_code offset 1 limit 1;
  perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);

  -- Customer baru dengan Kode Depot: tersimpan DAN terlihat.
  begin
    execute 'set local role authenticated';
    r := public.rc_customer_upsert(jsonb_build_array(jsonb_build_object('custCode','UJIKD01','custName','TOKO UJI KODE DEPOT',
           'kodeDepot', d1.depot_code || ', ' || d2.depot_code)));
    l := public.rc_customer_list('UJIKD01', 0, 50);
    if (r->>'dibuat')::int <> 1 or (l->>'total')::int <> 1
       or (l->'rows'->0->'depotCodes') <> jsonb_build_array(d1.depot_code, d2.depot_code) then
      e := e || format(' customer baru: simpan %s, daftar %s;', r, l->'rows'->0->'depotCodes'); end if;
    -- Ubah: Kode Depot menjadi satu depot -> kaitan depot kedua dilepas.
    r := public.rc_customer_upsert(jsonb_build_array(jsonb_build_object('custCode','UJIKD01','kodeDepot', d2.depot_code)));
    l := public.rc_customer_list('UJIKD01', 0, 50);
    if (l->'rows'->0->'depotCodes') <> jsonb_build_array(d2.depot_code) then e := e || format(' ubah kode depot: %s;', l->'rows'->0->'depotCodes'); end if;
    -- Kosong pada ubah: kaitan tetap.
    r := public.rc_customer_upsert(jsonb_build_array(jsonb_build_object('custCode','UJIKD01','kodeDepot','','top','45')));
    l := public.rc_customer_list('UJIKD01', 0, 50);
    if (l->'rows'->0->'depotCodes') <> jsonb_build_array(d2.depot_code) or (l->'rows'->0->>'top') <> '45' then
      e := e || format(' kode depot kosong mengubah kaitan: %s;', l->'rows'->0); end if;
    execute 'reset role';
    raise exception 'UJI_SELESAI';
  exception when others then if sqlerrm <> 'UJI_SELESAI' then e := e || ' customer: ' || sqlerrm || ';'; end if;
  end;
  -- Customer baru tanpa Kode Depot / kode tak dikenal: ditolak dengan pesan jelas.
  begin
    execute 'set local role authenticated';
    begin
      r := public.rc_customer_upsert('[{"custCode":"UJIKD02","custName":"TANPA DEPOT"}]'::jsonb);
      e := e || ' customer tanpa depot diterima;';
    exception when others then v_galat := sqlerrm;
      if v_galat !~ 'Kode Depot wajib diisi untuk customer baru' then e := e || ' pesan tanpa depot: ' || v_galat || ';'; end if;
    end;
    begin
      r := public.rc_customer_upsert('[{"custCode":"UJIKD03","custName":"DEPOT SALAH","kodeDepot":"ZZQX9"}]'::jsonb);
      e := e || ' kode depot tak dikenal diterima;';
    exception when others then v_galat := sqlerrm;
      if v_galat !~ 'tidak ada di Depot Master' then e := e || ' pesan kode salah: ' || v_galat || ';'; end if;
    end;
    execute 'reset role';
    raise exception 'UJI_SELESAI';
  exception when others then if sqlerrm <> 'UJI_SELESAI' then e := e || ' customer tolak: ' || sqlerrm || ';'; end if;
  end;
  -- Customer lama tanpa depot dipulihkan dengan menyimpan ulang kodenya + Kode Depot.
  begin
    n := (rc_private.customer_tanpa_depot()->>'jumlah')::bigint;
    insert into public.customers(customer_code, customer_name) values ('UJIKD04', 'TOKO TERSEMBUNYI');
    execute 'set local role authenticated';
    l := public.rc_customer_list('UJIKD04', 0, 50);
    if (l->>'total')::int <> 0 or (l->'tanpaDepot'->>'jumlah')::bigint <> n + 1 then
      e := e || format(' peringatan tanpa depot: %s;', l->'tanpaDepot'); end if;
    r := public.rc_customer_upsert(jsonb_build_array(jsonb_build_object('custCode','UJIKD04','kodeDepot', d1.depot_code)));
    l := public.rc_customer_list('UJIKD04', 0, 50);
    if (l->>'total')::int <> 1 or jsonb_array_length(r->'tanpaDepot') <> 0 then e := e || format(' pulihkan: %s / %s;', r, l->>'total'); end if;
    execute 'reset role';
    raise exception 'UJI_SELESAI';
  exception when others then if sqlerrm <> 'UJI_SELESAI' then e := e || ' pulihkan: ' || sqlerrm || ';'; end if;
  end;

  -- Campaign: total mengikuti pencarian.
  begin
    execute 'set local role authenticated';
    l := public.rc_campaign_list((select campaign_code from public.campaigns where archived_at is null order by campaign_code limit 1), 0, 50);
    if (l->>'total')::int <> jsonb_array_length(l->'rows') then e := e || format(' total campaign %s, baris %s;', l->>'total', jsonb_array_length(l->'rows')); end if;
    execute 'reset role';
    raise exception 'UJI_SELESAI';
  exception when others then if sqlerrm <> 'UJI_SELESAI' then e := e || ' campaign: ' || sqlerrm || ';'; end if;
  end;

  -- Depot: baru tanpa Abbr / Abbr salah format / Abbr kembar ditolak per baris; yang sah tetap masuk.
  begin
    execute 'set local role authenticated';
    r := public.rc_depot_upsert(jsonb_build_array(
      jsonb_build_object('kode','ZQ1','nama','UJI TANPA ABBR'),
      jsonb_build_object('kode','ZQ2','nama','UJI ABBR SALAH','abbr','A'),
      jsonb_build_object('kode','ZQ3','nama','UJI ABBR KEMBAR','abbr',(select abbr from public.depots where depot_code = d1.depot_code)),
      jsonb_build_object('kode','ZQ4','nama','UJI SAH','abbr','ZQU4')));
    if (r->>'baru')::int <> 1 or (r->>'ditolak')::int <> 3
       or not exists(select 1 from jsonb_array_elements_text(r->'pesanDitolak') x where x ~ 'wajib punya Abbr')
       or not exists(select 1 from jsonb_array_elements_text(r->'pesanDitolak') x where x ~ 'harus 2-10')
       or not exists(select 1 from jsonb_array_elements_text(r->'pesanDitolak') x where x ~ 'sudah dipakai depot') then
      e := e || format(' depot: %s;', r); end if;
    -- Abbr kosong pada ubah tidak menghapus Abbr yang ada.
    r := public.rc_depot_upsert(jsonb_build_array(jsonb_build_object('kode', d1.depot_code, 'abbr', '')));
    if (select abbr from public.depots where depot_code = d1.depot_code) is null then e := e || ' Abbr terhapus oleh kolom kosong;'; end if;
    l := public.rc_depot_list(null, 0, 1);
    if l->'tanpaAbbr' is null then e := e || ' tanpaAbbr tidak dikirim;'; end if;
    execute 'reset role';
    raise exception 'UJI_SELESAI';
  exception when others then if sqlerrm <> 'UJI_SELESAI' then e := e || ' depot: ' || sqlerrm || ';'; end if;
  end;

  -- Document Center: filter Created On (inklusif, Asia/Jakarta).
  begin
    select (created_at at time zone 'Asia/Jakarta')::date into v_hari from public.claims where archived_at is null order by created_at desc limit 1;
    execute 'set local role authenticated';
    r := public.rc_compilation_list(p_dibuat_dari => v_hari, p_dibuat_sampai => v_hari, p_limit => 500);
    select count(*) into n from public.claims c join public.campaigns ca on ca.id = c.campaign_id join public.depots dp on dp.id = c.depot_id
     where (c.created_at at time zone 'Asia/Jakarta')::date = v_hari;
    if (r->>'total')::bigint <> n or exists(select 1 from jsonb_array_elements(r->'rows') x where x->>'createdOn' <> to_char(v_hari, 'DD-Mon-YYYY')) then
      e := e || format(' created on %s: total %s, harap %s;', v_hari, r->>'total', n); end if;
    r := public.rc_compilation_list(p_dibuat_dari => v_hari + 1);
    if (r->>'total')::bigint <> (select count(*) from public.claims c join public.campaigns ca on ca.id = c.campaign_id join public.depots dp on dp.id = c.depot_id
                                  where (c.created_at at time zone 'Asia/Jakarta')::date > v_hari) then e := e || ' created on dari besok salah;'; end if;
    execute 'reset role';
    raise exception 'UJI_SELESAI';
  exception when others then if sqlerrm <> 'UJI_SELESAI' then e := e || ' created on: ' || sqlerrm || ';'; end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  if e <> '' then raise exception 'GAGAL:%', e; end if;
end
$uji$;
