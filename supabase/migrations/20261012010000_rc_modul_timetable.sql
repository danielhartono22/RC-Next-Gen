-- ==========================================================================================
-- Modul Timetable, dan hak baca untuk tabel pengendali laporan
-- ==========================================================================================
-- BAGIAN 1 memperbaiki kesalahan yang muncul saat modul Report diuji: view rc_report_rows
-- berjalan sebagai SECURITY INVOKER, sehingga membaca public.excluded_campaigns di dalamnya
-- ditolak dengan "permission denied for table excluded_campaigns". Ini pola yang sama persis
-- dengan rc_private.claim_sensitive dahulu - RLS menyala tanpa satu pun policy, dan hasilnya
-- bukan baris yang tersembunyi melainkan seluruh kueri yang gagal.
--
-- Kedua tabel ini pengendali pelaporan, bukan data per depot: isinya kode campaign yang
-- dikecualikan dan pasangan depot-campaign yang ditandai. Seluruh pengguna yang sudah masuk
-- boleh membacanya; yang dibatasi adalah siapa yang boleh mengubahnya, dan itu dijaga oleh
-- fungsi di bagian 3, bukan oleh policy baca.
--
-- BAGIAN 2 memasang matrix Timetable (FR-06), dengan aturan status persis seperti PRD:
--
--   Record Expired DIABAIKAN saat menentukan status pasangan depot-campaign.
--     tidak ada record, tidak ada tanda manual -> Not Yet       (merah)
--     tidak ada record, ada tanda manual       -> Not Achieved  (putih)
--     ada record dan semuanya Done             -> Completed     (hijau)
--     ada record selain Done                   -> Compiled      (oranye)
--
--   Data aktual selalu mengungguli tanda Not Achieved, dan tandanya tetap tersimpan walau
--   sedang diabaikan - sehingga ketika claim-nya kelak dihapus atau diarsipkan, tanda itu
--   berlaku kembali tanpa perlu diinput ulang.
--
--   Cleared     = Completed + Not Achieved
--   Compile %   = (Compiled + Completed + Not Achieved) / campaign aktif
--   Completed % = (Completed + Not Achieved) / campaign aktif
--
-- CAMPAIGN AKTIF, sesuai keputusan pemilik, adalah campaign yang periodenya mencakup tanggal
-- laporan dan tidak dikecualikan. Campaign tanpa periode yang dapat diurai tidak pernah masuk
-- penyebut - dua puluh campaign saat ini berada dalam keadaan itu, dan jumlahnya ikut
-- dilaporkan supaya tidak menghilang diam-diam.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

-- ------------------------------------------------------------------------------------------
-- 1. Hak baca tabel pengendali
-- ------------------------------------------------------------------------------------------
grant select on public.excluded_campaigns to authenticated;
grant select on public.timetable_not_achieved to authenticated;

drop policy if exists excluded_campaigns_baca on public.excluded_campaigns;
create policy excluded_campaigns_baca on public.excluded_campaigns
 for select to authenticated using (true);

drop policy if exists timetable_not_achieved_baca on public.timetable_not_achieved;
create policy timetable_not_achieved_baca on public.timetable_not_achieved
 for select to authenticated using (true);

