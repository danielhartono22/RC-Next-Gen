-- PENDING: not applied. Supabase MCP in this session has no permission on project
-- vvojshgcduqlugngpzkj, so nothing here has run against a PostgreSQL server yet.
-- Purpose: serve the existing `index (4).html` user interface unchanged from Supabase.
-- The legacy frontend consumes camelCase field names and whole arrays. These functions
-- reproduce that contract on top of the RLS-scoped tables, so the browser never sends
-- identity, role or depot scope as authority. Document Center stays out of scope.
--
-- Deliberate parity decision that still needs owner sign-off: the bootstrap ships the
-- claim/customer/campaign rows the signed-in user's depots already expose, because the
-- legacy screens filter and paginate in the browser. Row caps below keep the payload
-- bounded. Replacing these arrays with SQL aggregates requires changing those screens,
-- which the owner has excluded for now.

-- Legacy applyRoleBasedUI() reads single-letter flags. Map them from real permissions.
create or replace function rc_private.legacy_auth_flags() returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object(
  'j',case when x.p ? 'upload_claim' then 'Yes' else 'No' end,
  'k',case when x.p ? 'release_claim' then 'Yes' else 'No' end,
  'l',case when x.p ? 'process_claim' then 'Yes' else 'No' end,
  'm',case when x.p ? 'view_analytics' then 'Yes' else 'No' end,
  'd',case when x.p ? 'view_analytics' then 'Yes' else 'No' end,
  'n',case when x.p ? 'manage_access' then 'Yes' else 'No' end,
  'p',case when x.p ? 'view_master_depot' then 'Yes' else 'No' end,
  's',case when x.p ? 'bulk_process' then 'Yes' else 'No' end,
  'q','No')
 from (select coalesce(jsonb_object_agg(permission_code,true),'{}'::jsonb) as p
       from public.user_permissions where user_id=(select auth.uid())) x;
$$;
revoke all on function rc_private.legacy_auth_flags() from public,anon;
grant execute on function rc_private.legacy_auth_flags() to authenticated;

-- Status strings exactly as the legacy sheet produced them; normalizeClaimStatus() in the
-- browser maps blank to "Not Yet" and RA07/RA7 to "Done", so never emit those spellings.
create or replace function rc_private.legacy_status(s text) returns text
language sql immutable set search_path='' as $$
 select case s when 'not_yet' then 'Not Yet' when 'submitted' then 'Submitted'
 when 'released' then 'Released' when 'claimed' then 'Claimed' when 'done' then 'Done'
 when 'on_hold' then 'On Hold' when 'expired' then 'Expired' else s end;
$$;
revoke all on function rc_private.legacy_status(text) from public,anon;
grant execute on function rc_private.legacy_status(text) to authenticated;

create or replace function rc_private.legacy_date(d date) returns text
language sql immutable set search_path='' as $$ select case when d is null then '' else to_char(d,'DD-MM-YYYY') end; $$;
create or replace function rc_private.legacy_ts(t timestamptz) returns text
language sql stable set search_path='' as $$
 select case when t is null then '' else to_char(t at time zone 'Asia/Jakarta','DD-MM-YYYY') end; $$;
revoke all on function rc_private.legacy_date(date),rc_private.legacy_ts(timestamptz) from public,anon;
grant execute on function rc_private.legacy_date(date),rc_private.legacy_ts(timestamptz) to authenticated;

-- Documents feed the Claim Upload module lookup. Depot scope comes from RLS on claims.
create or replace function rc_private.legacy_documents() returns jsonb
language sql stable security definer set search_path='' as $$
 select coalesce(jsonb_agg(x order by x->>'noDoc'),'[]'::jsonb) from (
  select jsonb_build_object(
   'noDoc',c.no_doc,'status',rc_private.legacy_status(c.status),
   'dcCode',d.depot_code,'depotName',d.depot_name,
   'custCode',cu.customer_code,'custName',cu.customer_name,
   'codeCampaign',ca.campaign_code,'campaignName',ca.campaign_name,
   'cbNet',c.cb_net,'netValue',c.net_value,'volume',c.volume,
   'versionNo',c.version_no) as x
  from public.claims c
  join public.depots d on d.id=c.depot_id
  join public.customers cu on cu.id=c.customer_id
  join public.campaigns ca on ca.id=c.campaign_id
  where rc_private.can_access(c.depot_id)
  order by c.no_doc limit 20000) t;
$$;
revoke all on function rc_private.legacy_documents() from public,anon;
grant execute on function rc_private.legacy_documents() to authenticated;

