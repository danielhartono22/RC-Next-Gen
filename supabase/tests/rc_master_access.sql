begin;
-- Synthetic accounts are rolled back; no emails are sent.
select set_config('rc.test_user',gen_random_uuid()::text,true);
select set_config('rc.test_depot_a',gen_random_uuid()::text,true);
select set_config('rc.test_depot_b',gen_random_uuid()::text,true);
select set_config('rc.test_customer_a',gen_random_uuid()::text,true);
select set_config('rc.test_customer_b',gen_random_uuid()::text,true);
insert into auth.users(id) values(current_setting('rc.test_user')::uuid);
insert into public.profiles(id,user_code,full_name,business_email,role,status,suffix_num,must_change_password)
values(current_setting('rc.test_user')::uuid,current_setting('rc.test_user'),'Synthetic test','test@example.invalid','test','active','999',false);
insert into public.depots(id,depot_code,depot_name) values
(current_setting('rc.test_depot_a')::uuid,current_setting('rc.test_depot_a'),'Test A'),
(current_setting('rc.test_depot_b')::uuid,current_setting('rc.test_depot_b'),'Test B');
insert into public.customers(id,customer_code,customer_name) values
(current_setting('rc.test_customer_a')::uuid,current_setting('rc.test_customer_a'),'Test A'),
(current_setting('rc.test_customer_b')::uuid,current_setting('rc.test_customer_b'),'Test B');
insert into public.customer_depots values
(current_setting('rc.test_customer_a')::uuid,current_setting('rc.test_depot_a')::uuid),
(current_setting('rc.test_customer_b')::uuid,current_setting('rc.test_depot_b')::uuid);
insert into public.user_depot_access values(current_setting('rc.test_user')::uuid,current_setting('rc.test_depot_a')::uuid);
select set_config('request.jwt.claim.sub',current_setting('rc.test_user'),true);
set local role authenticated;
do $$ begin
 if (select count(*) from public.depots)<>1 then raise exception 'Depot scope failure'; end if;
 if (select count(*) from public.customers)<>1 then raise exception 'Customer scope failure'; end if;
 if not exists(select 1 from public.customers where id=current_setting('rc.test_customer_a')::uuid) then raise exception 'Allowed customer missing'; end if;
 begin
  insert into public.permissions values('test-escalation','not allowed');
  raise exception 'Unexpected write privilege';
 exception when insufficient_privilege then null; end;
 begin
  perform * from public.rc_claims_review limit 1;
  raise exception 'Unexpected review access';
 exception when insufficient_privilege then null; end;
end $$;
reset role;
update public.profiles set status='inactive' where id=current_setting('rc.test_user')::uuid;
set local role authenticated;
do $$ begin
 if exists(select 1 from public.depots) or exists(select 1 from public.customers)
 then raise exception 'Inactive account retained access'; end if;
end $$;
reset role;
set local role anon;
do $$ begin
 begin
  perform * from public.customers limit 1;
  raise exception 'Unexpected anonymous access';
 exception when insufficient_privilege then null; end;
end $$;
reset role;
select 'PASS: scoped read, denied write, denied review, inactive deny, anonymous deny' as result;
rollback;
