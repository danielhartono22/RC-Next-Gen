/*
 * Modul baru yang diminta pemilik pada 17 September 2026: Key Master (Customer Master dan
 * Campaign Master) serta Cashback Compilation, ditambah satu field Suffix Batch pada konsol
 * Otorisasi.
 *
 * Semua markup tambahan terkumpul di file ini supaya build dapat menguranginya kembali dan
 * tetap membuktikan sisa halaman identik dengan file legacy. Kelas Tailwind mengikuti modul
 * yang sudah ada, jadi hasilnya tampak menyatu, bukan tempelan.
 */

// Dua kartu pada dashboard, disisipkan sesudah kartu Bulk Process.
export const MENU_CARDS =
  '\n                        <div id="menuKeyMaster" onclick="openRcModule(\'keyMaster\')" class="hidden bg-white rounded-2xl shadow-sm border border-gray-200 cursor-pointer hover:border-emerald-400 hover:shadow-xl transition transform hover:-translate-y-1 p-8 flex flex-col items-center text-center group"><div class="bg-emerald-50 w-20 h-20 flex items-center justify-center rounded-full mb-5 group-hover:scale-110 transition"><i class="fas fa-key text-4xl text-emerald-600"></i></div><h3 class="font-black text-xl text-gray-800">Key Master</h3><p class="text-sm text-gray-500 mt-2">Customer Master dan Campaign Master.</p></div>' +
  '\n                        <div id="menuCompilation" onclick="openRcModule(\'compilation\')" class="hidden bg-white rounded-2xl shadow-sm border border-gray-200 cursor-pointer hover:border-cyan-400 hover:shadow-xl transition transform hover:-translate-y-1 p-8 flex flex-col items-center text-center group"><div class="bg-cyan-50 w-20 h-20 flex items-center justify-center rounded-full mb-5 group-hover:scale-110 transition"><i class="fas fa-layer-group text-4xl text-cyan-600"></i></div><h3 class="font-black text-xl text-gray-800">Cashback Compilation</h3><p class="text-sm text-gray-500 mt-2">Kompilasi cashback per campaign dan batch.</p></div>';

const subTab = (id, label, color) =>
  '<button id="' + id + '" onclick="switchKeyMasterTab(\'' + id.replace('kmTab', '').toLowerCase() + '\')" class="px-5 py-2 text-sm font-bold rounded-lg transition text-gray-500 hover:bg-gray-100">' + label + '</button>';

// Id elemen memakai huruf kecil di depan (customerSearch) sementara nama fungsi memakai
// huruf besar (loadCustomerMaster). Keduanya diturunkan dari satu variabel supaya tidak
// bisa berbeda diam-diam seperti sebelumnya.
const masterToolbar = (kind, placeholder) =>
  '<div class="flex flex-wrap gap-3 items-center mb-5">' +
  '<input id="' + kind.toLowerCase() + 'Search" onkeyup="if(event.key===\'Enter\')load' + kind + 'Master(0)" placeholder="' + placeholder + '" class="flex-1 min-w-[220px] px-4 py-2.5 border border-gray-300 rounded-lg text-sm">' +
  '<button onclick="load' + kind + 'Master(0)" class="px-5 py-2.5 bg-gray-800 hover:bg-black text-white font-bold rounded-lg text-sm transition"><i class="fas fa-search mr-2"></i>Cari</button>' +
  '<button onclick="download' + kind + 'Template()" class="px-5 py-2.5 bg-white border border-gray-300 hover:bg-gray-50 text-gray-700 font-bold rounded-lg text-sm transition"><i class="fas fa-file-excel mr-2 text-green-600"></i>Template</button>' +
  '<label class="px-5 py-2.5 bg-white border border-gray-300 hover:bg-gray-50 text-gray-700 font-bold rounded-lg text-sm transition cursor-pointer"><i class="fas fa-upload mr-2 text-blue-600"></i>Pilih File<input type="file" id="' + kind.toLowerCase() + 'File" accept=".xlsx,.xls" class="hidden" onchange="preview' + kind + 'Upload(this)"></label>' +
  '<button onclick="openRcRowEditor(\'' + kind.toLowerCase() + '\',null)" class="px-5 py-2.5 bg-emerald-600 hover:bg-emerald-700 text-white font-bold rounded-lg text-sm transition"><i class="fas fa-plus mr-2"></i>Tambah</button>' +
  '</div>';

