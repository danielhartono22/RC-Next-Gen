import {readFile,writeFile} from 'node:fs/promises';
import {thresholdsFromBaseline} from './plan.mjs';
const [source,dest]=process.argv.slice(2);
if(!source||!dest)throw Error('Usage: node make-budgets.mjs reviewed-baseline-report.json budgets.json');
const data=JSON.parse(await readFile(source,'utf8'));
if(data.mode!=='baseline')throw Error('Use baseline report only');
const operations={};
for(const r of data.rows){
 if(r.operation==='ALL'||r.kind!=='hold')continue;
 if(r.status!=='MEASURED_REQUIRES_REVIEW'||r.error_rate>=.01||r.timeout_rate>=.001)throw Error('Baseline is incomplete or unhealthy');
 operations[r.operation]={samples:r.samples,p95:r.p95_ms,p99:r.p99_ms};
}
if(Object.keys(operations).length===0)throw Error('No measured baseline operations');
await writeFile(dest,JSON.stringify(thresholdsFromBaseline({verified:true,operations}),null,2));
console.log('Wrote relative budgets (P95=2x, P99=3x). Review against environment and business SLO before acceptance.');
