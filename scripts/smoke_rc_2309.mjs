// Read-only functional RPC checks; not HTTP, browser, or concurrency benchmarks.
import {writeFile,mkdir} from 'node:fs/promises';
import sql from './lib-sql.mjs';
const calls=[
 ['bootstrap','rc_legacy_bootstrap()'],
 ['workflow','rc_legacy_workflow()'],
 ['analytics','rc_legacy_dashboard()'],
 ['permissions','rc_permission_catalog()'],
 ['customers',"rc_customer_list('',0,5)"],
 ['open',"rc_open_claims_filtered('','',0,5,'')"],
 ['peopleOSC',"rc_people_performance('osc','')"],
 ['peopleSupervisor',"rc_people_performance('supervisor','')"],
 ['peopleHistory',"rc_people_history(current_setting('qa.people_role'),current_setting('qa.people_user'),current_date-2,current_date,'day')"],
 ['timetable',"rc_timetable_matrix('{}')"],
 ['profile',"rc_depot_profile(current_setting('qa.depot'))"],
 ['logs','rc_legacy_logs(1)'],
 ['campaign',"rc_campaign_list('',0,5)"],
 ['compilation',"rc_compilation_list('','','','',0,5)"],
 ['reprocessing',"rc_reprocessing_list('',0,5)"],
 ['archive','rc_archived_list(0,5)'],
 ['approvalWPT',"rc_approval_batches('wpt',null)"],
 ['approvalOverdue',"rc_approval_batches('ovd',null)"],
 ['approvalHold','rc_approval_hold(null,null)'],
 ['manageable','rc_legacy_manageable()']
];
const query=[
 "begin read only; set local timezone='Asia/Jakarta'; set local statement_timeout='30s';",
 "select set_config('request.jwt.claims',jsonb_build_object('sub',(select id from public.profiles where role='system manager' and status='active' and not must_change_password limit 1),'role','authenticated')::text,true);",
 "select set_config('qa.people_user',user_code,true),set_config('qa.people_role',role,true) from public.profiles where role in ('osc','supervisor') and status='active' order by role,user_code limit 1;",
 "select set_config('qa.depot',(select depot_code from public.depots order by depot_code limit 1),true);",
 'set local role authenticated;',
 'with checks(name,response) as (values '+calls.map(([name,expr])=>"('"+name+"',public."+expr+")").join(',')+')',
 "select name,case when response is not null and jsonb_typeof(response) in ('object','array') and coalesce(response->>'status','success') not in ('error','failed') then 'PASS' else 'FAIL' end as status from checks;",
 'rollback;'
].join('\n');
const started=Date.now();
const rows=await sql(query);
const evidence={testedAt:new Date().toISOString(),readOnly:true,method:'SQL functions under authenticated role; not HTTP end-to-end',durationMs:Date.now()-started,rows};
await mkdir('.runtime/rc-2309',{recursive:true});
await writeFile('.runtime/rc-2309/smoke-applied.json',JSON.stringify(evidence,null,2));
console.log(JSON.stringify(evidence,null,2));
if(rows.length!==calls.length||rows.some(row=>row.status!=='PASS'))process.exitCode=1;
