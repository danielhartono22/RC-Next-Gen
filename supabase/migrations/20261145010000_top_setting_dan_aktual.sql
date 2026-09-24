-- ==========================================================================================
-- TOP Setting dan TOP Actual dipisahkan, dan Overdue diukur dari selisihnya
-- ==========================================================================================
-- Pemilik bertanya: "ini kok top 120 hari ga masuk overdue apa karena di masternya memang
-- < 120 hari?" Jawabannya tidak - dan sebabnya justru sebuah cacat.
--
-- ------------------------------------------------------------------------------------------
-- TEMUANNYA: UNGGAHAN MENIMPA CUSTOMER MASTER
-- ------------------------------------------------------------------------------------------
-- rc_private.mutate_claims_unchecked, pada tahap submit, menulis TOP yang diketik depot KEMBALI
-- ke public.customers.top_text. Jadi begitu sebuah dokumen dengan TOP 120 diunggah, TOP pada
-- Customer Master pelanggan itu ikut berubah menjadi 120.
--
-- Terukur pada kesebelas dokumen yang sedang menunggu persetujuan: top_aktual dan top_master
-- SAMA PERSIS di setiap baris, termasuk dua dokumen ber-TOP 120. Keduanya memang tidak pernah
-- berbeda - bukan karena disepakati sama, melainkan karena yang satu menimpa yang lain.
--
-- Akibatnya perbandingan yang justru menjadi inti persetujuan - "apakah TOP yang diminta
-- melebihi yang disepakati?" - selalu menjawab tidak. Setiap permintaan membenarkan dirinya
-- sendiri dengan cara menulis ulang acuannya.
--
-- Penimpaan itu dihentikan di sini. TOP pada Customer Master adalah KESEPAKATAN, dan sebuah
-- dokumen tidak berwenang mengubahnya; kalau memang perlu berubah, tempatnya Key Master.
-- Nomor rekening, nama rekening dan bank TETAP diperbarui dari unggahan seperti semula -
-- ketiganya memang data mutakhir pelanggan, bukan kesepakatan.
--
-- ------------------------------------------------------------------------------------------
-- WITHIN PAYMENT TERM DIUKUR DARI KESEPAKATAN, BUKAN DARI UMUR DOKUMEN
-- ------------------------------------------------------------------------------------------
-- Aturan sebelumnya membandingkan umur dokumen terhadap TOP. Dengan itu, TOP 120 pada dokumen
-- yang baru diunggah tidak pernah Overdue - dan memang itulah yang dilihat pemilik.
--
-- Aturannya kini mengikuti arti namanya. "Within Payment Term" berarti TOP yang DIMINTA masih
-- di dalam tempo yang disepakati:
--
--   WPT : TOP Actual <= TOP Setting   (atau tidak diisi, sehingga memakai Setting apa adanya)
--   OVD : TOP Actual >  TOP Setting
--
-- Pembagian itu sekaligus menjelaskan pembagian kewenangannya: Depot Head menyetujui yang masih
-- di dalam tempo, sedangkan yang MELEBIHI tempo memerlukan Management. Dengan aturan lama,
-- pembagian itu tidak berarti apa-apa - tab Overdue hanya akan terisi oleh dokumen yang
-- kebetulan lama tergeletak, bukan oleh dokumen yang memang meminta kelonggaran.
--
-- ------------------------------------------------------------------------------------------
-- TOP TIDAK LAGI WAJIB DIISI
-- ------------------------------------------------------------------------------------------
-- "kolom top pada upload biarkan kosong". Dibiarkan kosong berarti tidak ada permintaan
-- kelonggaran: dokumen memakai TOP Setting apa adanya, dan otomatis Within Payment Term.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

