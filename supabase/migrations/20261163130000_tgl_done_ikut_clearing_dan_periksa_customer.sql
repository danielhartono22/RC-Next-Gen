-- ==========================================================================================
-- Tanggal Done = tanggal proses pilihan pengguna di Clearing; pemeriksa unggahan Customer Master
-- ==========================================================================================
-- Pemilik, 16 Oktober 2026:
--   "revisi saya mau tanggal done itu = tanggal proses yang dipilih oleh user saat clearing di
--    claim process - clearing."
--   "untuk key master, customer master yang upload 30 ribu secara bertahap otomatis ..."
--
-- 1. TANGGAL DONE
--    SEBELUMNYA (20261162270000) Clearing menyimpan dua tanggal: cleared_at = waktu tombol
--    ditekan, dan cleared_actual_on = tanggal transfer/proses pilihan pengguna. Seluruh tampilan
--    "Tgl Done" (Document Center, riwayat, Analytics, Report, dashboard publik, email tren)
--    membaca cleared_at, sehingga yang tampil adalah tanggal sistem.
--    SEKARANG Clearing mengisi cleared_at = tanggal pilihan pengguna, dengan jam proses (WIB)
--    yang sebenarnya. Bila tanggal yang dipilih hari ini, nilainya persis waktu proses. Semua
--    tampilan ikut tanpa diubah satu per satu. Waktu proses di sistem tetap tercatat di riwayat
--    status (claim_status_history.created_at) dan di email Done ("Diproses di sistem ... pada").
--    Jalur Done lain (Bulk Process Rebate, approval Rebate Manual/Voucher, submit langsung)
--    tidak punya tanggal pilihan, jadi tetap memakai waktu proses.
--    Data lama: dokumen yang cleared_actual_on-nya berbeda dari tanggal cleared_at disamakan
--    (prod 16 Oktober 2026: 407 dokumen, semuanya Done, selisih 5 hari). Jamnya dipertahankan.
--    version_no tidak dinaikkan: isi yang terlihat pengguna tidak berubah selain tanggalnya.
--
-- 2. PEMERIKSA UNGGAHAN CUSTOMER MASTER
--    Satu panggilan rc_customer_upsert maksimal 2.000 baris (batas waktu 8 detik). Layar kini
--    memecah unggahan besar per 2.000 baris. Supaya satu baris salah tidak meninggalkan setengah
--    berkas tersimpan, seluruh bagian diperiksa lebih dulu dengan rc_customer_upsert_periksa:
--    menjalankan rc_customer_upsert yang sama persis (aturan, hak akses, pesan galat), lalu
--    membatalkannya. Baru bila semua bagian lolos, bagian-bagiannya disimpan.
--
-- Ditambal dengan penjaga MD5 pra-citra (dev dan prod sama, 16 Oktober 2026). Aman diulang.
-- ==========================================================================================

do $tambal$
declare src text; baru text; n int;
  lama text := $p$
 cleared_at=case when p_action in('clearing','bulk_rebate') or ((p_action='approve' or v_langsung) and target='done') then stamp else cleared_at end,$p$;
  ganti text := $p$
 -- 20261163130000: Clearing memakai tanggal proses pilihan pengguna sebagai tanggal Done,
 -- dengan jam proses WIB yang sebenarnya.
 cleared_at=case when p_action='clearing' and v_tgl_aktual is not null
   then (v_tgl_aktual + (stamp at time zone 'Asia/Jakarta')::time) at time zone 'Asia/Jakarta'
  when p_action in('clearing','bulk_rebate') or ((p_action='approve' or v_langsung) and target='done') then stamp else cleared_at end,$p$;
