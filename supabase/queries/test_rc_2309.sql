-- Executed by scripts/test_rc_2309.mjs inside BEGIN ... ROLLBACK.
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
 prefix text:='QA-APP-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,12)); code text;
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
 insert into public.customer_depots(customer_id,depot_id) values(cu,d);
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
 perform pg_temp.qa_assert((select status='submitted' and pending_approval->>'kind'='submit' and version_no=2 from public.claims where no_doc=doc),'Submit enters Submitted and records pending request');
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
 perform pg_temp.qa_assert((select status='submitted' from public.claims where no_doc=doc),'RA07 waits for approval');
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

do $$
declare ctx record; doc text; r jsonb;r2 jsonb; req uuid; items jsonb; n integer;
begin
 select * into ctx from qa_approval_context;
 -- Current label and formatting rules are shared by all read models.
 perform pg_temp.qa_assert(rc_private.cb_label('RA07')='Rebate Manual' and rc_private.cb_label('RA7')='Rebate Manual','RA aliases have one CB label');
 perform pg_temp.qa_assert(rc_private.legacy_date('2026-01-22')='22-Jan-2026','English dd-Mmm-yyyy date format');
 doc:=pg_temp.qa_doc('REBATE');
 perform pg_temp.qa_action(doc,'submit',ctx.uploader,null,null,'{"jenis_cashback":"Rebate"}');
 perform pg_temp.qa_action(doc,'approve',ctx.manager);
 perform pg_temp.qa_denied(doc,'release',ctx.manager,'hanya dapat diproses lewat Bulk');
 perform pg_temp.qa_action(doc,'bulk_rebate',ctx.manager);
 perform pg_temp.qa_assert((select status='done' and cashback_type_changed and cashback_type_override='Rebate' and bulk_processed_at is not null and released_at is null and claimed_at is null from public.claims where no_doc=doc),'Rebate persists type override and real Bulk Process chronology');
 perform pg_temp.qa_assert((select count(*)=2 from public.claim_status_history h join public.claims c on c.id=h.claim_id where c.no_doc=doc and h.action in('bulk_process','bulk_rebate')),'Bulk Process and Done are separate history events');
 perform pg_temp.qa_assert((select count(*)=2 from public.claim_status_history h join public.claims c on c.id=h.claim_id where c.no_doc=ctx.prefix||'-RA07' and h.action in('approve','manual_complete')),'Manual rebate records Approved and Done history');
 perform pg_temp.qa_assert((select rc_private.claim_remark(c)='CB Type Changed' from public.claims c where no_doc=doc),'CB Type Changed remark is retained');

 -- 500 different claims exercise batch processing, not duplicated copies of a single claim.
 select jsonb_agg(jsonb_build_object('no_doc',pg_temp.qa_doc('BATCH-'||g),'version_no',1)) into items from generate_series(1,500) g;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',ctx.uploader,'role','authenticated')::text,true);
 set local role authenticated;
 r:=public.rc_process_claims('submit',items,gen_random_uuid(),'Dummy 500');
 reset role;
 perform pg_temp.qa_assert((select count(*)=500 from public.claims where no_doc like ctx.prefix||'-BATCH-%' and status='submitted'),'500 distinct upload rows accepted');
 begin
  set local role authenticated;
  perform public.rc_process_claims('submit',items||jsonb_build_array(jsonb_build_object('no_doc','dummy-501','version_no',1)),gen_random_uuid(),'Dummy 501');
  reset role;raise exception 'Expected 501 limit';
 exception when others then reset role;if sqlerrm not ilike '%maksimal 500%' then raise;end if;
 end;
 perform pg_temp.qa_assert(true,'501 upload rows rejected before writes');

 -- Profile writes stay pending until an independent reviewer approves.
 perform set_config('request.jwt.claims',jsonb_build_object('sub',ctx.uploader,'role','authenticated')::text,true);
 set local role authenticated;
 r:=public.rc_depot_profile_request(ctx.prefix,'{"nama":"Updated dummy depot","abbr":"QAX","region":"QA Region","grade":"A","alamat":"Dummy address","emailDepot":"depot@example.invalid","karAdmin":2,"karSales":3}');
 reset role;req:=(r->>'id')::uuid;
 perform pg_temp.qa_assert((select depot_name='Dummy approval depot' from public.depots where id=ctx.depot),'Profile remains unchanged before approval');
 perform set_config('request.jwt.claims',jsonb_build_object('sub',ctx.manager,'role','authenticated')::text,true);
 set local role authenticated;
 r:=public.rc_depot_profile_review(req,true,'Dummy reviewed');
 r2:=public.rc_depot_profile(ctx.prefix);
 reset role;
 perform pg_temp.qa_assert(r2->>'namaDepot'='Updated dummy depot' and r2->>'emailDepot'='depot@example.invalid' and r2->>'grade'='A' and (r2#>>'{karyawan,total}')::int=5,'Approved profile synchronizes name, email, grade and employee total');
 set local role authenticated;
 r:=public.rc_legacy_bootstrap();
 reset role;
 perform pg_temp.qa_assert(r#>>'{data,tabs,people.osc}'='true','Bootstrap includes tab rights');

 insert into public.user_permissions(user_id,permission_code) values(ctx.uploader,'view_people'),(ctx.uploader,'manage_key_master') on conflict do nothing;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',ctx.uploader,'role','authenticated')::text,true);
 set local role authenticated;
 r:=public.rc_legacy_bootstrap();
 r2:=public.rc_people_performance('osc',(select user_code from public.profiles where id=ctx.uploader));
 reset role;
 perform pg_temp.qa_assert(r#>>'{data,tabs,upload.mass}'='true','Non-manager bootstrap can read own tab rights');
 perform pg_temp.qa_assert(jsonb_array_length(r2->'rows')=1 and (r2#>>'{summary,depotCount}')::int=1,'OSC People Performance is scoped to assigned depot');
 perform pg_temp.qa_assert((r2#>>'{summary,claims,total}')::int>=500 and (r2#>>'{summary,claims,depotPct}')::numeric>0,'People Performance counts and percentages use real claims');
 set local role authenticated;
 r:=public.rc_people_history('osc',(select user_code from public.profiles where id=ctx.uploader),current_date-2,current_date,'day');
 r2:=public.rc_customer_list(ctx.prefix,0,50);
 reset role;
 perform pg_temp.qa_assert(jsonb_array_length(r->'rows')=3,'People daily history returns requested dates');
 perform pg_temp.qa_assert(jsonb_typeof(r2#>'{rows,0,depotNames}')='array','Customer Master provides depot names for lookup');

 insert into rc_private.user_tab_access values(ctx.uploader,'upload.mass',false),(ctx.uploader,'upload.single',false),(ctx.uploader,'people.osc',false);
 doc:=pg_temp.qa_doc('TAB-DENIED');
 perform pg_temp.qa_denied(doc,'submit',ctx.uploader,'Izin Mass Upload');
 begin
  set local role authenticated;perform public.rc_people_performance('osc','');reset role;raise exception 'Expected tab denial';
 exception when others then reset role;if sqlstate<>'42501' then raise;end if;end;
 perform pg_temp.qa_assert(true,'Denied People tab cannot be bypassed via direct RPC');
 update rc_private.user_tab_access set allowed=true where user_id=ctx.uploader;

 perform set_config('request.jwt.claims',jsonb_build_object('sub',ctx.manager,'role','authenticated')::text,true);
 set local role authenticated;
 r:=public.rc_legacy_logs();
 r2:=public.rc_open_claims_filtered(ctx.prefix,'',0,50,'Rebate');
 reset role;
 perform pg_temp.qa_assert(exists(select 1 from jsonb_array_elements(r->'logs') l where l->>'module'<>'' and l->>'tab'<>'' and l->>'stage'<>'' and l->>'batch'<>'' and l->>'timestampIso' is not null),'New audit events include timestamp, module, tab, stage and batch');
 perform pg_temp.qa_assert(not exists(select 1 from jsonb_array_elements(r2->'rows') x where x->>'jenisCb'<>'Rebate'),'Open CB filter applies on server');

 -- Save/read-back tab rights through the same RPC as Access Management.
 set local role authenticated;
 r:=public.rc_update_access(jsonb_build_object('userId',(select user_code from public.profiles where id=ctx.uploader),'tabs',jsonb_build_object('people.osc',false,'upload.open',false)));
 reset role;
 perform pg_temp.qa_assert((select not allowed from rc_private.user_tab_access where user_id=ctx.uploader and tab_code='people.osc'),'Access Management persists explicit tab denials');
 update rc_private.user_tab_access set allowed=true where user_id=ctx.uploader;

 -- Histories with no evidence must not silently become Not Yet.
 doc:=pg_temp.qa_doc('HISTORIC-UNKNOWN');
 update public.claims set created_at=now()-interval '5 days' where no_doc=doc;
 r:=rc_private.people_metrics(array[ctx.depot],current_date-2);
 perform pg_temp.qa_assert((r#>>'{claims,unknown}')::int=1,'Missing historical status is explicitly Unknown');

 -- Boundary test uses 2,000 unique customer/campaign relationships, rolled back at the end.
 insert into public.customers(customer_code,customer_name,npwp)
 select ctx.prefix||'-COMPILE-'||g,'Dummy compile customer '||g,'000000000000000' from generate_series(1,2000) g;
 insert into public.customer_depots(customer_id,depot_id)
 select id,ctx.depot from public.customers where customer_code like ctx.prefix||'-COMPILE-%';
 select jsonb_agg(jsonb_build_object('kodeDepot',ctx.prefix,'abbr','QAX','codeCampaign',ctx.prefix,
  'custCode',ctx.prefix||'-COMPILE-'||g,'custName','Dummy compile customer '||g,'netValue','10000','volume','1','cbNet','100.99','jenisCb','Rebate Manual')) into items from generate_series(1,2000) g;
 set local role authenticated;
 r:=public.rc_compile_preview(items);
 req:=gen_random_uuid();r2:=public.rc_compile_upload(items,req);
 reset role;
 perform pg_temp.qa_assert((r->>'siap')::int=2000 and (r2->>'dibuat')::int=2000,'2,000 unique compile rows accepted');
 perform pg_temp.qa_assert(not exists(select 1 from public.claims c join public.customers cu on cu.id=c.customer_id where cu.customer_code like ctx.prefix||'-COMPILE-%' and (c.status<>'not_yet' or rc_private.cb_label(c.cashback_type_override)<>'Rebate Manual')),'Compiled manual rebates start Not Yet and keep their CB type');
 begin
  set local role authenticated;perform public.rc_compile_upload(items||jsonb_build_array(items->0),gen_random_uuid());reset role;raise exception 'Expected compile limit';
 exception when others then reset role;if sqlerrm not ilike '%maksimal 2000%' then raise;end if;end;
 perform pg_temp.qa_assert(true,'2,001 compile rows rejected before writes');
 set local role authenticated;r:=public.rc_compile_upload(items,req);reset role;
 perform pg_temp.qa_assert(r=r2,'Compile replay is idempotent');
 -- Master metadata must not depend on a claim alias; compiled rows retain their override.
 set local role authenticated;
 r:=public.rc_campaign_list(ctx.prefix,0,50);
 r2:=public.rc_compilation_list(ctx.prefix,'','','Dummy compile customer',0,50);
 reset role;
 perform pg_temp.qa_assert(jsonb_array_length(r->'rows')=1 and r#>>'{rows,0,jenisCb}'='CN'
  and r#>>'{rows,0,periodStart}'='01-Jan-2026' and r#>>'{rows,0,periodEnd}'='31-Jan-2026',
  'Campaign Master returns its own CB type and actual period dates');
 perform pg_temp.qa_assert(jsonb_array_length(r2->'rows')=50 and (r2->>'total')::int=2000
  and not exists(select 1 from jsonb_array_elements(r2->'rows') x where x->>'jenisCb'<>'Rebate Manual'),
  'Compilation list preserves claim CB override across pagination');
 update public.campaigns set cashback_type='RA7' where id=ctx.campaign;
 set local role authenticated;r:=public.rc_campaign_list(ctx.prefix,0,50);reset role;
 perform pg_temp.qa_assert(r#>>'{rows,0,jenisCb}'='Rebate Manual','Campaign Master normalizes RA7 alias');
end $$;

select * from qa_approval_results;
