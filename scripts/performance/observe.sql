-- Read-only observability snapshots, every 5-10 seconds on ISOLATED STAGING.
-- Save before/during/after and compute deltas; don't reset shared statistics.
select now() as captured_at,current_setting('server_version') as postgres_version,
 current_setting('max_connections') as max_connections,current_setting('shared_buffers') as shared_buffers,
 current_setting('work_mem') as work_mem,current_setting('statement_timeout') as statement_timeout,
 pg_database_size(current_database()) as database_bytes;
select now() as captured_at,state,wait_event_type,wait_event,count(*) as connections,
 max(extract(epoch from now()-query_start)) as longest_query_seconds
from pg_stat_activity where datname=current_database() group by state,wait_event_type,wait_event;
select now() as captured_at,datname,numbackends,xact_commit,xact_rollback,blks_read,blks_hit,
 temp_files,temp_bytes,deadlocks,conflicts,blk_read_time,blk_write_time
from pg_stat_database where datname=current_database();
select now() as captured_at,schemaname,relname,seq_scan,seq_tup_read,idx_scan,idx_tup_fetch,
 n_tup_ins,n_tup_upd,n_tup_del,n_dead_tup,last_autovacuum,last_autoanalyze
from pg_stat_user_tables where schemaname in('public','rc_private');
-- Query IDs only: no query text or bind values in telemetry.
select now() as captured_at,queryid,calls,total_exec_time,mean_exec_time,max_exec_time,rows,
 shared_blks_hit,shared_blks_read,temp_blks_read,temp_blks_written
from extensions.pg_stat_statements order by total_exec_time desc limit 30;
select now() as captured_at,pid,cardinality(pg_blocking_pids(pid)) as blocking_connections
from pg_stat_activity where cardinality(pg_blocking_pids(pid))>0;
