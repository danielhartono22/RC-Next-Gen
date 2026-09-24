-- Read-only: locate disposable fixtures from the interrupted HTTP test.
select p.user_code,p.created_at,p.must_change_password,
       c.no_doc,c.status,c.version_no
from public.profiles p
left join public.claims c on c.no_doc=p.user_code
where p.user_code ~ '^__rc_e2e_[0-9]{13}$'
and p.full_name='Synthetic E2E' and p.business_email='test@example.invalid'
order by p.created_at;