export const MODULES = [
  '                <!-- MODULE: KEY MASTER -->',
  '                <div id="modKeyMaster" class="module-section hidden">',
  '                    <div class="bg-white rounded-2xl shadow-sm border border-gray-200 p-6">',
  '                        <div class="mb-5 border-b border-gray-100 pb-4"><h2 class="text-2xl font-extrabold text-gray-800"><i class="fas fa-key text-emerald-600 mr-2"></i>Key Master</h2><p class="text-gray-500 mt-1 text-sm">Master pelanggan dan campaign. Data di sini adalah sumber kebenaran; upload klaim membacanya dan tidak menimpanya.</p></div>',
  '                        <div class="flex gap-2 mb-5 bg-gray-50 p-1.5 rounded-xl w-fit">' + subTab('kmTabCustomer', 'Customer Master', 'emerald') + subTab('kmTabCampaign', 'Campaign Master', 'emerald') + '</div>',
  '                        <div id="kmPanelCustomer">' + masterToolbar('Customer', 'Cari kode atau nama pelanggan') +
  '<div id="customerUploadInfo" class="hidden mb-4 p-4 bg-blue-50 border border-blue-200 rounded-xl text-sm"><p id="customerUploadText" class="text-blue-900 font-bold mb-3">-</p><button onclick="commitCustomerUpload()" id="btnCommitCustomer" class="px-5 py-2 bg-blue-600 hover:bg-blue-700 text-white font-bold rounded-lg text-sm">Simpan ke Master</button> <button onclick="cancelMasterUpload(\'Customer\')" class="px-4 py-2 bg-white border border-gray-300 text-gray-700 font-bold rounded-lg text-sm">Batal</button></div>',
  '                        <div class="overflow-auto border border-gray-200 rounded-xl"><table class="w-full text-sm"><thead class="bg-gray-50 text-gray-600"><tr><th class="p-3 text-left font-bold">Kode</th><th class="p-3 text-left font-bold">Nama</th><th class="p-3 text-center font-bold">TOP</th><th class="p-3 text-left font-bold">KTP</th><th class="p-3 text-left font-bold">NPWP</th><th class="p-3 text-center font-bold">Subyek Pajak</th><th class="p-3 text-left font-bold">Rekening</th><th class="p-3 text-left font-bold">Contact Person</th><th class="p-3 text-center font-bold">Aksi</th></tr></thead><tbody id="customerTableBody"></tbody></table></div>',
  '                        <div id="customerPager" class="mt-4"></div></div>',
  '                        <div id="kmPanelCampaign" class="hidden">' + masterToolbar('Campaign', 'Cari kode atau nama campaign') +
  '<div id="campaignUploadInfo" class="hidden mb-4 p-4 bg-blue-50 border border-blue-200 rounded-xl text-sm"><p id="campaignUploadText" class="text-blue-900 font-bold mb-3">-</p><button onclick="commitCampaignUpload()" id="btnCommitCampaign" class="px-5 py-2 bg-blue-600 hover:bg-blue-700 text-white font-bold rounded-lg text-sm">Simpan ke Master</button> <button onclick="cancelMasterUpload(\'Campaign\')" class="px-4 py-2 bg-white border border-gray-300 text-gray-700 font-bold rounded-lg text-sm">Batal</button></div>',
  '                        <div class="overflow-auto border border-gray-200 rounded-xl"><table class="w-full text-sm"><thead class="bg-gray-50 text-gray-600"><tr><th class="p-3 text-left font-bold">Kode</th><th class="p-3 text-left font-bold">Nama Campaign</th><th class="p-3 text-center font-bold">Periode Start</th><th class="p-3 text-center font-bold">Periode End</th><th class="p-3 text-center font-bold">Jenis CB</th><th class="p-3 text-center font-bold">Status Pajak</th><th class="p-3 text-center font-bold">Klaim</th><th class="p-3 text-center font-bold">Aksi</th></tr></thead><tbody id="campaignTableBody"></tbody></table></div>',
  '                        <div id="campaignPager" class="mt-4"></div></div>',
  '                    </div>',
  '                </div>',
  '',
  '                <!-- MODULE: CASHBACK COMPILATION -->',
  '                <div id="modCompilation" class="module-section hidden">',
  '                    <div class="bg-white rounded-2xl shadow-sm border border-gray-200 p-6">',
  '                        <div class="mb-5 border-b border-gray-100 pb-4 flex flex-wrap justify-between items-end gap-3"><div><h2 class="text-2xl font-extrabold text-gray-800"><i class="fas fa-layer-group text-cyan-600 mr-2"></i>Cashback Compilation</h2><p class="text-gray-500 mt-1 text-sm">Pencarian terarah per campaign atau batch, maksimal 2.000 baris sekali tarik.</p></div><button onclick="toggleArchivedList()" id="btnArchivedList" class="hidden px-4 py-2 bg-white border border-gray-300 hover:bg-gray-50 text-gray-700 font-bold rounded-lg text-sm"><i class="fas fa-box-archive mr-2"></i>Lihat Arsip</button></div>',
  '                        <div class="flex flex-wrap gap-3 items-center mb-5"><select id="compCampaign" class="min-w-[240px] px-4 py-2.5 border border-gray-300 rounded-lg text-sm"><option value="">-- Semua Campaign --</option></select><input id="compBatch" placeholder="Nomor batch" class="px-4 py-2.5 border border-gray-300 rounded-lg text-sm w-[180px]"><select id="compStatus" class="px-4 py-2.5 border border-gray-300 rounded-lg text-sm"><option value="">Semua status</option><option value="not_yet">Not Yet</option><option value="submitted">Submitted</option><option value="released">Released</option><option value="claimed">Claimed</option><option value="done">Done</option><option value="on_hold">On Hold</option><option value="expired">Expired</option></select><input id="compSearch" placeholder="No Doc / kode / nama toko" class="flex-1 min-w-[200px] px-4 py-2.5 border border-gray-300 rounded-lg text-sm"><button onclick="loadCompilation(0)" class="px-5 py-2.5 bg-cyan-600 hover:bg-cyan-700 text-white font-bold rounded-lg text-sm"><i class="fas fa-search mr-2"></i>Tarik Data</button></div>',
  '                        <div id="compSummary" class="mb-4 flex flex-wrap gap-3 text-sm"></div>',
  '                        <div id="compArchiveBar" class="hidden mb-4 p-4 bg-red-50 border border-red-200 rounded-xl flex flex-wrap gap-3 items-center"><span class="font-bold text-red-800 text-sm"><span id="compSelectedCount">0</span> baris dipilih</span><input id="compArchiveReason" placeholder="Alasan pengarsipan (wajib)" class="flex-1 min-w-[240px] px-4 py-2 border border-red-300 rounded-lg text-sm"><button onclick="archiveCompilationRows()" id="btnArchiveComp" class="px-5 py-2 bg-red-600 hover:bg-red-700 text-white font-bold rounded-lg text-sm">Arsipkan</button></div>',
  '                        <div class="overflow-auto border border-gray-200 rounded-xl"><table class="w-full text-sm"><thead class="bg-gray-50 text-gray-600"><tr><th class="p-3 text-center font-bold"><input type="checkbox" id="compSelectAll" onchange="toggleAllCompilation(this)" class="w-4 h-4 rounded"></th><th class="p-3 text-left font-bold">No Doc</th><th class="p-3 text-center font-bold">Status</th><th class="p-3 text-left font-bold">Toko</th><th class="p-3 text-left font-bold">Campaign</th><th class="p-3 text-center font-bold">Jenis CB</th><th class="p-3 text-center font-bold">Subyek</th><th class="p-3 text-right font-bold">Cashback</th><th class="p-3 text-right font-bold">Gross Up</th><th class="p-3 text-left font-bold">Batch</th></tr></thead><tbody id="compTableBody"></tbody></table></div>',
  '                        <div id="compPager" class="mt-4"></div>',
  '                        <div id="compArchivedPanel" class="hidden mt-6 border-t border-gray-200 pt-6"><h3 class="font-black text-gray-800 mb-3"><i class="fas fa-box-archive text-gray-500 mr-2"></i>Baris Terarsip</h3><div class="overflow-auto border border-gray-200 rounded-xl"><table class="w-full text-sm"><thead class="bg-gray-50 text-gray-600"><tr><th class="p-3 text-left font-bold">No Doc</th><th class="p-3 text-left font-bold">Toko</th><th class="p-3 text-left font-bold">Campaign</th><th class="p-3 text-right font-bold">Cashback</th><th class="p-3 text-left font-bold">Alasan</th><th class="p-3 text-left font-bold">Oleh</th><th class="p-3 text-center font-bold">Aksi</th></tr></thead><tbody id="compArchivedBody"></tbody></table></div></div>',
  '                    </div>',
  '                </div>',
  '',
  '                <!-- MODAL: EDITOR BARIS MASTER -->',
  '                <div id="rcRowEditor" class="hidden fixed inset-0 bg-black/60 backdrop-blur-sm flex items-center justify-center z-[90] p-4">',
  '                    <div class="bg-white rounded-2xl shadow-2xl w-full max-w-lg overflow-hidden flex flex-col max-h-[92vh]"><div class="bg-emerald-50 p-5 border-b border-emerald-100 flex justify-between items-center"><h3 id="rcRowEditorTitle" class="font-black text-gray-800 text-lg">Ubah Data</h3><button onclick="closeRcRowEditor()" class="text-emerald-400 hover:text-emerald-700"><i class="fas fa-times text-xl"></i></button></div><div class="p-6 overflow-auto"><div id="rcRowEditorError" class="hidden bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded text-sm font-bold mb-4"><span id="rcRowEditorErrorText">-</span></div><div id="rcRowEditorFields" class="space-y-4"></div></div><div class="p-4 bg-gray-50 border-t flex gap-3"><button onclick="closeRcRowEditor()" class="flex-1 py-2.5 bg-white border border-gray-300 text-gray-700 font-bold rounded-xl hover:bg-gray-100">Batal</button><button onclick="saveRcRowEditor()" id="btnSaveRcRow" class="flex-1 py-2.5 bg-emerald-600 hover:bg-emerald-700 text-white font-bold rounded-xl shadow-md">Simpan</button></div></div>',
  '                </div>',
  ''
].join('\n');

