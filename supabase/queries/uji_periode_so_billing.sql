-- ==========================================================================================
-- UJI (tidak menyimpan apa pun): periode SO/Billing pada Campaign Master dan turunannya
-- ==========================================================================================
-- Menempuh rantai penuh sebagai System Manager sungguhan lewat klaim JWT:
--
--   Campaign Master ditulis -> terbaca di daftar -> menjadi dasar Reprocessing dan Document
--   Center -> menjadi penyaring di Report.
--
-- Berkas ini SELALU berakhir dengan raise exception, jadi seluruh perubahannya dibatalkan.
-- Jalankan: node scripts/apply-sql.mjs supabase/queries/uji_periode_so_billing.sql
-- ==========================================================================================
do $uji$
declare
  v_uid uuid; kode text; v_doc text; v_ver bigint; h jsonb; baris jsonb;
  n_semua int; n_saring int; v_lolos int := 0;
begin
  select id into v_uid from public.profiles
   where lower(coalesce(role,'')) like '%system%' and coalesce(status,'')='active'
   order by user_code limit 1;

  -- Dipilih campaign yang BENAR-BENAR dipakai dokumen On Hold, supaya rantainya dapat ditempuh
  -- sampai ke layar Reprocessing.
  -- Dokumen On Hold sering tidak ada - sejak alur hold memakai pending_approval, antreannya
  -- kerap kosong. Uji ini karena itu MENCIPTAKAN keadaannya sendiri di dalam transaksi yang
  -- dibatalkan, bukan menunggu kebetulan: penyaring yang hanya diuji ketika datanya kebetulan
  -- ada adalah penyaring yang tidak pernah benar-benar diuji.
  select ca.campaign_code, c.no_doc, c.version_no into kode, v_doc, v_ver
    from public.claims c join public.campaigns ca on ca.id = c.campaign_id
   where c.status='on_hold' and c.archived_at is null and c.pending_approval is null
   order by c.no_doc limit 1;

  if v_doc is null then
    select ca.campaign_code, c.no_doc, c.version_no into kode, v_doc, v_ver
      from public.claims c join public.campaigns ca on ca.id = c.campaign_id
     where c.archived_at is null and c.previous_status is null
     order by c.no_doc limit 1;
    if v_doc is not null then
      update public.claims set status='on_hold', previous_status='not_yet',
             pending_approval=null
       where no_doc = v_doc;
      raise notice 'Dokumen % ditahan sementara untuk keperluan uji.', v_doc;
    end if;
  end if;

  if kode is null then
    select campaign_code into kode from public.campaigns where archived_at is null
     order by campaign_code limit 1;
  end if;
  if kode is null then raise exception 'Tidak ada campaign untuk diuji.'; end if;
  raise notice 'Campaign uji: %  | dokumen On Hold: %', kode, coalesce(v_doc,'(tidak ada)');

  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_uid::text,'role','authenticated')::text, true);

  -- ---- 1. Keempat periode tersimpan dari bentuk resmi RC ---------------------------------
  perform public.rc_campaign_upsert(jsonb_build_array(jsonb_build_object(
    'codeCampaign', kode,
    'soStart','05-01-2026','soEnd','25-03-2026',
    'billingStart','10.02.2026','billingEnd','15042026')));
  if not exists (select 1 from public.campaigns where campaign_code=kode
                  and so_start='2026-01-05' and so_end='2026-03-25'
                  and billing_start='2026-02-10' and billing_end='2026-04-15') then
    reset role; raise exception 'GAGAL: keempat periode tidak tersimpan dengan benar.'; end if;
  v_lolos := v_lolos + 1;
  raise notice 'OK  1. dd-mm-yyyy, dd.mm.yyyy dan ddmmyyyy sama-sama terurai';

  -- ---- 2. Terbaca kembali lewat daftar Campaign Master -----------------------------------
  h := public.rc_campaign_list(kode, 0, 5);
  select x into baris from jsonb_array_elements(h->'rows') x where x->>'codeCampaign' = kode;
  if baris is null then reset role; raise exception 'GAGAL: campaign tidak ada di daftar.'; end if;
  if coalesce(baris->>'soStart','')='' or coalesce(baris->>'billingEnd','')='' then
    reset role; raise exception 'GAGAL: daftar tidak membawa periode barunya.'; end if;
  v_lolos := v_lolos + 1;
  raise notice 'OK  2. Daftar membawa SO % s/d % dan Billing % s/d %',
    baris->>'soStart', baris->>'soEnd', baris->>'billingStart', baris->>'billingEnd';

  -- ---- 3. Periode terbalik ditolak --------------------------------------------------------
  begin
    perform public.rc_campaign_upsert(jsonb_build_array(jsonb_build_object(
      'codeCampaign', kode, 'soStart','25-03-2026','soEnd','05-01-2026')));
    reset role; raise exception 'GAGAL: periode SO terbalik diterima.';
  exception when others then
    if sqlerrm like 'GAGAL:%' then raise; end if;
    v_lolos := v_lolos + 1;
    raise notice 'OK  3. Periode terbalik ditolak';
  end;

  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_uid::text,'role','authenticated')::text, true);

  -- ---- 4. Reprocessing memakai periode master bila dokumen tidak memperpanjang -----------
  if v_doc is not null then
    reset role;
    update public.claims set extend_so_start=null, extend_so_end=null,
           extend_billing_start=null, extend_billing_end=null
     where no_doc = v_doc;
    set local role authenticated;
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_uid::text,'role','authenticated')::text, true);
    h := public.rc_reprocessing_list('', 0, 200);
    select x into baris from jsonb_array_elements(h->'rows') x where x->>'noDoc' = v_doc;
    if baris is null then
      reset role; raise exception 'GAGAL: dokumen % tidak ada di Reprocessing.', v_doc; end if;
    if coalesce(baris->>'soStart','') <> '2026-01-05' then
      reset role; raise exception 'GAGAL: Reprocessing soStart = %, seharusnya periode master.',
        coalesce(baris->>'soStart','(kosong)'); end if;
    v_lolos := v_lolos + 1;
    raise notice 'OK  4. Reprocessing memakai periode master: SO % s/d %',
      baris->>'soStart', baris->>'soEnd';

    -- Dan perpanjangan pada dokumen tetap MENIMPA master.
    reset role;
    update public.claims set extend_so_start='2026-06-01' where no_doc = v_doc;
    set local role authenticated;
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_uid::text,'role','authenticated')::text, true);
    h := public.rc_reprocessing_list('', 0, 200);
    select x into baris from jsonb_array_elements(h->'rows') x where x->>'noDoc' = v_doc;
    if coalesce(baris->>'soStart','') <> '2026-06-01' then
      reset role; raise exception 'GAGAL: perpanjangan dokumen tidak menimpa master.'; end if;
    v_lolos := v_lolos + 1;
    raise notice 'OK  5. Perpanjangan pada dokumen menimpa master';
  else
    raise notice '--  4-5. Dilewati: tidak ada dokumen On Hold.';
  end if;

  -- ---- 6. Document Center membawa kedua periode -------------------------------------------
  h := public.rc_compilation_list('', '', '', '', 0, 5);
  if jsonb_array_length(h->'rows') > 0 then
    if not ((h->'rows'->0) ? 'soStart' and (h->'rows'->0) ? 'billingStart') then
      reset role; raise exception 'GAGAL: Document Center tidak membawa periode.'; end if;
    v_lolos := v_lolos + 1;
    raise notice 'OK  6. Document Center membawa periode SO dan Billing';
  end if;

  -- ---- 7. Penyaring Report: tahun campaign -------------------------------------------------
  h := public.rc_report_dashboard('{}'::jsonb);
  if not (h ? 'tahunTersedia') then
    reset role; raise exception 'GAGAL: daftar tahun tidak ada.'; end if;
  n_semua := jsonb_array_length(h->'campaign');
  if jsonb_array_length(h->'tahunTersedia') > 0 then
    h := public.rc_report_dashboard(jsonb_build_object(
      'tahunCampaign', h->'tahunTersedia'->>0));
    n_saring := jsonb_array_length(h->'campaign');
    if n_saring = 0 or n_saring > n_semua then
      reset role; raise exception 'GAGAL: penyaring tahun menghasilkan % dari %.', n_saring, n_semua; end if;
    v_lolos := v_lolos + 1;
    raise notice 'OK  7. Tahun campaign menyaring % dari % campaign', n_saring, n_semua;
  end if;

  -- ---- 8. Penyaring Report: rentang billing ------------------------------------------------
  if jsonb_array_length(public.rc_cost_center(jsonb_build_object(
       'billingStart','01-01-1900','billingEnd','31-12-1900'))->'rows') <> 0 then
    reset role; raise exception 'GAGAL: rentang billing mustahil tetap mengembalikan baris.'; end if;
  v_lolos := v_lolos + 1;
  raise notice 'OK  8. Rentang billing di luar data menghasilkan kosong';

  -- ---- 9. Tanpa penyaring, hasilnya tidak berubah ------------------------------------------
  if jsonb_array_length(public.rc_cost_center('{}'::jsonb)->'rows')
     <> jsonb_array_length(public.rc_cost_center(jsonb_build_object(
          'tahunCampaign','','billingStart','','billingEnd',''))->'rows') then
    reset role; raise exception 'GAGAL: penyaring kosong mengubah hasil.'; end if;
  v_lolos := v_lolos + 1;
  raise notice 'OK  9. Penyaring kosong tidak mengubah apa pun';
  reset role;

  raise exception 'SELESAI: % langkah lolos. Transaksi sengaja dibatalkan.', v_lolos;
exception when others then
  reset role;
  if sqlerrm like 'SELESAI:%' or sqlerrm like 'GAGAL:%' then raise; end if;
  raise exception 'GAGAL: uji berhenti -> %', sqlerrm;
end
$uji$;
