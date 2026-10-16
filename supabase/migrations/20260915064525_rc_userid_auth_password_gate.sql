create schema if not exists rc_private;
revoke all on schema rc_private from public,anon,authenticated;
alter table public.profiles add column must_change_password boolean not null default true;
-- Profiles remain readable by the active owner so the UI can request password change.
-- Depot permissions remain blocked until Auth records a password change.
alter policy access_self on public.user_depot_access
using(user_id=(select auth.uid()) and exists(
 select 1 from public.profiles p where p.id=(select auth.uid()) and not p.must_change_password));
alter policy permissions_self on public.user_permissions
using(user_id=(select auth.uid()) and exists(
 select 1 from public.profiles p where p.id=(select auth.uid()) and not p.must_change_password));
create or replace function rc_private.password_changed() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if new.encrypted_password is distinct from old.encrypted_password
 and new.encrypted_password is not null and new.encrypted_password<>'' then
  update public.profiles set must_change_password=false where id=new.id;
 end if;
 return new;
end $$;
revoke all on function rc_private.password_changed() from public,anon,authenticated;
create trigger rc_auth_password_changed after update of encrypted_password on auth.users
for each row execute function rc_private.password_changed();

create or replace function public.rc_gross_up_legacy(net numeric,subject text)
returns numeric language sql immutable security invoker set search_path='' as $$
select case when coalesce(net,0)<=0 then 0
when lower(btrim(coalesce(subject,'')))='badan' then net/0.85
when net<=57000000 then net/0.95
when net<=218500000 then 60000000+(net-57000000)/0.85
when net<=406000000 then 250000000+(net-218500000)/0.75
when net<=3556000000 then 500000000+(net-406000000)/0.70
else 5000000000+(net-3556000000)/0.65 end;
$$;
revoke all on function public.rc_gross_up_legacy(numeric,text) from public,anon,authenticated;
grant execute on function public.rc_gross_up_legacy(numeric,text) to service_role;
comment on function public.rc_gross_up_legacy(numeric,text) is
'Parity with ResourceCollection.calcGrossUpCB, unrounded; not tax advice. No historical backfill or workflow integration yet.';

