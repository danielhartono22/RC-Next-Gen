import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import {readFile} from 'node:fs/promises';
const foundation=await readFile('src/view/js/10-dasar.js','utf8');
const changes=await readFile('src/js/91-rc-2309.js','utf8');
const analytics=await readFile('src/js/70-analytics.js','utf8');
const report=await readFile('src/view/js/20-report.js','utf8');
const adapter=await readFile('scripts/rc-legacy-adapter.js','utf8');
const timetable=await readFile('src/js/97-timetable.js','utf8');
const timetableMarkup=await readFile('src/parts/modules/timetable.html','utf8');
const sharedStyle=await readFile('src/view/parts/style.html','utf8');
const dialogUi=await readFile('src/js/94-tabel-urut.js','utf8');
const dialogMarkup=await readFile('src/parts/modals/detail-history.html','utf8');
const plain=x=>JSON.parse(JSON.stringify(x));
function page(overrides={}){
 const els=new Map();
 const element=id=>{if(!els.has(id))els.set(id,{value:'',innerHTML:'',classList:{add(){},remove(){},contains(){return false;}}});return els.get(id);};
 const noop=()=>{};
 const ctx={console,Intl,Date,TextEncoder,Math,document:{addEventListener:noop,getElementById:element,querySelectorAll:()=>[]},window:{},setTimeout:noop,
  applyRoleBasedUI:noop,logActivity:noop,popWorkflowFilters:noop,rcMoney:v=>'Rp '+Math.trunc(v).toLocaleString('id-ID'),rcStatusClass:()=>'',showNotification:noop,
  currentUserData:{sysRole:'osc',tabs:{'people.osc':true,'people.supervisor':false,'analytics.history':true}},RC_BULAN_SINGKAT:['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'],
  ...overrides};vm.createContext(ctx);vm.runInContext(foundation+'\n'+changes,ctx);ctx.showNotification=noop;return {ctx,element};
}
test('Summary cards show millions while details and exports retain full integer rupiah',()=>{
 const {ctx,element}=page();assert.equal(ctx.rcNominalPenuh(13268421.99),'Rp 13.268.421');assert.equal(ctx.rcNominal(1200000.9),'Rp 1.200.000');
 assert.equal(ctx.rcNominalRingkas(10923400000.99),'Rp 10.923,4 jt');
 assert.equal(ctx.rcNominalRingkas(897000),'Rp 0,9 jt');
 assert.equal(ctx.rcNominalRingkas(1500.99),'Rp 0,0015 jt');
 assert.equal(ctx.rcNominalRingkas(-1250000.99),'Rp -1,25 jt');
 assert.equal(ctx.rcNominalRingkas(null),'Rp 0 jt');
 assert.equal(ctx.rcExportAmount('grossUpCb',100.99),100);assert.equal(ctx.rcExportAmount('totalCashback',0.99),0);
 assert.equal(ctx.rcExportAmount('Clearing Rate',76.54),76.54);assert.equal(ctx.rcExportAmount('No Rekening','000123'),'000123');
 vm.runInContext(report,ctx);ctx.rtGambarChart=()=>{};ctx.rcAktifkanUrutSemua=()=>{};
 ctx.renderReportDashboard({kpi:{claimQty:2748,netCb:10923400000.99,netClaimed:7618390000.99,cbExpired:897000,outstandingValue:3304110000.99,clearingRate:0.698}});
 const cards=element('rtKpi').innerHTML;
 assert.match(cards,/>Rp 10\.923,4 jt<\/p>/);assert.match(cards,/>Rp 7\.618,39 jt<\/p>/);
 assert.match(cards,/>Rp 0,9 jt<\/p>/);assert.match(cards,/>Rp 3\.304,11 jt<\/p>/);
 assert.match(cards,/title="Rp 10\.923\.400\.000"/);assert.match(cards,/>69\.8%<\/p>/);assert.match(cards,/>2\.748 dok<\/p>/);
 ctx.renderCostCenter1([{netCb:10923400000.99}]);
 assert.match(element('rtCc1Body').innerHTML,/>Rp 10\.923\.400\.000<\/td>/);
});
test('Dates use English months and Jakarta time at midnight boundary',()=>{
 const {ctx}=page();assert.equal(ctx.rcDisplayDate('2026-09-23T17:05:06Z',true),'24-Sep-2026 00:05:06');
 assert.equal(ctx.rcDisplayDate('2026-01-22'),'22-Jan-2026');assert.equal(ctx.rcDisplayDate('22/01/2026'),'22-Jan-2026');assert.equal(ctx.rcDisplayDate(null),'-');
});
test('Tab navigation chooses allowed tab and fails closed for denied tabs',()=>{
 const {ctx}=page();assert.equal(ctx.rcCanTab('people.osc'),true);assert.equal(ctx.rcCanTab('people.supervisor'),false);
 assert.equal(ctx.rcFirstTab('people','supervisor'),'osc');assert.equal(ctx.rcEnterTab('people','supervisor'),false);assert.equal(ctx.rcFirstTab('access','list'),null);
});
test('CB aliases normalize and report pending groups follow requested stages',()=>{
 const {ctx}=page();assert.equal(ctx.rcCbLabel('RA07'),'Rebate Manual');assert.equal(ctx.rcCbLabel('ra7'),'Rebate Manual');
 vm.runInContext(report,ctx);const r=ctx.rtKelompokStatus([{status:'Submitted',qty:2,nilai:300},{status:'Approved',qty:3,nilai:400},{status:'Released',qty:4,nilai:500},{status:'Claimed',qty:5,nilai:600}]);
 assert.equal(r.find(x=>x.status==='Pending Depot').qty,2);assert.equal(r.find(x=>x.status==='Pending OSC').qty,7);assert.equal(r.find(x=>x.status==='Pending Finance').qty,5);
});
test('Analytics keeps canonical stages, wrapped chronology and escaped text without pending labels',()=>{
 const {ctx,element}=page({histCurrentPage:1,histItemsPerPage:10,checkMultiSelect:()=>'',globalHistoryData:[{noDoc:'QA-1',kodeToko:'C-1',namaToko:'<img onerror=alert(1)>',codeCampaign:'CA-1',campaign:'Campaign',status:'Approved',totalClaim:100.99,submittedAt:'2026-09-23T00:00:00Z',approvedAt:'2026-09-23T01:00:00Z',batchUpload:'B-1',remark:'Reprocessing, CB Type Changed',processBy:'Dummy'}]});
 vm.runInContext(analytics,ctx);element('histFilterStatus').value='ALL';ctx.renderHistoryTable(true);
 const html=element('historyTableBody').innerHTML;assert.match(html,/Approved/);assert.match(html,/23-Sep-2026 08:00:00/);assert.match(html,/No Batch/);assert.match(html,/SO Date Start/);assert.match(html,/Billing Date Start/);assert.match(html,/Process by/);assert.match(html,/&lt;img/);assert.doesNotMatch(html,/Pending Depot|Pending OSC|Pending Finance|onerror=alert\(1\)>/);assert.match(html,/Rp 100</);
});
test('Adapter matches SQL profile and CB filter argument names',async()=>{
 const calls=[];const ctx={window:{},crypto,TextEncoder,__client:{rpc:async(name,args)=>{calls.push({name,args});return {data:{status:'success'}};}}};
 vm.createContext(ctx);vm.runInContext(adapter.replace('var clientPromise = null;','var clientPromise = Promise.resolve(__client);'),ctx);
 await ctx.window.RCBackend.call({action:'depotProfileRequest',kode:'D-1',changes:{grade:'A'}});
 await ctx.window.RCBackend.call({action:'openClaims',cbType:'Rebate Manual',offset:50});
 assert.deepEqual(plain(calls[0]),{name:'rc_depot_profile_request',args:{p_kode:'D-1',p_perubahan:{grade:'A'}}});assert.equal(calls[1].args.p_cb_type,'Rebate Manual');assert.equal(calls[1].args.p_offset,50);
});
test('Timetable uses Campaign Year consistently and no longer exposes reference date',()=>{
 assert.match(timetableMarkup,/Tahun Campaign/);
 assert.match(timetableMarkup,/id="ttTahunCampaign"/);
 assert.doesNotMatch(timetableMarkup,/ttTanggal|Tanggal Acuan|tanggal acuan/i);
 assert.match(timetable,/const pilihanTahun = document\.getElementById\('ttTahunCampaign'\)\.value/);
 assert.match(timetable,/res\.tahunTersedia/);
 assert.match(timetable,/res\.tahunCampaign/);
 assert.match(timetable,/<option value="ALL">Semua Tahun<\/option>/);
 assert.match(timetable,/tahunCampaign:\s*pilihanTahun\s*\|\|\s*undefined/);
 assert.match(timetable,/RC_Timetable_' \+ \(ttData\.tahunCampaign === 'ALL' \? 'Semua_Tahun'/);
 assert.doesNotMatch(timetable,/ttTanggal|tanggal:\s*document\.getElementById|campaign aktif per|tanggal acuan/i);
});
test('Timetable cards and dialogs size themselves within their containers',()=>{
 assert.equal((timetableMarkup.match(/rc-chart-body/g)||[]).length,4);
 assert.match(sharedStyle,/\.rc-chart-body\s*\{[^}]*height:\s*clamp\(/s);
 assert.match(sharedStyle,/#cardExpandBody\s*>\s*\.rc-expanded-content/);
 assert.match(sharedStyle,/#rcDialogModal\.rc-dialog-wide\s*>\s*\.rc-dialog-panel/);
 assert.match(dialogMarkup,/class="rc-dialog-panel/);
 assert.match(dialogUi,/classList\.toggle\('rc-dialog-wide'/);
 assert.match(timetable,/rcUkurUlangGrafik\(document\.getElementById\('modTimetable'\)\)/);
});
test('Bulk export writes truncated numeric CB and Gross Up values',async()=>{
 const workflow=await readFile('src/js/65-workflow.js','utf8');let rows;
 const {ctx}=page({rcKunciPajak:()=> 'customer',XLSX_FMT_ACCOUNTING_RP:'#,##0',XLSX:{utils:{aoa_to_sheet:r=>{rows=r;return {};},book_new:()=>({}),book_append_sheet(){}},writeFile(){}}});
 vm.runInContext(workflow,ctx);ctx.downloadBulkProcessExcel([{codeCampaign:'CA',kodeToko:'C',kodeDepot:'D',cbNet:100.99,statusPajakCust:'Badan',statusPajakCamp:'Customer'}]);
 assert.equal(rows[1][4],100);assert.equal(rows[1][5],118);
});

test('User template contains exactly seven columns and preserves leading zeros',()=>{
 const sheets={};let output;
 const {ctx}=page({mRegistrationOptions:{roles:[{code:'osc'}]},XLSX:{utils:{book_new:()=>({}),aoa_to_sheet:rows=>({rows}),
  encode_cell:({r,c})=>String.fromCharCode(65+c)+(r+1),book_append_sheet:(wb,s,name)=>sheets[name]=s},writeFile:(wb,name)=>output=name}});
 ctx.rcDownloadUserTemplate();
 assert.deepEqual(plain(sheets.Users.rows[0]),['User ID','Nama Lengkap','Kode Depot','Email','Role','PIN','Resource Partner / Area']);
 assert.equal(sheets.Users.F2.z,'@');assert.equal(sheets.Users.C501.z,'@');assert.equal(sheets.Users['!ref'],'A1:G501');
 assert.equal(output,'Template_Upload_User_RC.xlsx');
});

test('User upload submits approval proposals, hides PINs and retries only failed rows',async()=>{
 let rows=[['User ID','Nama Lengkap','Kode Depot','Email','Role','PIN','Resource Partner  / Area'],
  ['qa-1','Dummy One','001','one@example.invalid','supervisor','00123456','001,002,001'],
  ['qa-2','Dummy Two','002','two@example.invalid','management','00987654','002']];
 const calls=[];let failed=false;
 const {ctx,element}=page({currentUserData:{sysRole:'system manager'},globalDepotList:[{kode:'001'},{kode:'002'}],
  mRegistrationOptions:{roles:[{code:'supervisor'},{code:'management'}]},mBolehUbah:()=>true,fetchManageableData:async()=>true,
  XLSX:{read:()=>({SheetNames:['Users'],Sheets:{Users:{}}}),utils:{sheet_to_json:()=>rows}},
  fetchApp:async body=>{calls.push(plain(body));if(body.data.userId==='QA-2'&&!failed){failed=true;throw Error('Try again');}return {status:'success',source:'upload',activation:'pending'};}});
 ctx.setDisabledSafely=(id,v)=>element(id).disabled=v;ctx.setTextSafely=(id,v)=>element(id).innerHTML=v;
 const file=()=>({value:'file',files:[{size:1024,arrayBuffer:async()=>new ArrayBuffer(0)}]});
 await ctx.rcPreviewUserUpload(file());
 assert.equal(element('rcCommitUsers').disabled,false);
 assert.match(element('rcUserUploadPreview').innerHTML,/001, 002/);
 assert.doesNotMatch(element('rcUserUploadPreview').innerHTML,/00123456|00987654/);
 await Promise.all([ctx.rcCommitUserUpload(),ctx.rcCommitUserUpload()]);
 assert.equal(calls.length,2);assert.equal(calls[0].action,'uploadAccount');assert.deepEqual(calls[0].data.areaCodes,['001','002']);
 assert.match(element('rcUserUploadPreview').innerHTML,/Pending Approval/);
 assert.equal(vm.runInContext('rcUserUploadRows[0].data.pin',ctx),'');
 await ctx.rcCommitUserUpload();assert.equal(calls.length,3);assert.equal(calls[2].data.userId,'QA-2');
 assert.equal(element('rcCommitUsers').disabled,true);
 rows=[rows[0],['qa-3','Dummy','001','dummy@example.invalid','supervisor','00123456','003']];
 await ctx.rcPreviewUserUpload(file());assert.equal(element('rcCommitUsers').disabled,true);
 assert.match(element('rcUserUploadPreview').innerHTML,/di luar yurisdiksi/);
 rows=[['User ID','Nama Lengkap','Email','Role','Department','Home Depot','Depot Codes','OSC Codes','Regions','Initial PIN']];
 await ctx.rcPreviewUserUpload(file());assert.match(element('rcUserUploadPreview').innerHTML,/tepat 7 kolom/);
});
