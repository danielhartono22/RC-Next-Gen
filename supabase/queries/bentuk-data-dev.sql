-- ==========================================================================================
-- Menyesuaikan data rekayasa dev dengan alur status yang berlaku sekarang
-- ==========================================================================================
-- Generator dataset (scripts/performance/generate_dataset.py) dibuat sebelum ada tahap
-- Management of Approval. Akibatnya data yang dimuatnya:
--   * tidak memuat satu pun klaim berstatus 'approved' - antrean Release selalu kosong;
--   * klaim 'submitted' tidak membawa pending_approval, padahal modul approval hanya membaca
--     klaim yang membawanya - antrean approval juga kosong;
--   * klaim yang sudah melewati approval tidak punya approved_at / approved_by.
--
-- Hasilnya, dua modul utama tampak kosong di dev - bukan karena rusak, tetapi karena datanya
-- tidak mengikuti alur yang sekarang. Berkas ini membetulkan bentuknya tanpa mengubah jumlah
-- maupun sebaran totalnya.
--
-- HANYA UNTUK DEV. Menolak jalan bila jumlah klaim tidak menunjukkan data rekayasa.
--
-- Jalankan: node scripts/apply-sql.mjs --env dev supabase/queries/bentuk-data-dev.sql
-- ==========================================================================================
do $bentuk$
declare v_sm uuid; n_sub int; n_appr int; n_pend int; n_jejak int;
begin
  -- Penjaga: data rekayasa dikenali dari identitas NPWP buatannya. Produksi tidak memilikinya.
  if not exists (select 1 from public.customers where npwp like 'DUMMY-NPWP-%') then
    raise exception 'DITOLAK: ini bukan data rekayasa. Berkas ini hanya untuk dev.';
  end if;

  select id into v_sm from public.profiles
   where role='system manager' and status='active' order by user_code limit 1;

  -- 1. Sepertiga klaim Submitted dipindah ke Approved: mereka sudah disetujui dan menunggu
  --    Release. Dipilih deterministik lewat no_doc supaya hasilnya sama setiap dijalankan.
  update public.claims
     set status = 'approved',
         approved_at = coalesce(uploaded_at, created_at) + interval '1 day',
         approved_by = v_sm
   where status = 'submitted' and archived_at is null
     and (abs(hashtext(no_doc)) % 3) = 0;
  get diagnostics n_appr = row_count;

  -- 2. Sisa Submitted memang menunggu keputusan - mereka harus membawa pending_approval,
  --    persis seperti yang ditulis mutate_claims_unchecked saat submit.
  update public.claims
     set pending_approval = jsonb_build_object(
           'kind','submit',
           'requested_by', v_sm,
           'requested_at', coalesce(uploaded_at, created_at),
           'reason', null,
           'target_status','approved')
   where status = 'submitted' and archived_at is null and pending_approval is null;
  get diagnostics n_pend = row_count;

  -- 3. Klaim yang sudah melewati approval harus tercatat pernah disetujui.
  update public.claims
     set approved_at = coalesce(uploaded_at, created_at) + interval '1 day',
         approved_by = v_sm
   where status in ('released','claimed','done') and approved_at is null;
  get diagnostics n_jejak = row_count;

  -- 4. Riwayat status ikut: tanpa baris 'approved', kolom Approved By di antrean kosong.
  insert into public.claim_status_history(claim_id, actor_id, from_status, to_status, action, created_at)
  select c.id, v_sm, 'submitted', 'approved', 'approve', c.approved_at
    from public.claims c
   where c.approved_at is not null
     and not exists (select 1 from public.claim_status_history h
                      where h.claim_id = c.id and h.to_status = 'approved');

  select count(*) into n_sub from public.claims where status='submitted';
  raise notice 'Approved baru: % | Submitted menunggu keputusan: % | jejak approval: %',
    n_appr, n_pend, n_jejak;
end
$bentuk$;

analyze public.claims;

select status, count(*) as jumlah,
       count(*) filter (where pending_approval is not null) as menunggu_approval,
       count(*) filter (where approved_at is not null) as pernah_disetujui
  from public.claims group by status order by jumlah desc;
