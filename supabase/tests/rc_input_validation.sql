-- Run after rc_transaction_input_validation. All fixtures roll back.
begin;
do $$ declare u uuid:=gen_random_uuid(); begin
 insert into auth.users(id) values(u);
 insert into public.profiles(id,user_code,full_name,business_email,role,status,suffix_num,must_change_password)
 values(u,u::text,'Validation test','test@example.invalid','admin','active','996',false);
 insert into public.user_permissions values(u,'upload_claim');
 perform set_config('request.jwt.claim.sub',u::text,true);
end $$;
set local role authenticated;
do $$ declare item jsonb; error_text text; begin
 for item in select value from jsonb_array_elements('[
 {"no_doc":"none","version_no":1,"total_billing":"NaN"},
 {"no_doc":"none","version_no":1,"total_billing":-1},
 {"no_doc":"none","version_no":1,"paid_on":"01/02/2026"},
 {"no_doc":"none","version_no":1,"billing_months":[{"bad":true}]},
 {"no_doc":"none","version_no":1,"actor_id":"forged"},
 {"no_doc":"none","version_no":null},
 {"no_doc":"none","version_no":1.5}
 ]'::jsonb) loop
  begin
   perform public.rc_process_claims('submit',jsonb_build_array(item),gen_random_uuid(),'');
   raise exception 'VALIDATION_TEST_FAILED';
  exception when raise_exception then
   get stacked diagnostics error_text=message_text;
   if error_text in('VALIDATION_TEST_FAILED','Document not found') then raise; end if;
  end;
 end loop;
 begin
  perform rc_private.mutate_claims_unchecked('submit','[]',gen_random_uuid(),'');
  raise exception 'Unchecked entry point accessible';
 exception when insufficient_privilege then null;
 end;
end $$;
reset role;
select 'PASS: invalid money, dates, months, forged fields, versions and unchecked entry point denied' as result;
rollback;
