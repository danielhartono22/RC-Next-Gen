create or replace function rc_private.mutate_claims(p_action text,p_items jsonb,p_request_id uuid,p_reason text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid(); perm text; v_payload jsonb; cached rc_private.requests%rowtype;
 c public.claims%rowtype; item jsonb; target text; batch text; stage text; subject text;
 processed jsonb:='[]'; stamp timestamptz:=now();
begin
 if p_action not in('submit','release','claim','clearing','reject_release','reject_claim','reject_clearing','hold','unhold','expire','bulk_rebate')
 or p_action is null then raise exception 'Unknown action'; end if;
 perm:=case when p_action in('submit','hold','unhold','expire') then 'upload_claim'
 when p_action in('release','reject_release') then 'release_claim'
 when p_action='bulk_rebate' then 'bulk_process' else 'process_claim' end;
 if not rc_private.can_access(null,perm) then raise exception 'Access denied' using errcode='42501'; end if;
 if p_request_id is null or p_items is null or jsonb_typeof(p_items)<>'array' then raise exception 'Invalid request'; end if;
 if jsonb_array_length(p_items) not between 1 and 100 then raise exception 'Select 1-100 claims'; end if;
 if length(coalesce(p_reason,''))>1000 then raise exception 'Reason too long'; end if;
 if p_action in('reject_release','reject_claim','reject_clearing','hold','unhold','expire') and btrim(coalesce(p_reason,''))='' then raise exception 'Reason required'; end if;
 if exists(select 1 from jsonb_array_elements(p_items) x where jsonb_typeof(x)<>'object' or coalesce(x->>'no_doc','')='' or x->>'version_no' is null)
 or (select count(distinct x->>'no_doc') from jsonb_array_elements(p_items) x)<>jsonb_array_length(p_items)
 then raise exception 'Each claim must have a unique document number and version'; end if;
 v_payload:=jsonb_build_object('action',p_action,'items',p_items,'reason',p_reason);
 insert into rc_private.requests(actor_id,request_id,payload) values(actor,p_request_id,v_payload) on conflict do nothing;
 select * into strict cached from rc_private.requests where actor_id=actor and request_id=p_request_id for update;
 if cached.payload<>v_payload then raise exception 'Request ID reused for different payload'; end if;
 if cached.result is not null then return cached.result; end if;
 stage:=case p_action when 'submit' then '01' when 'release' then '02' when 'claim' then '03' when 'clearing' then '04' when 'bulk_rebate' then '02' end;
 for item in select value from jsonb_array_elements(p_items) order by value->>'no_doc' loop
 select * into c from public.claims where no_doc=item->>'no_doc' for update;
 if not found then raise exception 'Document not found'; end if;
 if not rc_private.can_access(c.depot_id,perm) then raise exception 'Depot access denied' using errcode='42501'; end if;
 if c.version_no<>(item->>'version_no')::bigint then raise exception 'Document changed; refresh first' using errcode='40001'; end if;
 target:=null;
 if p_action='submit' and c.status='not_yet' then target:='submitted';
 elsif p_action='release' and c.status='submitted' then target:='released';
 elsif p_action='claim' and c.status='released' then target:='claimed';
 elsif p_action='clearing' and c.status='claimed' then target:='done';
 elsif p_action='reject_release' and c.status='submitted' then target:='not_yet';
 elsif p_action='reject_claim' and c.status='released' then target:='submitted';
 elsif p_action='reject_clearing' and c.status='claimed' then target:='released';
 elsif p_action='hold' and c.status in('not_yet','submitted','released','claimed') then target:='on_hold';
 elsif p_action='unhold' and c.status='on_hold' and c.previous_status in('not_yet','submitted','released','claimed') then target:=c.previous_status;
 elsif p_action='expire' and c.status in('not_yet','submitted','released','claimed','on_hold') then target:='expired';
 elsif p_action='bulk_rebate' and c.status in('submitted','released','claimed') then
  if not exists(select 1 from public.campaigns where id=c.campaign_id and lower(btrim(cashback_type))='rebate') then raise exception 'Campaign is not rebate'; end if;
  target:='done';
 end if;
 if target is null then raise exception 'Invalid status transition for %',c.no_doc; end if;
 if stage is not null and batch is null then batch:=rc_private.next_batch(stage); end if;
 if p_action='submit' then
  subject:=btrim(coalesce(item->>'tax_subject',c.tax_subject,''));
  if lower(subject) not in('badan','pribadi','perorangan','perseorangan') then raise exception 'Tax subject required'; end if;
  if item ? 'total_billing' and (item->>'total_billing')::numeric<0 then raise exception 'Negative billing'; end if;
  if item ? 'billing_months' and (jsonb_typeof(item->'billing_months')<>'array' or jsonb_array_length(item->'billing_months')>4) then raise exception 'Invalid billing months'; end if;
  update public.claims set tax_subject=subject,gross_up=public.rc_gross_up_legacy(cb_net,subject),
    total_billing=case when item ? 'total_billing' then (item->>'total_billing')::numeric else total_billing end,
    period_start=coalesce(nullif(item->>'period_start','')::date,period_start),
    period_end=coalesce(nullif(item->>'period_end','')::date,period_end),paid_on=coalesce(nullif(item->>'paid_on','')::date,paid_on),
    approval=coalesce(item->>'approval',approval),billing_months=coalesce(item->'billing_months',billing_months)
   where id=c.id;
  insert into rc_private.claim_sensitive(claim_id) values(c.id) on conflict do nothing;
  update rc_private.claim_sensitive set ktp=coalesce(item->>'ktp',ktp),npwp=coalesce(item->>'npwp',npwp),
    bank=coalesce(item->>'bank',bank),account_number=coalesce(item->>'account_number',account_number),
    account_name=coalesce(item->>'account_name',account_name),top_text=coalesce(item->>'top',top_text) where claim_id=c.id;
 end if;
 update public.claims set status=target,
 previous_status=case when p_action='hold' then c.status when p_action in('unhold','expire') then null else previous_status end,
 uploaded_at=case when p_action='submit' then stamp when p_action='reject_release' then null else uploaded_at end,
 released_at=case when p_action in('release','bulk_rebate') then stamp when p_action='reject_claim' then null else released_at end,
 claimed_at=case when p_action in('claim','bulk_rebate') then stamp when p_action='reject_clearing' then null else claimed_at end,
 cleared_at=case when p_action in('clearing','bulk_rebate') then stamp else cleared_at end,
 batch_upload=case when p_action='submit' then batch when p_action='reject_release' then null else batch_upload end,
 batch_release=case when p_action in('release','bulk_rebate') then batch when p_action='reject_claim' then null else batch_release end,
 batch_claim=case when p_action in('claim','bulk_rebate') then batch when p_action='reject_clearing' then null else batch_claim end,
 batch_clearing=case when p_action in('clearing','bulk_rebate') then batch else batch_clearing end,
 version_no=version_no+1,updated_at=stamp where id=c.id;
 insert into public.claim_status_history(claim_id,actor_id,from_status,to_status,action,batch,reason)
 values(c.id,actor,c.status,target,p_action,batch,p_reason);
 insert into public.activity_logs(actor_id,depot_id,event_type,entity_id,details)
 values(actor,c.depot_id,p_action,c.id,jsonb_build_object('from',c.status,'to',target,'batch',batch));
 processed:=processed||jsonb_build_array(jsonb_build_object('no_doc',c.no_doc,'status',target,'version_no',c.version_no+1));
 end loop;
 v_payload:=jsonb_build_object('processed',processed,'batch',batch,'count',jsonb_array_length(processed));
 update rc_private.requests set result=v_payload where actor_id=actor and request_id=p_request_id;
 return v_payload;
end $$;
