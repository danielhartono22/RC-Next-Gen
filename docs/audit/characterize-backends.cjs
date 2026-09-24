// Offline characterization of supplied legacy code, not desired behavior tests.
// Run: node docs/audit/characterize-backends.cjs
// Only synthetic data and in-memory Apps Script substitutes are exposed to code.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const crypto = require('node:crypto');
const assert = require('node:assert/strict');
const root = path.resolve(__dirname, '../..');
const names = ['ResourceCollection', 'DocumentCenter', 'index (4).html', 'index (5).html'];
const originals = Object.fromEntries(names.map(name => [name, fs.readFileSync(path.join(root, name), 'utf8')]));
const hashes = Object.fromEntries(names.map(name => [name, crypto.createHash('sha256').update(fs.readFileSync(path.join(root, name))).digest('hex')]));
// Never use the embedded legacy secret for test tokens, or print source/errors.
const rcSource = originals.ResourceCollection.replace(/const SECRET_KEY\s*=\s*[^;]+;/, 'const SECRET_KEY = "synthetic-audit-key-not-a-credential";');
assert.notEqual(rcSource, originals.ResourceCollection, 'Expected secret replacement before execution');
const clone = x => JSON.parse(JSON.stringify(x));
const row = (fields, width = 42) => Object.assign(Array(width).fill(''), fields);
const header = width => Array.from({length: width}, (_, i) => `SYNTHETIC_${i}`);
const records = [];

function environment(kind, initial = {}, opts = {}) {
  const writes = [], reads = [], cacheValues = new Map();
  let held = false, flushes = 0;
  const lock = {waitLock() { held = true; }, hasLock() { return held; }, releaseLock() { held = false; }};
  const cache = {
    get: key => cacheValues.get(key) ?? null,
    put: (key, value) => cacheValues.set(key, value),
    remove: key => cacheValues.delete(key),
    getAll: keys => Object.fromEntries(keys.filter(k => cacheValues.has(k)).map(k => [k, cacheValues.get(k)])),
    putAll: values => Object.entries(values).forEach(([k,v]) => cacheValues.set(k,v))
  };
  class Sheet {
    constructor(name, data) { this.name = name; this.data = clone(data); }
    getLastRow() { return this.data.length; }
    getLastColumn() { return Math.max(1, ...this.data.map(r => r.length)); }
    getMaxRows() { return Math.max(1000, this.data.length); }
    getDataRange() { return this.getRange(1, 1, this.getLastRow(), this.getLastColumn()); }
    appendRow(values) { this.getRange(this.data.length + 1, 1, 1, values.length).setValues([values]); }
    getRange(r, c, height = 1, width = 1) {
      const sheet = this;
      return {
        getValues() {
          reads.push({sheet: sheet.name, r, c, height, width});
          return Array.from({length: height}, (_, i) => Array.from({length: width}, (_, j) => sheet.data[r+i-1]?.[c+j-1] ?? ''));
        },
        getValue() { return this.getValues()[0][0]; },
        setValues(values) {
          assert.equal(values.length, height);
          values.forEach(v => assert.equal(v.length, width));
          if (opts.failWrite?.({sheet: sheet.name, r, c, height, width})) throw new Error('synthetic write failure');
          writes.push({sheet: sheet.name, r, c, height, width, lockHeld: held});
          values.forEach((v,i) => {
            sheet.data[r+i-1] ??= [];
            v.forEach((value,j) => { sheet.data[r+i-1][c+j-1] = value; });
          });
          return this;
        },
        setValue(value) { return this.setValues([[value]]); },
        setNumberFormat() { return this; },
        getNextDataCell() {
          // Model only the fixture case: last physical row is empty, no merged cells.
          let last = 0;
          for (let i = 0; i < sheet.data.length; i++) if (sheet.data[i][c-1] !== '' && sheet.data[i][c-1] != null) last = i+1;
          return {getRow: () => last || 1, getValue: () => last ? sheet.data[last-1][c-1] : ''};
        }
      };
    }
  }
  const sheets = Object.fromEntries(Object.entries(initial).map(([name, data]) => [name, new Sheet(name, data)]));
  const ss = {getSheetByName: name => sheets[name] ?? null, insertSheet: name => sheets[name] = new Sheet(name, [])};
  const utilities = {
    formatDate(_date, _zone, format) { return format === 'ddMMyy' ? '140926' : '14-Sep-2026 10:00:00'; },
    base64EncodeWebSafe: data => Buffer.from(data).toString('base64url'),
    base64DecodeWebSafe: data => [...Buffer.from(data, 'base64url')],
    newBlob: data => ({getDataAsString: () => Buffer.from(data).toString('utf8')}),
    computeHmacSha256Signature: (data, key) => [...crypto.createHmac('sha256', key).update(data).digest()]
  };
  const context = vm.createContext({
    ContentService: {MimeType: {JSON: 'json'}, createTextOutput: value => ({value, setMimeType() { return this; }})},
    SpreadsheetApp: {openById: () => ss, Direction: {UP: 'UP'}, flush: () => { flushes++; }},
    CacheService: {getScriptCache: () => cache}, LockService: {getScriptLock: () => lock},
    Utilities: utilities, Session: {getScriptTimeZone: () => 'Asia/Jakarta'},
    Logger: {log() {}}, console: {error() {}, log() {}}
  }, {codeGeneration: {strings: false, wasm: false}});
  new vm.Script(kind === 'RC' ? rcSource : originals.DocumentCenter, {filename: `${kind}-audit-source`}).runInContext(context, {timeout: 1000});
  const call = (fn, ...args) => {
    context.__args = args;
    return vm.runInContext(`${fn}(...__args)`, context, {timeout: 1000});
  };
  return {
    call, sheets, ss, writes, reads, cacheValues, utilities,
    get flushes() { return flushes; },
    token: () => call('generateToken', 'USER_A', 'admin', '111'),
    post: payload => JSON.parse(call('doPost', {postData: {contents: JSON.stringify(payload)}}).value)
  };
}

