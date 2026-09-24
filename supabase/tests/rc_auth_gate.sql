begin;
do $$ declare u uuid:=gen_random_uuid(); d uuid:=gen_random_uuid(); begin
insert into auth.users(id) values(u);
insert into public.profiles(id,user_code,full_name,business_email,role,status,suffix_num)
values(u,u::text,'Test','test@example.invalid','test','active','999');
insert into public.depots(id,depot_code,depot_name) values(d,d::text,'Test');
insert into public.user_depot_access values(u,d);
perform set_config('request.jwt.claim.sub',u::text,true);
perform set_config('rc.test_user',u::text,true);
end $$;
set local role authenticated;
do $$ begin
if exists(select 1 from public.depots) then raise exception 'Password gate failed'; end if;
if not exists(select 1 from public.profiles where must_change_password) then raise exception 'Profile gate not visible'; end if;
end $$;
reset role;
update auth.users set encrypted_password='synthetic-test-only' where id=current_setting('rc.test_user')::uuid;
set local role authenticated;
do $$ begin
if (select count(*) from public.depots)<>1 then raise exception 'Password-change gate did not unlock'; end if;
end $$;
reset role;
do $$ begin
if public.rc_gross_up_legacy(85000,'Badan')<>100000
or public.rc_gross_up_legacy(57000000,'Pribadi')<>60000000
or public.rc_gross_up_legacy(218500000,'Pribadi')<>250000000
or public.rc_gross_up_legacy(406000000,'Pribadi')<>500000000
or public.rc_gross_up_legacy(3556000000,'Pribadi')<>5000000000
or public.rc_gross_up_legacy(-1,'Badan')<>0 then raise exception 'Gross-up parity failed'; end if;
end $$;
select 'PASS: password gate, password-change trigger, legacy gross-up boundaries' as result;
rollback;