-- ------------------------------------------------------------------------------------------
-- 1. Unggahan berhenti menimpa TOP pada Customer Master
-- ------------------------------------------------------------------------------------------
do $mig$
declare src text; baru text;
begin
  select pg_get_functiondef(p.oid) into src from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='rc_private' and p.proname='mutate_claims_unchecked';
  if src is null then raise exception 'rc_private.mutate_claims_unchecked tidak ditemukan.'; end if;

  if position($q$top_text=coalesce(v_top,top_text)$q$ in src) = 0 then
    raise notice 'Penimpaan TOP sudah dihentikan; dilewati.';
  else
    baru := replace(src,
      $q$  if master_changed or (v_top is not null and v_top is distinct from nullif(btrim(coalesce(cust.top_text,'')),'')) then$q$,
      $q$  -- TOP TIDAK lagi ikut diperbarui dari unggahan: ia kesepakatan, bukan data mutakhir,$q$ || chr(10) ||
      $q$  -- dan dokumen yang menulis ulang acuannya sendiri membuat persetujuan kehilangan arti.$q$ || chr(10) ||
      $q$  if master_changed then$q$);
    baru := replace(baru,
      $q$    top_text=coalesce(v_top,top_text),updated_at=now(),updated_by=actor$q$,
      $q$    updated_at=now(),updated_by=actor$q$);
    if baru = src then
      raise exception 'Pola penimpaan TOP tidak ditemukan. Sumbernya sudah berubah - periksa migration ini.';
    end if;
    execute baru;
    raise notice 'Unggahan tidak lagi menimpa TOP pada Customer Master.';
  end if;
end
$mig$;

-- ------------------------------------------------------------------------------------------
-- 2. Overdue diukur dari TOP Actual terhadap TOP Setting
-- ------------------------------------------------------------------------------------------
drop function if exists rc_private.approval_overdue(timestamptz, text);
create or replace function rc_private.approval_overdue(p_aktual text, p_setting text)
returns boolean language sql immutable set search_path='' as $fn$
  -- Keduanya diangkakan lebih dulu. TOP yang bukan angka - kosong, "COD", "-" - tidak pernah
  -- menjadikan dokumen Overdue: yang datanya belum rapi tidak boleh terlempar ke antrean yang
  -- lebih ketat hanya karena ketidakrapiannya. Kekurangannya terlihat di kolom TOP pada
  -- rincian, dan di situlah tempat memperbaikinya.
  select case
    when btrim(coalesce(p_aktual,''))  !~ '^[0-9]+([.][0-9]+)?$' then false
    when btrim(coalesce(p_setting,'')) !~ '^[0-9]+([.][0-9]+)?$' then false
    else btrim(p_aktual)::numeric > btrim(p_setting)::numeric
  end;
$fn$;
revoke all on function rc_private.approval_overdue(text, text) from public, anon;
grant execute on function rc_private.approval_overdue(text, text) to authenticated;

-- ------------------------------------------------------------------------------------------
-- 3. Kedua TOP dibawa terpisah sampai ke layar
-- ------------------------------------------------------------------------------------------
-- View-nya dibuat ulang, bukan diganti isinya: create or replace tidak dapat mengganti NAMA
-- kolom, dan kolom top_text kini terbelah menjadi dua.
drop view if exists rc_private.approval_rows;
create view rc_private.approval_rows as
  select c.id, c.no_doc, c.depot_id, c.batch_upload, c.uploaded_at, c.cb_net,
         c.tax_subject, c.status, c.version_no,
         cu.customer_code, cu.customer_name,
         ca.campaign_code, ca.campaign_name, ca.tax_status,
         -- Setting: kesepakatan pada Customer Master. Actual: yang diketik depot pada dokumen
         -- ini. Keduanya TIDAK digabung - perbandingannya justru inti dari persetujuan.
         nullif(btrim(coalesce(cu.top_text,'')),'')            as top_setting,
         nullif(btrim(coalesce(s.top_text,'')),'')             as top_aktual,
         rc_private.jenis_efektif(ca.cashback_type) as jenis_cb,
         coalesce(ca.cashback_type,'') as jenis_cb_label,
         c.submitted_by, c.approved_by, c.approved_at
    from public.claims c
    join public.customers cu on cu.id = c.customer_id
    join public.campaigns ca on ca.id = c.campaign_id
    left join rc_private.claim_sensitive s on s.claim_id = c.id
   where c.status = 'submitted' and c.archived_at is null;

revoke all on rc_private.approval_rows from public, anon;
grant select on rc_private.approval_rows to authenticated;

