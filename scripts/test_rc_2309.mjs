// Candidate schema and all dummy fixtures execute in one rollback transaction.
import {readFile,readdir,writeFile,mkdir} from 'node:fs/promises';
import sql from './lib-sql.mjs';
const candidate=!process.argv.includes('--applied');
const names=(await readdir('supabase/migrations')).filter(n=>n.startsWith('20261152')).sort();
const migrations=candidate?(await Promise.all(names.map(n=>readFile('supabase/migrations/'+n,'utf8')))).join('\n'):'';
const suite=await readFile('supabase/queries/test_rc_2309.sql','utf8');
const started=Date.now();
try{
 const result=await sql(`begin; set local timezone='Asia/Jakarta'; set local lock_timeout='5s'; set local statement_timeout='90s';\n${migrations}\n${suite}\nrollback;`);
 await mkdir('.runtime/rc-2309',{recursive:true});
 await writeFile(`.runtime/rc-2309/test-${candidate?'candidate':'applied'}.json`,JSON.stringify({testedAt:new Date().toISOString(),candidate,rolledBack:true,durationMs:Date.now()-started,result},null,2));
 console.log(JSON.stringify(result,null,2));
}catch(e){console.error(e.message);process.exitCode=1;}
