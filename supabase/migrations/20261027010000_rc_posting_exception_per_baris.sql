-- ==========================================================================================
-- Posting Exception memakai grid, dengan empat tanggal per baris
-- ==========================================================================================
-- KOREKSI ATAS RANCANGAN SEBELUMNYA
-- Versi pertama menerima satu daftar No Doc beserta sepasang tanggal yang berlaku untuk
-- seluruh daftar. Itu salah menangkap maksud pemilik. Bentuk yang dikehendaki tetap tabel
-- seperti Mass Upload - satu baris satu dokumen - hanya kolomnya yang berbeda:
--
--   No Doc, SO Start, SO End, Billing Start, Billing End
--
-- Tanggal per baris memang diperlukan, bukan sekadar lebih rapi: satu unggahan dapat memuat
-- dokumen dari campaign dengan periode berbeda, sehingga perpanjangan yang sah untuk satu
-- dokumen belum tentu sah untuk dokumen lain di daftar yang sama.
--
-- ATURAN
--   Expired   hanya No Doc. Keempat tanggal diabaikan seandainya pun terisi.
--   On Hold   keempat tanggal wajib, dan SETIDAKNYA SATU harus berbeda dari periode campaign
--             dokumen itu. Normalnya SO dan Billing mengikuti periode campaign; On Hold justru
--             dipakai ketika nominalnya harus direvisi, dan revisi itu menuntut perpanjangan
--             yang nyata. Bila keempatnya sama persis dengan periode campaign, tidak ada yang
--             benar-benar diperpanjang dan dokumen itu akan kembali pada keadaan yang sama.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

alter table public.claims add column if not exists extend_so_start date;
alter table public.claims add column if not exists extend_so_end date;
alter table public.claims add column if not exists extend_billing_start date;
alter table public.claims add column if not exists extend_billing_end date;

-- Dua kolom dari rancangan sebelumnya dipindahkan isinya lalu ditinggalkan, bukan dihapus,
-- supaya berkas ini tetap aman dijalankan pada basis data yang sudah memuat datanya.
update public.claims
   set extend_so_end = coalesce(extend_so_end, extend_so_date),
       extend_billing_end = coalesce(extend_billing_end, extend_billing_date)
 where extend_so_date is not null or extend_billing_date is not null;

drop function if exists public.rc_posting_exception(text,jsonb,date,date,text);

create or replace function public.rc_posting_exception(
  p_action text, p_rows jsonb, p_reason text default '')
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare
  v_action text; r jsonb; v_doc text; c public.claims%rowtype; camp public.campaigns%rowtype;
  n_ok integer := 0; gagal jsonb := '[]'::jsonb; v_target text; batch text;
  so_a date; so_b date; bi_a date; bi_b date; berbeda boolean;
  actor uuid := (select auth.uid());
