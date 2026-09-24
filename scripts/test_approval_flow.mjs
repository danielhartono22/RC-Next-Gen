import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import {readFile} from 'node:fs/promises';
import {webcrypto} from 'node:crypto';

const adapter=await readFile('scripts/rc-legacy-adapter.js','utf8');
function mockedAdapter(reply) {
 const calls=[];
 const context={window:{},crypto:webcrypto,TextEncoder,
   __testClient:{rpc:async(name,args)=>{calls.push({name,args});return {data:reply(name,args)};}}};
 vm.createContext(context);
 // Inject only the network client, retaining the actual handlers and conversion logic.
 vm.runInContext(adapter.replace('var clientPromise = null;', 'var clientPromise = Promise.resolve(__testClient);'),context);
 return {backend:context.window.RCBackend,calls};
}
const plain=x=>JSON.parse(JSON.stringify(x));
test('Claim Process uses direct expiry while Upload uses approval expiry',async()=>{
 const {backend,calls}=mockedAdapter(()=>({processed:[],count:0}));
 backend._test.setVersion('QA-1',4);
 for(const stage of ['claim','clearing']) {
  const r=await backend.call({action:'processWorkflow',workflowType:stage,actionType:'expired',docsToProcess:['QA-1']});
  assert.equal(r.status,'success');
  assert.equal(calls.at(-1).args.p_action,'expire_claim_process');
 }
 await backend.call({action:'markExpired',docsToProcess:['QA-1']});
 assert.equal(calls.at(-1).args.p_action,'expire');
 const n=calls.length;
 const invalid=await backend.call({action:'processWorkflow',workflowType:'release',actionType:'expired',docsToProcess:['QA-1']});
 assert.equal(invalid.status,'error');assert.equal(calls.length,n);
});
test('Approval detail refreshes document versions before decision',async()=>{
 const {backend,calls}=mockedAdapter(name=>name==='rc_process_claims'?{processed:[],count:0}:{rows:[{noDoc:'QA-2',versionNo:8}]});
 backend._test.setVersion('QA-2',1);
 for(const [read,write] of [['approvalDetail','approveDocs'],['approvalHold','approveHoldDocs']]) {
  await backend.call({action:read});
  const r=await backend.call({action:write,docsToProcess:['QA-2']});
  assert.equal(r.status,'success');assert.equal(calls.at(-1).args.p_items[0].version_no,8);
 }
});
test('Exception sends observed version and remembers successful result version',async()=>{
 const {backend,calls}=mockedAdapter(name=>name==='rc_posting_exception'
  ? {status:'success',processed:[{noDoc:'QA-3',status:'Not Yet',pendingApproval:true,versionNo:10}]}
  : {processed:[],count:0});
 backend._test.setVersion('QA-3',9);
 await backend.call({action:'postingException',tindakan:'expired',rows:[{noDoc:'QA-3'}]});
 assert.equal(calls[0].args.p_rows[0].versionNo,9);
 await backend.call({action:'approveHoldDocs',docsToProcess:['QA-3']});
 assert.equal(calls[1].args.p_items[0].version_no,10);
});
test('Submit exposes server status and pending flag to frontend',async()=>{
 const rows=[{no_doc:'QA-4',status:'submitted',pending_approval:true,version_no:2}];
 const {backend}=mockedAdapter(()=>({processed:rows,count:1,batch:'QA-BATCH'}));
 backend._test.setVersion('QA-4',1);
 const res=await backend.call({action:'submitData',data:[{noDoc:'QA-4'}]});
 assert.deepEqual(plain(res.summary.processed),rows);
});

const bootstrap=await readFile('src/js/25-bootstrap.js','utf8');
const helpers=bootstrap.slice(bootstrap.indexOf('            function normalizeClaimStatus'),bootstrap.indexOf('            async function refreshUploadDocuments'));
test('Local result updates successful rows to server Submitted status',()=>{
 const ctx={globalDocuments:[{noDoc:'QA-1',status:''},{noDoc:'QA-2',status:'Released'}]};
 vm.createContext(ctx);vm.runInContext(helpers,ctx);
 ctx.patchLocalApprovalResult([{no_doc:'QA-1',status:'submitted',pending_approval:true,version_no:2}]);
 assert.deepEqual(plain(ctx.globalDocuments),[{noDoc:'QA-1',status:'Submitted',pendingApproval:true,versionNo:2},{noDoc:'QA-2',status:'Released'}]);
 ctx.patchLocalApprovalResult([{noDoc:'QA-1',status:'On Hold',pendingApproval:false,versionNo:3}]);
 assert.equal(ctx.globalDocuments[0].status,'On Hold');
 assert.equal(ctx.globalDocuments[0].pendingApproval,false);
});

const upload=await readFile('src/js/60-upload-submit.js','utf8');
function uploadContext(response) {
 const noop=()=>{};
 const ctx={globalDocuments:[{noDoc:'QA-A',status:''},{noDoc:'QA-B',status:'Not Yet'}],
   massUploadDataValid:[{noDoc:'QA-A',currentStatus:''},{noDoc:'QA-B',currentStatus:'Not Yet'}],
   currentUserData:{},document:{querySelectorAll:()=>[{value:'QA-A'},{value:'QA-B'}]},
   EXC_STATUS_BOLEH:{expired:['not yet']},fetchApp:async()=>response,
   showConfirmModal:async()=>true,showNotification:noop,logActivity:noop,showActionResult:noop,
   resetInputGrid:noop,cancelPreview:noop,setDisabledSafely:noop,setHiddenSafely:noop,
   showLoadingOverlay:noop,hideLoadingOverlay:noop,rcDialog:noop,rcEsc:String};
 vm.createContext(ctx);vm.runInContext(helpers+'\n'+upload,ctx);
 return ctx;
}
test('Submit handler uses server Submitted state while preserving approval flag',async()=>{
 const ctx=uploadContext({status:'success',summary:{successfulDocs:['QA-A'],successCount:1,
   processed:[{no_doc:'QA-A',status:'submitted',pending_approval:true,version_no:2}]}});
 await ctx.submitMassClaim();
 assert.equal(ctx.globalDocuments[0].status,'Submitted');
 assert.equal(ctx.globalDocuments[0].pendingApproval,true);
 assert.equal(ctx.globalDocuments[1].pendingApproval,undefined);
});
test('Exception handler never applies Expired optimistically or changes failed rows',async()=>{
 const ctx=uploadContext({status:'success',berhasil:1,jumlahGagal:1,
   processed:[{noDoc:'QA-A',status:'Not Yet',pendingApproval:true,versionNo:2}],
   gagal:[{noDoc:'QA-B',sebab:'Dokumen berubah'}]});
 await ctx.submitPostingException('expired');
 assert.equal(ctx.globalDocuments[0].status,'Not Yet');
 assert.equal(ctx.globalDocuments[0].pendingApproval,true);
 assert.equal(ctx.globalDocuments[1].pendingApproval,undefined);
 assert.equal(ctx.globalDocuments[1].status,'Not Yet');
});
