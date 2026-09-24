// Shared display and access rules for the 23 September release.
const RC_CB_LABELS = ['Transfer', 'CN', 'Rebate', 'Rebate Manual'];
function rcCbLabel(value) {
    const raw = String(value || '').trim();
    const key = raw.toLowerCase();
    if (['ra07','ra7','rebate manual'].includes(key)) return 'Rebate Manual';
    if (key === 'voucher') return 'Transfer';
    return RC_CB_LABELS.find(v => v.toLowerCase() === key) || raw;
}
function rcDisplayDate(value, withTime = false) {
    const s = String(value || '').trim();
    if (!s || s === '-') return '-';
    const m = s.match(/^(\d{1,2})[\/-](\d{1,2})[\/-](\d{4})(.*)$/);
    if (m) return m[1].padStart(2,'0') + '-' + RC_BULAN_SINGKAT[Number(m[2])-1] + '-' + m[3] + (withTime ? m[4] : '');
    if (/^\d{1,2}-[A-Za-z]{3}-\d{4}/.test(s)) return withTime ? s : s.slice(0,11);
    if (!/^\d{4}-\d{2}-\d{2}/.test(s)) return s;
    const d = new Date(s.length === 10 ? s + 'T00:00:00+07:00' : s);
    if (Number.isNaN(d.getTime())) return '-';
    const parts = Object.fromEntries(new Intl.DateTimeFormat('en-GB', {timeZone:'Asia/Jakarta', day:'2-digit',month:'short',year:'numeric',hour:'2-digit',minute:'2-digit',second:'2-digit',hourCycle:'h23'}).formatToParts(d).map(p=>[p.type,p.value]));
    return parts.day+'-'+parts.month.slice(0,3)+'-'+parts.year+(withTime?' '+parts.hour+':'+parts.minute+':'+parts.second:'');
}
function rcPendingGroup(status) {
    const s = String(status || 'Not Yet').toLowerCase().replaceAll('_',' ');
    if (['not yet','submitted'].includes(s)) return 'Pending Depot';
    if (['approved','released','bulk process','bulk processed'].includes(s)) return 'Pending OSC';
    if (s === 'claimed') return 'Pending Finance';
    return s === 'done' ? 'Done' : status || 'Not Yet';
}
function rcDetailCard(title, value) {
    return '<div class="bg-white p-3 rounded-lg shadow-sm border border-gray-200 min-w-0"><span class="font-bold text-gray-500 block mb-1 uppercase text-[10px]">'+rcEsc(title)+'</span><div class="text-xs font-semibold whitespace-pre-line break-words">'+rcEsc(value || '-')+'</div></div>';
}
function rcHistoryDates(r) {
    return [['Submitted',r.submittedAt||r.tglUpload],['Approved',r.approvedAt||r.tglApprove],['Process OSC — Released',r.releasedAt||r.tglRelease],['Process OSC — Claimed',r.claimedAt||r.tglClaim],['Bulk Process',r.bulkProcessedAt||r.tglBulk],['Done',r.doneAt||r.tglClearing]].map(([k,v])=>'<div class="mb-1"><span class="text-gray-400">'+k+': </span>'+rcEsc(rcDisplayDate(v,true))+'</div>').join('');
}
function rcHistoryDetails(r) {
    const batches = [['Submitted',r.batchUpload],['Released',r.batchRelease],['Claimed',r.batchClaim],['Done',r.batchClearing]].map(([k,v])=>k+': '+(v||'-')).join('\n');
    return rcDetailCard('No Batch',batches)+rcDetailCard('SO Date Start / End',rcDisplayDate(r.soStart)+'\n'+rcDisplayDate(r.soEnd))+rcDetailCard('Billing Date Start / End',rcDisplayDate(r.billingStart)+'\n'+rcDisplayDate(r.billingEnd))+rcDetailCard('Remark',r.remark)+rcDetailCard('Process by',r.processBy)+rcDetailCard('Jenis CB',rcCbLabel(r.jenisCb));
}