-- ------------------------------------------------------------------------------------------
-- 2. Matrix Timetable
-- ------------------------------------------------------------------------------------------
create or replace function public.rc_timetable_matrix(p_filter jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable set search_path='' as $fn$
declare
  v_region text; v_depot text; v_campaign text; v_tanggal date;
begin
  if not rc_private.can_access(null,'view_report') and not rc_private.is_system_manager() then
    raise exception 'Tidak punya hak melihat Timetable' using errcode='42501'; end if;

  v_region   := nullif(btrim(coalesce(p_filter->>'region','')),'');
  v_depot    := nullif(btrim(coalesce(p_filter->>'depot','')),'');
  v_campaign := nullif(btrim(coalesce(p_filter->>'campaign','')),'');
  v_tanggal  := coalesce(nullif(btrim(coalesce(p_filter->>'tanggal','')),'')::date, current_date);

  return (
    with campaign_aktif as (
      select ca.id, ca.campaign_code, ca.campaign_name, ca.period_start, ca.period_end
        from public.campaigns ca
       where ca.period_start is not null
         and ca.period_start <= v_tanggal
         and coalesce(ca.period_end, v_tanggal) >= v_tanggal
         and not exists(select 1 from public.excluded_campaigns x where x.campaign_id = ca.id)
         and (v_campaign is null or ca.campaign_code = v_campaign)
    ),
    depot_terpilih as (
      -- RLS pada public.depots membatasi daftar ini pada depot yang memang boleh dilihat
      -- pemanggil, jadi Timetable tidak bisa menjadi pintu belakang ke depot orang lain.
      select d.id, d.depot_code, d.depot_name, coalesce(d.region,'') as region
        from public.depots d
       where (v_region is null or coalesce(d.region,'') = v_region)
         and (v_depot is null or d.depot_code = v_depot)
    ),
    -- Expired diabaikan, persis seperti PRD. Bila sebuah pasangan HANYA punya record Expired,
    -- ia diperlakukan seolah tidak punya record sama sekali.
    rekap as (
      select c.depot_id, c.campaign_id,
             count(*) filter (where c.status <> 'expired') as n_hidup,
             count(*) filter (where c.status = 'done')     as n_done
        from public.claims c
       where c.archived_at is null
       group by c.depot_id, c.campaign_id
    ),
    sel as (
      select d.id as depot_id, d.depot_code, d.depot_name, d.region,
             k.id as campaign_id, k.campaign_code, k.campaign_name,
             coalesce(r.n_hidup,0) as n_hidup, coalesce(r.n_done,0) as n_done,
             exists(select 1 from public.timetable_not_achieved na
                     where na.depot_id=d.id and na.campaign_id=k.id) as ditandai
        from depot_terpilih d
        cross join campaign_aktif k
        left join rekap r on r.depot_id=d.id and r.campaign_id=k.id
    ),
    dinilai as (
      select s.*,
        case
          when s.n_hidup = 0 and s.ditandai then 'Not Achieved'
          when s.n_hidup = 0 then 'Not Yet'
          when s.n_done = s.n_hidup then 'Completed'
          else 'Compiled'
        end as status
      from sel s
    )
    select jsonb_build_object(
      'status','success',
      'tanggal', v_tanggal,
      'campaignAktif', (select count(*) from campaign_aktif),
      'campaignTanpaPeriode', (select count(*) from public.campaigns
         where period_start is null),
      'campaignDikecualikan', (select count(*) from public.excluded_campaigns),
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
        from (
          select depot_code, depot_name, region,
                 count(*) total,
                 count(*) filter (where status='Not Yet')      not_yet,
                 count(*) filter (where status='Compiled')     compiled,
                 count(*) filter (where status='Completed')    completed,
                 count(*) filter (where status='Not Achieved') not_achieved,
                 jsonb_object_agg(campaign_code, status) sel
            from dinilai
           group by depot_code, depot_name, region) t),
      'dibuatPada', to_char(now() at time zone 'Asia/Jakarta','DD/MM/YYYY HH24:MI')
    )
  );
end $fn$;
revoke all on function public.rc_timetable_matrix(jsonb) from public,anon;
grant execute on function public.rc_timetable_matrix(jsonb) to authenticated;

