-- Executed by scripts/test_pending_approval.mjs inside BEGIN ... ROLLBACK.
-- All scenarios use generated dummy claims/customers/campaigns and temporary accounts.
create temporary table qa_approval_results (scenario text, status text) on commit drop;
create temporary table qa_approval_context (manager uuid, uploader uuid, finance uuid, depot uuid, customer uuid, campaign uuid, prefix text) on commit drop;

create function pg_temp.qa_assert(ok boolean, label text) returns void language plpgsql as $$
begin
 if ok is distinct from true then raise exception 'FAILED: %',label; end if;
 insert into qa_approval_results values(label,'PASS');
end $$;

do $$
declare d uuid:=gen_random_uuid(); cu uuid:=gen_random_uuid(); ca uuid:=gen_random_uuid();
 m uuid:=gen_random_uuid(); u uuid:=gen_random_uuid(); f uuid:=gen_random_uuid(); x uuid;
 prefix text:='QA-APP-'||substr(replace(gen_random_uuid()::text,'-',''),1,12); code text;
begin
 insert into public.depots(id,depot_code,depot_name) values(d,prefix,'Dummy approval depot');
 insert into public.customers(id,customer_code,customer_name,top_text,npwp)
 values(cu,prefix,'Dummy approval customer','30','000000000000000');
 insert into public.campaigns(id,campaign_code,campaign_name,cashback_type,tax_status,period_start,period_end)
 values(ca,prefix,'Dummy approval campaign','CN','Non PKP','2026-01-01','2026-01-31');
 foreach x in array array[m,u,f] loop
  code:=prefix||substr(x::text,1,8);
  insert into auth.users(id,email,raw_user_meta_data) values(x,code||'@example.invalid',
    jsonb_build_object('user_code',code,'full_name','Dummy approval tester','business_email',code||'@example.invalid',
      'requested_role','osc','requested_depot',prefix));
  update public.profiles set status='active',role=case when x=m then 'system manager' when x=f then 'finance' else 'osc' end,
    suffix_num='999',must_change_password=false where id=x;
  insert into public.user_depot_access(user_id,depot_id) values(x,d) on conflict do nothing;
 end loop;
 insert into public.user_permissions(user_id,permission_code) values(u,'upload_claim'),(f,'process_claim');
 insert into qa_approval_context values(m,u,f,d,cu,ca,prefix);
end $$;

create function pg_temp.qa_doc(label text, st text default 'not_yet') returns text language plpgsql as $$
declare ctx record; doc text;
begin
 select * into ctx from qa_approval_context;
 doc:=ctx.prefix||'-'||label;
 insert into public.claims(no_doc,campaign_id,customer_id,depot_id,status,cb_net)
 values(doc,ctx.campaign,ctx.customer,ctx.depot,st,1000);
 return doc;
end $$;

create function pg_temp.qa_action(doc text, action text, actor uuid, req uuid default null, ver bigint default null, extra jsonb default '{}')
returns jsonb language plpgsql as $$
declare result jsonb; v bigint;
begin
 select version_no into v from public.claims where no_doc=doc;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',actor,'role','authenticated')::text,true);
 set local role authenticated;
 result:=public.rc_process_claims(action,jsonb_build_array(jsonb_build_object('no_doc',doc,'version_no',coalesce(ver,v))||extra),coalesce(req,gen_random_uuid()),'Dummy approval test');
 reset role;
 return result;
exception when others then reset role; raise;
end $$;

create function pg_temp.qa_denied(doc text, action text, actor uuid, expected text, ver bigint default null) returns void language plpgsql as $$
begin
 begin
  perform pg_temp.qa_action(doc,action,actor,null,ver);
 exception when others then
  if sqlerrm not ilike '%'||expected||'%' then raise; end if;
  perform pg_temp.qa_assert(true,'Denied '||action||': '||expected);
  return;
 end;
 raise exception 'FAILED: % should be denied',action;
end $$;

do $$
declare ctx record; doc text; doc2 text; hdoc text; edoc text; r jsonb; r2 jsonb; rows jsonb;
 req uuid; ver bigint; st text; other_depot uuid;
