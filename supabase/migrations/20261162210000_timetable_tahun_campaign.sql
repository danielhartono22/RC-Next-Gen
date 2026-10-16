-- ==========================================================================================
-- Timetable: tanggal acuan diganti Tahun Campaign dan seluruh ringkasan memakai definisi sama
-- ==========================================================================================
-- Sebelumnya Timetable hanya mengambil campaign yang aktif pada satu tanggal (default: hari
-- ini di Asia/Jakarta). Akibatnya campaign historis pada tahun yang sama hilang dari matriks,
-- dan papan Top 10 menghitung baris claim berstatus not_yet alih-alih pasangan Depot x Campaign
-- yang belum mempunyai dokumen hidup. Kedua hal itu membuat angka antarkomponen tidak sinkron.
--
-- Acuan baru sama dengan Report:
--   Tahun Campaign = tahun Periode Start pada Campaign Master;
--   Periode End hanya menjadi fallback bagi data lama yang Periode Start-nya kosong.
--
-- Filter Region dan Depot tetap membatasi matriks sesuai yurisdiksi. Top 10 tetap bersifat umum
-- seperti keputusan 20261144010000, tetapi sekarang mengikuti Tahun Campaign yang dipilih dan
-- memakai definisi Not Yet yang persis sama dengan matriks.
-- ==========================================================================================

