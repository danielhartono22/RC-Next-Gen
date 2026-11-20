-- ==========================================================================================
-- Uji 14 November 2026: dokumen baru dinilai otomatis + pembersihan baris debtor (20261163950000)
-- ==========================================================================================
-- Seluruh perubahan dibatalkan lewat UJI_SELESAI.
--   node scripts/apply-sql.mjs --env dev|prod supabase/tests/rc_zdage_nilai_otomatis.sql
-- ==========================================================================================
create temp table if not exists _hasil_zn(urut serial, uji text, lulus boolean, rinci text);
truncate _hasil_zn;

do $uji$
declare hasil jsonb := '[]'; v_sm uuid; r jsonb; dd record; ca record; v_l record; v_g record; kl record; kg record;
  v_awal timestamptz := now(); /* waktu transaksi: log yang dibuat uji ini bercap sama */ v_n integer; v_n2 integer; v_txt text; v_upd timestamptz; v_log0 integer := 0;
  u_lama uuid := gen_random_uuid(); u_baru uuid := gen_random_uuid(); u_plama uuid := gen_random_uuid(); u_pbaru uuid := gen_random_uuid();
  q1 uuid := gen_random_uuid(); q2 uuid := gen_random_uuid(); v_baris_berlaku bigint;
begin
  select id into v_sm from public.profiles where role = 'system manager' and status = 'active' and suffix_num ~ '^[0-9]{3}$' order by user_code limit 1;
  perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);
  begin
    update public.profiles set must_change_password = false where id = v_sm;
    update public.pengaturan_sistem set nilai = 'false'::jsonb where kunci = 'approval_aktif';
    update public.pengaturan_sistem set nilai = 'true'::jsonb where kunci = 'zdage_aktif';
    -- Titik awal yang bersih: semua yang tertunggak dinilai dulu.
    perform rc_private.zdage_nilai_baru();

    -- Depot dengan data debtor berlaku; satu toko yang tidak ada di berkas (lunas) dan satu toko over due.
    for dd in select x.*, d.depot_code from public.rc_zdage_depot_data x join public.depots d on d.id = x.depot_id
               where not x.kosong and d.archived_at is null order by d.depot_code loop
      for ca in select c.id, c.campaign_code kode from public.campaigns c
                 where c.archived_at is null and c.status = 'active' and c.so_start is not null and c.so_start <= coalesce(c.billing_end, c.so_end)
                   and c.batas_compile >= (now() at time zone 'Asia/Jakarta')::date
                   and not exists(select 1 from public.campaign_not_participating n where n.campaign_id = c.id)
                   and not exists(select 1 from public.timetable_not_achieved t where t.campaign_id = c.id and t.depot_id = dd.depot_id)
                 order by c.created_at limit 12 loop
        select cu.id, cu.customer_code kode into v_l from public.customer_depots cd join public.customers cu on cu.id = cd.customer_id
         where cd.depot_id = dd.depot_id and cu.archived_at is null and coalesce(cu.ktp, cu.npwp, '') <> ''
           and not exists(select 1 from public.rc_zdage_rows z where z.upload_id = dd.upload_id and z.customer_key = rc_private.kode_toko(cu.customer_code))
           and not exists(select 1 from public.rc_bad_debt_remarks b where b.customer_id = cu.id and b.status = 'active')
           and not exists(select 1 from public.claims k where k.customer_id = cu.id and k.campaign_id = ca.id)
         order by cu.customer_code limit 1;
        select cu.id, cu.customer_code kode into v_g from public.customer_depots cd join public.customers cu on cu.id = cd.customer_id
          join public.rc_zdage_rows z on z.upload_id = dd.upload_id and z.customer_key = rc_private.kode_toko(cu.customer_code)
         where cd.depot_id = dd.depot_id and cu.archived_at is null and coalesce(cu.ktp, cu.npwp, '') <> '' and z.overdue_amt > 1000
           and not exists(select 1 from public.rc_bad_debt_remarks b where b.customer_id = cu.id and b.status = 'active')
           and not exists(select 1 from public.claims k where k.customer_id = cu.id and k.campaign_id = ca.id)
         order by cu.customer_code limit 1;
        exit when v_l.id is not null and v_g.id is not null;
      end loop;
      exit when v_l.id is not null and v_g.id is not null;
    end loop;
    if v_l.id is null or v_g.id is null then raise exception 'Fixture: toko lunas / over due untuk dicompile tidak ada'; end if;
    select updated_at into v_upd from public.rc_zdage_depot_data where depot_id = dd.depot_id;
    -- Log penilaian awal (dokumen yang memang tertunggak) tidak ikut dihitung.
    select count(*) into v_log0 from public.activity_logs where event_type = 'zdage_nilai_otomatis' and created_at >= v_awal;

    -- 1. Compile dua dokumen baru: TANPA upload ulang keduanya langsung dinilai.
    r := public.rc_compile_upload(jsonb_build_array(
      jsonb_build_object('kodeDepot', dd.depot_code, 'codeCampaign', ca.kode, 'custCode', v_l.kode, 'cbNet', '150000', 'netValue', '1500000', 'volume', '10'),
      jsonb_build_object('kodeDepot', dd.depot_code, 'codeCampaign', ca.kode, 'custCode', v_g.kode, 'cbNet', '250000', 'netValue', '2500000', 'volume', '20')), gen_random_uuid());
    select c.id, c.no_doc, c.paid_on, c.status into kl from public.claims c where c.customer_id = v_l.id and c.campaign_id = ca.id and c.archived_at is null;
    select c.id, c.no_doc, c.paid_on, c.status into kg from public.claims c where c.customer_id = v_g.id and c.campaign_id = ca.id and c.archived_at is null;
    hasil := hasil || jsonb_build_object('uji', 'Compile membuat dua dokumen Not Yet', 'lulus',
      (r->>'dibuat')::int = 2 and kl.status = 'not_yet' and kg.status = 'not_yet', 'rinci', left(r::text, 260));

    select count(*) into v_n from public.rc_clearing_offers o
     where o.claim_id = kl.id and o.status = 'offered' and o.result = 'LUNAS' and o.upload_id = dd.upload_id
       and (o.deadline_at at time zone 'Asia/Jakarta')::date = (now() at time zone 'Asia/Jakarta')::date + 7;
    hasil := hasil || jsonb_build_object('uji', 'Toko lunas: tawaran LUNAS aktif, batas 7 hari, dari upload yang berlaku', 'lulus', v_n = 1, 'rinci', v_n::text);
    hasil := hasil || jsonb_build_object('uji', 'Toko lunas: Tgl Lunas = tanggal tarikan data yang berlaku', 'lulus',
      kl.paid_on = (dd.extracted_at at time zone 'Asia/Jakarta')::date, 'rinci', coalesce(kl.paid_on::text, 'kosong'));
    select h.hasil || ' / upload ' || (h.upload_id = dd.upload_id)::text || ' / gagal ' || jsonb_array_length(h.alasan->'gagal') into v_txt
      from public.rc_zdage_hasil h where h.claim_id = kg.id;
    select count(*) into v_n from public.rc_clearing_offers o where o.claim_id = kg.id and o.status in ('offered', 'overdue');
    hasil := hasil || jsonb_build_object('uji', 'Toko over due: hasil GAGAL beralasan, tanpa tawaran, Tgl Lunas kosong', 'lulus',
      v_txt ~ '^GAGAL / upload true / gagal [1-9]' and v_n = 0 and kg.paid_on is null, 'rinci', coalesce(v_txt, 'tanpa hasil'));

    -- 2. Layar: dokumen lunas ada di Open, dokumen over due di Restricted dengan alasannya.
    r := public.rc_open_claims_filtered(kl.no_doc, '', 0, 50, '');
    v_n := (select count(*) from jsonb_array_elements(r->'rows') x where x->>'noDoc' = kl.no_doc and x->>'offerStatus' = 'offered');
    r := public.rc_restricted_claims(kg.no_doc, '', 0, 50, '');
    v_txt := (select x->>'alasan' from jsonb_array_elements(r->'rows') x where x->>'noDoc' = kg.no_doc);
    hasil := hasil || jsonb_build_object('uji', 'Dokumen lunas tampil di Open; dokumen over due tampil di Restricted beserta alasan', 'lulus',
      v_n = 1 and coalesce(v_txt, '') <> '' and v_txt !~* 'belum dinilai', 'rinci', v_n || ' / ' || coalesce(v_txt, 'tidak tampil'));

    -- 3. Riwayat dokumen, Log Activity satu baris, dan catatan "data yang berlaku" tidak berubah.
    select count(*) into v_n from public.claim_status_history h where h.claim_id = kl.id and h.action = 'zdage_offer' and h.reason ~ 'Batas proses';
    select count(*), max((details->>'jumlah')::int) into v_n2, v_n from (
      select details, v_n zz from public.activity_logs where event_type = 'zdage_nilai_otomatis' and created_at >= v_awal) z;
    hasil := hasil || jsonb_build_object('uji', 'Riwayat zdage_offer tercatat; Log Activity satu baris per proses', 'lulus',
      exists(select 1 from public.claim_status_history h where h.claim_id = kl.id and h.action = 'zdage_offer' and h.reason ~ 'Batas proses')
      and v_n2 - v_log0 = 1 and v_n >= 2, 'rinci', 'log baru ' || (v_n2 - v_log0) || ', jumlah ' || coalesce(v_n::text, '-'));
    hasil := hasil || jsonb_build_object('uji', 'Waktu "data berlaku" depot tidak berubah oleh penilaian otomatis', 'lulus',
      (select updated_at from public.rc_zdage_depot_data where depot_id = dd.depot_id) = v_upd, 'rinci', v_upd::text);

    -- 4. Stabil: tanpa perubahan apa pun, penilaian berikutnya tidak menyentuh apa-apa.
    r := rc_private.zdage_nilai_baru();
    hasil := hasil || jsonb_build_object('uji', 'Penilaian ulang tanpa perubahan = 0 dokumen', 'lulus', (r->>'dinilai')::int = 0, 'rinci', r::text);

    -- 5. Dokumen yang dulu tanpa Customer Master dan sekarang tertaut dinilai lagi.
    update public.rc_zdage_hasil set hasil = 'TANPA_MASTER' where claim_id = kg.id;
    r := rc_private.zdage_nilai_baru();
    hasil := hasil || jsonb_build_object('uji', 'Hasil TANPA_MASTER pada dokumen bertoko dinilai ulang', 'lulus',
      (r->>'dinilai')::int >= 1 and (select h.hasil from public.rc_zdage_hasil h where h.claim_id = kg.id) = 'GAGAL', 'rinci', r::text);

    -- 6. Tanggal SO campaign diperbaiki: dokumen campaign itu dinilai ulang dengan bulan yang baru.
    select h.alasan->>'bulanSo' into v_txt from public.rc_zdage_hasil h where h.claim_id = kg.id;
    update public.campaigns set so_start = so_start - interval '1 month' where id = ca.id;
    r := rc_private.zdage_nilai_baru();
    hasil := hasil || jsonb_build_object('uji', 'Perubahan bulan SO campaign memicu penilaian ulang dengan bulan baru', 'lulus',
      (r->>'dinilai')::int >= 2 and (select h.alasan->>'bulanSo' from public.rc_zdage_hasil h where h.claim_id = kg.id) is distinct from v_txt
      and (rc_private.zdage_nilai_baru()->>'dinilai')::int = 0, 'rinci', v_txt || ' -> ' || (select h.alasan->>'bulanSo' from public.rc_zdage_hasil h where h.claim_id = kg.id));

    -- 7. Saklar ZDAGE mati: tidak ada penilaian.
    update public.pengaturan_sistem set nilai = 'false'::jsonb where kunci = 'zdage_aktif';
    delete from public.rc_zdage_hasil where claim_id = kg.id;
    r := rc_private.zdage_nilai_baru();
    hasil := hasil || jsonb_build_object('uji', 'Saklar ZDAGE mati: penilaian dilewati', 'lulus',
      r ? 'lewati' and not exists(select 1 from public.rc_zdage_hasil where claim_id = kg.id), 'rinci', r::text);
    update public.pengaturan_sistem set nilai = 'true'::jsonb where kunci = 'zdage_aktif';

    -- 8. Pembersihan: upload lama tak berlaku dihapus barisnya; yang berlaku dan yang baru tetap.
    insert into public.rc_zdage_uploads(id, file_name, extracted_at, as_of_month, row_count, uploaded_by, status, created_at) values
      (u_lama, 'uji-lama.xlsx', now() - interval '8 days', date_trunc('month', now())::date, 2, v_sm, 'applied', now() - interval '8 days'),
      (u_baru, 'uji-baru.xlsx', now() - interval '2 days', date_trunc('month', now())::date, 2, v_sm, 'applied', now() - interval '2 days'),
      (u_plama, 'uji-preview-lama.xlsx', now() - interval '9 days', date_trunc('month', now())::date, 1, v_sm, 'preview', now() - interval '9 days'),
      (u_pbaru, 'uji-preview-baru.xlsx', now() - interval '1 day', date_trunc('month', now())::date, 1, v_sm, 'preview', now() - interval '1 day');
    insert into public.rc_zdage_rows(upload_id, row_no, customer_code, customer_key) values
      (u_lama, 1, 'UJI1', 'UJI1'), (u_lama, 2, 'UJI2', 'UJI2'), (u_baru, 1, 'UJI1', 'UJI1'), (u_baru, 2, 'UJI2', 'UJI2'),
      (u_plama, 1, 'UJI1', 'UJI1'), (u_pbaru, 1, 'UJI1', 'UJI1');
    update public.rc_zdage_uploads set created_at = now() - interval '30 days' where id = dd.upload_id;
    select count(*) into v_baris_berlaku from public.rc_zdage_rows where upload_id = dd.upload_id;
    insert into rc_private.requests(actor_id, request_id, payload, result, dibuat_pada) values
      (v_sm, q1, '{}'::jsonb, '{}'::jsonb, now() - interval '31 days'), (v_sm, q2, '{}'::jsonb, '{}'::jsonb, now() - interval '3 days');
    r := rc_private.bersih_harian();
    hasil := hasil || jsonb_build_object('uji', 'Upload > 7 hari yang tidak berlaku: baris dihapus, ringkasan tetap', 'lulus',
      (select count(*) from public.rc_zdage_rows where upload_id = u_lama) = 0 and exists(select 1 from public.rc_zdage_uploads where id = u_lama and status = 'applied' and row_count = 2),
      'rinci', r::text);
    hasil := hasil || jsonb_build_object('uji', 'Upload < 7 hari dan upload yang berlaku (walau lama) tetap utuh', 'lulus',
      (select count(*) from public.rc_zdage_rows where upload_id = u_baru) = 2 and v_baris_berlaku > 0
      and (select count(*) from public.rc_zdage_rows where upload_id = dd.upload_id) = v_baris_berlaku, 'rinci', v_baris_berlaku::text);
    hasil := hasil || jsonb_build_object('uji', 'Preview > 7 hari dibatalkan dan barisnya dihapus; preview baru tidak disentuh', 'lulus',
      (select status from public.rc_zdage_uploads where id = u_plama) = 'discarded' and (select count(*) from public.rc_zdage_rows where upload_id = u_plama) = 0
      and (select status from public.rc_zdage_uploads where id = u_pbaru) = 'preview' and (select count(*) from public.rc_zdage_rows where upload_id = u_pbaru) = 1, 'rinci', '-');
    hasil := hasil || jsonb_build_object('uji', 'Kunci anti dobel proses > 30 hari dihapus, yang baru tetap', 'lulus',
      not exists(select 1 from rc_private.requests where request_id = q1) and exists(select 1 from rc_private.requests where request_id = q2), 'rinci', r->>'kunciProses');
    hasil := hasil || jsonb_build_object('uji', 'Pembersihan tercatat satu baris di Log Activity', 'lulus',
      (select count(*) from public.activity_logs where event_type = 'zdage_bersih' and created_at >= v_awal) = 1, 'rinci', '-');

    -- 9. Hak dan jadwal.
    hasil := hasil || jsonb_build_object('uji', 'Penilaian dan pembersihan tidak dapat dipanggil pengguna (anon / login)', 'lulus',
      not has_function_privilege('authenticated', 'rc_private.zdage_nilai_baru()', 'execute') and not has_function_privilege('anon', 'rc_private.zdage_nilai_baru()', 'execute')
      and not has_function_privilege('authenticated', 'rc_private.bersih_harian()', 'execute') and not has_function_privilege('anon', 'rc_private.bersih_harian()', 'execute'), 'rinci', '-');
    select string_agg(jobname || ' [' || schedule || ']', ', ' order by jobname) into v_txt from cron.job where jobname in ('rc_zdage_nilai', 'rc_bersih_harian');
    hasil := hasil || jsonb_build_object('uji', 'Jadwal: penilaian tiap 10 menit 07-19 WIB, pembersihan 03:40 WIB', 'lulus',
      v_txt = 'rc_bersih_harian [40 20 * * *], rc_zdage_nilai [*/10 0-12 * * *]', 'rinci', v_txt);

    raise exception 'UJI_SELESAI';
  exception when others then
    if sqlerrm <> 'UJI_SELESAI' then hasil := hasil || jsonb_build_object('uji', 'Blok uji berhenti', 'lulus', false, 'rinci', sqlerrm); end if;
  end;
  perform set_config('request.jwt.claims', '', true);
  insert into _hasil_zn(uji, lulus, rinci) select x->>'uji', (x->>'lulus')::boolean, x->>'rinci' from jsonb_array_elements(hasil) x;
end $uji$;

select urut, case when lulus then 'LULUS' else 'GAGAL' end hasil, uji, rinci from _hasil_zn order by urut;