function fixture() {
  return {
    Authority: [header(19), row({1:'SYNTHETIC USER',2:'A',4:'USER_A',5:'synthetic-pin',7:'admin',8:'active',17:'111'},19)],
    DepoMaster: [header(24), row({1:'A',2:'DEPOT_A',7:'USER_A'},24), row({1:'B',2:'DEPOT_B',7:'USER_B'},24)],
    Compile: [header(42), row({1:'DOC_B',2:'CAMP',4:'B',5:'DEPOT_B',6:'CUST_B',10:85000,13:'Regular',26:'Submitted'})],
    ListCampaign: [header(23), row({0:'CAMP',1:'CAMPAIGN',6:'Regular'},23)],
    ListCust: [header(11), row({1:'CUST_B',3:'SYNTHETIC_ACCOUNT_B',7:'SYNTHETIC_ID_B',8:'Badan'},11)],
    LogActivity: [header(4), ['2026-09-14','USER_B','admin','SYNTHETIC_EVENT']],
    ReqProfile: [header(7)], BatchLog: [header(3)],
    Depot_ID: [header(2), ['A','DEPOT_A'], ['B','DEPOT_B']],
    Upload: [header(21), Array(21).fill('')],
    'DM-30D': [header(34), row({1:'DOC_B',4:'B',14:'SYNTHETIC_ID_B',31:'BATCH_B'},34)]
  };
}
const upload = overrides => ({kodeCampaign:'CAMP',dc:'B',custCode:'CUST_B',custName:'SYNTHETIC CUSTOMER',netValue:100,total:85,jenisCb:'Regular',beforeTaxVal:100,namaCampaign:'CAMPAIGN',...overrides});
function test(id, description, evidence, fn) {
  try { fn(); records.push({id,description,evidence,result:'PASS'}); }
  catch { records.push({id,description,evidence,result:'FAIL'}); }
}

