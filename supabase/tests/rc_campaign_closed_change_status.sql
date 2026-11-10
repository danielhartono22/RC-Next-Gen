-- ==========================================================================================
-- Uji 10 November 2026: status campaign Closed dan Amend Doc > Change Status (880000)
-- ==========================================================================================
-- Seluruh perubahan dibatalkan lewat UJI_SELESAI. Email hanya ke alamat uji dan ikut dibatalkan.
--   node scripts/apply-sql.mjs --env dev|prod supabase/tests/rc_campaign_closed_change_status.sql
-- ==========================================================================================
create temp table if not exists _hasil_cl(urut serial, uji text, lulus boolean, rinci text);
truncate _hasil_cl;

do $uji$
declare hasil jsonb := '[]'; r jsonb; v_sm uuid; v_galat text; ca record; n bigint; n_lain bigint; v_out bigint; v_kloter bigint; v_log bigint; v_batch text;
  a1 record; e1 record; v_tanpa uuid; v_arsip uuid; v_cek jsonb; v_osc uuid; v_adm uuid;
begin
  select id into v_sm from public.profiles where role = 'system manager' and status = 'active' and not must_change_password and suffix_num ~ '^[0-9]{3}$' order by user_code limit 1;
  perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);

  begin
    update public.email_settings set aktif = true, mode_uji = true, email_uji = 'uji@example.com',
           cc_per_jenis = coalesce(cc_per_jenis, '{}'::jsonb) || jsonb_build_object('closed', jsonb_build_array('cc.uji@example.com')) where jenis = 'pengajuan';

    -- ---- Campaign Closed ---------------------------------------------------------------------------
    -- Campaign aktif dengan dokumen Not Yet di lebih dari satu depot dan dokumen berstatus lain.
    select c.campaign_id id, ca2.campaign_code kode into ca from public.claims c join public.campaigns ca2 on ca2.id = c.campaign_id
     where ca2.status = 'active' and c.archived_at is null group by 1, 2
    having count(*) filter (where c.status = 'not_yet' and c.customer_id is not null) >= 3 and count(distinct c.depot_id) filter (where c.status = 'not_yet') >= 2
     order by count(*) filter (where c.status <> 'not_yet') desc limit 1;
    if ca.id is null then raise exception 'Fixture: campaign dengan Not Yet di dua depot tidak ada'; end if;
    -- Satu Not Yet tanpa Customer Master dan satu Not Yet yang diarsipkan.
    update public.claims set customer_id = null, source_customer_code = coalesce(source_customer_code, 'UJI-CL')
     where id = (select id from public.claims where campaign_id = ca.id and status = 'not_yet' and archived_at is null and customer_id is not null order by no_doc limit 1) returning id into v_tanpa;
    update public.claims set archived_at = now()
     where id = (select id from public.claims where campaign_id = ca.id and status = 'not_yet' and archived_at is null and customer_id is not null order by no_doc desc limit 1) returning id into v_arsip;
    insert into public.rc_clearing_offers(claim_id, result, reason, offered_at, offered_by, deadline_at, status)
    select id, 'LUNAS', '{}'::jsonb, now(), v_sm, now() + interval '7 days', 'offered' from public.claims
     where campaign_id = ca.id and status = 'not_yet' and archived_at is null and customer_id is not null order by no_doc limit 1 on conflict do nothing;

    v_cek := public.rc_campaign_tutup_cek(ca.kode);
    select count(*) into n from public.claims where campaign_id = ca.id and status = 'not_yet' and archived_at is null;
    select count(*) into n_lain from public.claims where campaign_id = ca.id and status not in ('not_yet') and archived_at is null;
    hasil := hasil || jsonb_build_object('uji', 'Pratinjau Closed: jumlah Not Yet dan per depot', 'lulus', (v_cek->>'jumlah')::bigint = n and jsonb_array_length(v_cek->'depot') >= 2, 'rinci', (v_cek->>'jumlah') || ' dok, ' || jsonb_array_length(v_cek->'depot') || ' depot');

    select count(*) into v_out from public.email_outbox where konteks->>'aksi' = 'closed';
    select count(*) into v_kloter from rc_private.email_expired_antrean;
    select count(*) into v_log from public.activity_logs where event_type = 'campaign_closed';
    perform public.rc_campaign_upsert(jsonb_build_array(jsonb_build_object('codeCampaign', ca.kode, 'campaignName', (select campaign_name from public.campaigns where id = ca.id), 'status', 'closed')));

    select batch_clearing into v_batch from public.claims where campaign_id = ca.id and status = 'expired' and batch_event_code = '3' and batch_clearing ~ '^34' order by updated_at desc limit 1;
    hasil := hasil || jsonb_build_object('uji', 'Closed lewat Campaign Master: seluruh Not Yet menjadi Expired, satu batch berkepala 34',
      'lulus', not exists (select 1 from public.claims where campaign_id = ca.id and status = 'not_yet' and archived_at is null)
           and (select count(*) from public.claims where campaign_id = ca.id and batch_clearing = v_batch and status = 'expired') = n
           and (select count(*) from public.claim_status_history h join public.claims c on c.id = h.claim_id where c.campaign_id = ca.id and h.action = 'campaign_closed' and h.batch = v_batch) = n,
      'rinci', n || ' dokumen, batch ' || coalesce(v_batch, '-'));
    hasil := hasil || jsonb_build_object('uji', 'Hanya Not Yet: status lain dan dokumen arsip tidak berubah',
      'lulus', (select count(*) from public.claims where campaign_id = ca.id and status not in ('not_yet') and archived_at is null and coalesce(batch_clearing, '') <> coalesce(v_batch, '#')) = n_lain
           and (select status from public.claims where id = v_arsip) = 'not_yet', 'rinci', n_lain || ' dokumen status lain');
    hasil := hasil || jsonb_build_object('uji', 'Not Yet tanpa Customer Master ikut Expired; tawaran aktif dibatalkan',
      'lulus', (select status from public.claims where id = v_tanpa) = 'expired'
           and not exists (select 1 from public.rc_clearing_offers o join public.claims c on c.id = o.claim_id where c.campaign_id = ca.id and o.status in ('offered', 'overdue')), 'rinci', '-');
    hasil := hasil || jsonb_build_object('uji', 'Satu Log Activity dengan nomor batch; email expired per depot tidak ikut',
      'lulus', (select count(*) from public.activity_logs where event_type = 'campaign_closed') = v_log + 1
           and exists (select 1 from public.activity_logs where event_type = 'campaign_closed' and entity_id = ca.id and batch_no = v_batch and (details->>'jumlah')::int = n)
           and (select count(*) from rc_private.email_expired_antrean) = v_kloter, 'rinci', '-');
    select * into e1 from public.email_outbox where konteks->>'aksi' = 'closed' order by dibuat_pada desc limit 1;
    hasil := hasil || jsonb_build_object('uji', 'Email Campaign Closed: SATU email untuk semua depot (bukan per depot), lewat Email Pengajuan, CC wajib jenis closed, mode uji',
      'lulus', (select count(*) from public.email_outbox where konteks->>'aksi' = 'closed') = v_out + 1 and e1.jenis = 'pengajuan'
           and e1.isi_html ~ ('Campaign <strong>' || ca.kode) and e1.isi_html ~ 'sudah ditutup \(closed\)' and e1.isi_html ~ 'Penutupan campaign ini diproses oleh'
           and e1.isi_html ~ 'Total Qty Expired' and e1.isi_html ~ 'Total Value Expired' and e1.isi_html ~ 'final dihanguskan \(expired\)'
           and e1.isi_html ~ 'cc.uji@example.com' and e1.tujuan = array['uji@example.com'] and e1.subjek ~ ('^\[UJI\] Campaign Closed - ' || ca.kode),
      'rinci', e1.subjek);
    begin
      update public.campaigns set status = 'active' where id = ca.id; v_galat := 'lolos';
    exception when others then v_galat := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'Campaign Closed tidak dapat dibuka kembali', 'lulus', v_galat ~ 'tidak dapat dibuka kembali', 'rinci', v_galat);
    select c.id, c.no_doc, cu.customer_code, d.depot_code into a1 from public.claims c join public.customers cu on cu.id = c.customer_id join public.depots d on d.id = c.depot_id
     where c.campaign_id = ca.id and c.status = 'expired' and c.batch_clearing = v_batch limit 1;
    -- Toko dari dokumen yang diarsipkan: kombinasinya tidak menghalangi, jadi yang menolak adalah status campaign.
    select cu.customer_code, d.depot_code into a1.customer_code, a1.depot_code from public.claims c join public.customers cu on cu.id = c.customer_id join public.depots d on d.id = c.depot_id where c.id = v_arsip;
    r := public.rc_compile_upload(jsonb_build_array(jsonb_build_object('kodeDepot', a1.depot_code, 'codeCampaign', ca.kode, 'custCode', a1.customer_code, 'cbNet', '1000', 'netValue', '1000', 'volume', '1')), gen_random_uuid());
    hasil := hasil || jsonb_build_object('uji', 'Compile ke campaign Closed ditolak', 'lulus', coalesce((r->>'dibuat')::int, 0) = 0 and r::text ~ '(?i)closed', 'rinci', left(r::text, 200));
    r := public.rc_change_status_cek(jsonb_build_array(jsonb_build_object('noDoc', a1.no_doc)));
    hasil := hasil || jsonb_build_object('uji', 'Change Status menolak Expired campaign Closed', 'lulus', r->'rows'->0->>'galat' ~ 'Closed', 'rinci', r->'rows'->0->>'galat');
    begin
      update public.claims set status = 'not_yet' where id = a1.id; v_galat := 'lolos';
    exception when others then v_galat := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'Jalur lain pun tidak dapat mengembalikan Expired campaign Closed', 'lulus', v_galat ~ 'final', 'rinci', v_galat);

    -- ---- Cleared otomatis menjadi Closed -------------------------------------------------------------
    select c.campaign_id id, ca2.campaign_code kode into ca from public.claims c join public.campaigns ca2 on ca2.id = c.campaign_id
     where ca2.status = 'active' and c.archived_at is null and c.status = 'not_yet' group by 1, 2 order by count(*) limit 1;
    perform public.rc_campaign_upsert(jsonb_build_array(jsonb_build_object('codeCampaign', ca.kode, 'campaignName', (select campaign_name from public.campaigns where id = ca.id), 'status', 'cleared')));
    hasil := hasil || jsonb_build_object('uji', 'Status Cleared otomatis menjadi Closed, Not Yet-nya Expired',
      'lulus', (select status from public.campaigns where id = ca.id) = 'closed'
           and not exists (select 1 from public.claims where campaign_id = ca.id and status = 'not_yet' and archived_at is null)
           and not exists (select 1 from public.campaigns where status = 'cleared'), 'rinci', ca.kode);

    -- ---- Change Status -------------------------------------------------------------------------------
    select c.id, c.no_doc, c.depot_id into a1 from public.claims c join public.campaigns ca2 on ca2.id = c.campaign_id
     where c.status = 'not_yet' and c.archived_at is null and c.customer_id is not null and c.pending_approval is null and ca2.status = 'active' order by c.no_doc limit 1;
    update public.claims set status = 'expired', batch_clearing = '340610911260001', batch_event_code = '3', extend_so_start = date '2026-01-01' where id = a1.id;
    r := public.rc_change_status_cek(jsonb_build_array(jsonb_build_object('noDoc', lower(a1.no_doc)), jsonb_build_object('noDoc', 'TIDAKADA/999')));
    hasil := hasil || jsonb_build_object('uji', 'Cek Change Status: Expired dikenali, galat per baris',
      'lulus', r->'rows'->0->>'statusDok' = 'Expired' and not (r->'rows'->0 ? 'claimId') and r->'rows'->1->>'galat' ~ 'tidak ditemukan', 'rinci', (r->'rows')::text);
    select c.no_doc into e1 from public.claims c where c.status = 'not_yet' and c.archived_at is null and c.id <> a1.id limit 1;
    begin
      perform public.rc_change_status(jsonb_build_array(jsonb_build_object('noDoc', a1.no_doc, 'alasan', 'Uji'), jsonb_build_object('noDoc', e1.no_doc, 'alasan', 'Uji salah')), '');
      v_galat := 'lolos';
    exception when others then v_galat := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'Satu baris bukan Expired: seluruhnya ditolak, tidak ada yang berubah',
      'lulus', v_galat ~ 'hanya Expired' and (select status from public.claims where id = a1.id) = 'expired', 'rinci', v_galat);
    begin perform public.rc_change_status(jsonb_build_array(jsonb_build_object('noDoc', a1.no_doc)), ''); v_galat := 'lolos'; exception when others then v_galat := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'Alasan wajib (per baris atau umum)', 'lulus', v_galat ~ 'Alasan wajib', 'rinci', v_galat);
    begin perform public.rc_change_status(jsonb_build_array(jsonb_build_object('noDoc', a1.no_doc), jsonb_build_object('noDoc', lower(a1.no_doc))), 'Uji'); v_galat := 'lolos'; exception when others then v_galat := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'No Doc ganda ditolak', 'lulus', v_galat ~ 'ganda', 'rinci', v_galat);
    select count(*) into v_out from public.email_outbox where konteks->>'aksi' = 'changestatus';
    select count(*) into v_log from public.activity_logs where event_type = 'change_status';
    r := public.rc_change_status(jsonb_build_array(jsonb_build_object('noDoc', a1.no_doc)), 'Uji Change Status umum');
    hasil := hasil || jsonb_build_object('uji', 'Change Status: Not Yet, batch Expired dan perpanjangan dikosongkan, riwayat, satu log, email depot',
      'lulus', r->>'status' = 'success'
           and (select status = 'not_yet' and batch_clearing is null and extend_so_start is null from public.claims where id = a1.id)
           and exists (select 1 from public.claim_status_history h where h.claim_id = a1.id and h.action = 'change_status' and h.from_status = 'expired' and h.to_status = 'not_yet' and h.reason ~ 'Uji Change Status umum')
           and (select count(*) from public.activity_logs where event_type = 'change_status') = v_log + 1
           and (select count(*) from public.email_outbox where konteks->>'aksi' = 'changestatus') = v_out + 1
           and exists (select 1 from public.email_outbox where konteks->>'aksi' = 'changestatus' and isi_html ~ a1.no_doc and isi_html ~ 'dikembalikan dari'), 'rinci', r->>'message');
    r := public.rc_legacy_dashboard(5000, null, null);
    hasil := hasil || jsonb_build_object('uji', 'Remark Status Changed: claim_remark dan Analytics',
      'lulus', (select rc_private.claim_remark(c) from public.claims c where c.id = a1.id) ~ 'Status Changed'
           and exists (select 1 from jsonb_array_elements(r->'history') x where x->>'noDoc' = a1.no_doc and x->>'remark' ~ 'Status Changed'),
      'rinci', (select rc_private.claim_remark(c) from public.claims c where c.id = a1.id));
    r := public.rc_change_status_riwayat();
    hasil := hasil || jsonb_build_object('uji', 'Riwayat Change Status per dokumen', 'lulus', exists (select 1 from jsonb_array_elements(r->'rows') x where x->>'noDoc' = a1.no_doc and x->>'alasan' = 'Uji Change Status umum'), 'rinci', '-');

    -- ---- Hak tab ---------------------------------------------------------------------------------------
    select p.id into v_osc from public.profiles p where lower(p.role) = 'osc' and p.status = 'active'
       and exists (select 1 from public.user_permissions up where up.user_id = p.id and up.permission_code = 'view_compilation')
       and not exists (select 1 from rc_private.user_tab_access u where u.user_id = p.id and u.tab_code = 'compilation.changestatus') limit 1;
    select p.id into v_adm from public.profiles p where p.role = 'admin' and p.status = 'active'
       and not exists (select 1 from rc_private.user_tab_access u where u.user_id = p.id and u.tab_code = 'compilation.changestatus') limit 1;
    hasil := hasil || jsonb_build_object('uji', 'Tab Change Status: bawaan OSC dan SM, peran lain bila dicentang',
      'lulus', coalesce((rc_private.tab_rights(v_sm)->>'compilation.changestatus')::boolean, false)
           and (v_osc is null or coalesce((rc_private.tab_rights(v_osc)->>'compilation.changestatus')::boolean, false))
           and (v_adm is null or not coalesce((rc_private.tab_rights(v_adm)->>'compilation.changestatus')::boolean, false)),
      'rinci', 'osc ' || coalesce(v_osc::text, '-') || ', admin ' || coalesce(v_adm::text, '-'));

    raise exception 'UJI_SELESAI';
  exception when others then
    if sqlerrm <> 'UJI_SELESAI' then hasil := hasil || jsonb_build_object('uji', 'Blok uji berhenti', 'lulus', false, 'rinci', sqlerrm); end if;
  end;
  perform set_config('request.jwt.claims', '', true);
  insert into _hasil_cl(uji, lulus, rinci) select x->>'uji', (x->>'lulus')::boolean, x->>'rinci' from jsonb_array_elements(hasil) x;
end $uji$;

select urut, case when lulus then 'LULUS' else 'GAGAL' end hasil, uji, rinci from _hasil_cl order by urut;