// Suffix menentukan nomor batch, jadi System Manager harus dapat menetapkannya, bukan hanya
// menerima angka yang diberikan otomatis saat persetujuan.
export const SUFFIX_FIELD =
  '<div><label class="block text-[10px] font-bold text-gray-500 uppercase mb-1.5 ml-1">Suffix Batch (3 digit)</label><input id="editSuffix" maxlength="3" pattern="[0-9]{3}" placeholder="001" class="w-full px-3 py-2 text-sm border border-gray-300 rounded-lg bg-white font-bold text-gray-800"><p class="text-[10px] text-gray-400 mt-1 ml-1">Membentuk nomor batch. Tidak dapat dipindahkan bila sudah pernah menerbitkan batch.</p></div>';

export const MODULES_SCRIPT = `
            // ===================== MODUL BARU: KEY MASTER & COMPILATION =====================
            // Menyalin pola openModule() milik halaman ini supaya perilaku navigasinya sama,
            // tanpa perlu mengubah fungsi aslinya.
            let rcMasterState = { customer: { offset: 0, rows: [] }, campaign: { offset: 0, rows: [] } };
            let rcCompState = { offset: 0, rows: [], canArchive: false, campaigns: [] };
            let rcPendingUpload = { Customer: null, Campaign: null };
            let rcEditorKind = null, rcEditorRow = null;

            function openRcModule(mod) {
                setHiddenSafely('dashboardSection', true); setHiddenSafely('navBackBtn', false);
                setHiddenSafely('workspaceSection', false); setHiddenSafely('profileSection', true);
                document.querySelectorAll('.module-section').forEach(el => el.classList.add('hidden'));
                if (mod === 'keyMaster') {
                    document.getElementById('modKeyMaster').classList.remove('hidden');
                    switchKeyMasterTab('customer');
                } else if (mod === 'compilation') {
                    document.getElementById('modCompilation').classList.remove('hidden');
                    initCompilation();
                }
            }

            function switchKeyMasterTab(tab) {
                setHiddenSafely('kmPanelCustomer', tab !== 'customer');
                setHiddenSafely('kmPanelCampaign', tab !== 'campaign');
                let active = "px-5 py-2 text-sm font-bold rounded-lg transition bg-emerald-100 text-emerald-700";
                let idle = "px-5 py-2 text-sm font-bold rounded-lg transition text-gray-500 hover:bg-gray-100";
                document.getElementById('kmTabCustomer').className = tab === 'customer' ? active : idle;
                document.getElementById('kmTabCampaign').className = tab === 'campaign' ? active : idle;
                if (tab === 'customer') loadCustomerMaster(rcMasterState.customer.offset);
                else loadCampaignMaster(rcMasterState.campaign.offset);
            }

            function rcEsc(v) {
                return String(v === null || v === undefined ? '' : v)
                    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
            }
            function rcMoney(v) { return 'Rp ' + Number(v || 0).toLocaleString('id-ID'); }

            // ---------- Customer Master ----------
            async function loadCustomerMaster(offset) {
                showLoadingOverlay("Memuat Customer Master...");
                try {
                    let res = await fetchApp({ action: 'customerList', search: document.getElementById('customerSearch').value.trim(), offset: offset });
                    if (res.status !== 'success') { showNotification(res.message || "Gagal memuat.", "error"); return; }
                    rcMasterState.customer = { offset: offset, rows: res.rows || [] };
                    let html = '';
                    (res.rows || []).forEach((r, i) => {
                        let badge = r.subyekPajak === 'Badan' ? 'bg-purple-100 text-purple-700'
                                  : (r.subyekPajak === 'Perorangan' ? 'bg-orange-100 text-orange-700' : 'bg-gray-100 text-gray-500');
                        html += '<tr class="border-b border-gray-100 hover:bg-emerald-50/40">'
                            + '<td class="p-3 font-black text-gray-800">' + rcEsc(r.custCode) + '</td>'
                            + '<td class="p-3 text-gray-700">' + rcEsc(r.custName) + '</td>'
                            + '<td class="p-3 text-center">' + rcEsc(r.top || '-') + '</td>'
                            + '<td class="p-3 text-gray-600 font-mono whitespace-nowrap">' + rcEsc(rcFull(r.ktp) || '-') + '</td>'
                            + '<td class="p-3 text-gray-600 font-mono whitespace-nowrap">' + rcEsc(rcFull(r.npwp) || '-') + '</td>'
                            + '<td class="p-3 text-center"><span class="' + badge + ' px-2 py-1 rounded text-[10px] font-black uppercase">' + rcEsc(r.subyekPajak || 'Belum ada') + '</span></td>'
                            + '<td class="p-3 text-xs text-gray-600 font-mono whitespace-nowrap">' + rcEsc(rcFull(r.noRek) || '-') + '<br><span class="text-gray-400">' + rcEsc(r.namaRek || '-') + ' / ' + rcEsc(r.bank || '-') + '</span></td>'
                            + '<td class="p-3 text-gray-600">' + rcEsc(r.contactPerson || '-') + '</td>'
                            + '<td class="p-3 text-center"><button onclick="openRcRowEditor(\\'customer\\',' + i + ')" class="px-3 py-1.5 bg-white border border-gray-300 hover:bg-emerald-50 text-emerald-700 font-bold rounded-lg text-xs">Ubah</button></td></tr>';
                    });
                    document.getElementById('customerTableBody').innerHTML = html
                        || '<tr><td colspan="9" class="p-8 text-center text-gray-500">Tidak ada data.</td></tr>';
                    renderRcPager('customerPager', offset, (res.rows || []).length, res.total, 'loadCustomerMaster');
                } catch (e) { showNotification("Gagal memuat Customer Master.", "error"); }
                finally { hideLoadingOverlay(); }
            }

            // ---------- Campaign Master ----------
            async function loadCampaignMaster(offset) {
                showLoadingOverlay("Memuat Campaign Master...");
                try {
                    let res = await fetchApp({ action: 'campaignList', search: document.getElementById('campaignSearch').value.trim(), offset: offset });
                    if (res.status !== 'success') { showNotification(res.message || "Gagal memuat.", "error"); return; }
                    rcMasterState.campaign = { offset: offset, rows: res.rows || [] };
                    let html = '';
                    (res.rows || []).forEach((r, i) => {
                        let jc = String(r.jenisCb || '').toLowerCase();
                        let jcCls = jc === 'transfer' ? 'bg-green-100 text-green-800'
                                  : (jc === 'cn' ? 'bg-yellow-100 text-yellow-800'
                                  : (jc === 'rebate' ? 'bg-pink-100 text-pink-800' : 'bg-red-100 text-red-700'));
                        html += '<tr class="border-b border-gray-100 hover:bg-emerald-50/40">'
                            + '<td class="p-3 font-black text-gray-800">' + rcEsc(r.codeCampaign) + '</td>'
                            + '<td class="p-3 text-gray-700">' + rcEsc(r.campaignName) + '</td>'
                            + '<td class="p-3 text-center text-gray-600">' + rcEsc(r.periodStart || '-') + '</td>'
                            + '<td class="p-3 text-center text-gray-600">' + rcEsc(r.periodEnd || '-') + '</td>'
                            + '<td class="p-3 text-center"><span class="' + jcCls + ' px-2 py-1 rounded text-[10px] font-black uppercase">' + rcEsc(r.jenisCb || 'BELUM DIISI') + '</span></td>'
                            + '<td class="p-3 text-center text-gray-600">' + rcEsc(r.statusPajak || '-') + '</td>'
                            + '<td class="p-3 text-center font-bold text-gray-700">' + rcEsc(r.jumlahClaim) + '</td>'
                            + '<td class="p-3 text-center"><button onclick="openRcRowEditor(\\'campaign\\',' + i + ')" class="px-3 py-1.5 bg-white border border-gray-300 hover:bg-emerald-50 text-emerald-700 font-bold rounded-lg text-xs">Ubah</button></td></tr>';
                    });
                    document.getElementById('campaignTableBody').innerHTML = html
                        || '<tr><td colspan="8" class="p-8 text-center text-gray-500">Tidak ada data.</td></tr>';
                    renderRcPager('campaignPager', offset, (res.rows || []).length, res.total, 'loadCampaignMaster');
                } catch (e) { showNotification("Gagal memuat Campaign Master.", "error"); }
                finally { hideLoadingOverlay(); }
            }

            function renderRcPager(containerId, offset, shown, total, fnName) {
                let el = document.getElementById(containerId); if (!el) return;
                let from = total === 0 ? 0 : offset + 1, to = offset + shown;
                el.innerHTML = '<div class="flex justify-between items-center text-xs text-gray-600 bg-white p-3 border rounded-xl">'
                    + '<span>Menampilkan <b>' + from + '</b> - <b>' + to + '</b> dari <b>' + total + '</b></span>'
                    + '<span class="flex gap-2">'
                    + '<button ' + (offset === 0 ? 'disabled' : '') + ' onclick="' + fnName + '(' + Math.max(0, offset - 50) + ')" class="px-3 py-1.5 bg-white border rounded-lg disabled:opacity-40">Sebelumnya</button>'
                    + '<button ' + (to >= total ? 'disabled' : '') + ' onclick="' + fnName + '(' + (offset + 50) + ')" class="px-3 py-1.5 bg-white border rounded-lg disabled:opacity-40">Berikutnya</button>'
                    + '</span></div>';
            }

            // ---------- Editor satu baris ----------
            const RC_FIELDS = {
                customer: [['custCode','Customer Code',true],['custName','Nama Pelanggan',true],['top','TOP',false],
                           ['ktp','No KTP',false],['npwp','No NPWP',false],['namaRek','Nama Rekening',false],
                           ['noRek','Nomor Rekening',false],['bank','Nama Bank',false],['contactPerson','Contact Person',false]],
                campaign: [['codeCampaign','Code Campaign',true],['campaignName','Nama Campaign',true],
                           ['periodStart','Periode Start',false],['periodEnd','Periode End',false],
                           ['jenisCb','Jenis CB (Transfer / CN / Rebate)',false],['statusPajak','Status Pajak',false]]
            };

            function openRcRowEditor(kind, index) {
                rcEditorKind = kind;
                rcEditorRow = (index === null || index === undefined) ? null : rcMasterState[kind].rows[index];
                document.getElementById('rcRowEditorTitle').innerText =
                    (rcEditorRow ? 'Ubah ' : 'Tambah ') + (kind === 'customer' ? 'Pelanggan' : 'Campaign');
                setHiddenSafely('rcRowEditorError', true);
                let html = '';
                RC_FIELDS[kind].forEach(f => {
                    let key = f[0], label = f[1], required = f[2];
                    let val = rcEditorRow ? (rcEditorRow[key] || '') : '';
                    // Kode pelanggan dan kode campaign adalah identitas baris. Mengubahnya akan
                    // memutus kaitan dengan claim yang sudah ada, jadi pada mode ubah field itu
                    // dibuat readonly, bukan disabled: nilainya tetap terbaca, dapat disalin,
                    // dan alasannya dinyatakan di layar alih-alih terlihat seperti kerusakan.
                    let kunci = rcEditorRow && key === RC_FIELDS[kind][0][0];
                    // Identitas panjang seperti KTP, NPWP dan rekening ditulis penuh dengan
                    // huruf lebar tetap supaya tidak pernah terbaca terpotong.
                    let identitas = ['ktp','npwp','noRek','top'].indexOf(key) !== -1;
                    html += '<div><label class="block text-sm font-medium text-gray-700 mb-1">' + label
                        + (required ? ' <span class="text-red-500">*</span>' : '')
                        + (kunci ? ' <span class="text-[10px] font-normal text-gray-400">(kunci, tidak dapat diubah)</span>' : '')
                        + '</label>'
                        + '<input id="rcField_' + key + '" value="' + rcEsc(rcFull(val)) + '"'
                        + (kunci ? ' readonly' : '')
                        + (identitas ? ' inputmode="numeric" autocomplete="off"' : '')
                        + ' class="w-full px-4 py-2.5 border rounded-lg text-sm bg-gray-50 focus:bg-white'
                        + (kunci ? ' bg-gray-100 text-gray-600 cursor-not-allowed' : '')
                        + (identitas ? ' font-mono tracking-wide' : '') + '"></div>';
                });
                if (kind === 'customer') {
                    html += '<p class="text-xs text-gray-500 bg-gray-50 border border-gray-200 rounded-lg p-3">Subyek pajak tidak diisi manual. NPWP terisi berarti <b>Badan</b>, hanya KTP berarti <b>Perorangan</b>. Mengisi keduanya akan menolak upload klaim pelanggan ini.</p>';
                }
                document.getElementById('rcRowEditorFields').innerHTML = html;
                setHiddenSafely('rcRowEditor', false);
            }
            function closeRcRowEditor() { setHiddenSafely('rcRowEditor', true); }

            async function saveRcRowEditor() {
                let kind = rcEditorKind, row = {};
                RC_FIELDS[kind].forEach(f => { row[f[0]] = document.getElementById('rcField_' + f[0]).value.trim(); });
                let missing = RC_FIELDS[kind].filter(f => f[2] && !row[f[0]]);
                if (missing.length > 0) {
                    document.getElementById('rcRowEditorErrorText').innerText = missing[0][1] + ' wajib diisi.';
                    setHiddenSafely('rcRowEditorError', false); return;
                }
                setDisabledSafely('btnSaveRcRow', true);
                try {
                    let res = await fetchApp({ action: kind === 'customer' ? 'customerUpsert' : 'campaignUpsert', rows: [row] });
                    if (res.status === 'success') {
                        showNotification("Data master tersimpan.", "success");
                        logActivity('Ubah ' + kind + ' master: ' + row[RC_FIELDS[kind][0][0]]);
                        closeRcRowEditor();
                        if (kind === 'customer') loadCustomerMaster(rcMasterState.customer.offset);
                        else loadCampaignMaster(rcMasterState.campaign.offset);
                    } else {
                        document.getElementById('rcRowEditorErrorText').innerText = res.message || 'Gagal menyimpan.';
                        setHiddenSafely('rcRowEditorError', false);
                    }
                } catch (e) {
                    document.getElementById('rcRowEditorErrorText').innerText = 'Gagal terhubung ke server.';
                    setHiddenSafely('rcRowEditorError', false);
                } finally { setDisabledSafely('btnSaveRcRow', false); }
            }

            // ---------- Mass upload ----------
            const RC_TEMPLATE = {
                Customer: { headers: ['Customer Code','Customer Name','TOP','No KTP','No NPWP','Nama Rekening','Nomor Rekening','Nama Bank','Contact Person'],
                            keys: ['custCode','custName','top','ktp','npwp','namaRek','noRek','bank','contactPerson'],
                            contoh: ['C00123','TOKO MAJU JAYA','30','','012345678901234','TOKO MAJU JAYA','0081234567','BCA','Budi 0812xxxx'] },
                Campaign: { headers: ['Code Campaign','Nama Campaign','Periode Start','Periode End','Jenis CB','Status Pajak'],
                            keys: ['codeCampaign','campaignName','periodStart','periodEnd','jenisCb','statusPajak'],
                            contoh: ['CMP2601','PROMO AWAL TAHUN','01-01-2026','31-03-2026','Transfer','PKP'] }
            };

            function downloadCustomerTemplate() { downloadRcTemplate('Customer'); }
            function downloadCampaignTemplate() { downloadRcTemplate('Campaign'); }

            function downloadRcTemplate(kind) {
                let t = RC_TEMPLATE[kind];
                let wb = XLSX.utils.book_new();
                let ws = XLSX.utils.aoa_to_sheet([t.headers, t.contoh]);
                ws['!cols'] = t.headers.map(() => ({ wch: 22 }));
                // Identitas dan rekening harus tetap teks supaya angka nol di depan tidak hilang.
                for (let r = 2; r <= 501; r++) {
                    t.keys.forEach((k, ci) => {
                        if (['ktp','npwp','noRek','top'].indexOf(k) === -1) return;
                        let ref = XLSX.utils.encode_cell({ c: ci, r: r - 1 });
                        if (!ws[ref]) ws[ref] = { t: 's', v: '' };
                        ws[ref].z = '@';
                    });
                }
                XLSX.utils.book_append_sheet(wb, ws, kind);
                XLSX.writeFile(wb, 'Template_' + kind + '_Master.xlsx');
            }

            function previewCustomerUpload(el) { previewRcUpload('Customer', el); }
            function previewCampaignUpload(el) { previewRcUpload('Campaign', el); }

            function previewRcUpload(kind, fileInput) {
                let file = fileInput.files && fileInput.files[0];
                if (!file) return;
                if (file.size > 5 * 1024 * 1024) { showNotification("File maksimal 5 MB.", "error"); fileInput.value = ''; return; }
                let t = RC_TEMPLATE[kind];
                let reader = new FileReader();
                reader.onload = function (e) {
                    try {
                        let wb = XLSX.read(new Uint8Array(e.target.result), { type: 'array', cellDates: false });
                        let rows = XLSX.utils.sheet_to_json(wb.Sheets[wb.SheetNames[0]], { header: 1, raw: true, defval: '' });
                        let hIdx = rows.findIndex(r => String((r && r[0]) || '').trim().toLowerCase() === t.headers[0].toLowerCase());
                        if (hIdx < 0) { showNotification("Header '" + t.headers[0] + "' tidak ditemukan. Gunakan template.", "error"); return; }
                        let colMap = {};
                        rows[hIdx].forEach((h, i) => {
                            let pos = t.headers.findIndex(x => x.toLowerCase() === String(h || '').trim().toLowerCase());
                            if (pos >= 0) colMap[t.keys[pos]] = i;
                        });
                        if (colMap[t.keys[0]] === undefined) { showNotification("Kolom kunci tidak ditemukan.", "error"); return; }
                        let out = [], beresiko = [];
                        for (let i = hIdx + 1; i < rows.length; i++) {
                            let raw = rows[i]; if (!raw) continue;
                            let obj = {}, kosong = true;
                            t.keys.forEach(k => {
                                let cell = colMap[k] === undefined ? '' : raw[colMap[k]];
                                if (rcPrecisionRisk(cell)) beresiko.push('baris ' + (i + 1) + ' kolom ' + k);
                                let v = rcCellText(cell);
                                obj[k] = v; if (v) kosong = false;
                            });
                            if (kosong) continue;
                            if (!obj[t.keys[0]]) { showNotification("Baris " + (i + 1) + ": " + t.headers[0] + " kosong.", "error"); return; }
                            out.push(obj);
                        }
                        if (out.length === 0) { showNotification("Tidak ada baris data.", "warning"); return; }
                        if (out.length > 2000) { showNotification("Maksimal 2000 baris per unggahan.", "error"); return; }
                        if (beresiko.length > 0) {
                            showNotification("Ada angka terlalu panjang sehingga digitnya bisa berubah: "
                                + beresiko.slice(0, 3).join(', ') + ". Format kolom itu sebagai Teks di Excel lalu ulangi.", "error");
                            return;
                        }
                        rcPendingUpload[kind] = out;
                        document.getElementById(kind.toLowerCase() + 'UploadText').innerText =
                            out.length + ' baris siap disimpan. Kode yang sudah ada akan ditimpa oleh data ini.';
                        setHiddenSafely(kind.toLowerCase() + 'UploadInfo', false);
                    } catch (err) { showNotification("File tidak dapat dibaca.", "error"); }
                };
                reader.readAsArrayBuffer(file);
            }

            function cancelMasterUpload(kind) {
                rcPendingUpload[kind] = null;
                setHiddenSafely(kind.toLowerCase() + 'UploadInfo', true);
                let f = document.getElementById(kind.toLowerCase() + 'File'); if (f) f.value = '';
            }

            function commitCustomerUpload() { commitRcUpload('Customer', 'customerUpsert', loadCustomerMaster); }
            function commitCampaignUpload() { commitRcUpload('Campaign', 'campaignUpsert', loadCampaignMaster); }

            async function commitRcUpload(kind, action, reload) {
                let rows = rcPendingUpload[kind];
                if (!rows) return;
                let confirmed = await showConfirmModal({ title: "Konfirmasi Upload Master",
                    message: rows.length + " baris akan disimpan ke " + kind + " Master.\\n\\nKode yang sudah ada akan DITIMPA oleh data dari file ini.",
                    confirmText: "Ya, Simpan", danger: false });
                if (!confirmed) return;
                setDisabledSafely('btnCommit' + kind, true);
                showLoadingOverlay("Menyimpan " + kind + " Master...");
                try {
                    let res = await fetchApp({ action: action, rows: rows });
                    if (res.status === 'success') {
                        showNotification((res.dibuat || 0) + " baris baru, " + (res.diperbarui || 0) + " diperbarui.", "success");
                        logActivity('Mass upload ' + kind + ' Master: ' + rows.length + ' baris');
                        cancelMasterUpload(kind); reload(0);
                    } else { showNotification(res.message || "Gagal menyimpan.", "error"); }
                } catch (e) { showNotification("Gagal terhubung ke server.", "error"); }
                finally { setDisabledSafely('btnCommit' + kind, false); hideLoadingOverlay(); }
            }

            // ---------- Cashback Compilation ----------
            async function initCompilation() {
                let sel = document.getElementById('compCampaign');
                if (sel.options.length <= 1) {
                    try {
                        let res = await fetchApp({ action: 'campaignList', search: '', offset: 0, limit: 200 });
                        if (res.status === 'success') {
                            rcCompState.campaigns = res.rows || [];
                            (res.rows || []).forEach(c => {
                                let o = document.createElement('option');
                                o.value = c.codeCampaign;
                                o.textContent = c.codeCampaign + ' - ' + c.campaignName + ' (' + c.jumlahClaim + ')';
                                sel.appendChild(o);
                            });
                        }
                    } catch (e) { showNotification("Gagal memuat daftar campaign.", "error"); }
                }
                loadCompilation(0);
            }

            async function loadCompilation(offset) {
                showLoadingOverlay("Menarik data cashback...");
                try {
                    let res = await fetchApp({ action: 'compilationList',
                        campaign: document.getElementById('compCampaign').value,
                        batch: document.getElementById('compBatch').value.trim(),
                        status: document.getElementById('compStatus').value,
                        search: document.getElementById('compSearch').value.trim(),
                        offset: offset });
                    if (res.status !== 'success') { showNotification(res.message || "Gagal menarik data.", "error"); return; }
                    rcCompState = Object.assign(rcCompState, { offset: offset, rows: res.rows || [], canArchive: !!res.canArchive });
                    setHiddenSafely('btnArchivedList', !res.canArchive);
                    setHiddenSafely('compArchiveBar', !res.canArchive);

                    let totalCb = (res.rows || []).reduce((s, r) => s + (Number(r.cbNet) || 0), 0);
                    let totalGu = (res.rows || []).reduce((s, r) => s + (Number(r.grossUpCb) || 0), 0);
                    let toko = new Set((res.rows || []).map(r => r.kodeToko).filter(Boolean)).size;
                    document.getElementById('compSummary').innerHTML =
                        '<span class="px-3 py-2 bg-gray-100 rounded-lg font-bold text-gray-700">Total baris: ' + res.total + '</span>'
                        + '<span class="px-3 py-2 bg-purple-50 rounded-lg font-bold text-purple-800">Qty Toko: ' + toko + '</span>'
                        + '<span class="px-3 py-2 bg-red-50 rounded-lg font-bold text-red-700">Cashback: ' + rcMoney(totalCb) + '</span>'
                        + '<span class="px-3 py-2 bg-orange-50 rounded-lg font-bold text-orange-700">Gross Up: ' + rcMoney(totalGu) + '</span>';

                    let html = '';
                    (res.rows || []).forEach(r => {
                        let batches = [r.batchUpload, r.batchRelease, r.batchClaim, r.batchClearing]
                            .map(rcFull).filter(Boolean).map(rcEsc).join('<br>') || '-';
                        html += '<tr class="border-b border-gray-100 hover:bg-cyan-50/40">'
                            + '<td class="p-3 text-center">' + (res.canArchive ? '<input type="checkbox" class="cb-comp w-4 h-4 rounded" value="' + rcEsc(r.id) + '" onchange="updateCompSelection()">' : '') + '</td>'
                            + '<td class="p-3 font-black text-blue-700">' + rcEsc(r.noDoc) + '</td>'
                            + '<td class="p-3 text-center"><span class="' + rcStatusClass(r.status) + ' px-2 py-1 rounded text-[10px] font-black uppercase">' + rcEsc(r.status) + '</span></td>'
                            + '<td class="p-3 text-xs"><b>' + rcEsc(r.namaToko) + '</b><br><span class="text-gray-500">' + rcEsc(r.kodeToko) + '</span>'
                            + (r.contactPerson ? '<br><span class="text-gray-400">' + rcEsc(r.contactPerson) + '</span>' : '') + '</td>'
                            + '<td class="p-3 text-xs"><b>' + rcEsc(r.codeCampaign) + '</b><br><span class="text-gray-500">' + rcEsc(r.campaignName) + '</span></td>'
                            + '<td class="p-3 text-center text-xs font-bold">' + rcEsc(r.jenisCb || '-') + '</td>'
                            + '<td class="p-3 text-center text-xs">' + rcEsc(r.subyekPajak || '-') + '</td>'
                            + '<td class="p-3 text-right font-black text-red-600">' + rcMoney(r.cbNet) + '</td>'
                            + '<td class="p-3 text-right font-bold text-orange-700">' + rcMoney(r.grossUpCb) + '</td>'
                            + '<td class="p-3 text-[10px] text-gray-500">' + batches + '</td></tr>';
                    });
                    document.getElementById('compTableBody').innerHTML = html
                        || '<tr><td colspan="10" class="p-8 text-center text-gray-500">Tidak ada data untuk filter ini.</td></tr>';
                    renderRcPager('compPager', offset, (res.rows || []).length, res.total, 'loadCompilation');
                    updateCompSelection();
                } catch (e) { showNotification("Gagal menarik data cashback.", "error"); }
                finally { hideLoadingOverlay(); }
            }

            function toggleAllCompilation(src) {
                document.querySelectorAll('.cb-comp').forEach(c => c.checked = src.checked);
                updateCompSelection();
            }
            function updateCompSelection() {
                let n = document.querySelectorAll('.cb-comp:checked').length;
                let el = document.getElementById('compSelectedCount'); if (el) el.innerText = n;
                setDisabledSafely('btnArchiveComp', n === 0);
            }

            async function archiveCompilationRows() {
                let ids = [];
                document.querySelectorAll('.cb-comp:checked').forEach(c => ids.push(c.value));
                if (ids.length === 0) return;
                let reason = document.getElementById('compArchiveReason').value.trim();
                if (!reason) { showNotification("Alasan pengarsipan wajib diisi.", "error"); return; }
                let confirmed = await showConfirmModal({ title: "Konfirmasi Arsip",
                    message: ids.length + " baris cashback akan diarsipkan dan hilang dari seluruh layar serta laporan.\\n\\nBaris tetap tersimpan dan dapat dikembalikan lewat daftar arsip.",
                    confirmText: "Ya, Arsipkan", danger: true });
                if (!confirmed) return;
                showLoadingOverlay("Mengarsipkan...");
                try {
                    let res = await fetchApp({ action: 'archiveCompilation', ids: ids, reason: reason });
                    if (res.status === 'success') {
                        showNotification(res.jumlah + " baris diarsipkan.", "success");
                        logActivity('Arsip cashback: ' + res.jumlah + ' baris. Alasan: ' + reason);
                        document.getElementById('compArchiveReason').value = '';
                        loadCompilation(rcCompState.offset);
                    } else { showNotification(res.message || "Gagal mengarsipkan.", "error"); }
                } catch (e) { showNotification("Gagal terhubung ke server.", "error"); }
                finally { hideLoadingOverlay(); }
            }

            async function toggleArchivedList() {
                let panel = document.getElementById('compArchivedPanel');
                if (!panel.classList.contains('hidden')) { panel.classList.add('hidden'); return; }
                showLoadingOverlay("Memuat arsip...");
                try {
                    let res = await fetchApp({ action: 'archivedList' });
                    if (res.status !== 'success') { showNotification(res.message || "Gagal memuat arsip.", "error"); return; }
                    let html = '';
                    (res.rows || []).forEach(r => {
                        html += '<tr class="border-b border-gray-100">'
                            + '<td class="p-3 font-bold text-gray-700">' + rcEsc(r.noDoc) + '</td>'
                            + '<td class="p-3 text-xs">' + rcEsc(r.kodeToko) + '</td>'
                            + '<td class="p-3 text-xs">' + rcEsc(r.codeCampaign) + '</td>'
                            + '<td class="p-3 text-right">' + rcMoney(r.cbNet) + '</td>'
                            + '<td class="p-3 text-xs text-gray-600">' + rcEsc(r.alasan) + '</td>'
                            + '<td class="p-3 text-xs">' + rcEsc(r.olehUser) + '<br><span class="text-gray-400">' + rcEsc(r.waktu) + '</span></td>'
                            + '<td class="p-3 text-center"><button onclick="unarchiveCompilationRow(\\'' + rcEsc(r.id) + '\\')" class="px-3 py-1.5 bg-white border border-gray-300 hover:bg-green-50 text-green-700 font-bold rounded-lg text-xs">Kembalikan</button></td></tr>';
                    });
                    document.getElementById('compArchivedBody').innerHTML = html
                        || '<tr><td colspan="7" class="p-6 text-center text-gray-500">Tidak ada baris terarsip.</td></tr>';
                    panel.classList.remove('hidden');
                } catch (e) { showNotification("Gagal memuat arsip.", "error"); }
                finally { hideLoadingOverlay(); }
            }

            async function unarchiveCompilationRow(id) {
                showLoadingOverlay("Mengembalikan...");
                try {
                    let res = await fetchApp({ action: 'unarchiveCompilation', ids: [id] });
                    if (res.status === 'success') {
                        showNotification("Baris dikembalikan.", "success");
                        logActivity('Kembalikan cashback dari arsip');
                        toggleArchivedList(); toggleArchivedList();
                        loadCompilation(rcCompState.offset);
                    } else { showNotification(res.message || "Gagal.", "error"); }
                } catch (e) { showNotification("Gagal terhubung ke server.", "error"); }
                finally { hideLoadingOverlay(); }
            }
`;