create or replace function public.rc_legacy_documents() returns jsonb
language plpgsql stable security invoker set search_path='' as $$
begin
 if not rc_private.can_access(null) then raise exception 'Access denied' using errcode='42501'; end if;
 return rc_private.legacy_documents();
end $$;
revoke all on function public.rc_legacy_documents() from public,anon;
grant execute on function public.rc_legacy_documents() to authenticated;

-- Customer contact fields live per claim in rc_private.claim_sensitive, not on the master.
-- Collapse to the latest claim per customer so the legacy autofill keeps working, and hand
-- out contact fields only to accounts that may already read them through the claim form.
create or replace function rc_private.legacy_customers(p_with_contacts boolean) returns jsonb
language sql stable security definer set search_path='' as $$
 select coalesce(jsonb_agg(jsonb_build_object(
   'custCode',customer_code,'custName',customer_name,
   'ktp',coalesce(ktp,''),'npwp',coalesce(npwp,''),
   'noRek',coalesce(account_number,''),'namaRek',coalesce(account_name,''),
   'bank',coalesce(bank,'')) order by customer_code),'[]'::jsonb)
 from (
  select distinct on (cu.customer_code) cu.customer_code,cu.customer_name,
   case when p_with_contacts then s.ktp end as ktp,
   case when p_with_contacts then s.npwp end as npwp,
   case when p_with_contacts then s.account_number end as account_number,
   case when p_with_contacts then s.account_name end as account_name,
   case when p_with_contacts then s.bank end as bank
  from public.customers cu
  join public.customer_depots cd on cd.customer_id=cu.id
  left join public.claims c on c.customer_id=cu.id and c.depot_id=cd.depot_id
  left join rc_private.claim_sensitive s on s.claim_id=c.id
  where rc_private.can_access(cd.depot_id)
  order by cu.customer_code,c.updated_at desc nulls last) t;
$$;
revoke all on function rc_private.legacy_customers(boolean) from public,anon;
grant execute on function rc_private.legacy_customers(boolean) to authenticated;

-- Login bootstrap. One round trip, shaped exactly like the old Apps Script login response.
create or replace function public.rc_legacy_bootstrap() returns jsonb
language plpgsql stable security invoker set search_path='' as $$
declare me public.profiles%rowtype; flags jsonb; depot_ids uuid[]; home public.depots%rowtype;
 may_read_contacts boolean; result jsonb;
begin
 select * into me from public.profiles where id=(select auth.uid());
 if not found then raise exception 'Profile not found' using errcode='42501'; end if;
 if me.status<>'active' then return jsonb_build_object('status','error','message','Akun dinonaktifkan administrator.'); end if;
 if me.must_change_password then
  return jsonb_build_object('status','error','message','Ganti PIN sebelum mengakses sistem.','mustChangePassword',true);
 end if;
 flags:=rc_private.legacy_auth_flags();
 select array_agg(depot_id) into depot_ids from public.user_depot_access where user_id=me.id;
 depot_ids:=coalesce(depot_ids,'{}'::uuid[]);
 select * into home from public.depots where id=any(depot_ids) order by depot_code limit 1;
 may_read_contacts:=rc_private.can_access(null,'upload_claim');

 result:=jsonb_build_object(
  'status','success',
  'data',jsonb_build_object(
   'userId',me.user_code,'namaLengkap',me.full_name,'role',me.role,'sysRole',me.role,
   'email',me.business_email,'activation','active','suffix',me.suffix_num,
   'kodeDepot',coalesce(home.depot_code,''),'depot',coalesce(home.depot_name,''),
   'regional','','auth',flags,
   'managedDepots',coalesce((select jsonb_agg(depot_code order by depot_code)
     from public.depots where id=any(depot_ids)),'[]'::jsonb),
   'depotDetail',jsonb_build_object(
    'kode',coalesce(home.depot_code,''),'nama',coalesce(home.depot_name,''),
    'alamat',coalesce(home.address,''),'link',coalesce(home.master_link,''))),
  'depots',coalesce((select jsonb_agg(jsonb_build_object(
     'kode',depot_code,'nama',depot_name,'link',coalesce(master_link,''))
     order by depot_code) from public.depots where id=any(depot_ids)),'[]'::jsonb),
  'campaigns',coalesce((select jsonb_agg(jsonb_build_object(
     'codeCampaign',campaign_code,'campaignName',campaign_name,
     'jenisCb',coalesce(cashback_type,''),'statusPajak',coalesce(tax_status,''),
     'masterCode','','masterCodeName','',
     'periodStart',coalesce(period_start_text,''),'periodEnd',coalesce(period_end_text,''))
     order by campaign_code) from public.campaigns),'[]'::jsonb),
  'documents',rc_private.legacy_documents(),
  'customers',rc_private.legacy_customers(may_read_contacts));
 return result;
