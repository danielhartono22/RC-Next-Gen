// Remote integration test. Every schema/data mutation and dummy fixture is rolled back.
// --candidate includes the migration in the same rollback transaction (before deployment).
import {readFile,writeFile,mkdir} from 'node:fs/promises';
import sql from './lib-sql.mjs';
const candidate=process.argv.includes('--candidate');
const migration=candidate ? await readFile('supabase/migrations/20261150010000_pending_approval_status.sql','utf8') : '';
const suite=await readFile('supabase/queries/test_pending_approval.sql','utf8');
const result=await sql(`begin; set local lock_timeout='5s'; set local statement_timeout='45s';\n${migration}\n${suite}\nrollback;`);
await mkdir('.runtime/approval-fix',{recursive:true});
await writeFile(`.runtime/approval-fix/test-${candidate?'candidate':'applied'}.json`,JSON.stringify({testedAt:new Date().toISOString(),candidate,rolledBack:true,result},null,2));
console.log(JSON.stringify(result,null,2));
