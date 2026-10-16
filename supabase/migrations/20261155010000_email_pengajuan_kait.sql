-- ==========================================================================================
-- Email Pengajuan - bagian 2: mengantre saat kejadian
-- ==========================================================================================
-- Kelima peristiwa yang diminta pemilik - Submitted, On Hold, Expired, Approval dan Clearing -
-- seluruhnya melewati rc_private.mutate_claims_unchecked. Karena itu kaitnya cukup di satu
-- tempat; menempelkannya pada masing-masing RPC hanya akan menciptakan lima tempat yang harus
-- diingat setiap kali alurnya berubah.
--
-- Suratnya DIANTRE, bukan dikirim di tempat. Antrean sudah dikuras cron tiap menit
-- (rc_email_proses), jadi "langsung saat kejadian" tetap terpenuhi tanpa menaruh panggilan
-- HTTP ke Gmail di dalam transaksi yang sedang memegang kunci baris klaim. Kalau Gmail
-- sedang lambat, yang menunggu adalah suratnya - bukan depot yang menekan Posting.
--
-- Satu surat per DEPOT. Satu aksi bisa menyentuh beberapa depot sekaligus (misalnya Supervisor
-- menyetujui lintas depot), sementara alamat TO justru milik depot - menggabungkannya akan
-- mengirim angka depot lain ke depot yang tidak berhak melihatnya.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

-- ------------------------------------------------------------------------------------------
-- 1. Pengantre
-- ------------------------------------------------------------------------------------------
create or replace function rc_private.email_pengajuan_antre(
  p_action text, p_batch text, p_ids uuid[], p_aktor uuid, p_alasan text default '')
returns integer language plpgsql security definer set search_path to '' as $fn$
declare
  v_aktif boolean; v_dep record; v_ids uuid[]; v_pen jsonb; v_html text;
  v_judul text; v_n int := 0;
begin
  if p_ids is null or array_length(p_ids,1) is null then return 0; end if;

  -- Peristiwa di luar kelima yang diminta tidak dikabarkan. Penolakan, unhold dan bulk rebate
  -- sengaja TIDAK ikut: pemilik menyebut lima, dan surat yang tidak diminta lebih merugikan
  -- daripada surat yang belum ada.
  if p_action not in ('submit','hold','expire','expire_claim_process','approve','clearing') then
    return 0; end if;

  select aktif into v_aktif from public.email_settings where jenis='pengajuan';
  if not coalesce(v_aktif,false) then return 0; end if;

  v_judul := case p_action
    when 'submit'               then 'Pengajuan Baru'
    when 'hold'                 then 'Dokumen On Hold'
    when 'expire'               then 'Dokumen Expired'
    when 'expire_claim_process' then 'Dokumen Expired'
    when 'approve'              then 'Dokumen Disetujui'
    when 'clearing'             then 'Clearing Selesai' end;

  for v_dep in
    select c.depot_id, coalesce(d.depot_name, d.depot_code, '') as nama
      from public.claims c
      left join public.depots d on d.id = c.depot_id
     where c.id = any(p_ids) and c.depot_id is not null
     group by c.depot_id, 2
  loop
    select array_agg(id) into v_ids
      from public.claims where id = any(p_ids) and depot_id = v_dep.depot_id;

    v_pen := rc_private.email_pengajuan_penerima(v_dep.depot_id);

    -- Depot tanpa alamat tujuan dilewati dengan jejak, bukan diam-diam. Surat tanpa penerima
    -- hanya akan menumpuk di antrean sebagai kegagalan yang membingungkan.
    if jsonb_array_length(v_pen->'to') = 0 then
      insert into public.activity_logs(actor_id,depot_id,event_type,details)
      values(p_aktor, v_dep.depot_id, 'email_pengajuan_tanpa_tujuan',
        jsonb_build_object('aksi',p_action,'batch',p_batch,
                           'sebab','Alamat email depot belum diisi di Depot Master'));
      continue;
    end if;

    v_html := rc_private.email_pengajuan_html(p_action, p_batch, v_ids, p_aktor, p_alasan);

    insert into public.email_outbox(jenis,tujuan,cc,subjek,isi_html,konteks)
    values('pengajuan',
      array(select jsonb_array_elements_text(v_pen->'to')),
      array(select jsonb_array_elements_text(v_pen->'cc')),
      'RC ' || v_judul || ' - ' || coalesce(nullif(v_dep.nama,''),'Depot')
        || case when coalesce(p_batch,'') <> '' then ' - ' || p_batch else '' end,
      v_html,
      jsonb_build_object('aksi',p_action,'batch',p_batch,'depot',v_dep.depot_id,
                         'qty',coalesce(array_length(v_ids,1),0)));
    v_n := v_n + 1;
  end loop;

  return v_n;
