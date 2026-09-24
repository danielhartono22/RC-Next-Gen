-- Performance is scoped to the caller's depots, including Supervisor callers.
create or replace function rc_private.people_depots(p_user uuid) returns uuid[]
language sql stable security definer set search_path='' as $$
 select coalesce(array_agg(distinct a.depot_id),'{}'::uuid[]) from public.user_depot_access a
 join public.depots d on d.id=a.depot_id where a.user_id=p_user and d.archived_at is null and rc_private.can_access(d.id);
$$;

create or replace function rc_private.people_metrics(p_depots uuid[],p_asof date default (now() at time zone 'Asia/Jakarta')::date) returns jsonb
language sql stable security definer set search_path='' as $$
 with scoped as (
 select c.id,c.campaign_id,c.depot_id,c.cb_net,
 case when p_asof>=(now() at time zone 'Asia/Jakarta')::date then c.status else coalesce(h.to_status,'unknown') end status
 from public.claims c left join lateral (select h.to_status from public.claim_status_history h where h.claim_id=c.id
 and h.created_at<(p_asof+1)::timestamp at time zone 'Asia/Jakarta' order by h.created_at desc,h.id desc limit 1) h on true
 where c.archived_at is null and c.depot_id=any(p_depots) and rc_private.can_access(c.depot_id)
 and c.created_at<(p_asof+1)::timestamp at time zone 'Asia/Jakarta'
 ), stages as (select status,count(*) n from scoped group by status),
 cp as (select count(*) total,count(*) filter(where status in('not_yet','submitted')) depot,
 count(*) filter(where status in('approved','released','bulk_processed')) osc,count(*) filter(where status='claimed') finance,
 count(*) filter(where status='done') done,count(*) filter(where status not in('not_yet','submitted','approved','released','bulk_processed','claimed','done')) other,
 count(*) filter(where status='unknown') unknown from scoped),
 campaigns as (select ca.id from public.campaigns ca where ca.archived_at is null and ca.period_start<=p_asof and coalesce(ca.period_end,p_asof)>=p_asof
 and not exists(select 1 from public.excluded_campaigns x where x.campaign_id=ca.id)),
 combinations as (select d.id depot_id,ca.id campaign_id from public.depots d cross join campaigns ca where d.id=any(p_depots) and rc_private.can_access(d.id)),
 counts as (select depot_id,campaign_id,count(*) filter(where status<>'expired') alive,count(*) filter(where status='done') done,
 count(*) filter(where status='unknown') unknown from scoped group by depot_id,campaign_id),
 classified as (select case when coalesce(r.unknown,0)>0 then 'Unknown'
 when coalesce(r.alive,0)=0 and exists(select 1 from public.timetable_not_achieved n where n.depot_id=x.depot_id and n.campaign_id=x.campaign_id and n.marked_at<(p_asof+1)::timestamp at time zone 'Asia/Jakarta') then 'Not Achieved'
 when coalesce(r.alive,0)=0 then 'Not Yet' when r.done=r.alive then 'Completed' else 'Compiled' end status
 from combinations x left join counts r using(depot_id,campaign_id)),
 tt as (select count(*) total,count(*) filter(where status='Not Yet') not_yet,count(*) filter(where status='Compiled') compiled,
 count(*) filter(where status='Completed') completed,count(*) filter(where status='Not Achieved') not_achieved,count(*) filter(where status='Unknown') unknown from classified)
 select jsonb_build_object('asOf',p_asof,'depotCount',cardinality(p_depots),
 'stages',coalesce((select jsonb_object_agg(status,n) from stages),'{}'),
 'claims',(select to_jsonb(cp)||jsonb_build_object('depotPct',round(100.0*depot/nullif(total,0),2),'oscPct',round(100.0*osc/nullif(total,0),2),
 'financePct',round(100.0*finance/nullif(total,0),2),'donePct',round(100.0*done/nullif(total,0),2)) from cp),
 'timetable',(select to_jsonb(tt)||jsonb_build_object('notYetPct',round(100.0*not_yet/nullif(total,0),2),'compiledPct',round(100.0*compiled/nullif(total,0),2),
 'completedPct',round(100.0*completed/nullif(total,0),2),'notAchievedPct',round(100.0*not_achieved/nullif(total,0),2)) from tt));
$$;
revoke all on function rc_private.people_depots(uuid),rc_private.people_metrics(uuid[],date) from public,anon,authenticated;