test('B01','Both complete backend files compile as JavaScript','RCB:1-1558; DCB:1-502',() => {
  new vm.Script(rcSource); new vm.Script(originals.DocumentCenter);
});
test('B02','RC private route rejects absent and tampered tokens','RCB:450-469',() => {
  const e=environment('RC',fixture());
  assert.equal(e.post({action:'refreshDocuments'}).status,'error');
  assert.equal(e.post({action:'refreshDocuments',token:e.token()+'x'}).status,'error');
});
test('B03','RC login returns foreign-depot documents and synthetic sensitive customer fields','RCB:524-652',() => {
  const e=environment('RC',fixture()); const r=e.post({action:'login',userid:'USER_A',pin:'synthetic-pin'});
  assert.equal(r.status,'success'); assert.deepEqual(r.data.managedDepots,['A']);
  assert.equal(r.documents[0].dcCode,'B'); assert.equal(r.customers[0].noRek,'SYNTHETIC_ACCOUNT_B');
});
test('B04','RC admin can read all logs despite UI role restriction','RCB:513-521',() => {
  const e=environment('RC',fixture()); const r=e.post({action:'getLogActivity',token:e.token()});
  assert.equal(r.logs[0].userId,'USER_B');
});
test('B05','RC public activity route accepts caller-supplied actor','RCB:456-458,500-503',() => {
  const e=environment('RC',fixture()); assert.equal(e.post({action:'logActivity',userId:'SYNTHETIC_ACTOR',role:'system manager',detail:'fixture'}).status,'success');
  assert.equal(e.sheets.LogActivity.data.at(-1)[1],'SYNTHETIC_ACTOR');
});
test('B06','RC reads Released foreign-depot workflow row even without spoofed role/scope','RCB:797-859',() => {
  const f=fixture(); f.Compile[1][26]='Released'; const e=environment('RC',f);
  const r=e.post({action:'getWorkflowData',token:e.token(),requesterId:'USER_A',requesterRole:'admin',managedDepots:['A']});
  assert.equal(r.claimFinData[0].kodeDepot,'B');
});
test('B07','RC dashboard trusts a body role over signed admin role','RCB:1183-1239',() => {
  const e=environment('RC',fixture()); const token=e.token();
  assert.equal(e.post({action:'getDashboardData',token,requesterRole:'admin',managedDepots:['A']}).history.length,0);
  assert.equal(e.post({action:'getDashboardData',token,requesterRole:'system manager',managedDepots:[]}).history[0].kodeDepot,'B');
});
test('B08','RC signed admin can create a system-manager fixture account','RCB:1321-1382',() => {
  const e=environment('RC',fixture()); const r=e.post({action:'addAccount',token:e.token(),data:{userId:'NEW_FIXTURE',pin:'fixture-only',role:'system manager',nama:'SYNTHETIC'}});
  assert.equal(r.status,'success'); assert.equal(e.sheets.Authority.data.at(-1)[7],'system manager');
});
test('B09','RC signed admin can update another account permission flags','RCB:1385-1414',() => {
  const f=fixture(); f.Authority.push(row({4:'USER_B',7:'admin',8:'active',13:'Hidden'},19));
  const e=environment('RC',f); const r=e.post({action:'updateUserAccess',token:e.token(),data:{targetUserId:'USER_B',auth:{n:'Yes'}}});
  assert.equal(r.status,'success'); assert.equal(e.sheets.Authority.data[2][13],'Yes');
});
test('B10','Issued RC token remains accepted after account is disabled; logout route is absent','RCB:120-135,472-488',() => {
  const e=environment('RC',fixture()); const token=e.token(); e.sheets.Authority.data[1][8]='inactive';
  assert.equal(e.post({action:'refreshDocuments',token}).status,'success');
  assert.equal(e.post({action:'logout',token}).status,'error'); assert.ok(e.call('verifyToken',token));
});
test('B11','RC clearing approve skips Submitted regular claim directly to Done across depots','RCB:862-977',() => {
  const e=environment('RC',fixture()); const r=e.post({action:'processWorkflow',token:e.token(),docsToProcess:['DOC_B'],workflowType:'clearing',actionType:'approve'});
  assert.equal(r.summary.successCount,1); assert.equal(e.sheets.Compile.data[1][26],'Done');
});
test('B12','RC submit accepts Released and changes unrelated supplied customer master','RCB:655-795',() => {
  const f=fixture(); f.Compile[1][26]='Released'; f.ListCust.push(row({1:'OTHER_CUSTOMER',3:'OLD_SYNTHETIC'},11));
  const e=environment('RC',f); const r=e.post({action:'submitData',token:e.token(),data:{noDoc:'DOC_B',custCode:'OTHER_CUSTOMER',noRekening:'NEW_SYNTHETIC',subyekPajak:'Badan'}});
  assert.equal(r.summary.successCount,1); assert.equal(e.sheets.Compile.data[1][26],'Submitted');
  assert.equal(e.sheets.ListCust.data[2][3],'NEW_SYNTHETIC');
});
test('B13','RC Hold accepts Released, restores it, and also accepts legacy RA7','RCB:979-1050',() => {
  const f=fixture(); f.Compile[1][26]='Released'; const e=environment('RC',f); const token=e.token();
  e.post({action:'toggleOnHold',token,docsToProcess:['DOC_B'],holdAction:'hold'});
  assert.equal(e.sheets.Compile.data[1][35],'Released');
  e.post({action:'toggleOnHold',token,docsToProcess:['DOC_B'],holdAction:'unhold'});
  assert.equal(e.sheets.Compile.data[1][26],'Released');
  e.sheets.Compile.data[1][26]='RA7'; e.post({action:'toggleOnHold',token,docsToProcess:['DOC_B'],holdAction:'hold'});
  assert.equal(e.sheets.Compile.data[1][26],'On Hold');
});
test('B14','RC Expired rejects Done but changes RA07 to Expired','RCB:1053-1106',() => {
  const f=fixture(); f.Compile[1][26]='Done'; const e=environment('RC',f); const token=e.token();
  e.post({action:'markExpired',token,docsToProcess:['DOC_B']}); assert.equal(e.sheets.Compile.data[1][26],'Done');
  e.sheets.Compile.data[1][26]='RA07'; e.post({action:'markExpired',token,docsToProcess:['DOC_B']});
  assert.equal(e.sheets.Compile.data[1][26],'Expired');
});
test('B15','Backend gross-up is 100000 while frontend export is zero for NIPSEA net 85000 Badan','RCB:245-273; RCF:1737-1756',() => {
  const e=environment('RC',fixture());
  const match=originals['index (4).html'].match(/let calcGrossUp = ([\s\S]*?\n\s*};)/);
  assert.ok(match); const calc=vm.runInNewContext('('+match[1].trim().slice(0,-1)+')');
  assert.equal(e.call('calcGrossUpCB',85000,'Badan','NIPSEA'),100000); assert.equal(calc(85000,'Badan','NIPSEA'),0);
  for(const [net,gross] of [[57000000,60000000],[218500000,250000000],[406000000,500000000],[3556000000,5000000000]]) {
    assert.ok(Math.abs(e.call('calcGrossUpCB',net,'Perorangan','normal')-gross)<0.01);
  }
});
test('B16','Batch counter is shared across suffixes and wraps after 9999','RCB:278-325',() => {
  const e=environment('RC',fixture()); const first=e.call('generateSecureBatchNumber','01','111');
  assert.ok(first.endsWith('0001')); assert.ok(e.call('generateSecureBatchNumber','01','222').endsWith('0002'));
  e.cacheValues.set('batchCtr_01_140926','9999'); assert.ok(e.call('generateSecureBatchNumber','01','111').endsWith('0000'));
  assert.equal(e.call('generateSecureBatchNumber','01','111'),first);
});
test('B17','Nested batch generator releases shared lock before RC workflow writes in documented lock model','RCB:278-325,869-975',() => {
  const e=environment('RC',fixture()); e.post({action:'processWorkflow',token:e.token(),docsToProcess:['DOC_B'],workflowType:'release',actionType:'approve'});
  const changes=e.writes.filter(w=>w.sheet==='Compile'); assert.ok(changes.length>0); assert.ok(changes.every(w=>!w.lockHeld));
});
test('B18','Profile address update overwrites column also read as masterLink','RCB:575,1480-1517',() => {
  const f=fixture(); f.DepoMaster[1][12]='SYNTHETIC_MASTER_LINK';
  f.ReqProfile.push(['2026-09-14','admin','A','DEPOT_A','USER_A',JSON.stringify({alamat:'SYNTHETIC_ADDRESS'}),'PENDING']);
  const e=environment('RC',f); const r=e.post({action:'approveProfileRequest',token:e.token(),reqId:2,status:'APPROVED'});
  assert.equal(r.status,'success'); assert.equal(e.sheets.DepoMaster.data[1][12],'SYNTHETIC_ADDRESS');
});
test('B19','DC submit route writes without any login and stores caller actor','DCB:113-150,369-502',() => {
  const e=environment('DC',fixture()); const r=e.post({action:'submitCashback',username:'SYNTHETIC_ACTOR',data:[upload()]});
  assert.equal(r.success,true); assert.equal(e.sheets.Upload.data[2][20],'SYNTHETIC_ACTOR');
});
test('B20','DC login ignores inactive status; lookup returns foreign-depot synthetic identifier without session','DCB:165-233',() => {
  const f=fixture(); f.Authority[1][8]='inactive'; const e=environment('DC',f);
  assert.equal(e.post({action:'login',username:'USER_A',password:'synthetic-pin'}).success,true);
  const r=e.post({action:'lookupBatch',lookupType:'upload',batchNumbers:['BATCH_B']});
  assert.equal(r.success,true); assert.equal(r.data[0].O,'SYNTHETIC_ID_B');
});
test('B21','DC preview only labels unknown campaign and submit accepts it with negative amounts','DCB:257-263,419-445',() => {
  const e=environment('DC',fixture()); const data=[upload({kodeCampaign:'UNKNOWN',total:-1,netValue:-2})];
  const preview=e.post({action:'previewCashback',data}); assert.equal(preview.success,true);
  assert.equal(preview.data[0].namaCampaign,'CAMPAIGN TIDAK DITEMUKAN');
  assert.equal(e.post({action:'submitCashback',data:preview.data,username:'SYNTHETIC'}).success,true);
  assert.equal(e.sheets.Upload.data[2][10],-1);
});
test('B22','DC partial acceptance deduplicates campaign/customer across depots','DCB:379-387,419-445',() => {
  const e=environment('DC',fixture()); const r=e.post({action:'submitCashback',data:[upload({dc:'A'}),upload({dc:'B'})],username:'SYNTHETIC'});
  assert.equal(r.success,true); assert.equal(r.rejected.length,1); assert.equal(e.sheets.Upload.data.length,3);
});
test('B23','DC delimiter collision rejects distinct campaign/customer tuples','DCB:381,422',() => {
  const e=environment('DC',fixture()); const r=e.post({action:'submitCashback',data:[upload({kodeCampaign:'A_B',custCode:'C'}),upload({kodeCampaign:'A',custCode:'B_C'})],username:'SYNTHETIC'});
  assert.equal(r.rejected.length,1);
});
test('B24','DC cached index misses same-row key edits','DCB:334-363',() => {
  const f=fixture(); f.Upload.push(row({2:'OLD',6:'CUSTOMER'},21)); const e=environment('DC',f);
  const first=e.call('getExistingKeysForDedup',e.sheets.Upload,3); e.call('saveExistingKeysIndex',first,3);
  e.sheets.Upload.data[2][2]='NEW'; const second=e.call('getExistingKeysForDedup',e.sheets.Upload,3);
  assert.ok(second.has('OLD_CUSTOMER')); assert.equal(second.has('NEW_CUSTOMER'),false);
});
test('B25','DC failure between column writes leaves partial fixture row and no rollback','DCB:458-479',() => {
  const e=environment('DC',fixture(),{failWrite:w=>w.sheet==='Upload'&&w.c===5});
  const r=e.post({action:'submitCashback',data:[upload()],username:'SYNTHETIC'});
  assert.equal(r.success,false); assert.equal(e.sheets.Upload.data[2][2],'CAMP'); assert.equal(e.sheets.Upload.data[2][6],undefined);
});
test('B26','DC upload lookup enforces server 200-row cap after full source range read','DCB:200-228',() => {
  const f=fixture(); f['DM-30D']=[header(34),...Array.from({length:201},()=>row({1:'DOC',31:'BATCH'},34))];
  const e=environment('DC',f); const r=e.post({action:'lookupBatch',lookupType:'upload',batchNumbers:['BATCH']});
  assert.equal(r.success,false); assert.ok(e.reads.some(x=>x.sheet==='DM-30D'&&x.height===201&&x.width===33));
});

const report = {
  recorded_at_utc: new Date().toISOString(), scope:'Offline synthetic characterization; no network or production operations',
  interpretation:'PASS means the observed legacy behavior was reproduced, including defects; not a safety or migration acceptance result.',
  models:['Apps Script services replaced with in-memory fixtures. Lock modeled as non-recursive per Google API semantics.',
    'Spreadsheet writes modeled as immediate; failure injection demonstrates missing rollback, not observed live persistence.',
    'Cache TTL/eviction, real concurrency, Apps Script runtime, formula evaluation and deployed-version parity are not tested.',
    'Legacy embedded token key replaced in memory with a synthetic test key; test tokens never recorded.'],
  source_hashes:hashes, total:records.length, passed:records.filter(r=>r.result==='PASS').length,
  failed:records.filter(r=>r.result==='FAIL').length, checks:records
};
fs.writeFileSync(path.join(root,'docs/phase-0-backend-test-results.json'),JSON.stringify(report,null,2)+'\n');
console.log(JSON.stringify({total:report.total,passed:report.passed,failed:report.failed,failed_ids:records.filter(r=>r.result==='FAIL').map(r=>r.id)}));
process.exitCode=report.failed?1:0;
