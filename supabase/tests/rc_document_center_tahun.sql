-- ==========================================================================================
-- Uji Document Center: saringan Tahun Campaign dan 2.000 baris per panggilan (20261163770000)
-- ==========================================================================================
-- Hanya membaca; blok diakhiri UJI_SELESAI.
--
--   node scripts/apply-sql.mjs --env dev|prod supabase/tests/rc_document_center_tahun.sql
-- ==========================================================================================
create temp table if not exists _hasil_dct(urut serial, uji text, lulus boolean, rinci text);
truncate _hasil_dct;

do $uji$
declare hasil jsonb := '[]'; r jsonb; v_sm uuid; v_th integer; n bigint; v_semua bigint;
begin
  select id into v_sm from public.profiles where role = 'system manager' and status = 'active' and not must_change_password order by user_code limit 1;
  begin
    perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);
    -- Tahun dengan dokumen terbanyak.
    select extract(year from coalesce(c.period_start, ca.period_start))::integer into v_th
      from public.claims c join public.campaigns ca on ca.id = c.campaign_id
     where c.archived_at is null and coalesce(c.period_start, ca.period_start) is not null group by 1 order by count(*) desc limit 1;
    if v_th is null then raise exception 'Fixture: tidak ada dokumen berperiode campaign'; end if;

    v_semua := (public.rc_compilation_list('', '', '', '', 0, 1)->>'total')::bigint;
    r := public.rc_compilation_list('', '', '', '', 0, 2000, '', null, null, v_th);
    select count(*) into n from public.claims c join public.campaigns ca on ca.id = c.campaign_id
     where extract(year from coalesce(c.period_start, ca.period_start)) = v_th; -- daftar ikut menghitung dokumen arsip
    hasil := hasil || jsonb_build_object('uji', 'Tahun Campaign ' || v_th || ': total = jumlah dokumen berperiode tahun itu',
      'lulus', (r->>'total')::bigint = n and (r->>'total')::bigint < v_semua, 'rinci', (r->>'total') || ' / ' || n || ' dari ' || v_semua);
    hasil := hasil || jsonb_build_object('uji', 'Satu panggilan sampai 2.000 baris; seluruh baris bertahun itu',
      'lulus', jsonb_array_length(r->'rows') = least(2000, n)
           and not exists (select 1 from jsonb_array_elements(r->'rows') x join public.claims c on c.id = (x->>'id')::uuid
                            join public.campaigns ca on ca.id = c.campaign_id
                            where extract(year from coalesce(c.period_start, ca.period_start)) is distinct from v_th),
      'rinci', jsonb_array_length(r->'rows')::text);
    r := public.rc_compilation_list('', '', '', '', 0, 5000);
    hasil := hasil || jsonb_build_object('uji', 'Batas per panggilan 2.000 (permintaan 5.000 dipotong)',
      'lulus', jsonb_array_length(r->'rows') = least(2000, v_semua), 'rinci', jsonb_array_length(r->'rows')::text);
    r := public.rc_compilation_list('', '', '', '', 0, 2000, '', null, null, 0);
    select count(*) into n from public.claims c join public.campaigns ca on ca.id = c.campaign_id
     where coalesce(c.period_start, ca.period_start) is null;
    hasil := hasil || jsonb_build_object('uji', 'Tahun 0 = dokumen tanpa periode campaign',
      'lulus', (r->>'total')::bigint = n, 'rinci', (r->>'total') || ' / ' || n);
    r := public.rc_compilation_list('', '', '', '', 0, 100, '', null, null, null);
    hasil := hasil || jsonb_build_object('uji', 'Tanpa tahun (null) = semua tahun, sama seperti sebelumnya',
      'lulus', (r->>'total')::bigint = v_semua, 'rinci', r->>'total');
    hasil := hasil || jsonb_build_object('uji', 'Signature lama dibuang; anon tidak boleh menjalankan',
      'lulus', to_regprocedure('public.rc_compilation_list(text,text,text,text,integer,integer,text,date,date)') is null
           and not has_function_privilege('anon', 'public.rc_compilation_list(text,text,text,text,integer,integer,text,date,date,integer)', 'execute')
           and has_function_privilege('authenticated', 'public.rc_compilation_list(text,text,text,text,integer,integer,text,date,date,integer)', 'execute'),
      'rinci', '-');
    raise exception 'UJI_SELESAI';
  exception when others then
    if sqlerrm <> 'UJI_SELESAI' then hasil := hasil || jsonb_build_object('uji', 'Blok uji berhenti', 'lulus', false, 'rinci', sqlerrm); end if;
  end;
  perform set_config('request.jwt.claims', '', true);
  insert into _hasil_dct(uji, lulus, rinci) select x->>'uji', (x->>'lulus')::boolean, x->>'rinci' from jsonb_array_elements(hasil) x;
end $uji$;

select urut, case when lulus then 'LULUS' else 'GAGAL' end hasil, uji, rinci from _hasil_dct order by urut;