create or replace function public.rc_people_performance(p_role text default 'osc',p_user_code text default '') returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare result jsonb; all_depots uuid[];
begin
 if p_role not in('osc','supervisor') then raise exception 'Tab People tidak valid';end if;
 perform rc_private.require_tab('people.'||p_role);
 select coalesce(jsonb_agg(jsonb_build_object('userId',p.user_code,'fullName',p.full_name,'role',p.role,
 'supervisors',coalesce((select jsonb_agg(jsonb_build_object('userId',sp.user_code,'name',sp.full_name)) from public.user_supervision s join public.profiles sp on sp.id=s.supervisor_id
 where s.osc_id=p.id and (sp.id=auth.uid() or cardinality(rc_private.people_depots(sp.id))>0)),'[]'),
 'oscs',coalesce((select jsonb_agg(jsonb_build_object('userId',o.user_code,'name',o.full_name,'depots',cardinality(rc_private.people_depots(o.id)))) from public.user_supervision s join public.profiles o on o.id=s.osc_id where s.supervisor_id=p.id and o.status='active' and cardinality(rc_private.people_depots(o.id))>0),'[]'),
 'depots',coalesce((select jsonb_agg(jsonb_build_object('code',d.depot_code,'name',d.depot_name,'region',d.region,
 'metrics',case when p_user_code<>'' then rc_private.people_metrics(array[d.id]) else null end) order by d.depot_code) from public.depots d where d.id=any(rc_private.people_depots(p.id))),'[]'),
 'metrics',rc_private.people_metrics(rc_private.people_depots(p.id))) order by p.user_code),'[]') into result
 from public.profiles p where p.role=p_role and p.status='active'
 and (p_user_code='' or p.user_code=upper(btrim(p_user_code)))
 and (p.id=auth.uid() or rc_private.is_system_manager() or cardinality(rc_private.people_depots(p.id))>0);
 select coalesce(array_agg(distinct a.depot_id),'{}') into all_depots from public.user_depot_access a join public.profiles p on p.id=a.user_id
 where p.role=p_role and p.status='active' and rc_private.can_access(a.depot_id) and (p_user_code='' or p.user_code=upper(btrim(p_user_code)));
 return jsonb_build_object('status','success','rows',result,'summary',rc_private.people_metrics(all_depots),
 'scope','Depot dalam yurisdiksi Anda; total ringkasan menghitung depot unik.');
end $$;

create or replace function public.rc_people_history(p_role text,p_user_code text,p_from date,p_to date,p_grain text default 'day') returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare uid uuid;depots uuid[];result jsonb;
begin
 if p_role not in('osc','supervisor') then raise exception 'Role tidak sah';end if;
 perform rc_private.require_tab('people.'||p_role);
 if p_from is null or p_to is null or p_to<p_from or p_to-p_from>366 or p_to>(now() at time zone 'Asia/Jakarta')::date or p_grain not in('day','week','month') then raise exception 'Rentang history maksimal 366 hari sampai hari ini';end if;
 select id into uid from public.profiles where user_code=upper(btrim(p_user_code)) and role=p_role and status='active';
 depots:=rc_private.people_depots(uid);
 if uid is null or (cardinality(depots)=0 and uid<>auth.uid() and not rc_private.is_system_manager()) then raise exception 'User di luar yurisdiksi' using errcode='42501';end if;
 select coalesce(jsonb_agg(jsonb_build_object('from',greatest(t.d::date,p_from),'to',least((t.d+('1 '||p_grain)::interval)::date-1,p_to),
 'metrics',rc_private.people_metrics(depots,least((t.d+('1 '||p_grain)::interval)::date-1,p_to)),
 'processed',coalesce((select jsonb_object_agg(e.action,e.n) from (select h.action,count(*) n from public.claim_status_history h join public.claims c on c.id=h.claim_id
 where c.depot_id=any(depots) and h.created_at>=greatest(t.d::date,p_from)::timestamp at time zone 'Asia/Jakarta'
 and h.created_at<(least((t.d+('1 '||p_grain)::interval)::date-1,p_to)+1)::timestamp at time zone 'Asia/Jakarta' group by h.action) e),'{}')) order by t.d),'[]') into result
 from generate_series(date_trunc(p_grain,p_from::timestamp),p_to::timestamp,('1 '||p_grain)::interval) t(d);
 return jsonb_build_object('status','success','userId',p_user_code,'grain',p_grain,'rows',result,
 'note','Mapping depot dan master campaign mengikuti kondisi saat ini. Unknown berarti status historis belum tercatat; bukan Not Yet. Data arsip tidak termasuk.');
end $$;
revoke all on function public.rc_people_performance(text,text),public.rc_people_history(text,text,date,date,text) from public,anon;
grant execute on function public.rc_people_performance(text,text),public.rc_people_history(text,text,date,date,text) to authenticated;
notify pgrst,'reload schema';