end $$;
revoke all on function public.rc_legacy_bootstrap() from public,anon;
grant execute on function public.rc_legacy_bootstrap() to authenticated;

-- Workflow queues. One call fills all four legacy tables, each already depot-scoped.
create or replace function public.rc_legacy_workflow() returns jsonb
language plpgsql stable security invoker set search_path='' as $$
declare rows_json jsonb;
begin
 if not rc_private.can_access(null) then raise exception 'Access denied' using errcode='42501'; end if;
 select coalesce(jsonb_agg(x),'[]'::jsonb) into rows_json from (
  select jsonb_build_object(
   'noDoc',c.no_doc,'status',rc_private.legacy_status(c.status),
   'depot',d.depot_name,'kodeDepot',d.depot_code,
   'kodeToko',cu.customer_code,'namaToko',cu.customer_name,
   'codeCampaign',ca.campaign_code,'campaignName',ca.campaign_name,
   'jenisCb',coalesce(ca.cashback_type,''),'statusPajakCamp',coalesce(ca.tax_status,''),
   'statusPajakCust',coalesce(c.tax_subject,''),
   'cbNet',c.cb_net,'grossUpCb',c.gross_up,'totTagih',c.total_billing,
   'periodeStart',rc_private.legacy_date(c.period_start),'periodeEnd',rc_private.legacy_date(c.period_end),
   'tglLunas',rc_private.legacy_date(c.paid_on),
   'tglUpload',rc_private.legacy_ts(c.uploaded_at),'tglRelease',rc_private.legacy_ts(c.released_at),
   'tglClaim',rc_private.legacy_ts(c.claimed_at),'tglClearing',rc_private.legacy_ts(c.cleared_at),
   'batchUpload',coalesce(c.batch_upload,''),'batchRelease',coalesce(c.batch_release,''),
   'batchClaim',coalesce(c.batch_claim,''),'batchClearing',coalesce(c.batch_clearing,''),
   'approval',coalesce(c.approval,''),'top',coalesce(s.top_text,''),
   'ktp',coalesce(s.ktp,''),'npwp',coalesce(s.npwp,''),'bankCust',coalesce(s.bank,''),
   'bank',coalesce(s.bank,''),'noRekening',coalesce(s.account_number,''),
   'namaRekening',coalesce(s.account_name,''),'pemilikRekening',coalesce(s.account_name,''),
   'versionNo',c.version_no,'rebate',lower(btrim(coalesce(ca.cashback_type,'')))='rebate') as x
  from public.claims c
  join public.depots d on d.id=c.depot_id
  join public.customers cu on cu.id=c.customer_id
  join public.campaigns ca on ca.id=c.campaign_id
  left join rc_private.claim_sensitive s on s.claim_id=c.id
  where c.status in('submitted','released','claimed')
  order by c.updated_at desc,c.id limit 5000) t;

 return jsonb_build_object('status','success',
  'releaseData',(select coalesce(jsonb_agg(v),'[]'::jsonb) from jsonb_array_elements(rows_json) v where v->>'status'='Submitted'),
  'claimFinData',(select coalesce(jsonb_agg(v),'[]'::jsonb) from jsonb_array_elements(rows_json) v where v->>'status'='Released'),
  'clearingData',(select coalesce(jsonb_agg(v),'[]'::jsonb) from jsonb_array_elements(rows_json) v where v->>'status'='Claimed'),
  'bulkRebateData',(select coalesce(jsonb_agg(v),'[]'::jsonb) from jsonb_array_elements(rows_json) v where (v->>'rebate')::boolean));
end $$;
revoke all on function public.rc_legacy_workflow() from public,anon;
grant execute on function public.rc_legacy_workflow() to authenticated;