let rcActiveContext = {module:'Home',tab:'Home'};
function rcCanTab(code) {
    if (!currentUserData) return false;
    if ((currentUserData.sysRole || currentUserData.role || '').toLowerCase() === 'system manager') return true;
    return currentUserData.tabs?.[code] === true;
}
function rcFirstTab(module, preferred) {
    if (rcCanTab(module+'.'+preferred)) return preferred;
    return Object.keys(currentUserData?.tabs || {}).find(k=>k.startsWith(module+'.')&&rcCanTab(k))?.split('.')[1] || null;
}
function rcEnterTab(module, tab) {
    if (!tab || !rcCanTab(module+'.'+tab)) { showNotification('Anda tidak memiliki izin tab ini.','warning'); return false; }
    rcActiveContext = {module:module,tab:tab};
    return true;
}
const RC_TAB_BUTTONS = {
    'upload.mass':'subnav_mass','upload.single':'subnav_single','upload.open':'subnav_open',
    'process.claimFin':'subnav_claimFin','process.clearing':'subnav_clearing',
    'analytics.history':'subnav_history','analytics.summary':'subnav_summary',
    'keyMaster.customer':'kmTabCustomer','keyMaster.campaign':'kmTabCampaign','keyMaster.depot':'kmTabDepot',
    'access.list':'mTabList','access.add':'mTabAdd','access.req':'mTabReq','access.email':'mTabEmail','access.exclude':'mTabExclude','access.arsip':'mTabArsip','access.grade':'mTabGrade',
    'report.dashboard':'rtTabDashboard','report.cc1':'rtTabCc1','report.cc2':'rtTabCc2',
    'people.osc':'peopleTabOsc','people.supervisor':'peopleTabSupervisor'
};
function rcApplyTabUI() {
    Object.entries(RC_TAB_BUTTONS).forEach(([code,id])=>{const el=document.getElementById(id);if(el){el.dataset.rcTab=code;el.hidden=!rcCanTab(code);}});
    document.querySelectorAll('[data-rc-tab]').forEach(el=>{el.hidden=!rcCanTab(el.dataset.rcTab);});
    const compileTab=document.getElementById('cmpTabCompile');if(compileTab)compileTab.hidden=!['list','compile','archive'].some(t=>rcCanTab('compilation.'+t));
    Object.entries({upload:'menuUpload',release:'menuRelease',process:'menuProcess',analytics:'menuAnalytics',access:'menuKelolaAkses',logs:'menuLogActivity',bulk:'menuBulkProcess',keyMaster:'menuKeyMaster',compilation:'menuCompilation',approval:'menuApproval',report:'menuReport',timetable:'menuTimetable',people:'menuPeople'}).forEach(([module,id])=>{
        const any=(currentUserData?.sysRole==='system manager') || Object.keys(currentUserData?.tabs||{}).some(k=>k.startsWith(module+'.')&&rcCanTab(k));setHiddenSafely(id,!any);
    });
}
const rcOriginalApplyRoleUI=applyRoleBasedUI;
applyRoleBasedUI=function(user){rcOriginalApplyRoleUI(user);rcApplyTabUI();};
const rcOriginalLogActivity=logActivity;
logActivity=function(detail){
    if (!currentUserData) return;
    const batch=String(detail||'').match(/(?:No Batch|Batch)\s*:\s*([^\s,;]+)/i)?.[1] || '';
    return fetchApp({action:'logActivity',detail:detail,module:rcActiveContext.module,tab:rcActiveContext.tab,batch:batch,stage:rcActiveContext.tab}).catch(()=>{});
};