create or replace function public.rc_timetable_matrix(p_filter jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable security definer
set search_path = ''
as $function$
declare
  v_region text;
  v_depot text;
  v_campaign text;
  v_tahun_teks text;
  v_tahun integer;
begin
  if not (rc_private.can_tab('timetable.matrix')
          or rc_private.can_tab('access.exclude')
          or rc_private.can_tab('report.dashboard')) then
    raise exception 'Timetable access denied' using errcode='42501';
  end if;
  if not rc_private.can_access(null,'manage_timetable')
     and not rc_private.can_tab('access.exclude')
     and not rc_private.can_access(null,'view_report')
     and not rc_private.is_system_manager() then
    raise exception 'Tidak punya hak melihat Timetable' using errcode='42501';
  end if;

  v_region     := nullif(btrim(coalesce(p_filter->>'region','')),'');
  v_depot      := nullif(btrim(coalesce(p_filter->>'depot','')),'');
  v_campaign   := nullif(btrim(coalesce(p_filter->>'campaign','')),'');
  v_tahun_teks := nullif(btrim(coalesce(p_filter->>'tahunCampaign','')),'');

  if v_tahun_teks is not null and v_tahun_teks !~ '^[0-9]{4}$' then
    raise exception 'Tahun Campaign harus empat digit.';
  end if;
  v_tahun := v_tahun_teks::integer;

  -- Default ke tahun Jakarta saat ini bila tersedia; bila tidak, gunakan tahun terbaru yang
  -- benar-benar ada. Campaign yang di-exclude tidak membuat sebuah tahun muncul di pilihan.
  if v_tahun is null then
    with tahun as (
      select distinct extract(year from coalesce(ca.period_start,ca.period_end))::integer nilai
        from public.campaigns ca
       where ca.archived_at is null
         and coalesce(ca.period_start,ca.period_end) is not null
         and not exists(select 1 from public.excluded_campaigns x where x.campaign_id=ca.id)
    )
    select coalesce(
             min(nilai) filter (where nilai=extract(year from now() at time zone 'Asia/Jakarta')::integer),
             max(nilai))
      into v_tahun
      from tahun;
  elsif not exists(
    select 1 from public.campaigns ca
     where ca.archived_at is null
       and extract(year from coalesce(ca.period_start,ca.period_end))::integer=v_tahun
       and not exists(select 1 from public.excluded_campaigns x where x.campaign_id=ca.id)
  ) then
    raise exception 'Tahun Campaign % tidak tersedia.', v_tahun;
  end if;

  return (
    with tahun_tersedia as (
      select distinct extract(year from coalesce(ca.period_start,ca.period_end))::integer tahun
        from public.campaigns ca
       where ca.archived_at is null
         and coalesce(ca.period_start,ca.period_end) is not null
         and not exists(select 1 from public.excluded_campaigns x where x.campaign_id=ca.id)
    ),
    campaign_tahun as (
      select ca.id,ca.campaign_code,ca.campaign_name,ca.period_start,ca.period_end
        from public.campaigns ca
       where ca.archived_at is null
         and extract(year from coalesce(ca.period_start,ca.period_end))::integer=v_tahun
         and not exists(select 1 from public.excluded_campaigns x where x.campaign_id=ca.id)
         and (v_campaign is null or ca.campaign_code=v_campaign)
    ),
    depot_boleh as (
      select d.id,d.depot_code,d.depot_name,coalesce(d.region,'') region
        from public.depots d
       where d.archived_at is null and rc_private.can_access(d.id)
    ),
    depot_terpilih as (
      select d.id,d.depot_code,d.depot_name,d.region
        from depot_boleh d
       where (v_region is null or d.region=v_region)
         and (v_depot is null or d.depot_code=v_depot)
    ),
    rekap as (
      select c.depot_id,c.campaign_id,
             count(*) filter (where c.status<>'expired') n_hidup,
             count(*) filter (where c.status='done') n_done
        from public.claims c
        join campaign_tahun k on k.id=c.campaign_id
       where c.archived_at is null
       group by c.depot_id,c.campaign_id
    ),
    dinilai as (
      select d.id depot_id,d.depot_code,d.depot_name,d.region,
             k.id campaign_id,k.campaign_code,k.campaign_name,
             case
               when coalesce(r.n_hidup,0)=0 and exists(
                 select 1 from public.timetable_not_achieved na
                  where na.depot_id=d.id and na.campaign_id=k.id
               ) then 'Not Achieved'
               when coalesce(r.n_hidup,0)=0 and rc_private.np_pasangan(d.id,k.id) then 'Not Achieved'
               when coalesce(r.n_hidup,0)=0 then 'Not Yet'
               when coalesce(r.n_done,0)=coalesce(r.n_hidup,0) then 'Completed'
               else 'Compiled'
             end status,
             (coalesce(r.n_hidup,0)=0 and rc_private.np_pasangan(d.id,k.id)) np
        from depot_terpilih d
        cross join campaign_tahun k
        left join rekap r on r.depot_id=d.id and r.campaign_id=k.id
    ),
    -- Papan umum: semua depot aktif, tetapi campaign dan definisi status sama dengan matriks.
    global_dinilai as (
      select d.depot_code,d.depot_name,
             case
               when coalesce(r.n_hidup,0)=0 and exists(
                 select 1 from public.timetable_not_achieved na
                  where na.depot_id=d.id and na.campaign_id=k.id
               ) then 'Not Achieved'
               when coalesce(r.n_hidup,0)=0 and rc_private.np_pasangan(d.id,k.id) then 'Not Achieved'
               when coalesce(r.n_hidup,0)=0 then 'Not Yet'
               when coalesce(r.n_done,0)=coalesce(r.n_hidup,0) then 'Completed'
               else 'Compiled'
             end status
        from public.depots d
        cross join campaign_tahun k
        left join rekap r on r.depot_id=d.id and r.campaign_id=k.id
       where d.archived_at is null
    )
    select jsonb_build_object(
      'status','success',
      'tahunCampaign',v_tahun,
      'tahunTersedia',(select coalesce(jsonb_agg(tahun order by tahun desc),'[]'::jsonb) from tahun_tersedia),
      'campaignJumlah',(select count(*) from campaign_tahun),
      -- Alias sementara untuk pemanggil lama; artinya kini jumlah campaign pada tahun terpilih.
      'campaignAktif',(select count(*) from campaign_tahun),
      'campaignTanpaPeriode',(select count(*) from public.campaigns ca
        where ca.archived_at is null and ca.period_start is null and ca.period_end is null
          and not exists(select 1 from public.excluded_campaigns x where x.campaign_id=ca.id)),
      'campaignDikecualikan',(select count(*) from public.excluded_campaigns x
        join public.campaigns ca on ca.id=x.campaign_id
       where ca.archived_at is null
         and extract(year from coalesce(ca.period_start,ca.period_end))::integer=v_tahun),

      'kpi',(select jsonb_build_object(
          'total',count(*),
          'completed',count(*) filter (where status='Completed'),
          'notAchieved',count(*) filter (where status='Not Achieved'),
          'compiled',count(*) filter (where status='Compiled'),
          'notYet',count(*) filter (where status='Not Yet'),
          'cleared',count(*) filter (where status in('Completed','Not Achieved')),
          'clearedPct',case when count(*)=0 then 0 else
            count(*) filter (where status in('Completed','Not Achieved'))::numeric/count(*) end,
          'compiledPct',case when count(*)=0 then 0 else
            count(*) filter (where status='Compiled')::numeric/count(*) end,
          'notYetPct',case when count(*)=0 then 0 else
            count(*) filter (where status='Not Yet')::numeric/count(*) end,
          'campaign',(select count(*) from campaign_tahun),
          'depot',(select count(*) from depot_terpilih)
        ) from dinilai),

      'perRegion',(select coalesce(jsonb_agg(jsonb_build_object(
          'region',case when g.region='' then '(belum diisi)' else g.region end,
          'total',g.total,'cleared',g.cleared,'compiled',g.compiled,'notYet',g.not_yet,
          'clearedPct',case when g.total=0 then 0 else round(g.cleared::numeric/g.total*100,1) end)
          order by g.region),'[]'::jsonb)
        from (select region,count(*) total,
                     count(*) filter (where status in('Completed','Not Achieved')) cleared,
                     count(*) filter (where status='Compiled') compiled,
                     count(*) filter (where status='Not Yet') not_yet
                from dinilai group by region) g),

      'perCampaign',(select coalesce(jsonb_agg(jsonb_build_object(
          'kode',c.campaign_code,'nama',c.campaign_name,
          'total',c.total,'completed',c.completed,'notAchieved',c.not_achieved,
          'cleared',c.cleared,'compiled',c.compiled,'notYet',c.not_yet,
          'clearedPct',case when c.total=0 then 0 else round(c.cleared::numeric/c.total*100,1) end)
          order by c.campaign_code),'[]'::jsonb)
        from (select campaign_code,campaign_name,count(*) total,
                     count(*) filter (where status='Completed') completed,
                     count(*) filter (where status='Not Achieved') not_achieved,
                     count(*) filter (where status in('Completed','Not Achieved')) cleared,
                     count(*) filter (where status='Compiled') compiled,
                     count(*) filter (where status='Not Yet') not_yet
                from dinilai group by campaign_code,campaign_name) c),

      'topNotYet',(select coalesce(jsonb_agg(jsonb_build_object(
          'kodeDepot',g.depot_code,'namaDepot',g.depot_name,'notYet',g.not_yet)
          order by g.not_yet desc,g.depot_code),'[]'::jsonb)
        from (select depot_code,depot_name,count(*) filter (where status='Not Yet') not_yet
                from global_dinilai
               group by depot_code,depot_name
              having count(*) filter (where status='Not Yet')>0
               order by not_yet desc,depot_code
               limit 10) g),

      'campaigns',(select coalesce(jsonb_agg(jsonb_build_object(
          'kode',campaign_code,'nama',campaign_name,'mulai',period_start,'selesai',period_end)
          order by campaign_code),'[]'::jsonb) from campaign_tahun),

      'depots',(select coalesce(jsonb_agg(jsonb_build_object(
          'kodeDepot',t.depot_code,'namaDepot',t.depot_name,
          'region',case when t.region='' then '(belum diisi)' else t.region end,
          'sel',t.sel,'notYet',t.not_yet,'compiled',t.compiled,
          'completed',t.completed,'notAchieved',t.not_achieved,
          'cleared',t.completed+t.not_achieved,
          'compilePersen',case when t.total=0 then null
            else round(((t.compiled+t.completed+t.not_achieved)::numeric/t.total)*100,1) end,
          'completedPersen',case when t.total=0 then null
            else round(((t.completed+t.not_achieved)::numeric/t.total)*100,1) end)
          order by t.depot_code),'[]'::jsonb)
        from (select depot_code,depot_name,region,count(*) total,
                     count(*) filter (where status='Not Yet') not_yet,
                     count(*) filter (where status='Compiled') compiled,
                     count(*) filter (where status='Completed') completed,
                     count(*) filter (where status='Not Achieved') not_achieved,
                     jsonb_object_agg(campaign_code,case when np then 'Not Participating' else status end) sel
                from dinilai group by depot_code,depot_name,region) t),

      'dibuatPada',to_char(now() at time zone 'Asia/Jakarta','DD-Mon-YYYY HH24:MI:SS')
    )
  );
end
$function$;

revoke all on function public.rc_timetable_matrix(jsonb) from public,anon;
grant execute on function public.rc_timetable_matrix(jsonb) to authenticated;
comment on function public.rc_timetable_matrix(jsonb) is
  'Matriks Timetable per Tahun Campaign. Tahun mengikuti Campaign Master period_start, period_end sebagai fallback.';

-- Pemeriksaan kontrak baca. Tidak ada data bisnis yang diubah.
do $uji$
declare
  v_sm uuid;
  v_hasil jsonb;
  v_filter jsonb;
  v_lama jsonb;
  v_tahun integer;
  v_jumlah integer;
  v_total integer;
  v_top jsonb;
begin
  select id into v_sm from public.profiles
   where role='system manager' and status='active' and not must_change_password
   order by user_code limit 1;
  if v_sm is null then
    raise notice 'Pemeriksaan Timetable dilewati: System Manager aktif tidak ditemukan.';
    return;
  end if;

  set local role authenticated;
  perform set_config('request.jwt.claims',json_build_object(
    'sub',v_sm::text,'role','authenticated')::text,true);
  v_hasil := public.rc_timetable_matrix('{}'::jsonb);
  reset role;

  if v_hasil->>'status'<>'success' then raise exception 'GAGAL: Timetable tidak sukses.'; end if;
  if v_hasil ? 'tanggal' then raise exception 'GAGAL: tanggal acuan lama masih dikirim.'; end if;
  if jsonb_typeof(v_hasil->'tahunTersedia')<>'array' then
    raise exception 'GAGAL: tahunTersedia bukan daftar.'; end if;

  v_tahun := nullif(v_hasil->>'tahunCampaign','')::integer;
  if v_tahun is null then
    if exists(select 1 from public.campaigns ca where ca.archived_at is null
               and coalesce(ca.period_start,ca.period_end) is not null
               and not exists(select 1 from public.excluded_campaigns x where x.campaign_id=ca.id)) then
      raise exception 'GAGAL: Tahun Campaign default kosong padahal campaign bertahun tersedia.';
    end if;
    raise notice 'Timetable tanpa campaign bertahun: kontrak kosong lolos.';
    return;
  end if;

  select count(*) into v_jumlah from public.campaigns ca
   where ca.archived_at is null
     and extract(year from coalesce(ca.period_start,ca.period_end))::integer=v_tahun
     and not exists(select 1 from public.excluded_campaigns x where x.campaign_id=ca.id);
  if (v_hasil->>'campaignJumlah')::integer<>v_jumlah then
    raise exception 'GAGAL: campaignJumlah %, seharusnya %.',v_hasil->>'campaignJumlah',v_jumlah;
  end if;

  v_total := ((v_hasil->'kpi'->>'campaign')::integer*(v_hasil->'kpi'->>'depot')::integer);
  if (v_hasil->'kpi'->>'total')::integer<>v_total then
    raise exception 'GAGAL: total kombinasi tidak sama dengan Campaign x Depot.';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
      'kodeDepot',q.kode,'namaDepot',q.nama,'notYet',q.n) order by q.n desc,q.kode),'[]'::jsonb)
    into v_top
    from (select d->>'kodeDepot' kode,d->>'namaDepot' nama,(d->>'notYet')::integer n
            from jsonb_array_elements(v_hasil->'depots') d
           where (d->>'notYet')::integer>0
           order by n desc,kode limit 10) q;
  if v_hasil->'topNotYet' is distinct from v_top then
    raise exception 'GAGAL: Top 10 tidak sama dengan status Not Yet pada matriks.';
  end if;

  v_filter := jsonb_build_object('tahunCampaign',v_tahun);
  set local role authenticated;
  perform set_config('request.jwt.claims',json_build_object(
    'sub',v_sm::text,'role','authenticated')::text,true);
  v_lama := public.rc_timetable_matrix(v_filter||jsonb_build_object('tanggal','1900-01-01'));
  reset role;
  if v_lama->>'tahunCampaign'<>v_tahun::text
     or v_lama->>'campaignJumlah'<>v_hasil->>'campaignJumlah'
     or v_lama->'tahunTersedia' is distinct from v_hasil->'tahunTersedia' then
    raise exception 'GAGAL: tanggal lama masih memengaruhi hasil Tahun Campaign.';
  end if;

  raise notice 'Timetable Tahun Campaign %: % campaign x % depot; pemeriksaan lolos.',
    v_tahun,v_hasil->>'campaignJumlah',v_hasil->'kpi'->>'depot';
exception when others then
  reset role;
  raise;
end
$uji$;

notify pgrst,'reload schema';