-- ------------------------------------------------------------------------------------------
-- 3. Menandai Not Achieved, dan mengecualikan campaign
-- ------------------------------------------------------------------------------------------
-- Menerima beberapa depot dan beberapa campaign sekaligus, lalu menandai hasil kali silangnya -
-- sama seperti FR-07. Menandai pasangan yang sudah punya claim tetap diizinkan dan tandanya
-- disimpan, tetapi matrix akan tetap menampilkan status aktualnya; itu memang perilaku yang
-- dikehendaki, dan angka yang dikembalikan menyebut berapa yang untuk sementara tidak berefek.
create or replace function public.rc_timetable_mark(
  p_depots jsonb, p_campaigns jsonb, p_tandai boolean default true, p_note text default '')
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare n_tulis integer := 0; n_abai integer := 0;
begin
  if not rc_private.can_access(null,'manage_timetable') and not rc_private.is_system_manager() then
    raise exception 'Tidak punya hak mengubah Timetable' using errcode='42501'; end if;
  if jsonb_typeof(p_depots)<>'array' or jsonb_typeof(p_campaigns)<>'array' then
    raise exception 'Depot dan campaign harus berupa daftar'; end if;

  if coalesce(p_tandai,true) then
    with pasangan as (
      select d.id depot_id, c.id campaign_id
        from jsonb_array_elements_text(p_depots) dd
        join public.depots d on d.depot_code = btrim(dd.value)
        join jsonb_array_elements_text(p_campaigns) cc on true
        join public.campaigns c on c.campaign_code = btrim(cc.value)
       -- Seorang pengelola hanya boleh menandai depot yang memang berada di wilayahnya.
       where rc_private.can_access(d.id)
    ), ditulis as (
      insert into public.timetable_not_achieved(depot_id,campaign_id,marked_by,note)
      select depot_id, campaign_id, (select auth.uid()), left(btrim(coalesce(p_note,'')),200)
        from pasangan
      on conflict(depot_id,campaign_id) do update set marked_at=now(),
        marked_by=(select auth.uid()), note=excluded.note
      returning depot_id, campaign_id
    )
    select count(*) into n_tulis from ditulis;

    select count(*) into n_abai
      from public.timetable_not_achieved na
      join public.claims c on c.depot_id=na.depot_id and c.campaign_id=na.campaign_id
       and c.archived_at is null and c.status<>'expired';
  else
    with dihapus as (
      delete from public.timetable_not_achieved na
       using public.depots d, public.campaigns c
       where na.depot_id=d.id and na.campaign_id=c.id
         and d.depot_code = any(select btrim(value) from jsonb_array_elements_text(p_depots))
         and c.campaign_code = any(select btrim(value) from jsonb_array_elements_text(p_campaigns))
         and rc_private.can_access(d.id)
      returning 1
    )
    select count(*) into n_tulis from dihapus;
  end if;

  insert into public.activity_logs(actor_id,event_type,entity_id,details)
  values((select auth.uid()),'timetable_marked',null,
    jsonb_build_object('tandai',coalesce(p_tandai,true),'jumlah',n_tulis));

  return jsonb_build_object('status','success','jumlah',n_tulis,
    'tertutupDataAktual',n_abai,
    'message',case when coalesce(p_tandai,true)
      then n_tulis||' pasangan ditandai Not Achieved'
      else n_tulis||' tanda Not Achieved dibatalkan' end
      || case when n_abai>0 then '. '||n_abai||' di antaranya sementara tidak berefek karena sudah ada data klaim.' else '' end);
end $fn$;
revoke all on function public.rc_timetable_mark(jsonb,jsonb,boolean,text) from public,anon;
grant execute on function public.rc_timetable_mark(jsonb,jsonb,boolean,text) to authenticated;

create or replace function public.rc_campaign_exclude(
  p_codes jsonb, p_kecualikan boolean default true, p_reason text default '')
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare n integer := 0;
begin
  if not rc_private.can_access(null,'manage_timetable') and not rc_private.is_system_manager() then
    raise exception 'Tidak punya hak mengubah pengecualian campaign' using errcode='42501'; end if;
  if jsonb_typeof(p_codes)<>'array' then raise exception 'Campaign harus berupa daftar'; end if;

  if coalesce(p_kecualikan,true) then
    with ditulis as (
      insert into public.excluded_campaigns(campaign_id,excluded_by,reason)
      select c.id,(select auth.uid()),left(btrim(coalesce(p_reason,'')),200)
        from jsonb_array_elements_text(p_codes) x
        join public.campaigns c on c.campaign_code=btrim(x.value)
      on conflict(campaign_id) do update set excluded_at=now(), reason=excluded.reason
      returning 1)
    select count(*) into n from ditulis;
  else
    with dihapus as (
      delete from public.excluded_campaigns e
       using public.campaigns c
       where e.campaign_id=c.id
         and c.campaign_code = any(select btrim(value) from jsonb_array_elements_text(p_codes))
      returning 1)
    select count(*) into n from dihapus;
  end if;

  return jsonb_build_object('status','success','jumlah',n,
    'message', n||case when coalesce(p_kecualikan,true)
      then ' campaign dikecualikan dari seluruh laporan'
      else ' campaign dikembalikan ke laporan' end);
end $fn$;
revoke all on function public.rc_campaign_exclude(jsonb,boolean,text) from public,anon;
grant execute on function public.rc_campaign_exclude(jsonb,boolean,text) to authenticated;

create or replace function rc_private.marker_20261012() returns boolean
language sql immutable set search_path='' as $fn$select true$fn$;
revoke all on function rc_private.marker_20261012() from public,anon;
grant execute on function rc_private.marker_20261012() to authenticated;

select 'Modul Timetable terpasang' as hasil,
 (select count(*) from public.campaigns
   where period_start is not null and period_start<=current_date
     and coalesce(period_end,current_date)>=current_date) as campaign_aktif_hari_ini,
 (select count(*) from public.campaigns where period_start is null) as campaign_tanpa_periode,
 (select count(*) from public.depots) as depot,
 (select count(*) from public.timetable_not_achieved) as tanda_not_achieved;