async function renderPermissionMatrix(user) {
    const host=document.getElementById('editModuleMatrix');if(!host)return;
    try {
        if(!rcPermissionCatalog){const r=await fetchApp({action:'permissionCatalog'});if(r.status!=='success')throw Error(r.message||'Katalog izin gagal dimuat');rcPermissionCatalog=r.rows;}
        const held=user?.permissions||[],role=(user?.sysRole||user?.role||'').toLowerCase();
        host.innerHTML=rcPermissionCatalog.map(c=>{
            const intrinsic=role==='system manager'||role==='depot head'||role==='management'||(role==='supervisor'&&c.key==='n')||!c.code;
            const on=intrinsic||held.includes(c.code);
            return '<fieldset class="border border-gray-200 rounded-xl p-3"><legend class="text-xs font-black px-1">'+rcEsc(c.modul)+'</legend><label class="flex gap-2 text-xs font-bold mb-3"><input type="checkbox" class="perm-matrix rounded" data-permkey="'+rcEsc(c.key)+'" '+(on?'checked ':'')+(intrinsic?'disabled ':'')+'onchange="rcMatrixModuleChanged(this)"> Izin modul</label><label class="flex gap-2 text-xs text-blue-700 mb-2"><input type="checkbox" '+((c.tabs||[]).every(t=>user?.tabs?.[t.code]!==false)&&on?'checked ':'')+'onchange="rcMatrixCheckTabs(this)"> Pilih semua tab</label>'+ (c.tabs||[]).map(t=>'<label class="flex gap-2 text-xs py-1"><input class="perm-tab rounded text-pink-600" data-tabcode="'+rcEsc(t.code)+'" type="checkbox" '+(on&&user?.tabs?.[t.code]!==false?'checked ':'')+(!on?'disabled ':'')+(role==='system manager'?'disabled ':'')+'>'+rcEsc(t.title)+'</label>').join('')+'</fieldset>';
        }).join('');
    } catch(e) {rcPermissionCatalog=null;host.innerHTML='<p class="text-red-600 text-sm">'+rcEsc(e.message)+'. Buka ulang sebelum menyimpan.</p>';}
}
function rcMatrixModuleChanged(input){input.closest('fieldset').querySelectorAll('.perm-tab').forEach(e=>{e.disabled=!input.checked;e.checked=input.checked;});}
function rcMatrixCheckTabs(input){input.closest('fieldset').querySelectorAll('.perm-tab').forEach(e=>{if(!e.disabled)e.checked=input.checked;});}
function rcMatrixValues(){const o={};document.querySelectorAll('.perm-matrix').forEach(e=>o[e.dataset.permkey]=e.checked?'Yes':'No');return o;}
function rcTabMatrixValues(){const o={};document.querySelectorAll('.perm-tab').forEach(e=>o[e.dataset.tabcode]=e.checked);return o;}

function rcWorkflowFilter(prefix,type){
    const wrap=document.getElementById(prefix+'Search')?.closest('.flex.flex-wrap');if(!wrap||document.getElementById(prefix+'CbType'))return;
    const label=document.createElement('label');label.className='text-xs font-bold text-gray-700 w-44';label.textContent='Jenis CB';
    const select=document.createElement('select');select.id=prefix+'CbType';select.className='block w-full border rounded-lg p-2.5 mt-1.5 text-sm bg-white';select.innerHTML='<option value="">Semua Jenis CB</option>'+RC_CB_LABELS.map(s=>'<option>'+s+'</option>').join('');select.onchange=()=>renderWorkflowTable(type);label.append(select);wrap.append(label);
    if(type!=='release'){
        const yearLabel=document.createElement('label');yearLabel.className=label.className;yearLabel.textContent='Tahun Campaign (SO Start)';
        const year=document.createElement('select');year.id=prefix+'CampaignYear';year.className=select.className;year.innerHTML='<option value="">Semua Tahun</option>';year.onchange=()=>renderWorkflowTable(type);yearLabel.append(year);wrap.append(yearLabel);
    }
}
const rcOriginalPopWorkflowFilters=popWorkflowFilters;
popWorkflowFilters=function(){rcOriginalPopWorkflowFilters();[['rel','release',globalReleaseData],['cf','claim',globalClaimFinData],['clr','clearing',globalClearingData]].forEach(([prefix,type,rows])=>{
    rcWorkflowFilter(prefix,type);const el=document.getElementById(prefix+'CampaignYear');if(el){const selected=el.value;el.innerHTML='<option value="">Semua Tahun</option>'+[...new Set(rows.map(r=>r.campaignYear).filter(Boolean))].sort().reverse().map(y=>'<option>'+rcEsc(y)+'</option>').join('');el.value=selected;}
});};