// ---------------------------------------------------------------------------------------
// Tambahan 17 September 2026: tab Open pada Claim Upload, matriks permission modul baru
// pada konsol Otorisasi, dan mass upload pada Cashback Compilation.
// ---------------------------------------------------------------------------------------

// Tombol tab ketiga di modul Claim Upload, di samping Mass Upload dan Manual Input.
export const OPEN_TAB_BUTTON =
  '<button onclick="openRcOpenTab()" id="subnav_open" class="px-5 py-2 text-sm font-bold rounded-lg text-gray-500 hover:bg-gray-100 transition">Open</button>';

// Panel tab Open. Ditempatkan sebelum blok preview supaya berada di dalam modul yang sama.
export const OPEN_TAB_PANEL = [
  '                    <div id="tab_open" class="hidden">',
  '                        <div class="flex flex-wrap gap-3 items-center mb-4"><input id="openSearch" placeholder="Cari No Doc, kode atau nama toko" class="flex-1 min-w-[220px] px-4 py-2.5 border border-gray-300 rounded-lg text-sm"><select id="openCampaign" class="min-w-[220px] px-4 py-2.5 border border-gray-300 rounded-lg text-sm"><option value="">-- Semua Campaign --</option></select><button onclick="loadOpenClaims(0)" class="px-5 py-2.5 bg-blue-600 hover:bg-blue-700 text-white font-bold rounded-lg text-sm"><i class="fas fa-search mr-2"></i>Cari</button></div>',
  '                        <div class="flex flex-wrap gap-3 items-center mb-4 p-4 bg-blue-50 border border-blue-200 rounded-xl"><span class="text-sm font-bold text-blue-900"><span id="openSelectedCount">0</span> dokumen dipilih</span><button onclick="openToMassUpload()" id="btnOpenToMass" disabled class="px-5 py-2 bg-blue-600 hover:bg-blue-700 disabled:bg-blue-300 text-white font-bold rounded-lg text-sm"><i class="fas fa-arrow-right mr-2"></i>Pindahkan ke Mass Upload</button><button onclick="openToTemplate()" id="btnOpenToTemplate" disabled class="px-5 py-2 bg-white border border-gray-300 hover:bg-gray-50 disabled:opacity-40 text-gray-700 font-bold rounded-lg text-sm"><i class="fas fa-file-excel mr-2 text-green-600"></i>Unduh sebagai Template</button><span class="text-xs text-blue-800">Field yang sudah ada di Customer Master ikut terbawa; Anda hanya melengkapi yang kosong.</span></div>',
  '                        <div class="overflow-auto border border-gray-200 rounded-xl"><table class="w-full text-sm"><thead class="bg-gray-50 text-gray-600"><tr><th class="p-3 text-center font-bold"><input type="checkbox" id="openSelectAll" onchange="toggleAllOpen(this)" class="w-4 h-4 rounded"></th><th class="p-3 text-left font-bold">No Document</th><th class="p-3 text-left font-bold">Toko</th><th class="p-3 text-left font-bold">Campaign</th><th class="p-3 text-center font-bold">Jenis CB</th><th class="p-3 text-right font-bold">Cashback</th><th class="p-3 text-center font-bold">Kelengkapan</th></tr></thead><tbody id="openTableBody"></tbody></table></div>',
  '                        <div id="openPager" class="mt-4"></div>',
  '                    </div>',
  ''
].join('\n');

