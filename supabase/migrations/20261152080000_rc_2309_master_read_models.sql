-- Master campaigns read their own CB type; a claim override belongs only to a claim row.
CREATE OR REPLACE FUNCTION public.rc_campaign_list(p_search text DEFAULT ''::text, p_offset integer DEFAULT 0, p_limit integer DEFAULT 50)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare v jsonb; nama jsonb;
begin
 if not rc_private.can_access(null) then raise exception 'Access denied' using errcode='42501'; end if;
 -- Nama pembuat lewat peta SECURITY DEFINER: profiles hanya membuka baris diri sendiri, jadi
 -- join langsung akan membuat kolom Created by kosong bagi hampir semua orang.
 nama := rc_private.peta_nama_pelaku();
 select coalesce(jsonb_agg(x order by x->>'codeCampaign'),'[]'::jsonb) into v from (
  select jsonb_build_object(
   'id',ca.id,'codeCampaign',ca.campaign_code,'campaignName',ca.campaign_name,
   'periodStart',rc_private.legacy_date(ca.period_start),'periodEnd',rc_private.legacy_date(ca.period_end),
   'jenisCb',rc_private.cb_label(ca.cashback_type),'statusPajak',coalesce(ca.tax_status,''),
   'status',ca.status,
   'createdOn',to_char(ca.created_at at time zone 'Asia/Jakarta','DD-Mon-YYYY'),
   'createdBy',coalesce(nama->>(ca.created_by::text),''),
   'memoPath',coalesce(ca.memo_path,''),'memoName',coalesce(ca.memo_name,''),
   'memoSize',coalesce(ca.memo_size,0),
   'memoUploadedOn',case when ca.memo_uploaded_at is null then ''
     else to_char(ca.memo_uploaded_at at time zone 'Asia/Jakarta','DD-Mon-YYYY HH24:MI:SS') end,
   'jumlahClaim',(select count(*) from public.claims c where c.campaign_id=ca.id and c.archived_at is null),
   'nilaiClaim',(select coalesce(sum(c.cb_net),0) from public.claims c
                  where c.campaign_id=ca.id and c.archived_at is null)) as x
  from public.campaigns ca
  where ca.archived_at is null and (coalesce(btrim(p_search),'')=''
     or ca.campaign_code ilike '%'||btrim(p_search)||'%'
     or ca.campaign_name ilike '%'||btrim(p_search)||'%')
  order by ca.campaign_code
  limit least(greatest(coalesce(p_limit,50),1),200) offset greatest(coalesce(p_offset,0),0)) t;
 return jsonb_build_object('status','success','rows',v,
  'total',(select count(*) from public.campaigns where archived_at is null));
