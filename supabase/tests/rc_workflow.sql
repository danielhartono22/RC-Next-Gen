begin;
do $$ declare u uuid:=gen_random_uuid(); d uuid:=gen_random_uuid(); d2 uuid:=gen_random_uuid(); cu uuid:=gen_random_uuid(); ca uuid:=gen_random_uuid(); begin
 perform set_config('rc.test_user',u::text,true);
 insert into auth.users(id) values(u);
 insert into public.profiles(id,user_code,full_name,business_email,role,status,suffix_num,must_change_password)
 values(u,u::text,'Test','test@example.invalid','system manager','active','998',false);
 insert into public.user_permissions select u,code from public.permissions;
 insert into public.depots(id,depot_code,depot_name) values(d,d::text,'Test'),(d2,d2::text,'Other');
 insert into public.user_depot_access values(u,d);
 insert into public.customers(id,customer_code,customer_name) values(cu,cu::text,'Test');
 insert into public.campaigns(id,campaign_code,campaign_name,cashback_type) values(ca,ca::text,'Test','rebate');
 insert into public.claims(no_doc,campaign_id,customer_id,depot_id,status,cb_net) values
 ('TEST-A-'||u,ca,cu,d,'not_yet',85000),('TEST-B-'||u,ca,cu,d,'not_yet',85000),('TEST-X-'||u,ca,cu,d2,'not_yet',85000);
 perform set_config('request.jwt.claim.sub',u::text,true);
end $$;
set local role authenticated;
do $$ declare doc text:='TEST-A-'||current_setting('rc.test_user'); b text:='TEST-B-'||current_setting('rc.test_user');
 v bigint; req uuid:=gen_random_uuid(); result jsonb; items jsonb;
begin
 items:=jsonb_build_array(jsonb_build_object('no_doc',doc,'version_no',1,'tax_subject','Badan'));
 result:=public.rc_process_claims('submit',items,req,'');
 if result<>public.rc_process_claims('submit',items,req,'') then raise exception 'Replay failure'; end if;
 if (select gross_up from public.claims where no_doc=doc)<>100000 then raise exception 'Gross-up failure'; end if;
 begin
 perform public.rc_process_claims('clearing',jsonb_build_array(jsonb_build_object('no_doc',doc,'version_no',2)),gen_random_uuid(),'');
 raise exception 'Stage skip accepted'; exception when raise_exception then if sqlerrm='Stage skip accepted' then raise; end if; end;
 begin
 perform public.rc_process_claims('release',jsonb_build_array(jsonb_build_object('no_doc',doc,'version_no',1)),gen_random_uuid(),'');
 raise exception 'Stale version accepted'; exception when serialization_failure then null; end;
 begin
 perform public.rc_process_claims('submit',jsonb_build_array(jsonb_build_object('no_doc','TEST-X-'||current_setting('rc.test_user'),'version_no',1,'tax_subject','Badan')),gen_random_uuid(),'');
 raise exception 'Foreign depot accepted'; exception when insufficient_privilege then null; end;
 -- A valid first item must roll back if any later item fails.
 begin
 perform public.rc_process_claims('submit',jsonb_build_array(jsonb_build_object('no_doc',b,'version_no',1,'tax_subject','Badan'),jsonb_build_object('no_doc','ZZZ-NOT-FOUND','version_no',1)),gen_random_uuid(),'');
 raise exception 'Partial transaction accepted'; exception when raise_exception then if sqlerrm='Partial transaction accepted' then raise; end if; end;
 if (select status from public.claims where no_doc=b)<>'not_yet' then raise exception 'Atomic rollback failure'; end if;
 perform public.rc_process_claims('release',jsonb_build_array(jsonb_build_object('no_doc',doc,'version_no',2)),gen_random_uuid(),'');
 perform public.rc_process_claims('claim',jsonb_build_array(jsonb_build_object('no_doc',doc,'version_no',3)),gen_random_uuid(),'');
 perform public.rc_process_claims('clearing',jsonb_build_array(jsonb_build_object('no_doc',doc,'version_no',4)),gen_random_uuid(),'');
 if (select status from public.claims where no_doc=doc)<>'done' then raise exception 'Workflow failed'; end if;
 perform public.rc_process_claims('hold',jsonb_build_array(jsonb_build_object('no_doc',b,'version_no',1)),gen_random_uuid(),'Test');
 perform public.rc_process_claims('unhold',jsonb_build_array(jsonb_build_object('no_doc',b,'version_no',2)),gen_random_uuid(),'Test');
 perform public.rc_process_claims('expire',jsonb_build_array(jsonb_build_object('no_doc',b,'version_no',3)),gen_random_uuid(),'Test');
 begin
 perform public.rc_process_claims('submit',jsonb_build_array(jsonb_build_object('no_doc',b,'version_no',4,'tax_subject','Badan')),gen_random_uuid(),'');
 raise exception 'Expired accepted'; exception when raise_exception then if sqlerrm='Expired accepted' then raise; end if; end;
 if (select count(*) from public.claim_status_history where actor_id=auth.uid())<>7 then raise exception 'Audit history mismatch'; end if;
end $$;
reset role;
select 'PASS: workflow, gross-up, replay, scope, version, rollback, exceptions, history' as result;
rollback;
