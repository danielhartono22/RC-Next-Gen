create table public.profile_change_requests(
 id uuid primary key default gen_random_uuid(),requester_id uuid not null references public.profiles(id),
 depot_id uuid not null references public.depots(id),changes jsonb not null,
 status text not null default 'pending' check(status in('pending','approved','rejected')),
 reviewer_id uuid references public.profiles(id),created_at timestamptz not null default now(),reviewed_at timestamptz
);
alter table public.profile_change_requests enable row level security;
revoke all on public.profile_change_requests from public,anon,authenticated;
grant select on public.profile_change_requests to authenticated;
grant all on public.profile_change_requests to service_role;
create index profile_requests_depot_idx on public.profile_change_requests(depot_id,status,created_at desc);
create policy request_scope on public.profile_change_requests for select to authenticated using(
rc_private.can_access(depot_id) and (requester_id=auth.uid() or rc_private.can_access(depot_id,'manage_access')));
create function rc_private.profile_request(p_depot uuid,p_changes jsonb) returns uuid language plpgsql security definer set search_path='' as $$
declare v uuid; begin
 if not rc_private.can_access(p_depot) then raise exception 'Access denied' using errcode='42501'; end if;
 if p_changes is null or jsonb_typeof(p_changes)<>'object' or p_changes='{}'::jsonb
 or exists(select 1 from jsonb_each(p_changes) x where x.key not in('address','master_link','depot_name') or jsonb_typeof(x.value)<>'string' or length(x.value#>>'{}')>2000)
 then raise exception 'Invalid depot changes'; end if;
 if p_changes ? 'master_link' and p_changes->>'master_link'<>'' and p_changes->>'master_link' !~ '^https://' then raise exception 'Master link must use HTTPS'; end if;
 insert into public.profile_change_requests(requester_id,depot_id,changes) values(auth.uid(),p_depot,p_changes) returning id into v;
 insert into public.activity_logs(actor_id,depot_id,event_type,entity_id) values(auth.uid(),p_depot,'profile_request',v);
 return v;
end $$;
create function rc_private.review_profile(p_id uuid,p_approve boolean) returns void language plpgsql security definer set search_path='' as $$
declare r public.profile_change_requests%rowtype; begin
 select * into strict r from public.profile_change_requests where id=p_id for update;
 if not rc_private.can_access(r.depot_id,'manage_access') or r.requester_id=auth.uid() then raise exception 'Independent approver required' using errcode='42501'; end if;
 if r.status<>'pending' or p_approve is null then raise exception 'Request already reviewed or decision missing'; end if;
 if p_approve then update public.depots set address=coalesce(r.changes->>'address',address),
 master_link=coalesce(r.changes->>'master_link',master_link),depot_name=coalesce(r.changes->>'depot_name',depot_name) where id=r.depot_id; end if;
 update public.profile_change_requests set status=case when p_approve then 'approved' else 'rejected' end,reviewer_id=auth.uid(),reviewed_at=now() where id=r.id;
 insert into public.activity_logs(actor_id,depot_id,event_type,entity_id) values(auth.uid(),r.depot_id,'profile_review',r.id);
end $$;
create function public.rc_request_profile(p_depot uuid,p_changes jsonb) returns uuid language sql security invoker set search_path='' as $$select rc_private.profile_request(p_depot,p_changes);$$;
create function public.rc_review_profile(p_id uuid,p_approve boolean) returns void language sql security invoker set search_path='' as $$select rc_private.review_profile(p_id,p_approve);$$;
revoke all on function rc_private.profile_request(uuid,jsonb),rc_private.review_profile(uuid,boolean),public.rc_request_profile(uuid,jsonb),public.rc_review_profile(uuid,boolean) from public,anon;
grant execute on function rc_private.profile_request(uuid,jsonb),rc_private.review_profile(uuid,boolean),public.rc_request_profile(uuid,jsonb),public.rc_review_profile(uuid,boolean) to authenticated;

create function rc_private.is_manager() returns boolean language sql stable security definer set search_path='' as $$
select rc_private.can_access(null,'manage_access') and exists(select 1 from public.profiles where id=auth.uid() and role='system manager');$$;
revoke all on function rc_private.is_manager() from public,anon;
grant execute on function rc_private.is_manager() to authenticated;
create function rc_private.manage_user(p_user uuid,p_status text,p_permissions text[],p_depots uuid[]) returns void language plpgsql security definer set search_path='' as $$
begin
 if not rc_private.is_manager() then raise exception 'Manager required' using errcode='42501'; end if;
 if p_user=auth.uid() then raise exception 'Cannot change own access'; end if;
 if p_status not in('active','inactive') or p_status is null or p_permissions is null or p_depots is null then raise exception 'Invalid access values'; end if;
 if exists(select 1 from unnest(p_permissions) x where not exists(select 1 from public.permissions where code=x))
 or exists(select 1 from unnest(p_depots) x where not rc_private.can_access(x)) then raise exception 'Invalid permission or depot outside scope'; end if;
 perform 1 from public.profiles where id=p_user for update;
 if not found then raise exception 'User not found'; end if;
 update public.profiles set status=p_status where id=p_user;
 delete from public.user_permissions where user_id=p_user;
 insert into public.user_permissions select p_user,x from unnest(p_permissions) x group by x;
 delete from public.user_depot_access where user_id=p_user;
 insert into public.user_depot_access select p_user,x from unnest(p_depots) x group by x;
 insert into public.activity_logs(actor_id,event_type,entity_id,details) values(auth.uid(),'access_changed',p_user,jsonb_build_object('status',p_status));
end $$;
create function public.rc_manage_user(p_user uuid,p_status text,p_permissions text[],p_depots uuid[]) returns void language sql security invoker set search_path='' as $$select rc_private.manage_user(p_user,p_status,p_permissions,p_depots);$$;
revoke all on function rc_private.manage_user(uuid,text,text[],uuid[]),public.rc_manage_user(uuid,text,text[],uuid[]) from public,anon;
grant execute on function rc_private.manage_user(uuid,text,text[],uuid[]),public.rc_manage_user(uuid,text,text[],uuid[]) to authenticated;
create function rc_private.list_users(p_offset integer) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare v jsonb; begin
 if not rc_private.is_manager() then raise exception 'Manager required' using errcode='42501'; end if;
 select coalesce(jsonb_agg(x),'[]') into v from (
 select p.id,p.user_code,p.full_name,p.role,p.status,p.must_change_password,
 array(select permission_code from public.user_permissions where user_id=p.id) as permissions,
 array(select depot_id from public.user_depot_access where user_id=p.id) as depots
 from public.profiles p order by user_code limit 50 offset greatest(p_offset,0)) x;
 return v;
end $$;
create function public.rc_list_users(p_offset integer default 0) returns jsonb language sql stable security invoker set search_path='' as $$select rc_private.list_users(p_offset);$$;
revoke all on function rc_private.list_users(integer),public.rc_list_users(integer) from public,anon;
grant execute on function rc_private.list_users(integer),public.rc_list_users(integer) to authenticated;