begin
  src := pg_get_functiondef('rc_private.mutate_claims_unchecked(text,jsonb,uuid,text)'::regprocedure);
  if src ~ '20261163130000' then raise notice 'mutate_claims_unchecked sudah ditambal.';
  else
    if md5(replace(src, E'\r', '')) <> '3157e66eb9c2eca66596a6813d203743' then
      raise exception 'DITOLAK: mutate_claims_unchecked berbeda dari yang diukur (md5 %).', md5(replace(src, E'\r', '')); end if;
    baru := replace(src, E'\r', '');
    n := (length(baru) - length(replace(baru, lama, ''))) / length(lama);
    if n <> 1 then raise exception 'mutate_claims_unchecked: pola ditemukan % kali, diharapkan 1.', n; end if;
    execute replace(baru, lama, ganti);
  end if;
end
$tambal$;

-- ------------------------------------------------------------------------------------------
-- Data lama: tanggal Done disamakan dengan tanggal pilihan pengguna, jam dipertahankan.
-- ------------------------------------------------------------------------------------------
do $samakan$
declare n int;
begin
  update public.claims
     set cleared_at = (cleared_actual_on + (cleared_at at time zone 'Asia/Jakarta')::time) at time zone 'Asia/Jakarta'
   where cleared_actual_on is not null and cleared_at is not null
     and cleared_actual_on <> (cleared_at at time zone 'Asia/Jakarta')::date;
  get diagnostics n = row_count;
  if n > 0 then
    insert into public.activity_logs(actor_id, event_type, details)
    values (null, 'tgl_done_ikut_clearing', jsonb_build_object('migrasi', '20261163130000', 'dokumen', n,
      'keterangan', 'cleared_at disamakan dengan tanggal transfer/proses pilihan pengguna'));
  end if;
  raise notice 'Tanggal Done disamakan: % dokumen.', n;
end
$samakan$;

-- ------------------------------------------------------------------------------------------
-- Pemeriksa unggahan Customer Master: rc_customer_upsert yang sama persis, lalu dibatalkan.
-- SECURITY INVOKER: hak akses tab dan jangkauan depot diperiksa rc_customer_upsert seperti biasa.
-- ------------------------------------------------------------------------------------------
create or replace function public.rc_customer_upsert_periksa(p_rows jsonb)
returns jsonb language plpgsql set search_path to '' as $fn$
declare v jsonb;
begin
  begin
    v := public.rc_customer_upsert(p_rows);
    -- Sengaja dibatalkan: hanya memeriksa. Variabel v tetap terisi sesudah pembatalan.
    raise exception using errcode = 'RCP01', message = 'periksa selesai';
  exception when sqlstate 'RCP01' then null;
  end;
  return v || jsonb_build_object('periksa', true);
end $fn$;
revoke all on function public.rc_customer_upsert_periksa(jsonb) from public, anon;
grant execute on function public.rc_customer_upsert_periksa(jsonb) to authenticated;

-- ------------------------------------------------------------------------------------------
-- Pemeriksaan (seluruhnya dibatalkan)
-- ------------------------------------------------------------------------------------------
do $uji$
declare v_sm uuid; d record; c public.claims%rowtype; e text := ''; v_galat text; v jsonb;
  kemarin date := (now() at time zone 'Asia/Jakarta')::date - 1; v_dep text; n_cust int;
