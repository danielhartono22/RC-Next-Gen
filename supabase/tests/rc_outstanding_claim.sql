-- ==========================================================================================
-- Uji Outstanding Claim % (20261163570000): kolom rc_report_rows, Report, Cost Center, email
-- Daily / Weekly (tolok ukur), lampiran PDF, dan pengaturan tolok ukur.
-- ==========================================================================================
-- Seluruh perubahan (sakelar approval, tolok ukur, email pratinjau) dibatalkan lewat UJI_SELESAI.
-- Tidak ada email yang dikirim: email disusun sebagai pratinjau (p_kirim = false).
--
--   node scripts/apply-sql.mjs --env dev|prod supabase/tests/rc_outstanding_claim.sql
-- ==========================================================================================
create temp table if not exists _hasil_oc(urut serial, uji text, lulus boolean, rinci text);
truncate _hasil_oc;

do $uji$
declare hasil jsonb := '[]'; r jsonb; v jsonb; v_sm uuid; v_ny uuid; v_ap uuid; v_hold integer; v_galat text;
  v_tot numeric; v_oc numeric; v_dep text; v_html text; v_aktif jsonb; n integer;
begin
  select id into v_sm from public.profiles where role = 'system manager' and status = 'active' and not must_change_password order by user_code limit 1;
  select nilai into v_aktif from public.pengaturan_sistem where kunci = 'approval_aktif';

  begin
    -- ---- Kolom outstanding_claim ------------------------------------------------------
    hasil := hasil || jsonb_build_object('uji', 'Not Yet = outstanding claim; Approved / Released / Claimed / Done / Expired / On Hold tidak',
      'lulus', not exists(select 1 from public.rc_report_rows where outstanding_claim <> (status = 'not_yet' or (status = 'submitted' and rc_private.approval_aktif()))),
      'rinci', (select string_agg(z.status || '=' || z.oc::text, ', ' order by z.status) from (select status, bool_or(outstanding_claim) oc from public.rc_report_rows group by 1) z));
    hasil := hasil || jsonb_build_object('uji', 'On Hold dan Expired tidak dihitung outstanding claim',
      'lulus', not exists(select 1 from public.rc_report_rows where status in ('on_hold', 'expired') and outstanding_claim), 'rinci', '-');

    -- Approval mati: Submitted tidak outstanding; approval hidup: Submitted outstanding.
    select id into v_ny from public.claims where status = 'not_yet' and archived_at is null order by id limit 1;
    update public.claims set status = 'submitted' where id = v_ny;
    update public.pengaturan_sistem set nilai = 'false'::jsonb where kunci = 'approval_aktif';
    hasil := hasil || jsonb_build_object('uji', 'Approval mati: dokumen Submitted (sudah diajukan Depot) bukan outstanding claim',
      'lulus', not (select outstanding_claim from public.rc_report_rows where id = v_ny), 'rinci', '-');
    update public.pengaturan_sistem set nilai = 'true'::jsonb where kunci = 'approval_aktif';
    hasil := hasil || jsonb_build_object('uji', 'Approval hidup: dokumen Submitted (belum disetujui) outstanding claim',
      'lulus', (select outstanding_claim from public.rc_report_rows where id = v_ny), 'rinci', '-');
    select id into v_ap from public.claims where status = 'approved' and archived_at is null order by id limit 1;
    hasil := hasil || jsonb_build_object('uji', 'Approval hidup: Approved bukan outstanding claim',
      'lulus', v_ap is null or not (select outstanding_claim from public.rc_report_rows where id = v_ap), 'rinci', coalesce(v_ap::text, 'tanpa dokumen approved'));
    update public.claims set status = 'not_yet' where id = v_ny;
    update public.pengaturan_sistem set nilai = coalesce(v_aktif, 'true'::jsonb) where kunci = 'approval_aktif';

    -- ---- Report --------------------------------------------------------------------
    perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);
    r := rc_private.report_dashboard('{}');
    select coalesce(sum(cb_net), 0), coalesce(sum(cb_net) filter (where outstanding_claim), 0) into v_tot, v_oc from public.rc_report_rows;
    hasil := hasil || jsonb_build_object('uji', 'KPI Report: Outstanding Claim Qty / Value / Rate = nilai outstanding claim / seluruh Net CB; Clearing Rate tetap ada',
      'lulus', (r->'kpi'->>'outstandingClaimValue')::numeric = v_oc and abs((r->'kpi'->>'outstandingClaimRate')::numeric - v_oc / nullif(v_tot, 0)) < 0.000001
        and (r->'kpi'->>'outstandingClaimQty')::int = (select count(*) from public.rc_report_rows where outstanding_claim) and r->'kpi' ? 'clearingRate',
      'rinci', (r->'kpi'->>'outstandingClaimRate') || ' / ' || (r->'kpi'->>'clearingRate'));
    select x->>'kodeDepot' into v_dep from jsonb_array_elements(r->'depot') x where (x->>'outstandingClaimQty')::int > 0 order by (x->>'outstandingClaimRate')::numeric desc limit 1;
    select coalesce(sum(cb_net), 0), coalesce(sum(cb_net) filter (where outstanding_claim), 0) into v_tot, v_oc from public.rc_report_rows where depot_code = v_dep;
    select x into v from jsonb_array_elements(r->'depot') x where x->>'kodeDepot' = v_dep;
    hasil := hasil || jsonb_build_object('uji', 'Per depot: Outstanding Claim Rate dan Value benar',
      'lulus', (v->>'outstandingClaimValue')::numeric = v_oc and abs((v->>'outstandingClaimRate')::numeric - v_oc / nullif(v_tot, 0)) < 0.000001,
      'rinci', v_dep || ' ' || (v->>'outstandingClaimRate'));
    hasil := hasil || jsonb_build_object('uji', 'Campaign dan Region juga mengirim Outstanding Claim',
      'lulus', not exists(select 1 from jsonb_array_elements(r->'campaign') x where not (x ? 'outstandingClaimRate'))
        and not exists(select 1 from jsonb_array_elements(r->'region') x where not (x ? 'outstandingClaimRate' and x ? 'outstandingClaimValue')), 'rinci', '-');
    r := rc_private.report_dashboard(jsonb_build_object('depot', v_dep));
    hasil := hasil || jsonb_build_object('uji', 'Saringan depot: KPI Outstanding Claim mengikuti saringan',
      'lulus', (r->'kpi'->>'outstandingClaimValue')::numeric = v_oc, 'rinci', r->'kpi'->>'outstandingClaimValue');
    r := rc_private.cost_center('{}');
    hasil := hasil || jsonb_build_object('uji', 'Cost Center 1 mengirim Outstanding Claim Rate / Value',
      'lulus', jsonb_array_length(r->'rows') > 0 and not exists(select 1 from jsonb_array_elements(r->'rows') x where not (x ? 'outstandingClaimRate' and x ? 'outstandingClaimValue')), 'rinci', '-');

    -- ---- Pengaturan tolok ukur --------------------------------------------------------
    r := public.rc_email_status();
    hasil := hasil || jsonb_build_object('uji', 'Pengaturan: Daily / Weekly bertolok ukur Outstanding Claim (bawaan); jenis lain tanpa tolok ukur',
      'lulus', (select bool_and(case when x->>'jenis' in ('daily', 'weekly') then x->>'tolokUkur' = 'outstanding_claim' else x->'tolokUkur' = 'null'::jsonb end)
                  from jsonb_array_elements(r->'pengaturan') x),
      'rinci', (select string_agg((x->>'jenis') || '=' || coalesce(x->>'tolokUkur', '-'), ', ') from jsonb_array_elements(r->'pengaturan') x));
    begin perform public.rc_email_settings_simpan('[{"jenis":"daily","tolokUkur":"apa"}]'); v_galat := 'lolos'; exception when others then v_galat := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'Tolok ukur tidak dikenal ditolak', 'lulus', v_galat ~ 'Tolok ukur', 'rinci', v_galat);

    -- ---- Email Daily / Weekly (pratinjau, tanpa login: jalur penjadwal) ---------------
    perform set_config('request.jwt.claims', '', true);
    r := public.rc_email_susun('daily', false);
    v_html := coalesce(r->>'isiHtml', '');
    select string_agg(x.d, ',' order by x.urut) into v_galat from (
      select d.depot_code d, row_number() over (order by coalesce(sum(c.cb_net) filter (where c.outstanding_claim), 0) / nullif(sum(c.cb_net), 0) desc,
                                                  coalesce(sum(c.cb_net) filter (where c.outstanding_claim), 0) desc) urut
        from public.rc_report_rows c join public.depots d on d.id = c.depot_id group by d.depot_code
       having coalesce(sum(c.cb_net), 0) > 0 and coalesce(sum(c.cb_net) filter (where c.outstanding_claim), 0) > 0) x where x.urut <= 5;
    hasil := hasil || jsonb_build_object('uji', 'Daily: Top 5 Depot dengan Outstanding Claim Tertinggi (urut Outstanding Claim %), kolom Outstanding Claim',
      'lulus', v_html ~ 'Top 5 Depot dengan Outstanding Claim Tertinggi' and v_html !~ 'Clearing Rate Terendah' and v_html ~ '>Outstanding Claim</th>'
        and v_html ~ 'Outstanding Claim sebesar'
        -- Sejak 20261163580000 kode depot berdiri sendiri di kolomnya (<strong>kode</strong>).
        and position('<strong>' || split_part(v_galat, ',', 1) || '</strong>' in v_html) > 0
        and position('<strong>' || split_part(v_galat, ',', 1) || '</strong>' in v_html) < position('<strong>' || split_part(v_galat, ',', 2) || '</strong>' in v_html),
      'rinci', coalesce(v_galat, '-'));
    update public.email_settings set tolok_ukur = 'clearing_rate' where jenis in ('daily', 'weekly');
    r := public.rc_email_susun('daily', false);
    hasil := hasil || jsonb_build_object('uji', 'Daily bertolok ukur Clearing Rate: kembali ke Top 5 Clearing Rate Terendah',
      'lulus', r->>'isiHtml' ~ 'Top 5 Depot dengan Clearing Rate Terendah' and r->>'isiHtml' !~ 'Outstanding Claim Tertinggi', 'rinci', '-');
    r := public.rc_email_susun('weekly', false);
    hasil := hasil || jsonb_build_object('uji', 'Weekly bertolok ukur Clearing Rate: Top 10 Clearing Rate Terendah, kartu Outstanding Claim tetap',
      'lulus', r->>'isiHtml' ~ 'Top 10 Depot dengan Clearing Rate Terendah' and r->>'isiHtml' ~ 'Outstanding Claim</div>', 'rinci', '-');
    update public.email_settings set tolok_ukur = 'outstanding_claim' where jenis in ('daily', 'weekly');
    r := public.rc_email_susun('weekly', false);
    v_html := coalesce(r->>'isiHtml', '');
    hasil := hasil || jsonb_build_object('uji', 'Weekly: Top 10 Outstanding Claim Tertinggi, kartu KPI dan kolom Region Outstanding Claim',
      'lulus', v_html ~ 'Top 10 Depot dengan Outstanding Claim Tertinggi' and v_html ~ 'Outstanding Claim</div>'
        and (length(v_html) - length(replace(v_html, '>Outstanding Claim</th>', ''))) / length('>Outstanding Claim</th>') = 2,
      'rinci', '-');

    v_html := rc_private.pdf_detail_html('Uji');
    hasil := hasil || jsonb_build_object('uji', 'Lampiran PDF Daily: ringkasan dan Top 10 mengikuti tolok ukur (Outstanding Claim)',
      'lulus', v_html ~ 'Top 10 Depot dengan Outstanding Claim Tertinggi' and v_html ~ 'Outstanding Claim \(', 'rinci', '-');

    perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);
    r := public.rc_email_settings_simpan('[{"jenis":"weekly","tolokUkur":"clearing_rate"}]');
    hasil := hasil || jsonb_build_object('uji', 'Simpan tolok ukur Weekly = Clearing Rate tersimpan; Daily tidak berubah',
      'lulus', (select tolok_ukur from public.email_settings where jenis = 'weekly') = 'clearing_rate'
        and (select tolok_ukur from public.email_settings where jenis = 'daily') = 'outstanding_claim', 'rinci', r->>'message');

    raise exception 'UJI_SELESAI';
  exception when others then
    if sqlerrm <> 'UJI_SELESAI' then hasil := hasil || jsonb_build_object('uji', 'Blok uji berhenti', 'lulus', false, 'rinci', sqlerrm); end if;
  end;
  perform set_config('request.jwt.claims', '', true);
  insert into _hasil_oc(uji, lulus, rinci) select x->>'uji', (x->>'lulus')::boolean, x->>'rinci' from jsonb_array_elements(hasil) x;
end $uji$;

select urut, case when lulus then 'LULUS' else 'GAGAL' end hasil, uji, rinci from _hasil_oc order by urut;
