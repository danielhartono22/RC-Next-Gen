-- ==========================================================================================
-- Uji 11 November 2026: Edit Akses System Manager (890000) dan status campaign Running (900000)
-- ==========================================================================================
-- Seluruh perubahan dibatalkan lewat UJI_SELESAI. Email hanya ke alamat uji dan ikut dibatalkan.
--   node scripts/apply-sql.mjs --env dev|prod supabase/tests/rc_status_running_20261111.sql
-- ==========================================================================================
create temp table if not exists _hasil_rn(urut serial, uji text, lulus boolean, rinci text);
truncate _hasil_rn;

create or replace function pg_temp.coba(p_sql text) returns text language plpgsql as $f$
begin execute p_sql; return 'OK';
exception when others then return sqlerrm; end $f$;

do $uji$
declare hasil jsonb := '[]'; v_sm uuid; v_galat text; r jsonb; v_hari date := (now() at time zone 'Asia/Jakarta')::date;
  v_sup record; v_osc uuid; ca record; k record; n1 uuid; n2 uuid; n3 uuid; v_log bigint; v_baris jsonb; d1 text;
  fmt constant text := 'DD-Mon-YYYY';
begin
  select id into v_sm from public.profiles where role = 'system manager' and status = 'active' and not must_change_password and suffix_num ~ '^[0-9]{3}$' order by user_code limit 1;
  perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);

  begin
    update public.email_settings set aktif = true, mode_uji = true, email_uji = 'uji@example.com' where jenis = 'pengajuan';

    -- ---- 890000: Edit Akses ----------------------------------------------------------------------
    select s.id, s.user_code, array_agg(o.user_code order by o.user_code) osc into v_sup
      from public.user_supervision us join public.profiles s on s.id = us.supervisor_id join public.profiles o on o.id = us.osc_id
     where s.role = 'supervisor' and s.status = 'active' and o.role = 'osc' group by 1, 2 order by 2 limit 1;
    if v_sup.id is null then raise exception 'Fixture: Supervisor dengan OSC binaan tidak ada'; end if;
    update public.profiles set status = 'inactive' where user_code = v_sup.osc[1] returning id into v_osc;
    begin
      r := public.rc_update_access(jsonb_build_object('userId', v_sup.user_code, 'assignedOsc', to_jsonb(v_sup.osc))); v_galat := 'OK';
    exception when others then v_galat := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'System Manager menyimpan akses Supervisor yang membina OSC tidak aktif',
      'lulus', v_galat = 'OK' and exists(select 1 from public.user_supervision where supervisor_id = v_sup.id and osc_id = v_osc),
      'rinci', v_sup.user_code || ' / ' || v_sup.osc[1] || ': ' || v_galat);
    begin
      r := public.rc_update_access(jsonb_build_object('userId', v_sup.user_code, 'assignedOsc', jsonb_build_array('TIDAKADA99'))); v_galat := 'lolos';
    exception when others then v_galat := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'Kode yang bukan OSC tetap ditolak, pesannya menyebut kodenya',
      'lulus', v_galat ~ 'TIDAKADA99' and v_galat ~ 'berperan OSC', 'rinci', v_galat);

    -- ---- 900000: Batas Compile --------------------------------------------------------------------
    hasil := hasil || jsonb_build_object('uji', 'Hitungan Batas Compile: billing end + 1 bulan; dibuat > 1 minggu sesudahnya = dibuat + 1 bulan',
      'lulus', rc_private.batas_compile_hitung(date '2026-10-31', date '2026-11-07') = date '2026-11-30'
           and rc_private.batas_compile_hitung(date '2026-10-31', date '2026-11-08') = date '2026-12-08'
           and rc_private.batas_compile_hitung(null, date '2026-11-11') = date '2026-12-11'
           and rc_private.batas_compile_hitung(date '2026-12-31', date '2026-11-11') = date '2027-01-31', 'rinci', '-');
    hasil := hasil || jsonb_build_object('uji', 'Tidak ada campaign tanpa Batas Compile dan tidak ada status Cleared',
      'lulus', not exists(select 1 from public.campaigns where batas_compile is null) and not exists(select 1 from public.campaigns where status = 'cleared'), 'rinci', '-');

    perform public.rc_campaign_upsert(jsonb_build_array(
      jsonb_build_object('codeCampaign', 'UJIRUN1', 'campaignName', 'Uji Running 1', 'billingStart', to_char(v_hari - 60, fmt), 'billingEnd', to_char(v_hari + 10, fmt)),
      jsonb_build_object('codeCampaign', 'UJIRUN2', 'campaignName', 'Uji Running 2', 'billingStart', to_char(v_hari - 90, fmt), 'billingEnd', to_char(v_hari - 30, fmt))));
    hasil := hasil || jsonb_build_object('uji', 'Campaign baru: bawaan Active; batas billing end + 1 bulan, atau dibuat + 1 bulan bila billing end sudah lewat > 1 minggu',
      'lulus', (select status = 'active' and batas_compile = (v_hari + 10 + interval '1 month')::date from public.campaigns where campaign_code = 'UJIRUN1')
           and (select status = 'active' and batas_compile = (v_hari + interval '1 month')::date from public.campaigns where campaign_code = 'UJIRUN2'),
      'rinci', (select string_agg(campaign_code || ' ' || status || ' ' || batas_compile, ', ') from public.campaigns where campaign_code like 'UJIRUN%'));
    v_galat := pg_temp.coba($s$select public.rc_campaign_upsert('[{"codeCampaign":"UJIRUN1","status":"cleared"}]'::jsonb)$s$);
    d1 := pg_temp.coba($s$select public.rc_campaign_upsert('[{"codeCampaign":"UJIRUN1","status":"running"}]'::jsonb)$s$);
    hasil := hasil || jsonb_build_object('uji', 'Status Cleared ditolak; Running diterima',
      'lulus', v_galat ~ 'Cleared tidak dipakai' and d1 = 'OK'
           and (select status from public.campaigns where campaign_code = 'UJIRUN1') = 'running', 'rinci', v_galat || ' / ' || d1);
    perform public.rc_campaign_upsert(jsonb_build_array(jsonb_build_object('codeCampaign', 'UJIRUN1', 'status', 'active', 'billingEnd', to_char(v_hari - 3, fmt))));
    hasil := hasil || jsonb_build_object('uji', 'Billing End diubah: Batas Compile dihitung ulang',
      'lulus', (select batas_compile from public.campaigns where campaign_code = 'UJIRUN1') = (v_hari - 3 + interval '1 month')::date,
      'rinci', (select batas_compile::text from public.campaigns where campaign_code = 'UJIRUN1'));
    perform public.rc_campaign_upsert(jsonb_build_array(jsonb_build_object('codeCampaign', 'UJIRUN1', 'batasCompile', to_char(v_hari + 5, fmt))));
    d1 := (select batas_compile::text from public.campaigns where campaign_code = 'UJIRUN1');
    perform public.rc_campaign_upsert(jsonb_build_array(jsonb_build_object('codeCampaign', 'UJIRUN1', 'batasCompile', '')));
    hasil := hasil || jsonb_build_object('uji', 'Batas Compile dapat ditimpa; dikosongkan = dihitung ulang',
      'lulus', d1 = (v_hari + 5)::text and (select batas_compile from public.campaigns where campaign_code = 'UJIRUN1') = (v_hari - 3 + interval '1 month')::date
           and pg_temp.coba($s$select public.rc_campaign_upsert('[{"codeCampaign":"UJIRUN1","batasCompile":"besok"}]'::jsonb)$s$) ~ 'tidak terbaca',
      'rinci', d1);
    r := public.rc_campaign_list('UJIRUN1', 0, 5);
    hasil := hasil || jsonb_build_object('uji', 'Campaign Master menampilkan Batas Compile (dd-Mmm-yyyy)',
      'lulus', r->'rows'->0->>'batasCompile' = to_char(v_hari - 3 + interval '1 month', fmt), 'rinci', r->'rows'->0->>'batasCompile');

    -- ---- Compile, pemindah otomatis, buka kembali -------------------------------------------------
    select c.campaign_id id, ca2.campaign_code kode into ca from public.claims c join public.campaigns ca2 on ca2.id = c.campaign_id
     where ca2.status = 'active' and ca2.archived_at is null and c.archived_at is null group by 1, 2
    having count(*) filter (where c.status = 'not_yet' and c.customer_id is not null and c.pending_approval is null) >= 3
     order by count(*) limit 1;
    if ca.id is null then raise exception 'Fixture: campaign dengan 3 Not Yet tidak ada'; end if;
    select d.depot_code, cu.customer_code into k from public.claims c join public.depots d on d.id = c.depot_id join public.customers cu on cu.id = c.customer_id
     where c.campaign_id = ca.id and c.archived_at is null limit 1;
    v_baris := jsonb_build_array(jsonb_build_object('kodeDepot', k.depot_code, 'codeCampaign', ca.kode, 'custCode', k.customer_code, 'cbNet', '1000', 'netValue', '1000', 'volume', '1'));
    update public.campaigns set batas_compile = v_hari - 1 where id = ca.id;
    r := public.rc_compile_preview(v_baris);
    hasil := hasil || jsonb_build_object('uji', 'Batas Compile lewat: compile ditolak walau status masih Active',
      'lulus', r->'ditolak'->0->>'alasan' ~ 'Batas Compile', 'rinci', r->'ditolak'->0->>'alasan');

    update public.campaigns set batas_compile = v_hari - 1 where campaign_code = 'UJIRUN2';
    select count(*) into v_log from public.activity_logs where event_type = 'campaign_status_otomatis';
    r := rc_private.campaign_batas_jalan();
    hasil := hasil || jsonb_build_object('uji', 'Pemindah otomatis: punya dokumen -> Running, tanpa dokumen -> Closed, satu Log Activity',
      'lulus', (select status from public.campaigns where id = ca.id) = 'running' and (select status from public.campaigns where campaign_code = 'UJIRUN2') = 'closed'
           and r->'running' ? ca.kode and r->'closed' ? 'UJIRUN2'
           and (select count(*) from public.activity_logs where event_type = 'campaign_status_otomatis') = v_log + 1, 'rinci', r::text);
    r := public.rc_compile_preview(v_baris);
    hasil := hasil || jsonb_build_object('uji', 'Running: compile ditolak', 'lulus', r->'ditolak'->0->>'alasan' ~ 'Running', 'rinci', r->'ditolak'->0->>'alasan');
    update public.campaigns set status = 'active' where id = ca.id;
    hasil := hasil || jsonb_build_object('uji', 'Running dibuka kembali menjadi Active: Batas Compile 1 bulan dari hari ini',
      'lulus', (select batas_compile from public.campaigns where id = ca.id) = (v_hari + interval '1 month')::date,
      'rinci', (select batas_compile::text from public.campaigns where id = ca.id));

    -- ---- Inactive: compile dan Claim Upload ditutup; yang sudah Submitted tetap berjalan ------------
    select jsonb_agg(z.id order by z.no_doc) into v_baris from (select c.id, c.no_doc from public.claims c
      where c.campaign_id = ca.id and c.status = 'not_yet' and c.customer_id is not null and c.pending_approval is null and c.archived_at is null order by c.no_doc limit 3) z;
    n1 := (v_baris->>0)::uuid; n2 := (v_baris->>1)::uuid; n3 := (v_baris->>2)::uuid;
    update public.claims set status = 'submitted' where id = n1;
    update public.campaigns set status = 'inactive' where id = ca.id;
    r := public.rc_compile_preview(jsonb_build_array(jsonb_build_object('kodeDepot', k.depot_code, 'codeCampaign', ca.kode, 'custCode', k.customer_code, 'cbNet', '1000', 'netValue', '1000', 'volume', '1')));
    v_galat := pg_temp.coba(format('update public.claims set status = %L where id = %L', 'submitted', n2));
    hasil := hasil || jsonb_build_object('uji', 'Inactive: compile dan Claim Upload (Not Yet -> Submitted) ditolak',
      'lulus', r->'ditolak'->0->>'alasan' ~ 'Inactive' and v_galat ~ 'Inactive; Claim Upload ditutup', 'rinci', v_galat);
    v_galat := pg_temp.coba(format('update public.claims set status = %L where id = %L', 'released', n1));
    hasil := hasil || jsonb_build_object('uji', 'Inactive: dokumen yang sudah Submitted tetap boleh maju', 'lulus', v_galat = 'OK', 'rinci', v_galat);

    -- ---- Closed: ditolak saat Release / Change Status -> Not Yet dan boleh diproses kembali -------------
    update public.campaigns set status = 'active' where id = ca.id;
    update public.claims set status = 'submitted' where id = n3;
    update public.campaigns set status = 'closed' where id = ca.id;
    hasil := hasil || jsonb_build_object('uji', 'Closed: Not Yet menjadi Expired, Submitted tetap',
      'lulus', (select status from public.claims where id = n2) = 'expired' and (select status from public.claims where id = n3) = 'submitted', 'rinci', '-');
    v_galat := pg_temp.coba(format('update public.claims set status = %L where id = %L', 'not_yet', n3));
    d1 := pg_temp.coba(format('update public.claims set status = %L where id = %L', 'submitted', n3));
    hasil := hasil || jsonb_build_object('uji', 'Closed: ditolak saat Release kembali Not Yet dan depot boleh Claim Upload lagi',
      'lulus', v_galat = 'OK' and d1 = 'OK' and (select status from public.claims where id = n3) = 'submitted', 'rinci', v_galat || ' / ' || d1);
    r := public.rc_change_status_cek(jsonb_build_array(jsonb_build_object('noDoc', (select no_doc from public.claims where id = n2))));
    hasil := hasil || jsonb_build_object('uji', 'Change Status menerima Expired campaign Closed',
      'lulus', r->'rows'->0->>'galat' is null and r->'rows'->0->>'statusDok' = 'Expired', 'rinci', coalesce(r->'rows'->0->>'galat', 'tanpa galat'));
    r := public.rc_change_status(jsonb_build_array(jsonb_build_object('noDoc', (select no_doc from public.claims where id = n2))), 'Uji Closed');
    d1 := (select status from public.claims where id = n2);
    v_galat := pg_temp.coba(format('update public.claims set status = %L where id = %L', 'submitted', n2));
    r := public.rc_compile_preview(jsonb_build_array(jsonb_build_object('kodeDepot', k.depot_code, 'codeCampaign', ca.kode, 'custCode', k.customer_code, 'cbNet', '1000', 'netValue', '1000', 'volume', '1')));
    hasil := hasil || jsonb_build_object('uji', 'Change Status di campaign Closed: Not Yet dan boleh diproses kembali; compile tetap ditutup',
      'lulus', d1 = 'not_yet' and v_galat = 'OK' and r->'ditolak'->0->>'alasan' ~ 'Closed',
      'rinci', d1 || ' / ' || v_galat || ' / ' || coalesce(r->'ditolak'->0->>'alasan', '-'));
    v_galat := pg_temp.coba(format('update public.campaigns set status = %L where id = %L', 'active', ca.id));
    hasil := hasil || jsonb_build_object('uji', 'Closed tetap tidak dapat dibuka kembali', 'lulus', v_galat ~ 'tidak dapat dibuka kembali', 'rinci', v_galat);

    raise exception 'UJI_SELESAI';
  exception when others then
    if sqlerrm <> 'UJI_SELESAI' then hasil := hasil || jsonb_build_object('uji', 'Blok uji berhenti', 'lulus', false, 'rinci', sqlerrm); end if;
  end;
  perform set_config('request.jwt.claims', '', true);
  insert into _hasil_rn(uji, lulus, rinci) select x->>'uji', (x->>'lulus')::boolean, x->>'rinci' from jsonb_array_elements(hasil) x;
end $uji$;

select urut, case when lulus then 'LULUS' else 'GAGAL' end hasil, uji, rinci from _hasil_rn order by urut;