begin
  if exists(select 1 from public.claims where cleared_actual_on is not null and cleared_at is not null
             and cleared_actual_on <> (cleared_at at time zone 'Asia/Jakarta')::date) then
    e := e || ' masih ada tanggal Done yang berbeda dari tanggal pilihan;'; end if;

  select id into v_sm from public.profiles where role = 'system manager' and status = 'active' and not must_change_password order by user_code limit 1;
  select c2.id, c2.no_doc, c2.version_no into d
    from public.claims c2 join public.campaigns ca on ca.id = c2.campaign_id and ca.status <> 'inactive'
   where c2.status = 'claimed' and c2.archived_at is null and c2.pending_approval is null and c2.customer_id is not null
   order by c2.no_doc limit 1;
  select depot_code into v_dep from public.depots where archived_at is null order by depot_code limit 1;
  if v_sm is null then raise notice 'Tidak ada System Manager; uji dilewati.'; return; end if;
  perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);

  if d.no_doc is null then raise notice 'Tidak ada dokumen Claimed; uji Clearing dilewati.';
  else
    -- Tanggal pilihan kemarin: tanggal Done = kemarin, jam = jam proses; riwayat = waktu proses.
    begin
      update public.email_settings set aktif = false where jenis = 'pengajuan';
      perform public.rc_process_claims('clearing', jsonb_build_array(jsonb_build_object('no_doc', d.no_doc,
        'version_no', d.version_no, 'tgl_aktual', to_char(kemarin, 'YYYY-MM-DD'))), gen_random_uuid(), '');
      select * into c from public.claims where id = d.id;
      if c.status <> 'done' or c.cleared_actual_on is distinct from kemarin
         or (c.cleared_at at time zone 'Asia/Jakarta')::date <> kemarin
         or (c.cleared_at at time zone 'Asia/Jakarta')::time <> (now() at time zone 'Asia/Jakarta')::time then
        e := e || format(' clearing kemarin: status %s, aktual %s, cleared_at %s;', c.status, c.cleared_actual_on, c.cleared_at); end if;
      if not exists(select 1 from public.claim_status_history h where h.claim_id = d.id and h.to_status = 'done' and h.created_at = now()) then
        e := e || ' riwayat Clearing tidak mencatat waktu proses;'; end if;
      raise exception 'UJI_SELESAI';
    exception when others then if sqlerrm <> 'UJI_SELESAI' then e := e || ' clearing kemarin galat: ' || sqlerrm || ';'; end if;
    end;
    -- Tanggal pilihan hari ini: tanggal Done = waktu proses persis.
    begin
      update public.email_settings set aktif = false where jenis = 'pengajuan';
      perform public.rc_process_claims('clearing', jsonb_build_array(jsonb_build_object('no_doc', d.no_doc,
        'version_no', d.version_no, 'tgl_aktual', to_char((now() at time zone 'Asia/Jakarta')::date, 'YYYY-MM-DD'))), gen_random_uuid(), '');
      select * into c from public.claims where id = d.id;
      if c.status <> 'done' or c.cleared_at <> now() then
        e := e || format(' clearing hari ini: status %s, cleared_at %s;', c.status, c.cleared_at); end if;
      raise exception 'UJI_SELESAI';
    exception when others then if sqlerrm <> 'UJI_SELESAI' then e := e || ' clearing hari ini galat: ' || sqlerrm || ';'; end if;
    end;
  end if;

  -- Pemeriksa Customer Master: hasilnya sama dengan simpan, tetapi tidak ada yang tertulis.
  select count(*) into n_cust from public.customers;
  begin
    v := public.rc_customer_upsert_periksa(jsonb_build_array(jsonb_build_object('custCode', 'UJI130PERIKSA', 'custName', 'UJI PERIKSA', 'kodeDepot', v_dep)));
    if coalesce((v->>'dibuat')::int, 0) <> 1 or not coalesce((v->>'periksa')::boolean, false) then
      e := e || ' periksa: hasil ' || coalesce(v::text, 'null') || ';'; end if;
    if exists(select 1 from public.customers where customer_code = 'UJI130PERIKSA') or (select count(*) from public.customers) <> n_cust then
      e := e || ' periksa menulis customer;'; end if;
    if exists(select 1 from public.activity_logs where event_type = 'customer_master_upsert' and details->>'dibuat' = '1' and created_at = now()) then
      e := e || ' periksa menulis activity log;'; end if;
  exception when others then e := e || ' periksa galat: ' || sqlerrm || ';';
  end;
  begin
    perform public.rc_customer_upsert_periksa(jsonb_build_array(jsonb_build_object('custCode', 'UJI130TANPANAMA', 'kodeDepot', v_dep)));
    e := e || ' periksa menerima kode baru tanpa nama;';
  exception when others then v_galat := sqlerrm;
    if v_galat !~ 'Nama pelanggan wajib diisi' then e := e || ' pesan periksa: ' || v_galat || ';'; end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  if e <> '' then raise exception 'GAGAL:%', e; end if;
end
$uji$;