-- Analytics. history = claims that entered the workflow; compileData = every scoped claim.
create or replace function public.rc_legacy_dashboard() returns jsonb
language plpgsql stable security invoker set search_path='' as $$
begin
 if not rc_private.can_access(null,'view_analytics') then raise exception 'Access denied' using errcode='42501'; end if;
 return jsonb_build_object('status','success',
  'history',coalesce((select jsonb_agg(jsonb_build_object(
    'noDoc',c.no_doc,'status',rc_private.legacy_status(c.status),
    'depot',d.depot_name,'osc',coalesce(p.full_name,''),
    'kodeToko',cu.customer_code,'namaToko',cu.customer_name,
    'codeCampaign',ca.campaign_code,'campaign',ca.campaign_name,
    'totalClaim',c.cb_net,'grossUpCb',c.gross_up,
    'tglUpload',rc_private.legacy_ts(c.uploaded_at),'tglClearing',rc_private.legacy_ts(c.cleared_at),
    'batchUpload',coalesce(c.batch_upload,''),'batchClearing',coalesce(c.batch_clearing,''))
    order by c.updated_at desc)
   from public.claims c
   join public.depots d on d.id=c.depot_id
   join public.customers cu on cu.id=c.customer_id
   join public.campaigns ca on ca.id=c.campaign_id
   left join lateral (select h.actor_id from public.claim_status_history h
     where h.claim_id=c.id and h.action='submit' order by h.id desc limit 1) sub on true
   left join public.profiles p on p.id=sub.actor_id
   where c.status<>'not_yet'),'[]'::jsonb),
  'compileData',coalesce((select jsonb_agg(jsonb_build_object(
    'depotName',d.depot_name,'codeCampaign',ca.campaign_code,'campaign',ca.campaign_name,
    'reward',c.cb_net,'kodeToko',cu.customer_code))
   from public.claims c
   join public.depots d on d.id=c.depot_id
   join public.customers cu on cu.id=c.customer_id
   join public.campaigns ca on ca.id=c.campaign_id),'[]'::jsonb));
end $$;
revoke all on function public.rc_legacy_dashboard() from public,anon;
grant execute on function public.rc_legacy_dashboard() to authenticated;

-- Activity log. Default window is 30 days, matching the target design note in section 10.6.
create or replace function public.rc_legacy_logs(p_days integer default 30) returns jsonb
language plpgsql stable security invoker set search_path='' as $$
begin
 if not rc_private.can_access(null) then raise exception 'Access denied' using errcode='42501'; end if;
 return jsonb_build_object('status','success','logs',coalesce((
  select jsonb_agg(jsonb_build_object(
   'timestamp',to_char(l.created_at at time zone 'Asia/Jakarta','DD/MM/YYYY HH24:MI:SS'),
   'userId',coalesce(p.user_code,''),'role',coalesce(p.role,''),
   'detail',coalesce(l.details->>'detail',l.event_type)) order by l.id desc)
  from (select * from public.activity_logs
        where created_at>=now()-make_interval(days=>least(greatest(coalesce(p_days,30),1),365))
        order by id desc limit 2000) l
  left join public.profiles p on p.id=l.actor_id),'[]'::jsonb));
end $$;
revoke all on function public.rc_legacy_logs(integer) from public,anon;
grant execute on function public.rc_legacy_logs(integer) to authenticated;

-- Client-side logActivity() posted the actor from the browser. Take it from the session.
create or replace function rc_private.log_activity(p_detail text) returns void
language plpgsql security definer set search_path='' as $$
declare home uuid;
begin
 if not rc_private.can_access(null) then raise exception 'Access denied' using errcode='42501'; end if;
 if p_detail is null or btrim(p_detail)='' or length(p_detail)>1000 then raise exception 'Invalid detail'; end if;
 select depot_id into home from public.user_depot_access where user_id=(select auth.uid()) limit 1;
 insert into public.activity_logs(actor_id,depot_id,event_type,details)
 values((select auth.uid()),home,'client_action',jsonb_build_object('detail',btrim(p_detail)));
end $$;
create or replace function public.rc_log_activity(p_detail text) returns void
language sql security invoker set search_path='' as $$select rc_private.log_activity(p_detail);$$;
revoke all on function rc_private.log_activity(text),public.rc_log_activity(text) from public,anon;
grant execute on function rc_private.log_activity(text),public.rc_log_activity(text) to authenticated;

create or replace function rc_private.legacy_users() returns jsonb
language sql stable security definer set search_path='' as $$
 select coalesce(jsonb_agg(jsonb_build_object(
   'id',p.id,'userId',p.user_code,'nama',p.full_name,'email',p.business_email,
   'role',p.role,'sysRole',p.role,'suffix',p.suffix_num,
   'activation',case when p.status='active' then 'Active' else 'Nonactive' end,
   'mustChangePin',p.must_change_password,
   'permissions',array(select permission_code from public.user_permissions where user_id=p.id),
   'depotCodes',array(select d.depot_code from public.user_depot_access a
     join public.depots d on d.id=a.depot_id where a.user_id=p.id),
   'depotIds',array(select depot_id from public.user_depot_access where user_id=p.id),
   'depotName',coalesce((select d.depot_name from public.user_depot_access a
     join public.depots d on d.id=a.depot_id where a.user_id=p.id order by d.depot_code limit 1),''))
   order by p.user_code),'[]'::jsonb)
 from public.profiles p;
