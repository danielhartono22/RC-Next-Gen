import {readFile,mkdir,writeFile,appendFile} from 'node:fs/promises';
import {spawn,execFile} from 'node:child_process';
import {promisify} from 'node:util';
import os from 'node:os';
import path from 'node:path';
import {validateTarget,plan} from './plan.mjs';
const command=promisify(execFile);
const args=process.argv.slice(2),mode=args[0]||'baseline';
if(!['baseline','load','stress','mixed','spike','soak','integrity'].includes(mode))throw Error('Unknown test mode');
if(!process.env.RC_TEST_CONFIG)throw Error('RC_TEST_CONFIG must point to reviewed isolated-staging config');
const config=validateTarget(JSON.parse(await readFile(process.env.RC_TEST_CONFIG,'utf8')));
const root=path.resolve('.runtime/performance/runs',new Date().toISOString().replace(/[:.]/g,'-')+'-'+mode);
await mkdir(root,{recursive:true});
const prefix=path.join(root,'result');
const script=mode==='integrity'?'integrity.js':'rc-scale.js';
const k6=process.env.K6_BIN||path.resolve('.runtime/performance/tools/k6-v2.2.0-windows-amd64/k6.exe');
const facts={started_at:new Date().toISOString(),mode,project_ref:config.projectRef,dataset_id:config.datasetId,
 claim_rows:config.claimRows,requested_steps:mode==='integrity'?[]:plan(mode,Number(process.env.RC_HOLD_SECONDS||300)),
 cpu:os.cpus()[0]?.model,logical_cpus:os.cpus().length,total_memory_bytes:os.totalmem(),platform:os.platform(),node:process.version,
 generator_location:process.env.RC_GENERATOR_LOCATION||'NOT_RECORDED',network_capacity:'NOT_MEASURED'};
await writeFile(path.join(root,'environment.json'),JSON.stringify(facts,null,2));
const child=spawn(k6,['run','--out','json='+path.join(root,'raw.json'),path.resolve('scripts/performance',script)],{
 stdio:['ignore','pipe','pipe'],env:{...process.env,RC_MODE:mode,RC_RESULT_PREFIX:prefix,K6_NO_USAGE_REPORT:'true'},windowsHide:true});
for(const [stream,file] of [[child.stdout,'stdout.log'],[child.stderr,'stderr.log']])stream.on('data',b=>{process.stdout.write(b);appendFile(path.join(root,file),b).catch(()=>{});});
let previousCpu=null,previousTime=null;
async function sample(){
 const row={at:new Date().toISOString(),free_memory_bytes:os.freemem(),generator_pid:child.pid};
 if(os.platform()==='win32'&&child.pid){try{
  const r=await command('powershell',['-NoProfile','-Command',`Get-Process -Id ${Number(child.pid)} | Select-Object CPU,WorkingSet64,Threads | ForEach-Object { [pscustomobject]@{cpu_seconds=$_.CPU;working_set_bytes=$_.WorkingSet64;threads=$_.Threads.Count} } | ConvertTo-Json -Compress`],{windowsHide:true,timeout:4000});
  Object.assign(row,JSON.parse(r.stdout));const now=Date.now();
  row.cpu_percent_machine=previousCpu===null?null:(row.cpu_seconds-previousCpu)/((now-previousTime)/1000)/os.cpus().length*100;
  previousCpu=row.cpu_seconds;previousTime=now;
 }catch{row.process_metrics='UNAVAILABLE';}}
 await appendFile(path.join(root,'generator.jsonl'),JSON.stringify(row)+'\n');
}
let sampling=false;const timer=setInterval(()=>{if(!sampling){sampling=true;sample().finally(()=>sampling=false);}},5000);
child.on('error',async e=>{clearInterval(timer);await writeFile(path.join(root,'execution.json'),JSON.stringify({status:'NOT_STARTED',error:e.code}));process.exitCode=1;});
child.on('exit',async(code,signal)=>{clearInterval(timer);await writeFile(path.join(root,'execution.json'),JSON.stringify({exit_code:code,signal,finished_at:new Date().toISOString()}));console.log('\nEvidence directory: '+root);process.exitCode=code??1;});
