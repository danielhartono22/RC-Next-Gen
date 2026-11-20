-- ==========================================================================================
-- Uji 20 November 2026: Timetable bawaan hanya campaign Billing End >= hari ini, Show All Campaign
-- (20261164090000). Hanya membaca.
--   node scripts/apply-sql.mjs --env dev|prod supabase/tests/rc_timetable_show_all.sql
-- ==========================================================================================
create temp table if not exists _hasil_tts(urut serial, uji text, lulus boolean, rinci text);
truncate _hasil_tts;

do $uji$
declare hasil jsonb := '[]'; v_sm uuid; r jsonb; r2 jsonb; v_hari date := (now() at time zone 'Asia/Jakarta')::date;
  v_n_semua integer; v_n_jalan integer; v_camp text;
begin
  select id into v_sm from public.profiles where role = 'system manager' and status = 'active' and archived_at is null order by user_code limit 1;
  perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);
  begin
    select count(*), count(*) filter (where coalesce(ca.billing_end, ca.so_end, ca.period_end) is null or coalesce(ca.billing_end, ca.so_end, ca.period_end) >= v_hari)
      into v_n_semua, v_n_jalan
      from public.campaigns ca
     where ca.archived_at is null and coalesce(ca.period_start, ca.period_end) is not null
       and not exists(select 1 from public.excluded_campaigns x where x.campaign_id = ca.id);
    r := public.rc_timetable_matrix('{"tahunCampaign":"ALL"}'::jsonb);
    r2 := public.rc_timetable_matrix('{"tahunCampaign":"ALL","semuaCampaign":"true"}'::jsonb);
    hasil := hasil || jsonb_build_object('uji', 'Timetable bawaan = campaign Billing End >= hari ini; Show All Campaign = semua; jumlah yang disembunyikan dilaporkan', 'lulus',
      (r->>'campaignJumlah')::int = v_n_jalan and (r2->>'campaignJumlah')::int = v_n_semua
      and (r->>'campaignBerakhir')::int = v_n_semua - v_n_jalan and (r2->>'campaignBerakhir')::int = 0,
      'rinci', 'bawaan ' || (r->>'campaignJumlah') || ', semua ' || (r2->>'campaignJumlah') || ', disembunyikan ' || (r->>'campaignBerakhir'));

    select ca.campaign_code into v_camp from public.campaigns ca
     where ca.archived_at is null and coalesce(ca.period_start, ca.period_end) is not null
       and not exists(select 1 from public.excluded_campaigns x where x.campaign_id = ca.id)
       and coalesce(ca.billing_end, ca.so_end, ca.period_end) < v_hari order by ca.campaign_code limit 1;
    if v_camp is not null then
      r := public.rc_timetable_matrix(jsonb_build_object('tahunCampaign', 'ALL', 'campaign', v_camp));
      hasil := hasil || jsonb_build_object('uji', 'Campaign yang sudah berakhir tetap tampil bila dipilih langsung', 'lulus',
        (r->>'campaignJumlah')::int = 1, 'rinci', v_camp);
    end if;
  exception when others then
    hasil := hasil || jsonb_build_object('uji', 'Blok uji berhenti', 'lulus', false, 'rinci', sqlerrm);
  end;
  perform set_config('request.jwt.claims', '', true);
  insert into _hasil_tts(uji, lulus, rinci) select x->>'uji', (x->>'lulus')::boolean, x->>'rinci' from jsonb_array_elements(hasil) x;
end $uji$;

select urut, case when lulus then 'LULUS' else 'GAGAL' end hasil, uji, rinci from _hasil_tts order by urut;