// Matriks modul tambahan pada konsol Otorisasi. Modul lama tetap memakai select yang sudah
// ada; yang baru dirender dari katalog server, sehingga modul berikutnya cukup ditambahkan
// di server tanpa mengubah markup lagi.
export const PERMISSION_MATRIX =
  '<div id="editModuleMatrixContainer" class="md:col-span-2 p-5 bg-emerald-50/60 border border-emerald-200 rounded-xl"><h4 class="text-xs font-black text-emerald-800 uppercase border-b border-emerald-200 pb-2.5 mb-4">Modul Tambahan</h4><div id="editModuleMatrix" class="grid grid-cols-1 sm:grid-cols-2 gap-4"></div></div>';

// Mass upload pada Cashback Compilation, mengikuti pola Print Document.
export const COMPILE_UPLOAD_BAR =
  '<div class="flex flex-wrap gap-3 items-center mb-5 p-4 bg-cyan-50 border border-cyan-200 rounded-xl"><span class="font-bold text-cyan-900 text-sm"><i class="fas fa-file-import mr-2"></i>Compile Cashback</span><button onclick="downloadCompileTemplate()" class="px-4 py-2 bg-white border border-gray-300 hover:bg-gray-50 text-gray-700 font-bold rounded-lg text-sm"><i class="fas fa-file-excel mr-2 text-green-600"></i>Template</button><label class="px-4 py-2 bg-white border border-gray-300 hover:bg-gray-50 text-gray-700 font-bold rounded-lg text-sm cursor-pointer"><i class="fas fa-upload mr-2 text-blue-600"></i>Pilih File<input type="file" id="compileFile" accept=".xlsx,.xls" class="hidden" onchange="previewCompileUpload(this)"></label><button onclick="commitCompileUpload()" id="btnCommitCompile" disabled class="px-4 py-2 bg-cyan-600 hover:bg-cyan-700 disabled:bg-cyan-300 text-white font-bold rounded-lg text-sm">Simpan Compile</button><span class="text-xs text-cyan-800">Maksimal 2.000 baris. Jenis CB RA07 atau RA7 langsung berstatus Done.</span></div><div id="compileResult" class="hidden mb-5 p-4 border rounded-xl text-sm"></div>';