let rcDepotProfileData=null;
async function openProfileView(){
    if(!rcEnterTab('profile','view'))return;
    setHiddenSafely('workspaceSection',true);setHiddenSafely('dashboardSection',true);setHiddenSafely('navBackBtn',false);setHiddenSafely('profileSection',false);
    const select=document.getElementById('profileDepotSelect');
    select.innerHTML=(globalDepotList||[]).map(d=>{const code=d.kodeDepot||d.kode||d.depotCode;return '<option value="'+rcEsc(code)+'">'+rcEsc(code+' — '+(d.namaDepot||d.nama||d.depot||''))+'</option>';}).join('');
    if(currentUserData.kodeDepot&&[...select.options].some(o=>o.value===currentUserData.kodeDepot))select.value=currentUserData.kodeDepot;
    if(!select.value){setTextSafely('profDepotName','Belum ada depot dalam yurisdiksi');setHiddenSafely('profileEditButton',true);return;}
    await rcLoadDepotProfile();
}
async function rcLoadDepotProfile(){
    rcDepotProfileData=null;setHiddenSafely('profileEditButton',true);showLoadingOverlay('Memuat profil depot...');
    try{
        const r=await fetchApp({action:'depotProfile',kode:document.getElementById('profileDepotSelect').value});if(r.status!=='success')throw Error(r.message||'Profil gagal dimuat');rcDepotProfileData=r;
        const map={profType:r.tipeDepot||'Profil Depot',profDepotName:r.namaDepot,profDepotCode:r.kodeDepot,profRegion:r.region,profGrade:r.grade,profAddress:r.alamat,profRsm:r.emailRsm,profAsm:r.emailAsm,profSm:r.emailSm,profKaDepot:r.kepalaDepot,profKaAdmin:r.kepalaAdmin,profEmNpc:r.emailDepot,profEmFg:r.emailCc,profOsc:(r.timPengawas||[]).filter(x=>x.peran==='osc').map(x=>x.nama).join(', '),profEmSpv:(r.timPengawas||[]).filter(x=>x.peran==='supervisor').map(x=>x.nama).join(', '),profUsers:(r.akunTerdaftar||[]).map(x=>x.userId+' — '+x.nama).join(', ')};
        Object.entries({profTotKar:'total',profKSales:'sales',profKAdmin:'admin',profKFg:'fg',profKPcc:'pcc',profKTek:'teknisi',profKDrv:'driver',profKLain:'lain'}).forEach(([id,k])=>map[id]=r.karyawan?.[k]||0);
        Object.entries(map).forEach(([id,v])=>setTextSafely(id,v??'-'));
        setTextSafely('profilePendingNote',r.pengajuanTertunda+' pengajuan menunggu approval. Diperbarui: '+rcDisplayDate(r.diperbaruiPada,true));setHiddenSafely('profileEditButton',!rcCanTab('profile.edit'));
    }catch(e){showNotification(e.message,'error');setTextSafely('profDepotName','Profil gagal dimuat');}finally{hideLoadingOverlay();}
}
const RC_PROFILE_FIELDS=[['nama','Nama Depot'],['abbr','Abbreviation'],['region','Region'],['tipeDepot','Tipe Depot'],['grade','Grade'],['alamat','Alamat'],['gmapsUrl','Google Maps URL'],['fotoUrl','Foto URL'],['kepalaDepot','Kepala Depot'],['kepalaAdmin','Kepala Admin'],['emailRsm','Email RSM'],['emailAsm','Email ASM'],['emailSm','Email SM'],['emailDepot','Email Depot'],['emailTo','Email To'],['emailCc','Email CC'],['karAdmin','Karyawan Admin'],['karSales','Karyawan Sales'],['karDriver','Karyawan Driver'],['karFg','Karyawan FG'],['karPcc','Karyawan PCC'],['karTeknisi','Karyawan Teknisi'],['karLain','Karyawan Lainnya']];
function rcProfileEdit(){
    if(!rcEnterTab('profile','edit')||!rcDepotProfileData)return;const r=rcDepotProfileData;
    const data={...r,nama:r.namaDepot};Object.entries({karAdmin:'admin',karSales:'sales',karDriver:'driver',karFg:'fg',karPcc:'pcc',karTeknisi:'teknisi',karLain:'lain'}).forEach(([key,k])=>data[key]=r.karyawan?.[k]||0);
    rcDialog('Ajukan perubahan profil — '+r.kodeDepot,'<p class="text-sm text-gray-600 mb-4">Perubahan berlaku setelah disetujui reviewer lain. Tim pengawas dan akun mengikuti penugasan di Access Management.</p><form onsubmit="event.preventDefault();rcSubmitProfileEdit()" id="rcProfileEditForm"><div class="grid grid-cols-1 md:grid-cols-2 gap-3">'+RC_PROFILE_FIELDS.map(([key,label])=>'<label class="text-xs font-bold text-gray-600">'+rcEsc(label)+'<input data-profile-field="'+key+'" value="'+rcEsc(data[key]??'')+'" '+(key.startsWith('kar')?'type="number" min="0" step="1"':'type="text"')+' class="block w-full p-2 border rounded-lg mt-1"></label>').join('')+'</div><button id="rcProfileSave" class="mt-5 px-5 py-2 bg-blue-600 text-white rounded-lg font-bold">Ajukan Approval</button></form>');
}
async function rcSubmitProfileEdit(){
    const changes={};document.querySelectorAll('[data-profile-field]').forEach(e=>changes[e.dataset.profileField]=e.dataset.profileField.startsWith('kar')?Number(e.value):e.value.trim());
    setDisabledSafely('rcProfileSave',true);
    try{const r=await fetchApp({action:'depotProfileRequest',kode:rcDepotProfileData.kodeDepot,changes:changes});if(r.status!=='success')throw Error(r.message||'Pengajuan gagal');rcDialog('Pengajuan tersimpan','Profil akan berubah setelah disetujui melalui Access Management → Approval Request.');await rcLoadDepotProfile();}catch(e){showNotification(e.message,'error');setDisabledSafely('rcProfileSave',false);}
}

