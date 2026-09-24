import {readFile,writeFile,mkdir} from 'node:fs/promises';
import sql from './lib-sql.mjs';
const candidate=process.argv.includes('--candidate');
const migration=candidate?(await Promise.all(['20261151010000_access_registration_sync.sql','20261151020000_registration_auth_metadata.sql','20261151030000_registration_request_lock.sql'].map(f=>readFile('supabase/migrations/'+f,'utf8')))).join('\n'):'';
const suite=await readFile('supabase/queries/test_access_registration.sql','utf8');
const rows=await sql(`begin; set local lock_timeout='5s'; set local statement_timeout='45s';\n${migration}\n${suite}\nrollback;`);
await mkdir('.runtime/access-audit',{recursive:true});
await writeFile(`.runtime/access-audit/test-${candidate?'candidate':'applied'}.json`,JSON.stringify({testedAt:new Date().toISOString(),rolledBack:true,rows},null,2));
console.log(`${rows.length} database assertions passed; all fixtures rolled back.`);
