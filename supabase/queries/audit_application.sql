-- Read-only aggregate audit: no identities, bank numbers, passwords or claim details.
with checks as (
 select 'D01' id,'claim_status_invalid' rule,count(*) n from public.claims where status not in('not_yet','submitted','approved','released','claimed','done','on_hold','expired')
 union all select 'D02','duplicate_no_doc',count(*) from (select upper(btrim(no_doc)) from public.claims group by 1 having count(*)>1) s
 union all select 'D03','pending_submit_not_not_yet',count(*) from public.claims where pending_approval->>'kind'='submit' and status<>'not_yet'
 union all select 'D04','pending_exception_already_applied',count(*) from public.claims where pending_approval->>'kind' in('hold','expire') and status=pending_approval->>'target_status'
 union all select 'D05','active_pending_missing_requester',count(*) from public.claims where pending_approval is not null and archived_at is null and nullif(pending_approval->>'requested_by','') is null
 union all select 'D06','cashback_nonpositive',count(*) from public.claims where cb_net<=0
 union all select 'D07','cashback_above_net_value_review',count(*) from public.claims where cb_net>net_value and net_value>0
 union all select 'D08','volume_equals_currency_review',count(*) from public.claims where volume=net_value and volume>0
 union all select 'D09','workflow_missing_uploaded_at',count(*) from public.claims where status in('released','claimed','done') and uploaded_at is null
 union all select 'D10','done_missing_cleared_at',count(*) from public.claims where status='done' and cleared_at is null
 union all select 'D11','done_missing_clearing_batch',count(*) from public.claims where status='done' and nullif(btrim(batch_clearing),'') is null
 union all select 'D12','claim_dates_reversed',count(*) from public.claims where period_end<period_start
 union all select 'D13','customer_no_depot',count(*) from public.customers c where c.archived_at is null and not exists(select 1 from public.customer_depots d where d.customer_id=c.id)
 union all select 'D14','customer_missing_tax_identity',count(*) from public.customers where archived_at is null and nullif(btrim(ktp),'') is null and nullif(btrim(npwp),'') is null
 union all select 'D15','customer_double_tax_identity',count(*) from public.customers where archived_at is null and nullif(btrim(ktp),'') is not null and nullif(btrim(npwp),'') is not null
 union all select 'D16','open_transfer_missing_bank',count(*) from public.claims c join public.customers cu on cu.id=c.customer_id join public.campaigns ca on ca.id=c.campaign_id where c.status='not_yet' and c.pending_approval is null and c.archived_at is null and rc_private.jenis_efektif(ca.cashback_type)='transfer' and (nullif(btrim(cu.bank),'') is null or nullif(btrim(cu.account_number),'') is null or nullif(btrim(cu.account_name),'') is null)
 union all select 'D17','campaign_dates_reversed',count(*) from public.campaigns where archived_at is null and period_end<period_start
 union all select 'D18','campaign_missing_period',count(*) from public.campaigns where archived_at is null and (period_start is null or period_end is null)
 union all select 'D19','campaign_missing_tax_status',count(*) from public.campaigns where archived_at is null and nullif(btrim(tax_status),'') is null
 union all select 'D20','active_account_without_auth',count(*) from public.profiles p where p.status='active' and not exists(select 1 from auth.users u where u.id=p.id)
 union all select 'D21','pending_account_has_permissions',count(*) from public.profiles p where p.status='pending' and exists(select 1 from public.user_permissions u where u.user_id=p.id)
 union all select 'D22','pending_account_has_effective_access',count(*) from public.profiles p where p.status='pending' and exists(select 1 from public.user_depot_access u where u.user_id=p.id)
 union all select 'D23','active_nonmanager_without_depot',count(*) from public.profiles p where p.status='active' and p.role<>'system manager' and not exists(select 1 from public.user_depot_access u where u.user_id=p.id)
 union all select 'D24','active_nonintrinsic_role_without_permissions',count(*) from public.profiles p where p.status='active' and p.role not in('system manager','depot head','management') and not exists(select 1 from public.user_permissions u where u.user_id=p.id)
 union all select 'D25','duplicate_active_suffix',count(*) from (select suffix_num from public.profiles where status='active' group by 1 having count(*)>1) s
 union all select 'D26','materialized_depot_access_drift',count(*) from public.profiles p where p.status='active' and p.role<>'system manager' and exists(
   (select d from rc_private.effective_depots(p.id) d except select depot_id from public.user_depot_access where user_id=p.id)
   union all (select depot_id from public.user_depot_access where user_id=p.id except select d from rc_private.effective_depots(p.id) d))
 union all select 'D27','invalid_supervision_role',count(*) from public.user_supervision s join public.profiles a on a.id=s.supervisor_id join public.profiles b on b.id=s.osc_id where a.role<>'supervisor' or b.role<>'osc'
 union all select 'D28','region_grant_nonmanagement',count(*) from public.user_region_access r join public.profiles p on p.id=r.user_id where p.role<>'management'
 union all select 'D29','login_id_case_mismatch_review',count(*) from public.profiles p join auth.users u on u.id=p.id where p.status='active' and u.email<>encode(extensions.digest(btrim(p.user_code),'sha256'),'hex')||'@rc-login.invalid'
 union all select 'D30','public_tables_rls_disabled',count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind='r' and not c.relrowsecurity
 union all select 'D31','unvalidated_foreign_keys',count(*) from pg_constraint k join pg_class c on c.oid=k.conrelid join pg_namespace n on n.oid=c.relnamespace where n.nspname in('public','rc_private') and k.contype='f' and not k.convalidated
 union all select 'D32','anonymous_core_table_write_grants',count(*) from information_schema.role_table_grants where grantee='anon' and table_schema='public' and table_name in('claims','profiles','customers','campaigns','user_permissions','user_depot_access') and privilege_type in('INSERT','UPDATE','DELETE')
 union all select 'D33','authenticated_direct_claim_write_grants',count(*) from information_schema.role_table_grants where grantee='authenticated' and table_schema='public' and table_name='claims' and privilege_type in('INSERT','UPDATE','DELETE')
 union all select 'D34','security_definer_without_fixed_search_path',count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in('public','rc_private') and p.prosecdef and not exists(select 1 from unnest(p.proconfig) s where s like 'search_path=%')
 union all select 'D35','email_queue_pending_over_one_day',count(*) from public.email_outbox where status='pending' and dibuat_pada<now()-interval '1 day'
 union all select 'D36','email_queue_failed',count(*) from public.email_outbox where status in('failed','error','gagal')
)
select id,rule,n as affected from checks order by id;
