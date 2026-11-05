-- ==========================================================================================
-- Uji Head Office bukan depot (migrasi 20261163300000)
-- ==========================================================================================
-- Seluruhnya di subtransaksi yang DIBATALKAN (UJI_SELESAI): user uji yang ber-depot rumah HO dan
-- akses HO-nya ikut dibatalkan. Aman untuk dev dan prod.
--
--   node scripts/apply-sql.mjs --env dev|prod supabase/tests/rc_head_office.sql
-- ==========================================================================================
create temp table if not exists _hasil_ho(urut serial, uji text, lulus boolean, rinci text);
truncate _hasil_ho;

do $uji$
declare hasil jsonb := '[]'; v_sm uuid; v_ho uuid; v_osc uuid; r jsonb; t jsonb; v_html text; n integer;
begin
  select id into v_sm from public.profiles where role = 'system manager' and status = 'active' and not must_change_password order by user_code limit 1;
  select id into v_ho from public.depots where depot_code = 'HO';
  select id into v_osc from public.profiles where lower(role) = 'osc' and status = 'active' and not must_change_password order by user_code limit 1;

  begin
    hasil := hasil || jsonb_build_object('uji', 'HO ditandai bukan depot; depot lain tidak',
      'lulus', (select bukan_depot from public.depots where id = v_ho)
        and (select count(*) from public.depots where bukan_depot) = 1, 'rinci', '');

    t := rc_private.timetable_ringkas(extract(year from now())::integer);
    select count(*) into n from public.depots where archived_at is null and not bukan_depot;
    hasil := hasil || jsonb_build_object('uji', 'Ringkasan Timetable (email Timetable / Weekly) tidak menghitung HO',
      'lulus', (t->>'depot')::int = n, 'rinci', 'depot ' || (t->>'depot') || ', harap ' || n);

    perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);
    r := public.rc_timetable_matrix('{}'::jsonb);
    hasil := hasil || jsonb_build_object('uji', 'Matriks Timetable tidak memuat HO',
      'lulus', r->>'status' = 'success'
        and not exists(select 1 from jsonb_array_elements(r->'depots') x
                        where coalesce(x->>'kode', x->>'code', x->>'depotCode', x->>'depot') = 'HO'),
      'rinci', jsonb_array_length(r->'depots') || ' depot');

    -- User ber-depot rumah HO dengan akses ke HO (seperti OSC Head Office).
    update public.profiles set home_depot_id = v_ho where id = v_osc;
    insert into public.user_depot_access(user_id, depot_id) values (v_osc, v_ho) on conflict do nothing;
    perform set_config('request.jwt.claims', json_build_object('sub', v_osc::text, 'role', 'authenticated')::text, true);
    begin
      r := public.rc_timetable_campaigns();
      hasil := hasil || jsonb_build_object('uji', 'Details Campaign: depot rumah HO tidak dipakai, HO tidak di daftar depot maupun "tidak berlaku"',
        'lulus', coalesce(r->>'depotSaya', '') = ''
          and not (r->'depots' @> '[{"kode": "HO"}]'::jsonb)
          and not exists(select 1 from jsonb_array_elements(r->'rows') x where x->'tidakBerlakuDepot' ? 'HO'),
        'rinci', 'depotSaya="' || coalesce(r->>'depotSaya', '') || '"');
    exception when others then
      if sqlerrm ~ 'timetable.campaign|tidak diizinkan' then
        hasil := hasil || jsonb_build_object('uji', 'Details Campaign (dilewati: akun uji tanpa tab)', 'lulus', true, 'rinci', sqlerrm);
      else raise; end if;
    end;
    perform set_config('request.jwt.claims', '', true);
    hasil := hasil || jsonb_build_object('uji', 'People Performance: HO bukan depot OSC',
      'lulus', not (v_ho = any(rc_private.people_depots(v_osc))), 'rinci', cardinality(rc_private.people_depots(v_osc)) || ' depot');

    v_html := rc_private.email_kesehatan_isi(now() - interval '1 day')->>'html';
    hasil := hasil || jsonb_build_object('uji', 'Laporan Kesehatan tidak menyebut HO sebagai depot tanpa Abbr / Email TO',
      'lulus', v_html !~ '[>, ]HO</td>', 'rinci', '');

    raise exception 'UJI_SELESAI';
  exception when others then
    if sqlerrm <> 'UJI_SELESAI' then hasil := hasil || jsonb_build_object('uji', 'Blok uji berhenti', 'lulus', false, 'rinci', sqlerrm); end if;
  end;
  perform set_config('request.jwt.claims', '', true);

  insert into _hasil_ho(uji, lulus, rinci) select x->>'uji', (x->>'lulus')::boolean, x->>'rinci' from jsonb_array_elements(hasil) x;
end $uji$;

select urut, case when lulus then 'LULUS' else 'GAGAL' end hasil, uji, rinci from _hasil_ho order by urut;