end
$fn$;

revoke all on function rc_private.email_pengajuan_antre(text,text,uuid[],uuid,text)
  from public, anon, authenticated;

-- ------------------------------------------------------------------------------------------
-- 2. Kait pada satu-satunya pintu perpindahan status
-- ------------------------------------------------------------------------------------------
do $kait$
declare src text; baru text;
begin
  select pg_get_functiondef(p.oid) into src from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='rc_private' and p.proname='mutate_claims_unchecked';
  if src is null then raise exception 'rc_private.mutate_claims_unchecked tidak ditemukan.'; end if;

  if position('email_pengajuan_antre' in src) > 0 then
    raise notice 'Kait email pengajuan sudah terpasang; dilewati.'; return; end if;

  -- ---- a. Penampung id --------------------------------------------------------------------
  if position(' processed jsonb:=''[]''; stamp timestamptz:=now(); expire_batch text;' in src) = 0 then
    raise exception 'Pola deklarasi processed tidak ditemukan.'; end if;
  baru := replace(src,
    ' processed jsonb:=''[]''; stamp timestamptz:=now(); expire_batch text;',
    ' processed jsonb:=''[]''; stamp timestamptz:=now(); expire_batch text;' || chr(10) ||
    ' v_mail_ids uuid[]:=''{}'';');

  -- ---- b. Mengumpulkan id di dalam perulangan ---------------------------------------------
  if position(' processed:=processed||jsonb_build_array(jsonb_build_object(''no_doc'',c.no_doc,''status'',target,' in baru) = 0 then
    raise exception 'Pola pengisian processed tidak ditemukan.'; end if;
  baru := replace(baru,
    ' processed:=processed||jsonb_build_array(jsonb_build_object(''no_doc'',c.no_doc,''status'',target,',
    ' v_mail_ids:=v_mail_ids||c.id;' || chr(10) ||
    ' processed:=processed||jsonb_build_array(jsonb_build_object(''no_doc'',c.no_doc,''status'',target,');

  -- ---- c. Mengantre setelah seluruh baris selesai ------------------------------------------
  -- Ditaruh SETELAH perulangan supaya satu batch menghasilkan satu surat, bukan satu surat per
  -- dokumen. Dibungkus penangkap galat karena kabar tidak boleh membatalkan pekerjaan yang
  -- sudah sah: kalau penyusunan surat gagal, klaimnya tetap berpindah dan sebabnya dicatat.
  if position(' v_payload:=jsonb_build_object(''processed'',processed,''batch'',batch,''count'',jsonb_array_length(processed));' in baru) = 0 then
    raise exception 'Pola penutup v_payload tidak ditemukan.'; end if;
  baru := replace(baru,
    ' v_payload:=jsonb_build_object(''processed'',processed,''batch'',batch,''count'',jsonb_array_length(processed));',
    ' begin' || chr(10) ||
    '  perform rc_private.email_pengajuan_antre(p_action,batch,v_mail_ids,actor,p_reason);' || chr(10) ||
    ' exception when others then' || chr(10) ||
    '  insert into public.activity_logs(actor_id,event_type,details)' || chr(10) ||
    '  values(actor,''email_pengajuan_gagal'',jsonb_build_object(' || chr(10) ||
    '    ''aksi'',p_action,''batch'',batch,''sebab'',left(sqlerrm,300)));' || chr(10) ||
    ' end;' || chr(10) ||
    ' v_payload:=jsonb_build_object(''processed'',processed,''batch'',batch,''count'',jsonb_array_length(processed));');

  execute baru;
  raise notice 'Kait email pengajuan terpasang pada mutate_claims_unchecked.';
end
$kait$;

-- ------------------------------------------------------------------------------------------
-- Pemeriksaan
-- ------------------------------------------------------------------------------------------
do $periksa$
declare
  v_ids uuid[]; v_dep uuid; v_act uuid; n int; n_outbox_awal int; n_outbox_akhir int;