-- ------------------------------------------------------------------------------------------
-- 4. Antrean dan rincian memakai perbandingan itu
-- ------------------------------------------------------------------------------------------
create or replace function public.rc_approval_batches(p_kind text default 'wpt',
                                                      p_depot text default null)
returns jsonb language plpgsql stable set search_path='' as $fn$
declare v_ovd boolean; v_depot text; hasil jsonb;
begin
  if not rc_private.can_access(null,'approve_claim') and not rc_private.is_system_manager() then
    raise exception 'Tidak punya hak menyetujui dokumen' using errcode='42501'; end if;
  v_ovd := lower(coalesce(p_kind,'wpt')) = 'ovd';
  if v_ovd and not rc_private.boleh_approve_overdue() then
    raise exception 'Depot Head hanya dapat menyetujui dokumen Within Payment Term'
      using errcode='42501'; end if;
  v_depot := nullif(btrim(coalesce(p_depot,'')),'');

  select jsonb_build_object('status','success','kind', case when v_ovd then 'ovd' else 'wpt' end,
    'rows', coalesce(jsonb_agg(jsonb_build_object(
      'noBatch', t.batch, 'kodeDepot', t.depot_code, 'namaDepot', t.depot_name,
      'qtyDoc', t.qty_doc, 'qtyCust', t.qty_cust,
      'qtyCampaign', t.qty_camp, 'totalNetCb', t.net_cb,
      'submittedBy', t.submitted_by, 'postingDate', t.posting_date)
      order by t.posting_date desc nulls last, t.batch), '[]'::jsonb))
  into hasil
  from (
    select coalesce(nullif(btrim(r.batch_upload),''),'(tanpa batch)') batch,
           coalesce(d.depot_code,'-') depot_code,
           coalesce(d.depot_name,'-') depot_name,
           count(*) qty_doc,
           count(distinct r.customer_code) qty_cust,
           count(distinct r.campaign_code) qty_camp,
           coalesce(sum(r.cb_net),0) net_cb,
           coalesce(string_agg(distinct p.full_name, ', '),'-') submitted_by,
           to_char(max(r.uploaded_at) at time zone 'Asia/Jakarta','DD-Mon-YYYY') posting_date
      from rc_private.approval_rows r
      left join public.profiles p on p.id = r.submitted_by
      left join public.depots d on d.id = r.depot_id
     where rc_private.can_access(r.depot_id,'approve_claim')
       and rc_private.approval_overdue(r.top_aktual, r.top_setting) = v_ovd
       and (v_depot is null or d.depot_code = v_depot)
     group by 1,2,3) t;
  return hasil;
end $fn$;
revoke all on function public.rc_approval_batches(text,text) from public, anon;
grant execute on function public.rc_approval_batches(text,text) to authenticated;