$$;
create or replace function rc_private.legacy_all_depots() returns jsonb
language sql stable security definer set search_path='' as $$
 select coalesce(jsonb_agg(jsonb_build_object('id',id,'kode',depot_code,'nama',depot_name,
  'link',coalesce(master_link,'')) order by depot_code),'[]'::jsonb) from public.depots;
$$;
create or replace function rc_private.legacy_profile_requests() returns jsonb
language sql stable security definer set search_path='' as $$
 select coalesce(jsonb_agg(jsonb_build_object(
   'id',r.id,'namaDepot',d.depot_name,'kodeDepot',d.depot_code,
   'requesterId',coalesce(p.user_code,''),'changes',r.changes,
   'tglRequest',to_char(r.created_at at time zone 'Asia/Jakarta','DD/MM/YYYY HH24:MI'))
   order by r.created_at desc),'[]'::jsonb)
 from public.profile_change_requests r
 join public.depots d on d.id=r.depot_id
 left join public.profiles p on p.id=r.requester_id
 where r.status='pending';
$$;
revoke all on function rc_private.legacy_users(),rc_private.legacy_all_depots(),
 rc_private.legacy_profile_requests() from public,anon;
grant execute on function rc_private.legacy_users(),rc_private.legacy_all_depots(),
 rc_private.legacy_profile_requests() to authenticated;

-- Kelola Akses screen. Manager only; reuses the tested rc_private.is_manager() gate.
create or replace function public.rc_legacy_manageable() returns jsonb
language plpgsql stable security invoker set search_path='' as $$
begin
 if not rc_private.is_manager() then raise exception 'Manager required' using errcode='42501'; end if;
 return jsonb_build_object('status','success',
  'users',rc_private.legacy_users(),
  'allDepots',rc_private.legacy_all_depots(),
  'managedDepots',rc_private.legacy_all_depots(),
  'profileRequests',rc_private.legacy_profile_requests());
end $$;
revoke all on function public.rc_legacy_manageable() from public,anon;
grant execute on function public.rc_legacy_manageable() to authenticated;


-- Depot code -> id, so the profile-change screen can keep sending the code it displays.
create or replace function public.rc_legacy_depot_id(p_depot_code text) returns uuid
language plpgsql stable security invoker set search_path='' as $$
declare v uuid;
begin
 select id into v from public.depots where depot_code=btrim(p_depot_code);
 if v is null then raise exception 'Depot not found or outside scope' using errcode='42501'; end if;
 return v;
end $$;
revoke all on function public.rc_legacy_depot_id(text) from public,anon;
grant execute on function public.rc_legacy_depot_id(text) to authenticated;

-- Otorisasi Matrix screen. It posts the legacy letter flags plus a comma separated list of
-- depot codes, and identifies the target by user code. Translate here, then delegate to the
-- already tested rc_private.manage_user(), which keeps the manager and self-edit checks.
create or replace function public.rc_legacy_update_access(p_user_code text,p_auth jsonb,p_depot_codes text default null)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare target uuid; perms text[]; depot_ids uuid[]; new_status text; code text;
begin
 if not rc_private.is_manager() then raise exception 'Manager required' using errcode='42501'; end if;
 if p_auth is null or jsonb_typeof(p_auth)<>'object' then raise exception 'Invalid authorization payload'; end if;
 select id into target from public.profiles where user_code=btrim(coalesce(p_user_code,''));
 if target is null then raise exception 'User not found'; end if;

 new_status:=case when lower(coalesce(p_auth->>'i','')) in('active','approved','ok') then 'active' else 'inactive' end;

 perms:=array(select code from (values
  ('j','upload_claim'),('k','release_claim'),('l','process_claim'),('m','view_analytics'),
  ('n','manage_access'),('p','view_master_depot'),('s','bulk_process')
 ) as m(letter,code) where lower(coalesce(p_auth->>m.letter,'no')) in('yes','true','approved','visible'));

 if p_depot_codes is null or btrim(p_depot_codes)='' then
  depot_ids:=array(select depot_id from public.user_depot_access where user_id=target);
 else
  depot_ids:='{}'::uuid[];
  foreach code in array string_to_array(p_depot_codes,',') loop
   if btrim(code)<>'' then depot_ids:=depot_ids||public.rc_legacy_depot_id(btrim(code)); end if;
  end loop;
 end if;

 perform rc_private.manage_user(target,new_status,perms,depot_ids);
 return jsonb_build_object('status','success');
end $$;
revoke all on function public.rc_legacy_update_access(text,jsonb,text) from public,anon;
grant execute on function public.rc_legacy_update_access(text,jsonb,text) to authenticated;
