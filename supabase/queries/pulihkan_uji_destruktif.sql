-- ==========================================================================================
-- Mengembalikan dokumen yang dipakai uji destruktif email pengajuan
-- ==========================================================================================
-- Pasangan dari uji_destruktif_email_pengajuan.sql. Mengembalikan setiap baris persis seperti
-- sebelum uji dijalankan, memakai salinan di rc_private.uji_email_cadangan.
--
-- Riwayat status dan Log Aktivitas yang terbentuk selama uji ikut dihapus. Dibiarkan, keduanya
-- menjadi jejak perpindahan yang tidak pernah benar-benar terjadi secara bisnis - dan jejak
-- palsu pada catatan audit lebih merugikan daripada tidak ada catatan sama sekali.
--
-- Nomor batch yang sempat terbit TIDAK ditarik kembali. Penomoran berjalan maju dan menariknya
-- justru berisiko membenturkan nomor di kemudian hari; lompatan nomor tidak merusak apa pun.
--
-- Jalankan: node scripts/apply-sql.mjs supabase/queries/pulihkan_uji_destruktif.sql
-- ==========================================================================================

do $pulih$
declare v_n int; v_awal timestamptz; v_ids uuid[];
begin
  if not exists (select 1 from rc_private.uji_email_cadangan) then
    raise notice 'Tidak ada cadangan uji; tidak ada yang perlu dikembalikan.';
    return;
  end if;

  select min(dibuat) into v_awal from rc_private.uji_email_cadangan;
  select array_agg((klaim->>'id')::uuid) into v_ids from rc_private.uji_email_cadangan;

  -- ---- 1. Mengembalikan isi baris klaim ---------------------------------------------------
  update public.claims c set
    status               = (b.klaim->>'status'),
    previous_status      = (b.klaim->>'previous_status'),
    pending_approval     = case when b.klaim->'pending_approval' = 'null'::jsonb
                                then null else b.klaim->'pending_approval' end,
    tax_subject          = (b.klaim->>'tax_subject'),
    gross_up             = nullif(b.klaim->>'gross_up','')::numeric,
    total_billing        = nullif(b.klaim->>'total_billing','')::numeric,
    period_start         = nullif(b.klaim->>'period_start','')::date,
    period_end           = nullif(b.klaim->>'period_end','')::date,
    paid_on              = nullif(b.klaim->>'paid_on','')::date,
    approval             = (b.klaim->>'approval'),
    cashback_type_override  = (b.klaim->>'cashback_type_override'),
    cashback_type_changed   = coalesce((b.klaim->>'cashback_type_changed')::boolean,false),
    uploaded_at          = nullif(b.klaim->>'uploaded_at','')::timestamptz,
    submitted_by         = nullif(b.klaim->>'submitted_by','')::uuid,
    approved_at          = nullif(b.klaim->>'approved_at','')::timestamptz,
    approved_by          = nullif(b.klaim->>'approved_by','')::uuid,
    released_at          = nullif(b.klaim->>'released_at','')::timestamptz,
    released_by          = nullif(b.klaim->>'released_by','')::uuid,
    claimed_at           = nullif(b.klaim->>'claimed_at','')::timestamptz,
    claimed_by           = nullif(b.klaim->>'claimed_by','')::uuid,
    cleared_at           = nullif(b.klaim->>'cleared_at','')::timestamptz,
    cleared_by           = nullif(b.klaim->>'cleared_by','')::uuid,
    hold_approved_at     = nullif(b.klaim->>'hold_approved_at','')::timestamptz,
    hold_approved_by     = nullif(b.klaim->>'hold_approved_by','')::uuid,
    bulk_processed_at    = nullif(b.klaim->>'bulk_processed_at','')::timestamptz,
    bulk_processed_by    = nullif(b.klaim->>'bulk_processed_by','')::uuid,
    batch_upload         = (b.klaim->>'batch_upload'),
    batch_release        = (b.klaim->>'batch_release'),
    batch_claim          = (b.klaim->>'batch_claim'),
    batch_clearing       = (b.klaim->>'batch_clearing'),
    extend_so_start      = nullif(b.klaim->>'extend_so_start','')::date,
    extend_so_end        = nullif(b.klaim->>'extend_so_end','')::date,
    extend_billing_start = nullif(b.klaim->>'extend_billing_start','')::date,
    extend_billing_end   = nullif(b.klaim->>'extend_billing_end','')::date,
    -- version_no sengaja DINAIKKAN, bukan dikembalikan: layar yang sempat memegang versi lama
    -- harus tetap menolak menyimpan di atasnya.
    version_no           = c.version_no + 1,
    updated_at           = now()
  from rc_private.uji_email_cadangan b
  where c.no_doc = b.no_doc;
  get diagnostics v_n = row_count;
  raise notice 'Klaim dikembalikan: % baris', v_n;

  -- ---- 2. claim_sensitive ------------------------------------------------------------------
  update rc_private.claim_sensitive s set
    ktp            = (b.sensitif->>'ktp'),
    npwp           = (b.sensitif->>'npwp'),
    bank           = (b.sensitif->>'bank'),
    account_number = (b.sensitif->>'account_number'),
    account_name   = (b.sensitif->>'account_name'),
    top_text       = (b.sensitif->>'top_text')
  from rc_private.uji_email_cadangan b
  where s.claim_id = (b.klaim->>'id')::uuid and b.sensitif is not null;

  -- Baris yang belum ada sebelum uji dan baru dibuat oleh submit ikut dibuang.
  delete from rc_private.claim_sensitive s
   using rc_private.uji_email_cadangan b
   where s.claim_id = (b.klaim->>'id')::uuid and b.sensitif is null;

  -- ---- 3. Jejak yang terbentuk selama uji --------------------------------------------------
  delete from public.claim_status_history
   where claim_id = any(v_ids) and created_at >= v_awal;
  get diagnostics v_n = row_count;
  raise notice 'Riwayat status uji dihapus: % baris', v_n;

  delete from public.activity_logs
   where entity_id = any(v_ids) and created_at >= v_awal;
  get diagnostics v_n = row_count;
  raise notice 'Log aktivitas uji dihapus: % baris', v_n;

  -- ---- 4. Cadangan dibuang supaya uji berikutnya tidak tertahan ----------------------------
  delete from rc_private.uji_email_cadangan;
  raise notice 'Cadangan dibersihkan.';
end
$pulih$;

-- Bukti bahwa keadaannya benar-benar kembali.
select 'dokumen tersisa di cadangan' as periksa,
       (select count(*)::text from rc_private.uji_email_cadangan) as nilai
union all
select 'surat uji di antrean (tetap disimpan sebagai bukti)',
       (select count(*)::text from public.email_outbox
         where jenis='pengajuan' and konteks ? 'aksi');
