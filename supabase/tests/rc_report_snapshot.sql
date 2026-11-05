-- ==========================================================================================
-- Uji Report dari snapshot (20261163600000): salinan rc_report_rows, penyegar (jadwal, email,
-- manual), Report tanpa / dengan filter, dashboard publik, email Daily / Weekly.
-- ==========================================================================================
-- Seluruh perubahan (status klaim, snapshot, log, email) dibatalkan lewat UJI_SELESAI.
--
--   node scripts/apply-sql.mjs --env dev|prod supabase/tests/rc_report_snapshot.sql
-- ==========================================================================================
create temp table if not exists _hasil_snap(urut serial, uji text, lulus boolean, rinci text);
truncate _hasil_snap;

do $uji$
declare hasil jsonb := '[]'; r jsonb; r2 jsonb; v_sm uuid; v_tanpa uuid; v_klaim uuid; v_dep text; v_galat text;
  v_cr_lama numeric; v_kpi_dep jsonb; v_waktu timestamptz; v_sumber text; n integer; u record;
begin
  select id into v_sm from public.profiles where role = 'system manager' and status = 'active' and not must_change_password order by user_code limit 1;
  for u in select p.id from public.profiles p where p.status = 'active' order by p.user_code limit 200 loop
    perform set_config('request.jwt.claims', json_build_object('sub', u.id::text, 'role', 'authenticated')::text, true);
    if not (rc_private.can_tab('report.dashboard') or rc_private.can_tab('report.cc1') or rc_private.can_tab('report.cc2')) then
      v_tanpa := u.id; exit; end if;
  end loop;

  begin
    perform set_config('request.jwt.claims', '', true);
    perform rc_private.segarkan_report('uji');

    -- ---- Salinan ----------------------------------------------------------------------
    hasil := hasil || jsonb_build_object('uji', 'Salinan: kolom sama persis dengan rc_report_rows',
      'lulus', (select string_agg(attname || format_type(atttypid, atttypmod), ',' order by attnum) from pg_attribute
                 where attrelid = 'public.rc_report_rows'::regclass and attnum > 0 and not attisdropped)
             = (select string_agg(attname || format_type(atttypid, atttypmod), ',' order by attnum) from pg_attribute
                 where attrelid = 'rc_private.report_rows_snap'::regclass and attnum > 0 and not attisdropped), 'rinci', '-');
    hasil := hasil || jsonb_build_object('uji', 'Salinan: isi sama dengan rc_report_rows sesudah disegarkan',
      'lulus', not exists ((select * from public.rc_report_rows) except (select * from rc_private.report_rows_snap))
           and (select count(*) from public.rc_report_rows) = (select count(*) from rc_private.report_rows_snap),
      'rinci', (select count(*) from rc_private.report_rows_snap)::text || ' baris');
    -- pg-safeupdate (aktif pada panggilan API) menolak DELETE tanpa WHERE; uji ini berjalan tanpa
    -- pustaka itu, jadi bentuk perintahnya diperiksa langsung.
    hasil := hasil || jsonb_build_object('uji', 'Penyegar: DELETE salinan ber-WHERE (lolos pg-safeupdate di panggilan API)',
      'lulus', pg_get_functiondef('rc_private.segarkan_report(text,interval)'::regprocedure) ~ 'delete from rc_private\.report_rows_snap where true'
           and pg_get_functiondef('rc_private.segarkan_report(text,interval)'::regprocedure) !~ 'delete from rc_private\.report_rows_snap\s*;', 'rinci', '-');
    hasil := hasil || jsonb_build_object('uji', 'Salinan tidak bisa dibaca anon; Report (authenticated) bisa',
      'lulus', not has_table_privilege('anon', 'rc_private.report_rows_snap', 'select')
           and has_table_privilege('authenticated', 'rc_private.report_rows_snap', 'select')
           and not has_table_privilege('authenticated', 'rc_private.report_rows_snap', 'insert'), 'rinci', '-');

    -- ---- Data berubah, snapshot tetap ----------------------------------------------------
    perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);
    r := public.rc_report_dashboard('{}');
    v_cr_lama := (r->'kpi'->>'clearingRate')::numeric;
    select c.id, v.depot_code into v_klaim, v_dep from public.claims c join public.rc_report_rows v on v.id = c.id
     where c.status = 'not_yet' and c.archived_at is null and v.cb_net > 0 order by c.id limit 1;
    v_kpi_dep := public.rc_report_dashboard(jsonb_build_object('depot', v_dep))->'kpi';
    update public.claims set status = 'expired' where id = v_klaim;
    r2 := public.rc_report_dashboard('{}');
    hasil := hasil || jsonb_build_object('uji', 'Klaim berubah: Report tanpa filter tetap angka snapshot (belum disegarkan)',
      'lulus', r2 = r and (select status from public.rc_report_rows where id = v_klaim) = 'expired', 'rinci', '-');
    hasil := hasil || jsonb_build_object('uji', 'Klaim berubah: Report dengan filter depot juga membaca snapshot',
      'lulus', public.rc_report_dashboard(jsonb_build_object('depot', v_dep))->'kpi' = v_kpi_dep, 'rinci', v_dep);
    hasil := hasil || jsonb_build_object('uji', 'Report tanpa filter = JSON dashboard publik (satu sumber)',
      'lulus', r2 = (public.rc_dashboard_publik('{}')->'dashboard')
           and public.rc_cost_center('{}') = (public.rc_dashboard_publik('{}')->'cc1')
           and public.rc_cost_center_2('{"region":""}') = (public.rc_dashboard_publik('{}')->'cc2'), 'rinci', '-');

    -- ---- Penyegar manual -----------------------------------------------------------------
    r := public.rc_report_segarkan();
    hasil := hasil || jsonb_build_object('uji', 'Perbarui Data dalam 5 menit sesudah snapshot: tidak dihitung ulang',
      'lulus', r->>'status' = 'success' and (r->>'diperbarui')::boolean = false, 'rinci', r::text);
    update rc_private.report_snap_meta set dibuat_pada = now() - interval '6 minutes' where id;
    select count(*) into n from public.activity_logs where event_type = 'report_snapshot_manual';
    r := public.rc_report_segarkan();
    hasil := hasil || jsonb_build_object('uji', 'Perbarui Data sesudah 5 menit: snapshot dihitung ulang, dicatat sekali di Log Activity',
      'lulus', (r->>'diperbarui')::boolean and (select sumber from rc_private.report_snap_meta) = 'manual'
           and (select oleh from rc_private.report_snap_meta) = v_sm
           and (select count(*) from public.activity_logs where event_type = 'report_snapshot_manual') = n + 1,
      'rinci', r::text);
    r2 := public.rc_report_dashboard('{}');
    hasil := hasil || jsonb_build_object('uji', 'Sesudah diperbarui: Report memuat perubahan klaim (Clearing Rate naik)',
      'lulus', (r2->'kpi'->>'clearingRate')::numeric > v_cr_lama
           and (select status from rc_private.report_rows_snap where id = v_klaim) = 'expired',
      'rinci', v_cr_lama::text || ' -> ' || (r2->'kpi'->>'clearingRate'));
    hasil := hasil || jsonb_build_object('uji', 'Data per = waktu snapshot, format dd-Mmm-yyyy HH:MI',
      'lulus', r2->>'dibuatPada' ~ '^\d{2}-[A-Z][a-z]{2}-\d{4} \d{2}:\d{2}$'
           and r2->>'dibuatPada' = to_char((select dibuat_pada from rc_private.report_snap_meta) at time zone 'Asia/Jakarta', 'DD-Mon-YYYY HH24:MI')
           and public.rc_dashboard_publik('{}')->>'dibuatPada' = r2->>'dibuatPada', 'rinci', r2->>'dibuatPada');

    if v_tanpa is not null then
      perform set_config('request.jwt.claims', json_build_object('sub', v_tanpa::text, 'role', 'authenticated')::text, true);
      begin perform public.rc_report_segarkan(); v_galat := 'lolos'; exception when others then v_galat := sqlerrm; end;
    else v_galat := 'Akses tab Report (tidak ada user tanpa tab)'; end if;
    hasil := hasil || jsonb_build_object('uji', 'Perbarui Data ditolak bagi user tanpa tab Report',
      'lulus', v_galat ~ 'Akses tab Report', 'rinci', v_galat);
    hasil := hasil || jsonb_build_object('uji', 'Perbarui Data tidak bisa dipanggil anon',
      'lulus', not has_function_privilege('anon', 'public.rc_report_segarkan()', 'execute'), 'rinci', '-');

    -- ---- Dashboard publik ------------------------------------------------------------------
    update rc_private.dashboard_publik_cache set dibuat_pada = now() - interval '20 hours' where kunci = 'semua';
    hasil := hasil || jsonb_build_object('uji', 'Dashboard publik: snapshot 20 jam (malam) tetap dipakai, tidak dihitung langsung',
      'lulus', public.rc_dashboard_publik('{}') = (select isi from rc_private.dashboard_publik_cache where kunci = 'semua'), 'rinci', '-');

    -- ---- Email -----------------------------------------------------------------------------
    perform set_config('request.jwt.claims', '', true);
    update rc_private.report_snap_meta set dibuat_pada = now() - interval '1 hour', sumber = 'lama' where id;
    r := public.rc_email_susun('daily', false);
    hasil := hasil || jsonb_build_object('uji', 'Pratinjau email Daily tidak menyegarkan snapshot',
      'lulus', r->>'status' = 'success' and (select sumber from rc_private.report_snap_meta) = 'lama', 'rinci', '-');
    update public.claims set status = 'not_yet' where id = v_klaim;
    r := public.rc_email_susun('daily', true);
    hasil := hasil || jsonb_build_object('uji', 'Email Daily dikirim: snapshot disegarkan lebih dulu (perubahan klaim ikut)',
      'lulus', r->>'status' = 'success' and (select sumber from rc_private.report_snap_meta) = 'email daily'
           and (select status from rc_private.report_rows_snap where id = v_klaim) = 'not_yet',
      'rinci', coalesce(r->>'message', '') || ' | ' || (select sumber from rc_private.report_snap_meta));
    select dibuat_pada into v_waktu from rc_private.report_snap_meta;
    r := public.rc_email_susun('weekly', true);
    hasil := hasil || jsonb_build_object('uji', 'Email Weekly di menit yang sama: snapshot tidak dihitung dua kali',
      'lulus', r->>'status' = 'success' and (select sumber from rc_private.report_snap_meta) = 'email daily'
           and (select dibuat_pada from rc_private.report_snap_meta) = v_waktu, 'rinci', '-');
    r := public.rc_email_susun('daily', false);
    hasil := hasil || jsonb_build_object('uji', 'Isi email Daily: Outstanding Claim keseluruhan dari snapshot',
      'lulus', position('Outstanding Claim sebesar ' || rc_private.persen((select coalesce(sum(cb_net) filter (where outstanding_claim), 0) / nullif(sum(cb_net), 0)
                                 from rc_private.report_rows_snap)) in coalesce(r->>'isiHtml', '')) > 0,
      'rinci', rc_private.persen((select coalesce(sum(cb_net) filter (where outstanding_claim), 0) / nullif(sum(cb_net), 0)
                                 from rc_private.report_rows_snap)));

    -- ---- Jadwal ----------------------------------------------------------------------------
    hasil := hasil || jsonb_build_object('uji', 'Jadwal: 07, 09, 11, 13, 15, 17 WIB; jadwal 5 menit lama dihapus',
      'lulus', exists (select 1 from cron.job where jobname = 'rc_report_snapshot' and schedule = '0 0,2,4,6,8,10 * * *' and active
                         and command ~ 'segarkan_report')
           and not exists (select 1 from cron.job where jobname = 'rc_dashboard_publik_segar'),
      'rinci', (select string_agg(jobname || ' ' || schedule, ', ') from cron.job where jobname ~ 'report|publik'));

    raise exception 'UJI_SELESAI';
  exception when others then
    if sqlerrm <> 'UJI_SELESAI' then hasil := hasil || jsonb_build_object('uji', 'Blok uji berhenti', 'lulus', false, 'rinci', sqlerrm); end if;
  end;
  perform set_config('request.jwt.claims', '', true);
  insert into _hasil_snap(uji, lulus, rinci) select x->>'uji', (x->>'lulus')::boolean, x->>'rinci' from jsonb_array_elements(hasil) x;
end $uji$;

select urut, case when lulus then 'LULUS' else 'GAGAL' end hasil, uji, rinci from _hasil_snap order by urut;