begin
  v_action := lower(btrim(coalesce(p_action,'')));
  if v_action not in('expired','hold') then
    raise exception 'Tindakan "%" tidak dikenali', p_action; end if;
  if not rc_private.can_access(null,'upload_claim') then
    raise exception 'Tidak punya hak melakukan Posting Exception' using errcode='42501'; end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    raise exception 'Tidak ada baris yang dikirim'; end if;
  if jsonb_array_length(p_rows) > 500 then
    raise exception 'Maksimal 500 baris sekali proses'; end if;

  for r in select value from jsonb_array_elements(p_rows) loop
    v_doc := upper(btrim(coalesce(r->>'noDoc','')));
    if v_doc = '' then continue; end if;

    select * into c from public.claims where upper(no_doc) = v_doc for update;
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
      batch := rc_private.next_batch('04');
      so_a := null; so_b := null; bi_a := null; bi_b := null;
    else
      if c.status not in('not_yet','submitted','released','claimed') then
        gagal := gagal || jsonb_build_array(jsonb_build_object('noDoc',v_doc,
          'sebab','Status '||rc_private.legacy_status(c.status)||' tidak dapat di-On Hold'));
        continue;
      end if;

      so_a := nullif(btrim(coalesce(r->>'soStart','')),'')::date;
      so_b := nullif(btrim(coalesce(r->>'soEnd','')),'')::date;
      bi_a := nullif(btrim(coalesce(r->>'billingStart','')),'')::date;
      bi_b := nullif(btrim(coalesce(r->>'billingEnd','')),'')::date;

      if so_a is null or so_b is null or bi_a is null or bi_b is null then
        gagal := gagal || jsonb_build_array(jsonb_build_object('noDoc',v_doc,
          'sebab','On Hold memerlukan SO Start, SO End, Billing Start dan Billing End'));
        continue;
      end if;
      if so_b < so_a then
        gagal := gagal || jsonb_build_array(jsonb_build_object('noDoc',v_doc,
          'sebab','SO End lebih awal daripada SO Start'));
        continue;
      end if;
      if bi_b < bi_a then
        gagal := gagal || jsonb_build_array(jsonb_build_object('noDoc',v_doc,
          'sebab','Billing End lebih awal daripada Billing Start'));
        continue;
      end if;

      -- Setidaknya satu tanggal harus berbeda dari periode campaign. Bila campaign itu sendiri
      -- tidak punya periode yang terurai, syarat ini dilewati - tidak ada acuan untuk
      -- membandingkan, dan menolaknya hanya akan memblokir dokumen yang sah.
      if camp.period_start is not null and camp.period_end is not null then
        berbeda := (so_a is distinct from camp.period_start)
                or (so_b is distinct from camp.period_end)
                or (bi_a is distinct from camp.period_start)
                or (bi_b is distinct from camp.period_end);
        if not berbeda then
          gagal := gagal || jsonb_build_array(jsonb_build_object('noDoc',v_doc,
            'sebab','Keempat tanggal sama persis dengan periode campaign '
              ||to_char(camp.period_start,'DD.MM.YYYY')||' - '||to_char(camp.period_end,'DD.MM.YYYY')
              ||'; setidaknya satu harus diperpanjang'));
          continue;
        end if;
      end if;

      v_target := 'on_hold';
      batch := null;
    end if;

    update public.claims set
      status = v_target,
      previous_status = case when v_action = 'hold' then c.status else null end,
      batch_clearing = coalesce(batch, batch_clearing),
      extend_so_start      = case when v_action='hold' then so_a else extend_so_start end,
      extend_so_end        = case when v_action='hold' then so_b else extend_so_end end,
      extend_billing_start = case when v_action='hold' then bi_a else extend_billing_start end,
      extend_billing_end   = case when v_action='hold' then bi_b else extend_billing_end end,
      version_no = version_no + 1,
      updated_at = now()
    where id = c.id;

    insert into public.claim_status_history(claim_id,actor_id,from_status,to_status,action,batch,reason)
    values(c.id,actor,c.status,v_target,v_action,batch,left(btrim(coalesce(p_reason,'')),300));

    insert into public.activity_logs(actor_id,depot_id,event_type,entity_id,details)
    values(actor,c.depot_id,'posting_exception',c.id,jsonb_build_object(
      'noDoc',c.no_doc,'tindakan',v_action,'dari',c.status,'menjadi',v_target,
      'soStart',so_a,'soEnd',so_b,'billingStart',bi_a,'billingEnd',bi_b));

    n_ok := n_ok + 1;
  end loop;

  return jsonb_build_object('status','success','berhasil',n_ok,
    'gagal',gagal,'jumlahGagal',jsonb_array_length(gagal),
    'message',n_ok||' dokumen '||case when v_action='expired' then 'di-Expired' else 'di-On Hold' end
      ||case when jsonb_array_length(gagal) > 0
             then ', '||jsonb_array_length(gagal)||' ditolak' else '' end);
end $fn$;
revoke all on function public.rc_posting_exception(text,jsonb,text) from public,anon;
grant execute on function public.rc_posting_exception(text,jsonb,text) to authenticated;

-- Periode per dokumen, dipakai layar untuk mengisi keempat kolom tanggal secara default.
create or replace function public.rc_periode_dokumen(p_docs jsonb)
returns jsonb language sql stable security definer set search_path='' as $fn$
  select jsonb_build_object('status','success','rows',
    coalesce(jsonb_agg(jsonb_build_object(
      'noDoc',c.no_doc,'kodeCampaign',ca.campaign_code,'namaCampaign',ca.campaign_name,
      'status',rc_private.legacy_status(c.status),
      'kodeToko',cu.customer_code,'namaToko',cu.customer_name,'cbNet',c.cb_net,
      'mulai',ca.period_start,'selesai',ca.period_end)),'[]'::jsonb))
  from public.claims c
  join public.campaigns ca on ca.id = c.campaign_id
  join public.customers cu on cu.id = c.customer_id
  where upper(c.no_doc) in (select upper(btrim(value)) from jsonb_array_elements_text(p_docs))
    and rc_private.can_access(c.depot_id);
$fn$;
revoke all on function public.rc_periode_dokumen(jsonb) from public,anon;
grant execute on function public.rc_periode_dokumen(jsonb) to authenticated;

create or replace function rc_private.marker_20261027() returns boolean
language sql immutable set search_path='' as $fn$select true$fn$;
revoke all on function rc_private.marker_20261027() from public,anon;
grant execute on function rc_private.marker_20261027() to authenticated;

select 'Posting Exception per baris terpasang' as hasil,
 (select count(*) from public.claims where status='on_hold') as on_hold,
 (select count(*) from public.claims where extend_so_start is not null) as punya_perpanjangan;