begin
  select count(*) into n_outbox_awal from public.email_outbox;

  select depot_id into v_dep from public.claims
   where archived_at is null and depot_id is not null order by no_doc limit 1;

  -- Surat hanya lahir dari klaim sungguhan. Pada database yang belum berisi klaim, pengujian
  -- ini tidak punya bahan - tetapi fungsi dan kaitnya sudah terpasang dengan benar di atas.
  -- Dilewati dengan jejak, bukan digagalkan: menggagalkannya ikut menggulung balik pemasangan
  -- fungsinya, lalu tiga migrasi sesudahnya runtuh karena fungsi itu tidak ada.
  if v_dep is null then
    raise notice 'Belum ada klaim; pengujian surat dilewati.'; return; end if;

  select array_agg(id) into v_ids from (
    select id from public.claims where archived_at is null and depot_id = v_dep
     order by no_doc limit 4) x;
  select id into v_act from public.profiles
   where lower(coalesce(role,'')) like '%system%' order by user_code limit 1;

  -- 1. Sakelar mati -> tidak ada surat sama sekali.
  if (select aktif from public.email_settings where jenis='pengajuan') then
    raise exception 'GAGAL: sakelar sudah menyala sebelum diuji.'; end if;
  n := rc_private.email_pengajuan_antre('submit','B-UJI-01',v_ids,v_act,'');
  if n <> 0 then raise exception 'GAGAL: sakelar mati tetapi % surat diantre.', n; end if;
  select count(*) into n_outbox_akhir from public.email_outbox;
  if n_outbox_akhir <> n_outbox_awal then
    raise exception 'GAGAL: antrean bertambah padahal sakelar mati.'; end if;
  raise notice 'OK  1. Sakelar mati -> tidak ada surat';

  -- 2. Sakelar nyala -> tepat satu surat untuk satu depot. Dibatalkan lagi setelahnya.
  begin
    update public.email_settings set aktif=true where jenis='pengajuan';
    n := rc_private.email_pengajuan_antre('submit','B-UJI-01',v_ids,v_act,'');
    if n <> 1 then raise exception 'GAGAL: seharusnya 1 surat untuk 1 depot, dapat %.', n; end if;
    if not exists (select 1 from public.email_outbox
                    where jenis='pengajuan' and konteks->>'batch'='B-UJI-01'
                      and status='pending' and array_length(tujuan,1) >= 1) then
      raise exception 'GAGAL: barisnya tidak masuk antrean dengan benar.'; end if;
    raise notice 'OK  2. Sakelar nyala -> 1 surat per depot, masuk antrean';

    -- 3. Aksi di luar kelima yang diminta tidak menghasilkan surat.
    n := rc_private.email_pengajuan_antre('reject_approval','B-UJI-02',v_ids,v_act,'');
    if n <> 0 then raise exception 'GAGAL: aksi reject ikut mengirim surat.'; end if;
    raise notice 'OK  3. Aksi di luar lima peristiwa tidak mengirim surat';

    raise exception 'ULANGI_SAJA';
  exception when others then
    if sqlerrm <> 'ULANGI_SAJA' then raise; end if;
  end;

  -- Keadaan harus kembali persis seperti semula.
  select count(*) into n_outbox_akhir from public.email_outbox;
  if n_outbox_akhir <> n_outbox_awal then
    raise exception 'GAGAL: antrean uji tidak tergulung balik (% -> %).',
      n_outbox_awal, n_outbox_akhir; end if;
  if (select aktif from public.email_settings where jenis='pengajuan') then
    raise exception 'GAGAL: sakelar tertinggal menyala setelah uji.'; end if;
  raise notice 'OK  4. Uji tidak meninggalkan jejak; sakelar tetap MATI';

  -- 5. Kaitnya benar-benar terpasang.
  if (select position('email_pengajuan_antre' in pg_get_functiondef(p.oid))
        from pg_proc p join pg_namespace n2 on n2.oid=p.pronamespace
       where n2.nspname='rc_private' and p.proname='mutate_claims_unchecked') = 0 then
    raise exception 'GAGAL: kait tidak ada pada mutate_claims_unchecked.'; end if;
  raise notice 'OK  5. Kait terpasang pada mutate_claims_unchecked';
  raise notice 'Pemeriksaan lolos.';
end
$periksa$;
