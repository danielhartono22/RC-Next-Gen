-- ==========================================================================================
-- Posting Exception: Expired cukup No Doc, On Hold menuntut SO dan Billing Date
-- ==========================================================================================
-- Sebelumnya kedua tindakan menumpang pada grid unggahan yang sama, sehingga untuk sekadar
-- meng-expired-kan satu dokumen pun seluruh kolom klaim harus lolos validasi lebih dahulu.
-- Itu menyalahi sifat keduanya: keduanya adalah tindakan atas dokumen yang SUDAH ada, bukan
-- pengiriman data baru.
--
-- ATURAN YANG DITETAPKAN PEMILIK
--   Expired   cukup daftar No Doc. Tidak ada kolom lain.
--   On Hold   wajib menyertakan SO Date dan Billing Date, dan keduanya harus berada DI LUAR
--             periode campaign.
--
-- MENGAPA HARUS DI LUAR PERIODE CAMPAIGN
-- On Hold dipakai ketika nominalnya tidak sesuai dan harus direvisi di sisi compilation.
-- Tanggal di dalam periode campaign berarti dokumen itu masih berada pada rentang yang sama
-- dengan yang menghasilkan nominal keliru tadi, sehingga revisinya tidak akan mengubah apa pun.
-- Menuntut tanggal di luar periode memaksa keputusan itu dibuat secara sadar, bukan dilewati
-- dengan menekan tombol dua kali.
--
-- Keduanya disimpan pada dokumen, bukan hanya pada catatan aktivitas, karena tab Reprocessing
-- pada Cashback Compilation membacanya kembali saat dokumen itu diperbaiki.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

alter table public.claims add column if not exists extend_so_date date;
alter table public.claims add column if not exists extend_billing_date date;
comment on column public.claims.extend_so_date is
  'SO Date pengganti yang ditetapkan saat dokumen di-On Hold. Wajib di luar periode campaign.';

create or replace function public.rc_posting_exception(
  p_action text, p_docs jsonb, p_so date default null, p_billing date default null,
  p_reason text default '')
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare
  v_action text; v_doc text; c public.claims%rowtype; camp public.campaigns%rowtype;
  n_ok integer := 0; gagal jsonb := '[]'::jsonb; v_target text; stage text; batch text;
  actor uuid := (select auth.uid());