end $function$
;
CREATE OR REPLACE FUNCTION public.rc_depot_profile_request(p_kode text, p_perubahan jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_depot uuid; v_kode text; v_id uuid; v_bersih jsonb := '{}'::jsonb; k text;
  v_izin text[] := array['tipeDepot','alamat','gmapsUrl','fotoUrl','kepalaDepot','kepalaAdmin',
    'karAdmin','karSales','karDriver','karFg','karPcc','karTeknisi','karLain',
    'emailRsm','emailAsm','emailSm','emailDepot','nama','abbr','region','emailTo','emailCc','grade'];
begin
 perform rc_private.require_tab('profile.edit');
  v_kode := upper(btrim(coalesce(p_kode,'')));
  select id into v_depot from public.depots where depot_code = v_kode;
  if v_depot is null then raise exception 'Depot "%" tidak ditemukan', v_kode; end if;
  if not rc_private.can_access(v_depot) then
    raise exception 'Depot ini di luar yurisdiksi Anda' using errcode='42501'; end if;
  if p_perubahan is null or octet_length(p_perubahan::text)>20000 or jsonb_typeof(p_perubahan) <> 'object' then raise exception 'Perubahan tidak sah'; end if;

  -- Hanya kunci yang diizinkan yang diteruskan. Grade sengaja tidak ada di daftar: ia wewenang
  -- System Manager, dan membiarkannya lewat di sini akan menjadi pintu belakang.
  for k in select jsonb_object_keys(p_perubahan) loop
    if not k=any(v_izin) then raise exception 'Kolom profil tidak dikenali: %',k; end if;
    if jsonb_typeof(p_perubahan->k) not in('string','number','null') then raise exception 'Nilai profil tidak sah'; end if;
    if k like 'kar%' and coalesce(p_perubahan->>k,'') !~ '^[0-9]{1,6}$' then raise exception 'Jumlah karyawan harus bilangan bulat nonnegatif'; end if;
    if k = any(v_izin) then
      v_bersih := v_bersih || jsonb_build_object(k, p_perubahan->k);
    end if;
  end loop;
  if v_bersih = '{}'::jsonb then
    raise exception 'Tidak ada perubahan yang dapat diajukan'; end if;

  -- Alamat email diperiksa saat diajukan, bukan saat disetujui, supaya yang mengetik salah
  -- langsung tahu dan bukan penyetuju yang menemukannya beberapa hari kemudian.
  perform rc_private.periksa_email_maks(v_bersih->>'emailRsm','Email RSM',4);
  perform rc_private.periksa_email_maks(v_bersih->>'emailAsm','Email ASM',4);
  perform rc_private.periksa_email_maks(v_bersih->>'emailSm','Email SM',4);
  perform rc_private.periksa_email_maks(v_bersih->>'emailDepot','Email Depot',4);

  perform rc_private.periksa_email_maks(v_bersih->>'emailTo','Email To',4);
  perform rc_private.periksa_email_maks(v_bersih->>'emailCc','Email CC',20);
  if v_bersih ? 'nama' and btrim(v_bersih->>'nama')='' then raise exception 'Nama depot wajib diisi';end if;
  if v_bersih ? 'abbr' and btrim(v_bersih->>'abbr')='' then raise exception 'Abbreviation wajib diisi';end if;
  insert into public.depot_profile_requests(depot_id,requester_id,perubahan)
  values(v_depot,(select auth.uid()),v_bersih)
  returning id into v_id;

  insert into public.activity_logs(actor_id,depot_id,event_type,entity_id,details)
  values((select auth.uid()),v_depot,'profil_diajukan',v_id,
         jsonb_build_object('kolom',(select count(*) from jsonb_object_keys(v_bersih))));

  return jsonb_build_object('status','success','id',v_id,
    'message','Pengajuan dikirim. Nilai lama tetap berlaku sampai Supervisor wilayah atau System Manager menyetujui.');
end $function$
;
CREATE OR REPLACE FUNCTION public.rc_timetable_matrix(p_filter jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_region text; v_depot text; v_campaign text; v_tanggal date;
begin
 if not (rc_private.can_tab('timetable.matrix') or rc_private.can_tab('access.exclude') or rc_private.can_tab('report.dashboard')) then raise exception 'Timetable access denied' using errcode='42501';end if;
  -- Izin Timetable ATAU izin Report; keduanya membuka layar yang sama. Sebelumnya hanya
  -- 'view_report' yang diterima, sehingga akun yang justru diberi modul Timetable tetap ditolak.
  if not rc_private.can_access(null,'manage_timetable')
     and not rc_private.can_access(null,'view_report')
     and not rc_private.is_system_manager() then
    raise exception 'Tidak punya hak melihat Timetable' using errcode='42501'; end if;

  v_region   := nullif(btrim(coalesce(p_filter->>'region','')),'');
  v_depot    := nullif(btrim(coalesce(p_filter->>'depot','')),'');
  v_campaign := nullif(btrim(coalesce(p_filter->>'campaign','')),'');
  v_tanggal  := coalesce(nullif(btrim(coalesce(p_filter->>'tanggal','')),'')::date, (now() at time zone 'Asia/Jakarta')::date);

  return (
    with campaign_aktif as (
      select ca.id, ca.campaign_code, ca.campaign_name, ca.period_start, ca.period_end
        from public.campaigns ca
       where ca.archived_at is null and ca.period_start is not null
         and ca.period_start <= v_tanggal
         and coalesce(ca.period_end, v_tanggal) >= v_tanggal
         and not exists(select 1 from public.excluded_campaigns x where x.campaign_id = ca.id)
         and (v_campaign is null or ca.campaign_code = v_campaign)
    ),
    -- Yurisdiksi. Supervisor dan System Manager melihat seluruh depot; selain itu hanya depot
    -- sendiri atau yang di-tagging. Sebelumnya tidak ada pemeriksaan sama sekali di sini, dan
    -- karena fungsinya SECURITY DEFINER, RLS pada depots pun tidak ikut campur - siapa pun
    -- yang lolos gerbang melihat seluruh 52 depot.
    depot_boleh as (
      select d.id, d.depot_code, d.depot_name, coalesce(d.region,'') as region
        from public.depots d
       where d.archived_at is null and rc_private.can_access(d.id)
    ),
    depot_terpilih as (
      select d.id, d.depot_code, d.depot_name, d.region
        from depot_boleh d
       where (v_region is null or d.region = v_region)
         and (v_depot is null or d.depot_code = v_depot)
    ),
    rekap as (
      select c.depot_id, c.campaign_id,
             count(*) filter (where c.status <> 'expired') as n_hidup,
             count(*) filter (where c.status = 'done')     as n_done
        from public.claims c where c.archived_at is null
       group by c.depot_id, c.campaign_id
    ),
    dinilai as (
      select d.id as depot_id, d.depot_code, d.depot_name, d.region,
             k.id as campaign_id, k.campaign_code, k.campaign_name,
             case
               when coalesce(r.n_hidup,0) = 0 and exists(select 1 from public.timetable_not_achieved na
                     where na.depot_id=d.id and na.campaign_id=k.id) then 'Not Achieved'
               when coalesce(r.n_hidup,0) = 0 then 'Not Yet'
               when coalesce(r.n_done,0) = coalesce(r.n_hidup,0) then 'Completed'
               else 'Compiled'
             end as status
        from depot_terpilih d
        cross join campaign_aktif k
        left join rekap r on r.depot_id=d.id and r.campaign_id=k.id
    ),
    -- Seluruh depot YANG BOLEH DILIHAT, tanpa filter layar, khusus untuk peringkat Not Yet.
    -- Sistem lama menghitungnya lintas wilayah; di sini batas yurisdiksi tetap dipasang, karena
    -- peringkat yang memuat nama depot di luar yurisdiksi seseorang adalah kebocoran meski yang
    -- bocor hanya angka.
    global as (
      select d.id as depot_id, d.depot_code, d.depot_name,
             case when coalesce(r.n_hidup,0) = 0
                    and not exists(select 1 from public.timetable_not_achieved na
                                    where na.depot_id=d.id and na.campaign_id=k.id)
                  then 1 else 0 end as not_yet
        from (select id,depot_code,depot_name from public.depots where archived_at is null) d
        cross join campaign_aktif k
        left join rekap r on r.depot_id=d.id and r.campaign_id=k.id
    )
    select jsonb_build_object(
      'status','success',
      'tanggal', v_tanggal,
      'campaignAktif', (select count(*) from campaign_aktif),
      'campaignTanpaPeriode', (select count(*) from public.campaigns where period_start is null),
      'campaignDikecualikan', (select count(*) from public.excluded_campaigns),

      'kpi', (select jsonb_build_object(
          'total',        count(*),
          'completed',    count(*) filter (where status='Completed'),
          'notAchieved',  count(*) filter (where status='Not Achieved'),
          'compiled',     count(*) filter (where status='Compiled'),
          'notYet',       count(*) filter (where status='Not Yet'),
          'cleared',      count(*) filter (where status in('Completed','Not Achieved')),
          'clearedPct',   case when count(*)=0 then 0 else
            count(*) filter (where status in('Completed','Not Achieved'))::numeric/count(*) end,
          'compiledPct',  case when count(*)=0 then 0 else
            count(*) filter (where status='Compiled')::numeric/count(*) end,
          'notYetPct',    case when count(*)=0 then 0 else
            count(*) filter (where status='Not Yet')::numeric/count(*) end,
          'campaign',     (select count(*) from campaign_aktif),
          'depot',        (select count(*) from depot_terpilih)
        ) from dinilai),

      'perRegion', (select coalesce(jsonb_agg(jsonb_build_object(
          'region', case when g.region='' then '(belum diisi)' else g.region end,
          'total',g.total,'cleared',g.cleared,'compiled',g.compiled,'notYet',g.not_yet,
          'clearedPct', case when g.total=0 then 0 else round(g.cleared::numeric/g.total*100,1) end)
          order by g.region),'[]'::jsonb)
        from (select region, count(*) total,
                     count(*) filter (where status in('Completed','Not Achieved')) cleared,
                     count(*) filter (where status='Compiled') compiled,
                     count(*) filter (where status='Not Yet') not_yet
                from dinilai group by region) g),

      'perCampaign', (select coalesce(jsonb_agg(jsonb_build_object(
          'kode',c.campaign_code,'nama',c.campaign_name,
          'total',c.total,'cleared',c.cleared,'compiled',c.compiled,'notYet',c.not_yet,
          'clearedPct', case when c.total=0 then 0 else round(c.cleared::numeric/c.total*100,1) end)
          order by c.campaign_code),'[]'::jsonb)
        from (select campaign_code, campaign_name, count(*) total,
                     count(*) filter (where status in('Completed','Not Achieved')) cleared,
                     count(*) filter (where status='Compiled') compiled,
                     count(*) filter (where status='Not Yet') not_yet
                from dinilai group by campaign_code, campaign_name) c),

      'topNotYet', rc_private.timetable_top_notyet(),

      'campaigns', (select coalesce(jsonb_agg(jsonb_build_object(
          'kode',campaign_code,'nama',campaign_name,
          'mulai',period_start,'selesai',period_end) order by campaign_code),'[]'::jsonb)
        from campaign_aktif),

      'depots', (select coalesce(jsonb_agg(jsonb_build_object(
          'kodeDepot',t.depot_code,'namaDepot',t.depot_name,
          'region', case when t.region='' then '(belum diisi)' else t.region end,
          'sel', t.sel,
          'notYet',t.not_yet,'compiled',t.compiled,'completed',t.completed,'notAchieved',t.not_achieved,
          'cleared',t.completed + t.not_achieved,
          'compilePersen', case when t.total=0 then null
            else round(((t.compiled + t.completed + t.not_achieved)::numeric / t.total) * 100, 1) end,
          'completedPersen', case when t.total=0 then null
            else round(((t.completed + t.not_achieved)::numeric / t.total) * 100, 1) end)
          order by t.depot_code),'[]'::jsonb)
        from (select depot_code, depot_name, region, count(*) total,
                     count(*) filter (where status='Not Yet')      not_yet,
                     count(*) filter (where status='Compiled')     compiled,
                     count(*) filter (where status='Completed')    completed,
                     count(*) filter (where status='Not Achieved') not_achieved,
                     jsonb_object_agg(campaign_code, status) sel
                from dinilai group by depot_code, depot_name, region) t),

      'dibuatPada', to_char(now() at time zone 'Asia/Jakarta','DD-Mon-YYYY HH24:MI:SS')
    )
  );
end $function$
;
notify pgrst,'reload schema';
