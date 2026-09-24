// Deploy only the reviewed rc-admin function; tokens are never printed.
// API contract: https://supabase.com/docs/reference/api/v1-deploy-a-function
import {readFile,writeFile,mkdir} from 'node:fs/promises';
const ref='vvojshgcduqlugngpzkj';
const env=await readFile('.env','utf8');
const token=process.env.SUPABASE_ACCESS_TOKEN||env.match(/^\s*SUPABASE_ACCESS_TOKEN\s*=\s*(.+?)\s*$/m)?.[1].replace(/^["']|["']$/g,'');
if(!token)throw Error('Supabase access token missing');
const form=new FormData();
form.append('metadata',JSON.stringify({name:'rc-admin',entrypoint_path:'index.ts',verify_jwt:true}));
for(const file of ['index.ts','handler.mjs'])form.append('file',new Blob([await readFile('supabase/functions/rc-admin/'+file)]),file);
const bundle=process.argv.includes('--bundle-only');
const res=await fetch(`https://api.supabase.com/v1/projects/${ref}/functions/deploy?slug=rc-admin${bundle?'&bundleOnly=1':''}`,{method:'POST',headers:{Authorization:`Bearer ${token}`},body:form});
const data=await res.json();
if(!res.ok)throw Error(`Edge deploy ${res.status}: ${JSON.stringify(data).slice(0,500)}`);
const evidence={checkedAt:new Date().toISOString(),bundleOnly:bundle,id:data.id,slug:data.slug,status:data.status,version:data.version,verify_jwt:data.verify_jwt,sha256:data.ezbr_sha256};
await mkdir('.runtime/access-audit',{recursive:true});
await writeFile(`.runtime/access-audit/edge-${bundle?'bundle':'deployed'}.json`,JSON.stringify(evidence,null,2));
console.log(JSON.stringify(evidence));
