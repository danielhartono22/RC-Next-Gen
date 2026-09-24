import {readFile,writeFile,mkdir} from 'node:fs/promises';
import sql from './lib-sql.mjs';
const result=await sql('begin read only; set local statement_timeout=\'30s\';\n'+await readFile('supabase/queries/audit_application.sql','utf8')+'\nrollback;');
await mkdir('docs/audit',{recursive:true});
await writeFile('docs/audit/application-2026-09-22.json',JSON.stringify({checkedAt:new Date().toISOString(),project:'vvojshgcduqlugngpzkj',mode:'read-only aggregate',checks:result},null,2));
console.log(JSON.stringify(result.filter(x=>Number(x.affected)>0),null,2));
console.log(`${result.length} rules checked.`);
