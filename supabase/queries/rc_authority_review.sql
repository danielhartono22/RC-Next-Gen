-- Operator only. No PIN/password columns are stored in this table.
-- Resolve these email groups before creating individual Supabase Auth users.
select email, count(*) as user_count,
       array_agg(user_code order by user_code) as user_codes
from staging.rc_authority_review
group by email having count(*) > 1
order by user_count desc;

select user_code, full_name, email, legacy_role, legacy_status,
       depot_code, suffix_num, permissions
from staging.rc_authority_review order by source_row;

select count(*) as candidates,
       count(gross_up_text) as gross_up_available
from public.rc_claims_migration_candidates;
