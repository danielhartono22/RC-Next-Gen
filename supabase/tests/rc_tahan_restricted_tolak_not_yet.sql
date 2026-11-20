-- ==========================================================================================
-- Uji 14 November 2026: Pindahkan ke Restricted (ditahan 7 hari) + tolak langsung ke Not Yet (20261163980000)
-- ==========================================================================================
-- Seluruh perubahan dibatalkan lewat UJI_SELESAI.
--   node scripts/apply-sql.mjs --env dev|prod supabase/tests/rc_tahan_restricted_tolak_not_yet.sql
-- ==========================================================================================
create temp table if not exists _hasil_tr(urut serial, uji text, lulus boolean, rinci text);
truncate _hasil_tr;

do $uji$
declare hasil jsonb := '[]'; v_sm uuid; v_adm uuid; r jsonb; a record; b record; g record; kr record; kc record; kr2 record; kc2 record; k record;
  v_n integer; v_txt text; v_galat text; v_hari date := (now() at time zone 'Asia/Jakarta')::date;
begin
  select id into v_sm from public.profiles where role = 'system manager' and status = 'active' and suffix_num ~ '^[0-9]{3}$' order by user_code limit 1;
  perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);
  begin
    update public.profiles set must_change_password = false where id = v_sm;
    update public.pengaturan_sistem set nilai = 'false'::jsonb where kunci = 'approval_aktif';
    update public.pengaturan_sistem set nilai = 'true'::jsonb where kunci = 'zdage_aktif';
    perform rc_private.zdage_nilai_baru();

    -- A dan B: dua dokumen toko lunas di Open, depot yang sama. G: dokumen Restricted biasa (belum lunas) di depot itu.
    select c.id, c.no_doc, c.depot_id, o.id oid into a from public.claims c join public.rc_clearing_offers o on o.claim_id = c.id
     where o.status in ('offered','overdue') and o.result = 'LUNAS' and c.status = 'not_yet' and c.pending_approval is null and c.archived_at is null
       and exists(select 1 from public.claims c2 join public.rc_clearing_offers o2 on o2.claim_id = c2.id
                   where c2.depot_id = c.depot_id and c2.id <> c.id and o2.status in ('offered','overdue') and o2.result = 'LUNAS' and c2.status = 'not_yet' and c2.pending_approval is null and c2.archived_at is null)
       and exists(select 1 from public.claims c3 join public.rc_zdage_hasil h3 on h3.claim_id = c3.id
                   where c3.depot_id = c.depot_id and h3.hasil = 'GAGAL' and c3.status = 'not_yet' and c3.pending_approval is null and c3.archived_at is null and c3.customer_id is not null
                     and not exists(select 1 from public.rc_clearing_offers o3 where o3.claim_id = c3.id and o3.status in ('offered','overdue'))
                     and not exists(select 1 from public.rc_bad_debt_remarks x where x.customer_id = c3.customer_id and x.status = 'active'))
     order by c.no_doc limit 1;
    if a.id is null then raise exception 'Fixture: depot dengan dua dokumen toko lunas di Open dan satu dokumen belum lunas tidak ada'; end if;
    select c.id, c.no_doc, o.id oid into b from public.claims c join public.rc_clearing_offers o on o.claim_id = c.id
     where c.depot_id = a.depot_id and c.id <> a.id and o.status in ('offered','overdue') and o.result = 'LUNAS' and c.status = 'not_yet' and c.pending_approval is null and c.archived_at is null
     order by c.no_doc limit 1;
    select c.id, c.no_doc into g from public.claims c join public.rc_zdage_hasil h on h.claim_id = c.id
     where c.depot_id = a.depot_id and h.hasil = 'GAGAL' and c.status = 'not_yet' and c.pending_approval is null and c.archived_at is null and c.customer_id is not null
       and not exists(select 1 from public.rc_clearing_offers o where o.claim_id = c.id and o.status in ('offered','overdue'))
       and not exists(select 1 from public.rc_bad_debt_remarks x where x.customer_id = c.customer_id and x.status = 'active')
     order by c.no_doc limit 1;

    -- ---- A. Pindahkan ke Restricted --------------------------------------------------------
    begin perform public.rc_clearing_return(array[a.no_doc], ''); v_galat := 'diterima'; exception when others then v_galat := sqlerrm; end;
    r := public.rc_clearing_return(array[a.no_doc, b.no_doc], 'Toko minta ditunda');
    hasil := hasil || jsonb_build_object('uji', 'Pindahkan ke Restricted: alasan wajib; dua dokumen ditahan, pesan memuat tanggal', 'lulus',
      v_galat ~ 'Alasan' and (r->>'berhasil')::int = 2 and r->>'ditahanSampai' = to_char(v_hari + 6, 'DD-Mon-YYYY')
      and r->>'message' ~ ('mulai ' || to_char(v_hari + 7, 'DD-Mon-YYYY') || ' kembali mengikuti aturan debtor'), 'rinci', v_galat || ' | ' || (r->>'message'));
    hasil := hasil || jsonb_build_object('uji', 'Hasil penilaian langsung "ditahan"; riwayat mencatat tanggal akhir tahan', 'lulus',
      (select h.hasil from public.rc_zdage_hasil h where h.claim_id = a.id) = 'SUPPRESSED'
      and exists(select 1 from public.claim_status_history h where h.claim_id = a.id and h.action = 'zdage_return' and h.reason ~ ('ditahan sampai ' || to_char(v_hari + 6, 'DD-Mon-YYYY'))),
      'rinci', (select h.hasil from public.rc_zdage_hasil h where h.claim_id = a.id));
    r := public.rc_open_claims_filtered(a.no_doc, '', 0, 20, '');
    v_n := jsonb_array_length(r->'rows');
    r := public.rc_restricted_claims(a.no_doc, '', 0, 20, '');
    select x->>'alasan', x->'alasanRinci' into v_txt, r from jsonb_array_elements(r->'rows') x where x->>'noDoc' = a.no_doc;
    hasil := hasil || jsonb_build_object('uji', 'Keluar dari Open; di Restricted beralasan Ditahan sementara dengan tanggal', 'lulus',
      v_n = 0 and v_txt = 'Ditahan sementara' and (r->>'ditahan')::boolean and r->>'ditahanSampai' = to_char(v_hari + 6, 'DD-Mon-YYYY')
      and r->>'ikutDebtorMulai' = to_char(v_hari + 7, 'DD-Mon-YYYY') and r->>'alasanKembali' = 'Toko minta ditunda', 'rinci', v_n || ' / ' || coalesce(v_txt, '-') || ' / ' || coalesce(r::text, '-'));

    -- Selama ditahan tidak mengikuti aturan debtor: penilaian otomatis tidak menawarkannya.
    r := rc_private.zdage_nilai_baru();
    hasil := hasil || jsonb_build_object('uji', 'Hari ke-1: penilaian otomatis tidak menyentuh dokumen yang ditahan', 'lulus',
      (r->>'dinilai')::int = 0 and not exists(select 1 from public.rc_clearing_offers o where o.claim_id = a.id and o.status in ('offered','overdue')), 'rinci', r::text);
    update public.rc_clearing_offers set acted_at = now() - interval '6 days' where id = a.oid;
    r := rc_private.zdage_nilai_baru();
    hasil := hasil || jsonb_build_object('uji', 'Hari ke-7: masih ditahan', 'lulus',
      rc_private.zdage_ditahan_sampai(a.id) = v_hari and not exists(select 1 from public.rc_clearing_offers o where o.claim_id = a.id and o.status in ('offered','overdue')), 'rinci', coalesce(rc_private.zdage_ditahan_sampai(a.id)::text, 'null'));
    update public.rc_clearing_offers set acted_at = now() - interval '7 days' where id = a.oid;
    r := rc_private.zdage_nilai_baru();
    select o.result || ' / ' || to_char(o.deadline_at at time zone 'Asia/Jakarta', 'YYYY-MM-DD') into v_txt from public.rc_clearing_offers o where o.claim_id = a.id and o.status = 'offered';
    hasil := hasil || jsonb_build_object('uji', 'Hari ke-8: kembali mengikuti aturan debtor - toko lunas ditawarkan lagi di Open, batas 7 hari baru', 'lulus',
      rc_private.zdage_ditahan_sampai(a.id) is null and v_txt = 'LUNAS / ' || to_char(v_hari + 7, 'YYYY-MM-DD'), 'rinci', coalesce(v_txt, 'tanpa tawaran') || ' ' || r::text);

    -- ---- Pindahkan ke Open selama ditahan ---------------------------------------------------
    -- Akun bukan Editor yang memegang tab Restricted dan depot itu.
    for k in select p.id from public.profiles p where p.status = 'active' and p.role <> 'system manager' order by (p.role = 'admin') desc, p.user_code limit 80 loop
      update public.profiles set must_change_password = false where id = k.id;
      perform set_config('request.jwt.claims', json_build_object('sub', k.id::text, 'role', 'authenticated')::text, true);
      if rc_private.can_tab('upload.restricted') and not rc_private.can_tab('upload.restrictedEdit') and rc_private.can_access(a.depot_id, 'upload_claim') then v_adm := k.id; exit; end if;
    end loop;
    if v_adm is null then raise exception 'Fixture: akun bukan Editor yang memegang tab Restricted di depot uji tidak ada'; end if;
    r := public.rc_restricted_pindah(array[g.no_doc], 'Uji bukan editor');
    hasil := hasil || jsonb_build_object('uji', 'Bukan Editor: dokumen Restricted biasa tidak dapat dipindah', 'lulus',
      (r->>'berhasil')::int = 0 and not exists(select 1 from public.rc_clearing_offers o where o.claim_id = g.id and o.status in ('offered','overdue')), 'rinci', r->>'message');
    r := public.rc_restricted_pindah(array[b.no_doc, g.no_doc], 'Toko sudah siap diproses');
    select o.result || ' / ' || to_char(o.deadline_at at time zone 'Asia/Jakarta', 'YYYY-MM-DD') into v_txt from public.rc_clearing_offers o where o.claim_id = b.id and o.status = 'offered';
    hasil := hasil || jsonb_build_object('uji', 'Bukan Editor: dokumen yang ditahan kembali ke Open sebagai toko lunas; dokumen biasa tetap', 'lulus',
      (r->>'berhasil')::int = 1 and r->'lunas' ? upper(b.no_doc) and r->'gagal' ? upper(g.no_doc) and v_txt = 'LUNAS / ' || to_char(v_hari + 7, 'YYYY-MM-DD')
      and (select status from public.rc_clearing_offers where id = b.oid) = 'cancelled'
      and exists(select 1 from public.claim_status_history h where h.claim_id = b.id and h.action = 'zdage_lepas_tahan'), 'rinci', coalesce(v_txt, '-') || ' | ' || (r->>'message'));
    select count(*) into v_n from public.activity_logs where event_type = 'restricted_open' and created_at >= now() and details->>'alasan' = 'Toko sudah siap diproses';
    hasil := hasil || jsonb_build_object('uji', 'Pindahkan ke Open: satu baris Log Activity', 'lulus', v_n = 1, 'rinci', v_n::text);

    -- Editor: dokumen Restricted biasa tetap dipindah berlabel Restricted, seperti sebelumnya.
    perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);
    r := public.rc_restricted_pindah(array[g.no_doc], 'Persetujuan OSC');
    hasil := hasil || jsonb_build_object('uji', 'Editor: dokumen Restricted biasa dipindah berlabel Restricted (tanpa batas proses)', 'lulus',
      (r->>'berhasil')::int = 1 and not (r->'lunas' ? upper(g.no_doc))
      and exists(select 1 from public.rc_clearing_offers o where o.claim_id = g.id and o.status = 'offered' and o.result = 'RESTRICTED' and o.deadline_at is null), 'rinci', r->>'message');

    -- ---- B. Tolak langsung ke Not Yet --------------------------------------------------------
    select c.id, c.no_doc, c.version_no into kc from public.claims c join public.campaigns ca on ca.id = c.campaign_id
     where c.status = 'claimed' and c.pending_approval is null and c.archived_at is null and not coalesce(c.jalur_adhoc, false)
       and rc_private.jenis_efektif(coalesce(nullif(c.cashback_type_override, ''), ca.cashback_type)) <> 'rebate' order by c.no_doc limit 1;
    select c.id, c.no_doc, c.version_no into kc2 from public.claims c join public.campaigns ca on ca.id = c.campaign_id
     where c.status = 'claimed' and c.pending_approval is null and c.archived_at is null and not coalesce(c.jalur_adhoc, false) and c.id <> kc.id
       and rc_private.jenis_efektif(coalesce(nullif(c.cashback_type_override, ''), ca.cashback_type)) <> 'rebate' order by c.no_doc limit 1;
    -- Dua dokumen Released dibuat dari dua dokumen Claimed lain lewat tolak biasa (Clearing -> Released).
    select c.id, c.no_doc, c.version_no into kr from public.claims c join public.campaigns ca on ca.id = c.campaign_id
     where c.status = 'claimed' and c.pending_approval is null and c.archived_at is null and not coalesce(c.jalur_adhoc, false) and c.id not in (kc.id, kc2.id)
       and rc_private.jenis_efektif(coalesce(nullif(c.cashback_type_override, ''), ca.cashback_type)) <> 'rebate' order by c.no_doc limit 1;
    select c.id, c.no_doc, c.version_no into kr2 from public.claims c join public.campaigns ca on ca.id = c.campaign_id
     where c.status = 'claimed' and c.pending_approval is null and c.archived_at is null and not coalesce(c.jalur_adhoc, false) and c.id not in (kc.id, kc2.id, kr.id)
       and rc_private.jenis_efektif(coalesce(nullif(c.cashback_type_override, ''), ca.cashback_type)) <> 'rebate' order by c.no_doc limit 1;
    if kc.id is null or kc2.id is null or kr.id is null or kr2.id is null then raise exception 'Fixture: empat dokumen Claimed (bukan Rebate) tidak ada'; end if;
    r := public.rc_process_claims('reject_clearing', jsonb_build_array(jsonb_build_object('no_doc', kr.no_doc, 'version_no', kr.version_no),
           jsonb_build_object('no_doc', kr2.no_doc, 'version_no', kr2.version_no)), gen_random_uuid(), 'Reject pada tahap clearing');
    select c.id, c.no_doc, c.version_no into kr from public.claims c where c.id = kr.id and c.status = 'released';
    select c.id, c.no_doc, c.version_no into kr2 from public.claims c where c.id = kr2.id and c.status = 'released';
    if kr.id is null or kr2.id is null then raise exception 'Fixture: tolak biasa tidak menghasilkan dokumen Released'; end if;

    begin perform public.rc_process_claims('reject_claim_not_yet', jsonb_build_array(jsonb_build_object('no_doc', kr.no_doc, 'version_no', kr.version_no)), gen_random_uuid(), ''); v_galat := 'diterima';
    exception when others then v_galat := sqlerrm; end;
    begin perform public.rc_process_claims('reject_clearing_not_yet', jsonb_build_array(jsonb_build_object('no_doc', kr.no_doc, 'version_no', kr.version_no)), gen_random_uuid(), 'salah tahap'); v_txt := 'diterima';
    exception when others then v_txt := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'Tolak ke Not Yet: alasan wajib; aksi Clearing ditolak untuk dokumen Released', 'lulus',
      v_galat ~ 'Reason required' and v_txt ~ 'Invalid status transition', 'rinci', v_galat || ' | ' || v_txt);

    r := public.rc_process_claims('reject_claim_not_yet', jsonb_build_array(jsonb_build_object('no_doc', kr.no_doc, 'version_no', kr.version_no)), gen_random_uuid(), 'Reject langsung ke Not Yet pada tahap claim');
    select c.status || ' / ' || (c.uploaded_at is null)::text || (c.submitted_by is null)::text || (c.approved_at is null)::text || (c.released_at is null)::text
           || (c.batch_upload is null)::text || (c.batch_release is null)::text into v_txt from public.claims c where c.id = kr.id;
    hasil := hasil || jsonb_build_object('uji', 'Claim to Finance: Released langsung menjadi Not Yet; jejak tahap dikosongkan', 'lulus',
      r->'processed'->0->>'status' = 'not_yet' and v_txt = 'not_yet / truetruetruetruetruetrue'
      and exists(select 1 from public.claim_status_history h where h.claim_id = kr.id and h.action = 'reject_claim_not_yet' and h.from_status = 'released' and h.to_status = 'not_yet'), 'rinci', v_txt);

    r := public.rc_process_claims('reject_clearing_not_yet', jsonb_build_array(jsonb_build_object('no_doc', kc.no_doc, 'version_no', kc.version_no)), gen_random_uuid(), 'Reject langsung ke Not Yet pada tahap clearing');
    select c.status || ' / ' || (c.uploaded_at is null)::text || (c.approved_at is null)::text || (c.released_at is null)::text || (c.claimed_at is null)::text
           || (c.batch_upload is null)::text || (c.batch_release is null)::text || (c.batch_claim is null)::text into v_txt from public.claims c where c.id = kc.id;
    hasil := hasil || jsonb_build_object('uji', 'Clearing: Claimed langsung menjadi Not Yet; jejak tahap dikosongkan', 'lulus',
      r->'processed'->0->>'status' = 'not_yet' and v_txt = 'not_yet / truetruetruetruetruetruetrue'
      and exists(select 1 from public.claim_status_history h where h.claim_id = kc.id and h.action = 'reject_clearing_not_yet' and h.from_status = 'claimed' and h.to_status = 'not_yet'), 'rinci', v_txt);

    -- Tolak biasa tidak berubah.
    r := public.rc_process_claims('reject_claim', jsonb_build_array(jsonb_build_object('no_doc', kr2.no_doc, 'version_no', kr2.version_no)), gen_random_uuid(), 'Reject pada tahap claim');
    v_txt := r->'processed'->0->>'status';
    r := public.rc_process_claims('reject_clearing', jsonb_build_array(jsonb_build_object('no_doc', kc2.no_doc, 'version_no', kc2.version_no)), gen_random_uuid(), 'Reject pada tahap clearing');
    hasil := hasil || jsonb_build_object('uji', 'Tolak biasa tetap satu tahap: Claim to Finance -> Approved, Clearing -> Released', 'lulus',
      v_txt = 'approved' and r->'processed'->0->>'status' = 'released', 'rinci', v_txt || ' / ' || (r->'processed'->0->>'status'));
    hasil := hasil || jsonb_build_object('uji', 'Penilaian ulang sesudah tolak tidak gagal', 'lulus',
      not exists(select 1 from public.activity_logs where event_type = 'zdage_nilai_gagal' and created_at >= now()), 'rinci', '-');
    raise exception 'UJI_SELESAI';
  exception when others then
    if sqlerrm <> 'UJI_SELESAI' then hasil := hasil || jsonb_build_object('uji', 'Blok uji berhenti', 'lulus', false, 'rinci', sqlerrm); end if;
  end;
  perform set_config('request.jwt.claims', '', true);
  insert into _hasil_tr(uji, lulus, rinci) select x->>'uji', (x->>'lulus')::boolean, x->>'rinci' from jsonb_array_elements(hasil) x;
end $uji$;

select urut, case when lulus then 'LULUS' else 'GAGAL' end hasil, uji, rinci from _hasil_tr order by urut;
