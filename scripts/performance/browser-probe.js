// 1 real browser alongside protocol load; this is NOT 1000 browser sessions.
import {browser} from 'k6/browser';
import http from 'k6/http';
import {check} from 'k6';
import {Trend} from 'k6/metrics';
import {validateTarget} from './plan.mjs';
const c=validateTarget(JSON.parse(open(__ENV.RC_TEST_CONFIG)));
const u=JSON.parse(open(__ENV.RC_BROWSER_USER));
if(!u.userCode?.startsWith('PERF_'))throw Error('Dummy browser user required');
const loginTime=new Trend('rc_browser_login_to_dashboard',true);
export const options={scenarios:{ui:{executor:'constant-vus',vus:1,duration:'5m',options:{browser:{type:'chromium'}}}},thresholds:{checks:['rate==1']}};
export function setup(){
 const r=http.post(c.baseUrl+'/rest/v1/rpc/rc_perf_environment','{}',{headers:{apikey:c.publishableKey,'Content-Type':'application/json'},timeout:'30s',redirects:0});
 let m;try{m=r.json();}catch{}
 if(r.status!==200||m?.project_ref!==c.projectRef||m?.dataset_id!==c.datasetId||m?.claim_rows!==1000000||!m?.dummy_only||!m?.side_effects_disabled)throw Error('Staging attestation failed');
 const env=http.get(c.frontendUrl+'/config/rc-env.js',{timeout:'15s',redirects:0});
 if(env.status!==200||!env.body.includes(c.baseUrl)||env.body.includes('vvojshgcduqlugngpzkj')||!env.body.includes("dataBackend: 'supabase'"))throw Error('Staging frontend configuration mismatch');
}
export default async function(){
 const page=await browser.newPage();
 try{
  await page.goto(c.frontendUrl,{waitUntil:'networkidle'});
  await page.locator('#userid').fill(u.userCode);await page.locator('#pin').fill(u.password);
  const start=Date.now();await page.locator('#btnLogin').click();
  await page.locator('#dashboardSection').waitFor({state:'visible',timeout:30000});
  loginTime.add(Date.now()-start);
  check(await page.locator('#dashboardSection').isVisible(),{'dashboard rendered after login':Boolean});
  await page.locator('#menuAnalytics').click();
  await page.locator('#historyTableBody tr').first().waitFor({state:'visible',timeout:30000});
  check(await page.locator('#histSearch').isVisible(),{'analytics search is usable':Boolean});
 }finally{await page.close();}
}
export function handleSummary(d){return {[(__ENV.RC_RESULT_PREFIX||'rc-browser')+'-summary.json']:JSON.stringify(d,null,2)};}