begin
 select * into ctx from qa_approval_context;
 perform pg_temp.qa_assert(rc_private.legacy_status(null)='Not Yet' and rc_private.legacy_status('  ')='Not Yet','Blank and null normalize to Not Yet');
 doc:=pg_temp.qa_doc('NORMAL');
 perform pg_temp.qa_denied(doc,'approve',ctx.manager,'Invalid status transition');
 req:=gen_random_uuid();
 r:=pg_temp.qa_action(doc,'submit',ctx.uploader,req,1);
 perform pg_temp.qa_assert((select status='not_yet' and pending_approval->>'kind'='submit' and version_no=2 from public.claims where no_doc=doc),'Submit keeps Not Yet and records pending request');
 r2:=pg_temp.qa_action(doc,'submit',ctx.uploader,req,1);
 perform pg_temp.qa_assert(r=r2 and (select version_no=2 from public.claims where no_doc=doc),'Retry same request is idempotent');
 perform pg_temp.qa_assert((select count(*)=1 from rc_private.approval_rows where no_doc=doc),'Pending submit appears in approval queue');
 perform set_config('request.jwt.claims',jsonb_build_object('sub',ctx.manager,'role','authenticated')::text,true);
 set local role authenticated;
 r:=public.rc_legacy_workflow(); r2:=public.rc_open_claims(ctx.prefix,'',0,100);
 reset role;
 perform pg_temp.qa_assert(not exists(select 1 from jsonb_array_elements(r->'releaseData') x where x->>'noDoc'=doc)
  and not exists(select 1 from jsonb_array_elements(r2->'rows') x where x->>'noDoc'=doc),'Pending submission absent from Release and selectable Open claims');
 perform pg_temp.qa_denied(doc,'submit',ctx.uploader,'menunggu approval');
 perform pg_temp.qa_denied(doc,'release',ctx.manager,'menunggu approval');
 perform pg_temp.qa_denied(doc,'bulk_rebate',ctx.manager,'menunggu approval');
 perform pg_temp.qa_denied(doc,'approve',ctx.uploader,'Access denied');
 perform pg_temp.qa_denied(doc,'approve',ctx.manager,'Document changed',1);
 r:=pg_temp.qa_action(doc,'reject_approval',ctx.manager);
 perform pg_temp.qa_assert((select status='not_yet' and pending_approval is null and uploaded_at is null from public.claims where no_doc=doc),'Reject submit keeps Not Yet and permits resubmit');
 perform pg_temp.qa_action(doc,'submit',ctx.uploader);
 perform pg_temp.qa_action(doc,'approve',ctx.manager);
 perform pg_temp.qa_assert((select status='approved' and pending_approval is null and approved_by=ctx.manager from public.claims where no_doc=doc),'Approval applies Approved with actor');
 perform pg_temp.qa_denied(doc,'approve',ctx.manager,'Invalid status transition');
 perform pg_temp.qa_action(doc,'release',ctx.manager);
 perform pg_temp.qa_action(doc,'claim',ctx.finance);
 perform pg_temp.qa_action(doc,'clearing',ctx.finance);
 perform pg_temp.qa_assert((select status='done' from public.claims where no_doc=doc),'Approved claim completes normal workflow');

 doc:=pg_temp.qa_doc('RA07');
 perform pg_temp.qa_action(doc,'submit',ctx.uploader,null,null,'{"jenis_cashback":"RA07"}');
 perform pg_temp.qa_assert((select status='not_yet' from public.claims where no_doc=doc),'RA07 waits for approval');
 perform pg_temp.qa_action(doc,'approve',ctx.manager);
 perform pg_temp.qa_assert((select status='done' and cleared_at is not null from public.claims where no_doc=doc),'RA07 completes after approval');

 hdoc:=pg_temp.qa_doc('HOLD'); edoc:=pg_temp.qa_doc('UPLOAD-EXPIRED');
 perform set_config('request.jwt.claims',jsonb_build_object('sub',ctx.uploader,'role','authenticated')::text,true);
 set local role authenticated;
 r:=public.rc_posting_exception('hold',jsonb_build_array(jsonb_build_object('noDoc',hdoc,'versionNo',1,
  'soStart','2026-01-01','soEnd','2026-02-28','billingStart','2026-01-01','billingEnd','2026-02-28')),'Dummy extension');
 reset role;
 perform pg_temp.qa_assert((r->>'berhasil')::int=1 and (select status='not_yet' and extend_so_end is null from public.claims where no_doc=hdoc),'Hold request keeps status and effective periods unchanged');
 perform pg_temp.qa_denied(hdoc,'approve_hold',ctx.uploader,'Access denied');
 perform pg_temp.qa_denied(hdoc,'approve_hold',ctx.manager,'Document changed',1);
 perform pg_temp.qa_action(hdoc,'approve_hold',ctx.manager);
 perform pg_temp.qa_assert((select status='on_hold' and extend_so_end='2026-02-28' and pending_approval is null and hold_approved_at is not null from public.claims where no_doc=hdoc),'Approve hold applies status and requested periods atomically');
 perform pg_temp.qa_denied(hdoc,'reject_hold',ctx.manager,'Invalid status transition');

 perform set_config('request.jwt.claims',jsonb_build_object('sub',ctx.uploader,'role','authenticated')::text,true);
 set local role authenticated;
 r:=public.rc_posting_exception('expired',jsonb_build_array(jsonb_build_object('noDoc',edoc,'versionNo',1),jsonb_build_object('noDoc',hdoc,'versionNo',1)),'Dummy expiry');
 reset role;
 perform pg_temp.qa_assert((r->>'berhasil')::int=1 and (r->>'jumlahGagal')::int=1 and jsonb_array_length(r->'processed')=1,'Partial exception returns only successfully requested documents');
 perform pg_temp.qa_assert((select status='not_yet' and batch_clearing is null from public.claims where no_doc=edoc),'Upload Expired keeps Not Yet without clearing batch');
 perform set_config('request.jwt.claims',jsonb_build_object('sub',ctx.manager,'role','authenticated')::text,true);
 set local role authenticated;
 r:=public.rc_approval_hold(ctx.prefix,null);
 reset role;
 perform pg_temp.qa_assert(exists(select 1 from jsonb_array_elements(r->'rows') x where x->>'noDoc'=edoc and x->>'statusKini'='Not Yet' and x->>'statusPengajuan'='Expired'),'Exception queue separates effective status from requested status');
 perform pg_temp.qa_action(edoc,'reject_hold',ctx.manager);
 perform pg_temp.qa_assert((select status='not_yet' and pending_approval is null from public.claims where no_doc=edoc),'Reject expiry keeps original status');
 perform pg_temp.qa_action(edoc,'expire',ctx.uploader);
 perform pg_temp.qa_action(edoc,'approve_hold',ctx.manager);
 perform pg_temp.qa_assert((select status='expired' and batch_clearing is not null and pending_approval is null from public.claims where no_doc=edoc),'Approve upload expiry applies Expired and batch');
 perform pg_temp.qa_action(hdoc,'expire',ctx.uploader);
 perform pg_temp.qa_action(hdoc,'reject_hold',ctx.manager);
 perform pg_temp.qa_assert((select status='on_hold' and hold_approved_by=ctx.manager and hold_approved_at is not null and pending_approval is null from public.claims where no_doc=hdoc),'Rejected expiry preserves previously approved hold and its approval trace');

 foreach st in array array['released','claimed'] loop
  doc:=pg_temp.qa_doc('PROCESS-'||st,st);
  perform pg_temp.qa_denied(doc,'expire_claim_process',ctx.uploader,'Access denied');
  req:=gen_random_uuid();
  r:=pg_temp.qa_action(doc,'expire_claim_process',ctx.finance,req,1);
  r2:=pg_temp.qa_action(doc,'expire_claim_process',ctx.finance,req,1);
  perform pg_temp.qa_assert(r=r2 and (select version_no=2 from public.claims where no_doc=doc),'Direct expiry retry is idempotent for '||st);
  perform pg_temp.qa_assert((select status='expired' and pending_approval is null and hold_approved_at is null and batch_clearing is not null from public.claims where no_doc=doc),'Claim Process '||st||' expires immediately without approval');
  perform pg_temp.qa_denied(doc,'approve_hold',ctx.manager,'Invalid status transition');
 end loop;
 doc:=pg_temp.qa_doc('NO-PROCESS');
 perform pg_temp.qa_denied(doc,'expire_claim_process',ctx.finance,'Invalid status transition');

 doc:=pg_temp.qa_doc('OUTSIDE','released'); other_depot:=gen_random_uuid();
 insert into public.depots(id,depot_code,depot_name) values(other_depot,ctx.prefix||'-OTHER','Other dummy depot');
 update public.claims set depot_id=other_depot where no_doc=doc;
 perform pg_temp.qa_denied(doc,'expire_claim_process',ctx.finance,'Depot access denied');

 doc:=pg_temp.qa_doc('MIXED-HOLD');doc2:=pg_temp.qa_doc('MIXED-EXPIRE');
 perform pg_temp.qa_action(doc,'hold',ctx.uploader);
 perform pg_temp.qa_action(doc2,'expire',ctx.uploader);
 perform set_config('request.jwt.claims',jsonb_build_object('sub',ctx.manager,'role','authenticated')::text,true);
 set local role authenticated;
 r:=public.rc_process_claims('approve_hold',jsonb_build_array(jsonb_build_object('no_doc',doc,'version_no',2),
   jsonb_build_object('no_doc',doc2,'version_no',2)),gen_random_uuid(),'');
 reset role;
 perform pg_temp.qa_assert((select batch_clearing is null and status='on_hold' from public.claims where no_doc=doc)
  and (select batch_clearing is not null and status='expired' from public.claims where no_doc=doc2),'Mixed exception approval issues clearing batch only for Expired');

 perform set_config('request.jwt.claims',jsonb_build_object('sub',ctx.manager,'role','authenticated')::text,true);
 set local role authenticated;
 r:=public.rc_approval_hold(ctx.prefix,null);
 reset role;
 perform pg_temp.qa_assert(jsonb_array_length(r->'rows')=0,'Claim Process expiry and decided requests are absent from approval queue');
 perform pg_temp.qa_assert(not exists(select 1 from rc_private.approval_rows where no_doc like ctx.prefix||'%'),'All resolved dummy submissions leave normal approval queue');
end $$;

select * from qa_approval_results;
