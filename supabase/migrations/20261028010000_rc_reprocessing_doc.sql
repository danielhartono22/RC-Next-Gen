-- ==========================================================================================
-- Reprocessing Doc: dokumen On Hold direvisi nominalnya lalu kembali ke Not Yet
-- ==========================================================================================
-- On Hold dipakai ketika nominal sebuah dokumen tidak sesuai dan harus direvisi di sisi
-- compilation. Sampai sekarang dokumen itu hanya berhenti di sana tanpa jalan kembali. Berkas
-- ini melengkapi jalurnya: daftar dokumen tertahan, dan pengunggahan ulang yang mengembalikan
-- statusnya ke Not Yet sekaligus memperbarui nominalnya.
--
-- KUNCI RUJUKANNYA NO DOC, BUKAN NOMOR BARIS
-- Berkas revisi diunduh, disunting di Excel, lalu diunggah kembali. Di antara kedua langkah itu
-- urutan barisnya dapat berubah, baris dapat dihapus, dan baris lain dapat disisipkan. Karena
-- itu yang dipakai mencocokkan adalah No Doc, bukan posisi baris.
--
-- YANG DIPERBARUI DAN YANG TIDAK
-- Hanya total cashback yang boleh berubah lewat jalur ini. Kode campaign, nama customer dan
-- kolom lain pada berkas unduhan bersifat keterangan agar penyunting tahu sedang menyentuh
-- dokumen yang mana; nilainya diabaikan saat diunggah. Membiarkannya menimpa master akan
-- menjadikan berkas revisi sebagai pintu belakang ke seluruh data pelanggan.
--
-- Tanggal SO dan Billing yang ditetapkan saat On Hold ikut dikosongkan ketika dokumen kembali
-- ke Not Yet, karena perpanjangan itu hanya berlaku selama dokumennya tertahan.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

create or replace function public.rc_reprocessing_list(
  p_search text default '', p_offset integer default 0, p_limit integer default 200)
returns jsonb language plpgsql stable set search_path='' as $fn$
declare v jsonb; jml bigint; v_cari text;
begin
  if not rc_private.can_access(null,'view_compilation') and not rc_private.is_system_manager() then
    raise exception 'Tidak punya hak membuka Cashback Compilation' using errcode='42501'; end if;
  v_cari := nullif(btrim(coalesce(p_search,'')),'');

  select count(*) into jml
    from public.claims c
    join public.campaigns ca on ca.id = c.campaign_id
    join public.customers cu on cu.id = c.customer_id
   where c.status = 'on_hold' and c.archived_at is null
     and (v_cari is null or c.no_doc ilike '%'||v_cari||'%'
          or cu.customer_code ilike '%'||v_cari||'%' or cu.customer_name ilike '%'||v_cari||'%');

  select coalesce(jsonb_agg(x),'[]'::jsonb) into v from (
    select jsonb_build_object(
      'noDoc',c.no_doc,
      'kodeCampaign',ca.campaign_code,'namaCampaign',ca.campaign_name,
      'kodeToko',cu.customer_code,'namaToko',cu.customer_name,
      'totalCashback',c.cb_net,
      'dcCode',d.depot_code,'depotName',d.depot_name,
      -- Tanggal yang ditetapkan saat On Hold. Ditampilkan supaya penyunting tahu batas baru
      -- dokumen ini, dan ikut terbawa ke berkas unduhan.
      'soStart',c.extend_so_start,'soEnd',c.extend_so_end,
      'billingStart',c.extend_billing_start,'billingEnd',c.extend_billing_end,
      'ditahanPada',to_char(c.updated_at at time zone 'Asia/Jakarta','DD/MM/YYYY HH24:MI'),
      'alasan',coalesce((select h.reason from public.claim_status_history h
                          where h.claim_id=c.id and h.action='hold'
                          order by h.id desc limit 1),''),
      'versionNo',c.version_no) as x
    from public.claims c
    join public.campaigns ca on ca.id = c.campaign_id
    join public.customers cu on cu.id = c.customer_id
    join public.depots d on d.id = c.depot_id
   where c.status = 'on_hold' and c.archived_at is null
     and (v_cari is null or c.no_doc ilike '%'||v_cari||'%'
          or cu.customer_code ilike '%'||v_cari||'%' or cu.customer_name ilike '%'||v_cari||'%')
   order by c.updated_at desc, c.no_doc
   limit least(greatest(coalesce(p_limit,200),1),2000)
  offset greatest(coalesce(p_offset,0),0)) t;

  return jsonb_build_object('status','success','rows',v,'total',jml);
end $fn$;
revoke all on function public.rc_reprocessing_list(text,integer,integer) from public,anon;
grant execute on function public.rc_reprocessing_list(text,integer,integer) to authenticated;