document.addEventListener('DOMContentLoaded',function(){
    const style=document.createElement('style');style.textContent='[hidden]{display:none!important}.rc-wrap{white-space:normal!important;overflow-wrap:anywhere;min-width:120px;max-width:240px}.rc-time{white-space:normal!important;min-width:220px}';document.head.append(style);
    const open=document.getElementById('openCampaign');if(open){const select=document.createElement('select');select.id='openCbType';select.setAttribute('aria-label','Filter Jenis CB');select.className=open.className;select.innerHTML='<option value="">Semua Jenis CB</option>'+RC_CB_LABELS.map(s=>'<option>'+s+'</option>').join('');select.onchange=()=>loadOpenClaims(0);open.parentElement.append(select);}
    [['releaseTableBody',false],['claimFinTableBody',true],['clearingTableBody',true]].forEach(([id,gross])=>{const row=document.getElementById(id)?.closest('table')?.querySelector('thead tr');if(!row)return;let th=document.createElement('th');th.className='p-3 text-xs font-black text-gray-600';th.textContent='Jenis CB';row.insertBefore(th,row.lastElementChild);if(gross){th=document.createElement('th');th.className='p-3 text-xs font-black text-orange-700';th.textContent='Gross Up Value';row.insertBefore(th,row.lastElementChild);}});
    const cust=document.getElementById('customerTableBody')?.closest('table')?.querySelector('thead tr');if(cust){const anchor=cust.children[1];['Kode Depot','Nama Depot','Region'].forEach(t=>{const th=document.createElement('th');th.className='p-3 text-xs font-bold';th.textContent=t;cust.insertBefore(th,anchor);});}
    const suffix=document.getElementById('editSuffix');if(suffix){suffix.readOnly=true;suffix.title='Suffix digenerate otomatis oleh sistem';}
});

function rcHistoryCustomer(index){const r=globalHistoryData[index];if(r)showDetailModal('toko',r.kodeToko,r.namaToko);}

