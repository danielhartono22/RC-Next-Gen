-- Operator-only. Inspect rc_e2e_fixture_inventory.sql first and replace the marker.
-- Default value deliberately fails validation. Only one exact synthetic fixture is removed.
begin;
select set_config('rc.cleanup_user','__rc_e2e_REPLACE_WITH_VERIFIED_TIMESTAMP',true);
do $$
declare code text:=current_setting('rc.cleanup_user'); u uuid; c uuid; d uuid; ca uuid; cu uuid;
begin
 if code !~ '^__rc_e2e_[0-9]{13}$' then raise exception 'Select a verified synthetic fixture code'; end if;
 select id into strict u from public.profiles where user_code=code and full_name='Synthetic E2E' and business_email='test@example.invalid';
 select id,depot_id,campaign_id,customer_id into strict c,d,ca,cu from public.claims where no_doc=code and source_snapshot_id is null;
 if not exists(select 1 from public.depots where id=d and depot_code=code and depot_name='Synthetic E2E')
 or not exists(select 1 from public.customers where id=cu and customer_code=code and customer_name='Synthetic E2E')
 or not exists(select 1 from public.campaigns where id=ca and campaign_code=code and campaign_name='Synthetic E2E')
 or exists(select 1 from public.claim_status_history where actor_id=u and claim_id<>c)
 or exists(select 1 from public.user_depot_access where depot_id=d and user_id<>u)
 then raise exception 'Fixture ownership verification failed'; end if;
 delete from rc_private.requests where actor_id=u;
 delete from public.activity_logs where actor_id=u and (entity_id=c or entity_id is null);
 delete from public.claim_status_history where claim_id=c;
 delete from rc_private.claim_sensitive where claim_id=c;
 delete from public.claims where id=c;
 delete from public.customer_depots where customer_id=cu and depot_id=d;
 delete from public.user_depot_access where user_id=u;
 delete from public.user_permissions where user_id=u;
 delete from public.customers where id=cu;
 delete from public.campaigns where id=ca;
 delete from public.depots where id=d;
 delete from public.profiles where id=u;
 delete from auth.users where id=u;
 -- Batch counters remain monotonic; never reuse previously allocated numbers.
end $$;
commit;
