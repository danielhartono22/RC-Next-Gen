begin;
set local role service_role;
do $$
declare a jsonb; b jsonb;
begin
 a := public.rc_import_snapshot('rc-test-rollback','Compile','2026-09-15T00:00:00Z','["No Document","Amount"]','[["0001","1250"]]');
 b := public.rc_import_snapshot('rc-test-rollback','Compile','2026-09-15T00:00:00Z','["No Document","Amount"]','[["0001","1250"]]');
 if a->>'id' <> b->>'id' or b->>'replayed' <> 'true' then raise exception 'Replay failed'; end if;
 begin
 perform public.rc_import_snapshot('rc-test-rollback','Compile','2026-09-15T00:00:00Z','["No Document"]','[["different"]]');
 raise exception 'Expected conflict';
 exception when raise_exception then if sqlerrm <> 'Snapshot identity already exists with different content' then raise; end if;
 end;
 begin
 perform public.rc_import_snapshot('rc-test-rollback','Upload',now(),'["id"]','[["1"]]');
 raise exception 'Expected sheet rejection';
 exception when check_violation then null;
 end;
 begin
 perform public.rc_import_snapshot('rc-test-rollback','Compile',now(),'["id"]','[[1]]');
 raise exception 'Expected text rejection';
 exception when raise_exception then if sqlerrm <> 'All cells must be text' then raise; end if;
 end;
end $$;
reset role;
select
 not has_function_privilege('anon','public.rc_import_snapshot(text,text,timestamptz,jsonb,jsonb)','EXECUTE') as anon_denied,
 not has_function_privilege('authenticated','public.rc_import_snapshot(text,text,timestamptz,jsonb,jsonb)','EXECUTE') as authenticated_denied,
 not has_schema_privilege('anon','staging','USAGE') as staging_private,
 (select relrowsecurity from pg_class where oid='staging.rc_snapshots'::regclass) as rls_enabled,
 (select count(*)=1 from staging.rc_snapshots where source_name='rc-test-rollback') as replay_single_row;
rollback;