-- ------------------------------------------------------------------------------------------
-- Pengunggahan ulang
-- ------------------------------------------------------------------------------------------
create or replace function public.rc_reprocessing_upload(p_rows jsonb, p_reason text default '')
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare
  r jsonb; v_doc text; c public.claims%rowtype; v_baru numeric;
  n_ok integer := 0; gagal jsonb := '[]'::jsonb; actor uuid := (select auth.uid());
begin
  if not rc_private.can_access(null,'view_compilation') and not rc_private.is_system_manager() then
    raise exception 'Tidak punya hak mengubah Cashback Compilation' using errcode='42501'; end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    raise exception 'Tidak ada baris yang dikirim'; end if;
  if jsonb_array_length(p_rows) > 2000 then
    raise exception 'Maksimal 2000 baris sekali unggah'; end if;

  for r in select value from jsonb_array_elements(p_rows) loop
    v_doc := upper(btrim(coalesce(r->>'noDoc','')));
    if v_doc = '' then continue; end if;

    select * into c from public.claims where upper(no_doc) = v_doc for update;
    if not found then
      gagal := gagal || jsonb_build_array(jsonb_build_object('noDoc',v_doc,'sebab','Dokumen tidak ditemukan'));
      continue;
    end if;
    if c.status <> 'on_hold' then
      -- Menolak dokumen yang tidak tertahan penting: berkas unduhan yang dipakai ulang beberapa
      -- hari kemudian dapat memuat dokumen yang sementara itu sudah diproses orang lain.
      gagal := gagal || jsonb_build_array(jsonb_build_object('noDoc',v_doc,
        'sebab','Status saat ini '||rc_private.legacy_status(c.status)||', bukan On Hold'));
      continue;
    end if;
    if not rc_private.can_access(c.depot_id) then
      gagal := gagal || jsonb_build_array(jsonb_build_object('noDoc',v_doc,'sebab','Depot di luar yurisdiksi Anda'));
      continue;
    end if;

    begin
      v_baru := nullif(btrim(coalesce(r->>'totalCashback','')),'')::numeric;
    exception when others then
      gagal := gagal || jsonb_build_array(jsonb_build_object('noDoc',v_doc,
        'sebab','Total cashback bukan angka: '||coalesce(r->>'totalCashback','')));
      continue;
    end;
    if v_baru is null then
      gagal := gagal || jsonb_build_array(jsonb_build_object('noDoc',v_doc,'sebab','Total cashback kosong'));
      continue;
    end if;
    if v_baru < 0 then
      gagal := gagal || jsonb_build_array(jsonb_build_object('noDoc',v_doc,'sebab','Total cashback tidak boleh negatif'));
      continue;
    end if;

    update public.claims set
      cb_net = v_baru,
      status = 'not_yet',
      previous_status = null,
      -- Perpanjangan hanya berlaku selama dokumennya tertahan.
      extend_so_start = null, extend_so_end = null,
      extend_billing_start = null, extend_billing_end = null,
      version_no = version_no + 1,
      updated_at = now()
    where id = c.id;

    insert into public.claim_status_history(claim_id,actor_id,from_status,to_status,action,reason)
    values(c.id,actor,'on_hold','not_yet','reprocess',
      left(btrim(coalesce(p_reason,'Revisi nominal lewat Reprocessing Doc')),300));

    insert into public.activity_logs(actor_id,depot_id,event_type,entity_id,details)
    values(actor,c.depot_id,'reprocessing_upload',c.id,jsonb_build_object(
      'noDoc',c.no_doc,'cbNetLama',c.cb_net,'cbNetBaru',v_baru));

    n_ok := n_ok + 1;
  end loop;

  return jsonb_build_object('status','success','berhasil',n_ok,
    'gagal',gagal,'jumlahGagal',jsonb_array_length(gagal),
    'message',n_ok||' dokumen kembali ke Not Yet'
      ||case when jsonb_array_length(gagal) > 0
             then ', '||jsonb_array_length(gagal)||' ditolak' else '' end);
end $fn$;
revoke all on function public.rc_reprocessing_upload(jsonb,text) from public,anon;
grant execute on function public.rc_reprocessing_upload(jsonb,text) to authenticated;

create or replace function rc_private.marker_20261028() returns boolean
language sql immutable set search_path='' as $fn$select true$fn$;
revoke all on function rc_private.marker_20261028() from public,anon;
grant execute on function rc_private.marker_20261028() to authenticated;

select 'Reprocessing Doc terpasang' as hasil,
 (select count(*) from public.claims where status='on_hold' and archived_at is null) as menunggu_revisi;
