// Shared by k6 and offline tests. No network calls or production defaults.
export const BLOCKED_REFS = ['vvojshgcduqlugngpzkj'];
export const LEVELS = {load:[100,250,500,750,1000], stress:[100,250,500,750,1000,1250,1500]};
export function validateTarget(c) {
  if (!c || c.environment !== 'isolated-test' || c.dummyOnly !== true) throw Error('Isolated dummy-only environment required');
  if (!/^[a-z]{20}$/.test(c.projectRef) || BLOCKED_REFS.includes(c.projectRef)) throw Error('Forbidden or invalid project reference');
  if (c.baseUrl !== `https://${c.projectRef}.supabase.co`) throw Error('Project URL mismatch');
  if (!/^https:\/\/[a-z0-9.-]+\/?$/.test(c.frontendUrl || '') || !c.frontendVerified) throw Error('Verified staging frontend required');
  if (!/^sb_publishable_[A-Za-z0-9_-]+$/.test(c.publishableKey||'')) throw Error('Use a publishable key, never a service-role JWT or secret');
  if (!c.datasetId || c.claimRows !== 1000000) throw Error('Verified 1,000,000 claim dataset required');
  if (!c.sideEffectsDisabled) throw Error('Disable email, cron and external integrations in staging');
  return c;
}
export function plan(mode, hold=300, ramp=60) {
  if (!Number.isInteger(hold)||hold<1||!Number.isInteger(ramp)||ramp<1) throw Error('Invalid durations');
  let elapsed=0, steps=[];
  function add(kind,users,seconds){steps.push({phase:`${kind}_${users}_${steps.length}`,kind,users,seconds,start:elapsed});elapsed+=seconds;}
  if(mode==='baseline'){add('warmup',1,60);add('hold',1,hold);}
  else if(LEVELS[mode]){add('warmup',1,60); for(const n of LEVELS[mode]){add('ramp',n,ramp);add('hold',n,hold);}add('ramp',100,60);add('recovery',100,300);add('ramp',1,30);add('recovery',1,180);}
  else if(mode==='spike'){add('warmup',100,60);add('hold',100,180);for(const n of [500,1000,500,100]){add('ramp',n,10);add(n===100?'recovery':'hold',n,180);}}
  else if(mode==='soak'){add('ramp',500,120);add('hold',500,7200);add('ramp',1000,120);add('hold',1000,7200);add('ramp',100,60);add('recovery',100,300);}
  else if(mode==='mixed'){add('ramp',1000,120);add('hold',1000,600);add('ramp',100,60);add('recovery',100,300);}
  else throw Error('Unknown mode');
  return steps;
}
export function phaseAt(steps,seconds){return steps.find(s=>seconds<s.start+s.seconds)||steps[steps.length-1];}
export function laneFor(vu){const n=(vu-1)%20;return n<2?'dashboard':n<6?'search':n<10?'report':n<14?'transaction':n<17?'update':'upload';}
export function outcome(status,errorCode,semantic=true){return {failed:status<200||status>=300||!semantic,timeout:errorCode===1050};}
export function thresholdsFromBaseline(b) {
  if(!b || !b.verified || !b.operations) throw Error('Validated staging baseline required');
  const out={};
  for(const [name,m] of Object.entries(b.operations)){
    if(m.samples<200 || !(m.p95>0) || !(m.p99>0)) throw Error('Insufficient baseline samples: '+name);
    out[name]={p95:m.p95*2,p99:m.p99*3};
  }
  return out;
}