begin
  v_action := lower(btrim(coalesce(p_action,'')));
  if v_action not in('expired','hold') then
    raise exception 'Tindakan "%" tidak dikenali', p_action; end if;
  if not rc_private.can_access(null,'upload_claim') then
    raise exception 'Tidak punya hak melakukan Posting Exception' using errcode='42501'; end if;
  if jsonb_typeof(p_docs) <> 'array' or jsonb_array_length(p_docs) = 0 then
    raise exception 'Tidak ada No Doc yang dikirim'; end if;
  if jsonb_array_length(p_docs) > 500 then
    raise exception 'Maksimal 500 dokumen sekali proses'; end if;

  -- On Hold menuntut kedua tanggal SEBELUM satu dokumen pun disentuh, supaya tidak ada
  -- sebagian yang terlanjur berubah lalu sisanya ditolak.
  if v_action = 'hold' then
    if p_so is null or p_billing is null then
      raise exception 'On Hold memerlukan SO Date dan Billing Date'; end if;
  end if;

  for v_doc in select btrim(value) from jsonb_array_elements_text(p_docs) loop
    if v_doc = '' then continue; end if;
    select * into c from public.claims where no_doc = v_doc for update;
    if not found then
      gagal := gagal || jsonb_build_array(jsonb_build_object('noDoc',v_doc,'sebab','Dokumen tidak ditemukan'));
      continue;
    end if;
    if not rc_private.can_access(c.depot_id,'upload_claim') then
      gagal := gagal || jsonb_build_array(jsonb_build_object('noDoc',v_doc,'sebab','Depot di luar yurisdiksi Anda'));
      continue;
    end if;
    if c.archived_at is not null then
      gagal := gagal || jsonb_build_array(jsonb_build_object('noDoc',v_doc,'sebab','Dokumen sudah diarsipkan'));
      continue;
    end if;

    select * into camp from public.campaigns where id = c.campaign_id;

    if v_action = 'expired' then
      if c.status not in('not_yet','submitted','released','claimed','on_hold') then
        gagal := gagal || jsonb_build_array(jsonb_build_object('noDoc',v_doc,
          'sebab','Status '||rc_private.legacy_status(c.status)||' tidak dapat di-Expired'));
        continue;
      end if;
      v_target := 'expired';
    else
      if c.status not in('not_yet','submitted','released','claimed') then
        gagal := gagal || jsonb_build_array(jsonb_build_object('noDoc',v_doc,
          'sebab','Status '||rc_private.legacy_status(c.status)||' tidak dapat di-On Hold'));
        continue;
      end if;
      -- Tanggal harus di luar periode campaign. Diperiksa per dokumen karena setiap dokumen
      -- dapat berasal dari campaign dengan periode berbeda.
      if camp.period_start is not null and camp.period_end is not null then
        if p_so between camp.period_start and camp.period_end
           and p_billing between camp.period_start and camp.period_end then
          gagal := gagal || jsonb_build_array(jsonb_build_object('noDoc',v_doc,
            'sebab','SO dan Billing Date masih di dalam periode campaign '
              ||to_char(camp.period_start,'DD.MM.YYYY')||' - '||to_char(camp.period_end,'DD.MM.YYYY')
              ||'; salah satu harus di luar periode itu'));
          continue;
        end if;
      end if;
      v_target := 'on_hold';
    end if;

    -- Expired memperoleh nomor batch pada tahap Clearing, sesuai keputusan pemilik terdahulu.
    stage := case when v_action = 'expired' then '04' else null end;
    batch := case when stage is not null then rc_private.next_batch(stage) else null end;

    update public.claims set
      status = v_target,
      previous_status = case when v_action = 'hold' then c.status else null end,
      batch_clearing = coalesce(batch, batch_clearing),
      extend_so_date = case when v_action = 'hold' then p_so else extend_so_date end,
      extend_billing_date = case when v_action = 'hold' then p_billing else extend_billing_date end,
      version_no = version_no + 1,
      updated_at = now()
    where id = c.id;

    insert into public.claim_status_history(claim_id,actor_id,from_status,to_status,action,batch,reason)
    values(c.id,actor,c.status,v_target,v_action,batch,left(btrim(coalesce(p_reason,'')),300));

    insert into public.activity_logs(actor_id,depot_id,event_type,entity_id,details)
    values(actor,c.depot_id,'posting_exception',c.id,jsonb_build_object(
      'noDoc',c.no_doc,'tindakan',v_action,'dari',c.status,'menjadi',v_target,
      'soDate',p_so,'billingDate',p_billing));

    n_ok := n_ok + 1;
  end loop;

  return jsonb_build_object('status','success','berhasil',n_ok,
    'gagal',gagal,'jumlahGagal',jsonb_array_length(gagal),
    'message',n_ok||' dokumen '||case when v_action='expired' then 'di-Expired' else 'di-On Hold' end
      ||case when jsonb_array_length(gagal) > 0
             then ', '||jsonb_array_length(gagal)||' ditolak' else '' end);
end $fn$;
revoke all on function public.rc_posting_exception(text,jsonb,date,date,text) from public,anon;
grant execute on function public.rc_posting_exception(text,jsonb,date,date,text) to authenticated;

-- ------------------------------------------------------------------------------------------
-- Periode campaign untuk dokumen tertentu, agar layar dapat mengisi tanggal secara default
-- ------------------------------------------------------------------------------------------
create or replace function public.rc_periode_dokumen(p_docs jsonb)
returns jsonb language sql stable security definer set search_path='' as $fn$
  select jsonb_build_object('status','success','rows',
    coalesce(jsonb_agg(jsonb_build_object(
      'noDoc',c.no_doc,'kodeCampaign',ca.campaign_code,'namaCampaign',ca.campaign_name,
      'status',rc_private.legacy_status(c.status),
      'kodeToko',cu.customer_code,'namaToko',cu.customer_name,'cbNet',c.cb_net,
      'mulai',ca.period_start,'selesai',ca.period_end)),'[]'::jsonb),
    -- Rentang gabungan, dipakai layar sebagai nilai awal kedua kolom tanggal.
    'mulaiTerawal',min(ca.period_start),'selesaiTerakhir',max(ca.period_end))
  from public.claims c
  join public.campaigns ca on ca.id = c.campaign_id
  join public.customers cu on cu.id = c.customer_id
  where c.no_doc in (select btrim(value) from jsonb_array_elements_text(p_docs))
    and rc_private.can_access(c.depot_id);
$fn$;
revoke all on function public.rc_periode_dokumen(jsonb) from public,anon;
grant execute on function public.rc_periode_dokumen(jsonb) to authenticated;

create or replace function rc_private.marker_20261026() returns boolean
language sql immutable set search_path='' as $fn$select true$fn$;
revoke all on function rc_private.marker_20261026() from public,anon;
grant execute on function rc_private.marker_20261026() to authenticated;

select 'Posting Exception terpasang' as hasil,
 (select count(*) from public.claims where status='on_hold') as on_hold,
 (select count(*) from public.claims where status='expired') as expired,
 (select count(*) from public.claims where extend_so_date is not null) as punya_so_pengganti;