create or replace function public.rc_approval_detail(p_batch text, p_kind text default 'wpt')
returns jsonb language plpgsql stable set search_path='' as $fn$
declare v_ovd boolean; hasil jsonb;
begin
  if not rc_private.can_access(null,'approve_claim') and not rc_private.is_system_manager() then
    raise exception 'Tidak punya hak menyetujui dokumen' using errcode='42501'; end if;
  v_ovd := lower(coalesce(p_kind,'wpt')) = 'ovd';
  if v_ovd and not rc_private.boleh_approve_overdue() then
    raise exception 'Depot Head hanya dapat menyetujui dokumen Within Payment Term'
      using errcode='42501'; end if;

  select jsonb_build_object('status','success','noBatch',p_batch,
    'rows', coalesce(jsonb_agg(jsonb_build_object(
      'noDoc', r.no_doc, 'versionNo', r.version_no,
      'kodeCust', r.customer_code, 'namaCust', r.customer_name,
      'kodeCampaign', r.campaign_code, 'namaCampaign', coalesce(r.campaign_name,''),
      'netCb', r.cb_net, 'jenisCb', r.jenis_cb_label,
      'topSetting', coalesce(r.top_setting,''),
      'topAktual', coalesce(r.top_aktual,''),
      -- Selisihnya dihitung sekali di sini supaya layar tidak perlu menghitung ulang dan
      -- berisiko memakai aturan yang berbeda.
      'topSelisih', case
        when r.top_aktual ~ '^[0-9]+([.][0-9]+)?$' and r.top_setting ~ '^[0-9]+([.][0-9]+)?$'
        then r.top_aktual::numeric - r.top_setting::numeric else null end,
      'statusPajak', coalesce(r.tax_subject,''),
      'statusPajakCampaign', coalesce(r.tax_status,''),
      'submittedBy', coalesce(ps.full_name,''),
      'postingDate', to_char(r.uploaded_at at time zone 'Asia/Jakarta','DD-Mon-YYYY'),
      'approvedBy', coalesce(pa.full_name,''),
      'approvedAt', to_char(r.approved_at at time zone 'Asia/Jakarta','DD-Mon-YYYY HH24:MI'),
      'overdue', rc_private.approval_overdue(r.top_aktual, r.top_setting))
      order by r.no_doc), '[]'::jsonb))
  into hasil
  from rc_private.approval_rows r
  left join public.profiles ps on ps.id = r.submitted_by
  left join public.profiles pa on pa.id = r.approved_by
  where coalesce(nullif(btrim(r.batch_upload),''),'(tanpa batch)') = coalesce(p_batch,'')
    and rc_private.can_access(r.depot_id,'approve_claim')
    and rc_private.approval_overdue(r.top_aktual, r.top_setting) = v_ovd;
  return hasil;
end $fn$;
revoke all on function public.rc_approval_detail(text, text) from public, anon;
grant execute on function public.rc_approval_detail(text, text) to authenticated;

-- ------------------------------------------------------------------------------------------
-- Pemeriksaan
-- ------------------------------------------------------------------------------------------
do $periksa$
declare src text; v_uid uuid; b jsonb; d jsonb; v_batch text;
begin
  -- Aturannya benar-benar membandingkan kedua TOP.
  if not rc_private.approval_overdue('120','60') then
    raise exception 'GAGAL: TOP 120 atas setting 60 seharusnya Overdue.'; end if;
  if rc_private.approval_overdue('60','60') then
    raise exception 'GAGAL: TOP sama dengan setting seharusnya WPT.'; end if;
  if rc_private.approval_overdue('30','60') then
    raise exception 'GAGAL: TOP di bawah setting seharusnya WPT.'; end if;
  if rc_private.approval_overdue('','60') then
    raise exception 'GAGAL: TOP kosong seharusnya WPT.'; end if;
  if rc_private.approval_overdue('120','') then
    raise exception 'GAGAL: setting kosong seharusnya tidak menjadikan Overdue.'; end if;

  -- Unggahan tidak lagi menimpa TOP master.
  select pg_get_functiondef(p.oid) into src from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='rc_private' and p.proname='mutate_claims_unchecked';
  if position($q$top_text=coalesce(v_top,top_text)$q$ in src) > 0 then
    raise exception 'GAGAL: unggahan masih menimpa TOP pada Customer Master.'; end if;
  -- Data mutakhir pelanggan TETAP diperbarui; yang dicabut hanya TOP.
  if position($q$account_number=v_norek$q$ in src) = 0 then
    raise exception 'GAGAL: pembaruan rekening ikut hilang.'; end if;

  select id into v_uid from public.profiles
   where lower(coalesce(role,'')) like '%system%' and coalesce(status,'')='active'
   order by user_code limit 1;

  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_uid::text,'role','authenticated')::text, true);
  b := public.rc_approval_batches('wpt', null);
  v_batch := b->'rows'->0->>'noBatch';
  if v_batch is not null then
    d := public.rc_approval_detail(v_batch, 'wpt');
    if not ((d->'rows'->0) ? 'topSetting' and (d->'rows'->0) ? 'topAktual') then
      reset role;
      raise exception 'GAGAL: rincian tidak membawa TOP Setting dan TOP Actual terpisah.';
    end if;
  end if;
  reset role;

  raise notice 'Batch WPT: %', jsonb_array_length(b->'rows');
  raise notice 'Pemeriksaan lolos.';
exception when others then
  reset role; raise;
end
$periksa$;