const RC_USER_HEADERS=['User ID','Nama Lengkap','Kode Depot','Email','Role','PIN','Resource Partner / Area'];
let rcUserUploadRows=[];
let rcUserUploadBusy=false;
function rcDownloadUserTemplate(){
    const wb=XLSX.utils.book_new();const sheet=XLSX.utils.aoa_to_sheet([RC_USER_HEADERS]);sheet['!cols']=RC_USER_HEADERS.map(()=>({wch:24}));
    // Keep leading zeros in IDs, depot codes and PINs when Excel receives typed values.
    for(let row=1;row<=500;row++)for(let col=0;col<RC_USER_HEADERS.length;col++)sheet[XLSX.utils.encode_cell({r:row,c:col})]={t:'s',v:'',z:'@'};
    sheet['!ref']='A1:G501';sheet['!cols'][6]={wch:40};
    XLSX.utils.book_append_sheet(wb,sheet,'Users');
    const roles=(mRegistrationOptions?.roles||[]).map(r=>r.code).join(', ');
    XLSX.utils.book_append_sheet(wb,XLSX.utils.aoa_to_sheet([
        ['Kolom / Aturan','Keterangan'],['Role',roles||'admin, depot head, osc, supervisor, finance, others, management, system manager'],
        ['Kode Depot','Kode depot asal, bukan nama. Wajib untuk semua role.'],
        ['Resource Partner / Area','Kode depot yurisdiksi; lebih dari satu dipisahkan koma, contoh 001,002. Tidak menerima nama depot, nama region, atau user ID OSC.'],
        ['Scope','Admin: Resource Partner; role lainnya: area depot langsung. System Manager memperoleh akses penuh dari role setelah approval.'],
        ['PIN','Minimal 8 karakter, maksimal 72 byte. Gunakan PIN awal berbeda untuk setiap user. Kolom sudah berformat teks untuk menjaga nol di depan.'],
        ['Approval','Semua upload masuk Pending di Access Management > Approval Request. Tidak ada akses sebelum disetujui.'],
        ['Suffix','Otomatis saat approval; tidak perlu kolom tambahan.'],
        ['Limit','Maksimal 500 user per file; diproses satu per satu.'],
        ['Retry','Baris yang telah diajukan tidak dikirim ulang; hanya baris gagal yang dicoba kembali.']
    ]),'Petunjuk');XLSX.writeFile(wb,'Template_Upload_User_RC.xlsx');
}
async function rcPreviewUserUpload(input){
    if(rcUserUploadBusy)return;const file=input.files?.[0];if(!file)return;
    rcUserUploadRows=[];setDisabledSafely('rcCommitUsers',true);
    try{
        if(file.size>10*1024*1024)throw Error('File maksimal 10 MB.');
        const wb=XLSX.read(await file.arrayBuffer(),{type:'array'}),raw=XLSX.utils.sheet_to_json(wb.Sheets.Users||wb.Sheets[wb.SheetNames[0]],{header:1,raw:false,defval:''});
        const normalize=s=>String(s).trim().toLowerCase().replace(/\s+/g,' ').replace(/\s*\/\s*/g,'/');
        const header=raw[0]||[];const positions=RC_USER_HEADERS.map(h=>header.findIndex(c=>normalize(c)===normalize(h)));
        if(positions.some(i=>i<0)||header.filter(c=>String(c).trim()).length!==RC_USER_HEADERS.length)throw Error('Gunakan template terbaru dengan tepat 7 kolom: '+RC_USER_HEADERS.join(', ')+'.');
        const rows=raw.slice(1).filter(r=>r.some(c=>String(c).trim()));if(!rows.length||rows.length>500)throw Error('Isi 1 sampai 500 user per file.');
        const seen=new Set(),allowed=(mRegistrationOptions?.roles||[]).map(r=>r.code);
        const depotCodes=new Set((globalDepotList||[]).map(d=>String(d.kode||d.kodeDepot||'').trim().toUpperCase()));
        rcUserUploadRows=rows.map((r,i)=>{
            const values=positions.map(p=>String(r[p]??''));const [userId,nama,depotCode,email,role,pin,area]=values;
            const areaCodes=[...new Set(area.split(',').map(s=>s.trim().toUpperCase()).filter(Boolean))];
            const d={userId:userId.trim().toUpperCase(),nama:nama.trim(),email:email.trim(),role:role.trim().toLowerCase(),depotCode:depotCode.trim().toUpperCase(),areaCodes,pin};
            const issues=[];if(!/^[A-Z0-9._-]{1,100}$/.test(d.userId))issues.push('User ID tidak valid');if(seen.has(d.userId))issues.push('User ID duplikat dalam file');seen.add(d.userId);
            if(!d.nama||d.nama.length>200)issues.push('Nama wajib, maksimal 200 karakter');if(d.email.length>320||!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(d.email))issues.push('Email tidak valid');if(!allowed.includes(d.role))issues.push('Role tidak diizinkan');if(pin.length<8||new TextEncoder().encode(pin).length>72)issues.push('PIN minimal 8 karakter, maksimal 72 byte');
            if(!depotCodes.has(d.depotCode))issues.push('Kode Depot tidak valid atau di luar yurisdiksi');
            if(d.role!=='system manager'&&!areaCodes.length)issues.push('Resource Partner / Area wajib diisi kode depot');
            if(areaCodes.some(code=>!depotCodes.has(code)))issues.push('Resource Partner / Area mengandung kode depot tidak valid atau di luar yurisdiksi');
            return {row:i+2,data:d,status:issues.length?'Invalid':'Ready',message:issues.join('; ')};
        });
        rcRenderUserUpload();
    }catch(e){showNotification(e.message,'error');setTextSafely('rcUserUploadPreview',e.message);}finally{input.value='';}
}
function rcRenderUserUpload(){
    const invalid=rcUserUploadRows.some(r=>r.status==='Invalid'),pending=rcUserUploadRows.filter(r=>['Ready','Failed'].includes(r.status));
    document.getElementById('rcUserUploadPreview').innerHTML='<p class="text-xs mb-2">'+rcUserUploadRows.length+' user · '+rcUserUploadRows.filter(r=>['Pending Approval','Approved','Rejected'].includes(r.status)).length+' pengajuan tersimpan · Suffix otomatis setelah approval</p><div class="max-h-60 overflow-auto border rounded-lg"><table class="w-full text-xs text-left"><thead class="bg-gray-100"><tr><th class="p-2">Baris</th><th class="p-2">User / Nama</th><th class="p-2">Email</th><th class="p-2">Role / Kode Depot</th><th class="p-2">Resource Partner / Area</th><th class="p-2">Status</th></tr></thead><tbody>'+rcUserUploadRows.map(r=>'<tr class="border-b"><td class="p-2">'+r.row+'</td><td class="p-2">'+rcEsc(r.data.userId)+'<br>'+rcEsc(r.data.nama)+'</td><td class="p-2">'+rcEsc(r.data.email)+'</td><td class="p-2">'+rcEsc(r.data.role)+' / '+rcEsc(r.data.depotCode||'-')+'</td><td class="p-2">'+rcEsc(r.data.areaCodes.join(', '))+'</td><td class="p-2 '+(['Invalid','Failed'].includes(r.status)?'text-red-600':'text-gray-700')+'">'+rcEsc(r.status)+'<br>'+rcEsc(r.message)+'</td></tr>').join('')+'</tbody></table></div>';
    setDisabledSafely('rcCommitUsers',rcUserUploadBusy||invalid||!pending.length);
}
async function rcCommitUserUpload(){
    if(rcUserUploadBusy||!rcEnterTab('access','add')||!mBolehUbah()||rcUserUploadRows.some(r=>r.status==='Invalid'))return;
    rcUserUploadBusy=true;rcRenderUserUpload();setDisabledSafely('rcUserUploadFile',true);
    try{
        for(const row of rcUserUploadRows){if(!['Ready','Failed'].includes(row.status))continue;row.status='Processing';rcRenderUserUpload();
            try{const r=await fetchApp({action:'uploadAccount',data:row.data});if(r.status!=='success'||r.source!=='upload'||!['pending','active','rejected'].includes(r.activation))throw Error(r.message||'Pengajuan belum dapat dikonfirmasi');row.status={pending:'Pending Approval',active:'Approved',rejected:'Rejected'}[r.activation];row.message=r.message||'Tersimpan di Approval Request';row.data.pin='';}catch(e){row.status='Failed';row.message=e.message;}
        }
        await fetchManageableData();
    }finally{rcUserUploadBusy=false;setDisabledSafely('rcUserUploadFile',false);rcRenderUserUpload();}
}
