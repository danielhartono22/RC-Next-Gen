            function toggleAllWorkflow(src, cbClass, btnId, countId) { document.querySelectorAll('.' + cbClass).forEach(c => c.checked = src.checked); updateWorkflowCount(cbClass, btnId, countId); }
            function updateWorkflowCount(cbClass, btnId, countId) { let n = document.querySelectorAll('.' + cbClass + ':checked').length; document.getElementById(countId).innerText = n; setDisabledSafely(btnId, n === 0 || (btnId === 'btnSubmitClearing' && !document.getElementById('tglClearingInput').value)); }
            function validateClearingBtn() { let n = document.querySelectorAll('.cb-clr:checked').length; let d = document.getElementById('tglClearingInput').value; setDisabledSafely('btnSubmitClearing', n === 0 || !d); }

            async function fetchWorkflowData() {
                showLoadingOverlay("Memuat Data Operasional...");
                try {
                    let role = currentUserData.sysRole || currentUserData.role || '';
                    let res = await fetchApp({ action: 'getWorkflowData', requesterId: currentUserData.userId, requesterRole: role, managedDepots: currentUserData.managedDepots });
                    if (res.status === 'success') { globalReleaseData = res.releaseData || []; globalClaimFinData = res.claimFinData || []; globalClearingData = res.clearingData || []; globalBulkRebateData = res.bulkRebateData || []; popWorkflowFilters(); renderWorkflowTable('release'); renderWorkflowTable('claim'); renderWorkflowTable('clearing'); renderBulkTable(); }
                } catch (e) { showNotification("Gagal memuat data operasi dari server.", "error"); } finally { hideLoadingOverlay(); }
            }

            function popWorkflowFilters() {
                let dR = new Set(), cR = new Set(), dC = new Set(), cC = new Set(), dCl = new Set(), cCl = new Set();
                globalReleaseData.forEach(r => { dR.add(r.depot); cR.add(r.codeCampaign + " - " + r.campaignName); }); 
                globalClaimFinData.forEach(r => { dC.add(r.depot); cC.add(r.codeCampaign + " - " + r.campaignName); }); 
                globalClearingData.forEach(c => { dCl.add(c.depot); cCl.add(c.codeCampaign + " - " + c.campaignName); });
                if (document.getElementById('relDepotDropdown')) document.getElementById('relDepotDropdown').innerHTML = buildMultiselectHTML(Array.from(dR).map(x => ({ label: x, value: x })), true, 'relDepotDropdown', "renderWorkflowTable('release')");
                if (document.getElementById('relCampDropdown')) document.getElementById('relCampDropdown').innerHTML = buildMultiselectHTML(Array.from(cR).map(x => ({ label: x, value: x })), true, 'relCampDropdown', "renderWorkflowTable('release')");
                if (document.getElementById('cfDepotDropdown')) document.getElementById('cfDepotDropdown').innerHTML = buildMultiselectHTML(Array.from(dC).map(x => ({ label: x, value: x })), true, 'cfDepotDropdown', "renderWorkflowTable('claim')");
                if (document.getElementById('cfCampDropdown')) document.getElementById('cfCampDropdown').innerHTML = buildMultiselectHTML(Array.from(cC).map(x => ({ label: x, value: x })), true, 'cfCampDropdown', "renderWorkflowTable('claim')");
                if (document.getElementById('clrDepotDropdown')) document.getElementById('clrDepotDropdown').innerHTML = buildMultiselectHTML(Array.from(dCl).map(x => ({ label: x, value: x })), true, 'clrDepotDropdown', "renderWorkflowTable('clearing')");
                if (document.getElementById('clrCampDropdown')) document.getElementById('clrCampDropdown').innerHTML = buildMultiselectHTML(Array.from(cCl).map(x => ({ label: x, value: x })), true, 'clrCampDropdown', "renderWorkflowTable('clearing')");

                let dB = new Set(), cB = new Set();
                globalBulkRebateData.forEach(r => { dB.add(r.depot); cB.add(r.codeCampaign + " - " + r.campaignName); });
                if (document.getElementById('bulkDepotDropdown')) document.getElementById('bulkDepotDropdown').innerHTML = buildMultiselectHTML(Array.from(dB).map(x => ({ label: x, value: x })), true, 'bulkDepotDropdown', "renderBulkTable()");
                if (document.getElementById('bulkCampDropdown')) document.getElementById('bulkCampDropdown').innerHTML = buildMultiselectHTML(Array.from(cB).map(x => ({ label: x, value: x })), true, 'bulkCampDropdown', "renderBulkTable()");

                // Filter Depot pada Claim to Finance dan Clearing memakai wadah yang selalu
                // hidden di markup dan tidak pernah dibuka. Sama seperti di Analytics, filternya
                // terisi tetapi tidak terlihat. Dibuka hanya ketika antreannya memang memuat
                // lebih dari satu depot; bagi pengguna satu depot filter itu tidak ada gunanya.
                setHiddenSafely('cfFilterDepotContainer', dC.size < 2);
                setHiddenSafely('clrFilterDepotContainer', dCl.size < 2);
                setHiddenSafely('relFilterDepotContainer', dR.size < 2);
            }

            function renderBulkTable() {
                let sv = (document.getElementById('bulkSearch')?.value || "").toLowerCase();
                let sd = checkMultiSelect('bulkDepotDropdown') ? checkMultiSelect('bulkDepotDropdown').split(', ') : [];
                let sc = checkMultiSelect('bulkCampDropdown') ? checkMultiSelect('bulkCampDropdown').split(', ') : [];
                let stFilter = document.getElementById('bulkFilterStage')?.value || 'ALL';

                let filtered = globalBulkRebateData.filter(r => {
                    let matchSearch = !sv || Object.values(r).some(val => val !== null && String(val).toLowerCase().includes(sv));
                    let matchDepot = (sd.length === 0 || sd.includes(r.depot));
                    let matchCamp = (sc.length === 0 || sc.includes(r.codeCampaign + " - " + r.campaignName));
                    let matchStage = stFilter === 'ALL' || r.status === stFilter;
                    return matchSearch && matchDepot && matchCamp && matchStage;
                });

                let distinctTokoCount = new Set(filtered.map(r => r.kodeToko).filter(Boolean)).size;
                let totalCbSum = filtered.reduce((sum, r) => sum + (Number(r.cbNet) || 0), 0);
                rcIsiKartuAngka('bulkTotToko', distinctTokoCount.toLocaleString('id-ID'));
                rcIsiKartuAngka('bulkTotCB', rcNominalRingkas(totalCbSum), rcNominalPenuh(totalCbSum));

                let stageBadgeCls = {};
                let rowsHtml = filtered.map(r => `<tr class="hover:bg-pink-50 border-b transition-colors"><td class="p-3.5 text-center"><input type="checkbox" value="${r.noDoc}" class="cb-bulk w-4 h-4 rounded text-pink-600 focus:ring-pink-500" onchange="updateWorkflowCount('cb-bulk', 'btnSubmitBulk', 'bulkSelectedCount')"></td><td class="p-3.5 text-center"><span class="${rcStatusClass(r.status)} text-[10px] font-black px-2 py-1 rounded uppercase">${r.status}</span></td><td class="p-3.5 font-black text-blue-700">${r.noDoc}</td><td class="p-3.5"><span class="font-bold block text-gray-800">${r.namaToko}</span><span class="text-[10px] text-gray-500 bg-gray-100 px-1.5 py-0.5 rounded">${r.kodeToko}</span></td><td class="p-3.5"><span class="text-[10px] text-gray-500 block uppercase font-bold">${r.codeCampaign}</span><span class="text-sm font-medium whitespace-normal" title="${r.campaignName}">${r.campaignName}</span></td><td class="p-3.5 text-right font-black text-red-600">Rp ${Math.trunc(Number(Number(r.cbNet))||0).toLocaleString('id-ID')}</td></tr>`).join('');
                document.getElementById('bulkTableBody').innerHTML = rowsHtml;
                updateWorkflowCount('cb-bulk', 'btnSubmitBulk', 'bulkSelectedCount');
            }

            async function submitBulkProcess() {
                let docs = []; document.querySelectorAll('.cb-bulk:checked').forEach(c => docs.push(c.value)); if (docs.length === 0) return;
                let confirmedBulk = await showConfirmModal({ title: "Konfirmasi Bulk Process", message: `Yakin ingin memproses ${docs.length} dokumen langsung ke status "Done"? Tahap Bulk Process dicatat sebelum Done. Hanya Rebate yang sudah Approved dapat diproses.`, confirmText: "Ya, Proses", danger: true });
                if (!confirmedBulk) return;

                setDisabledSafely('btnSubmitBulk', true); showLoadingOverlay(`Memproses Bulk Process ke Done...`);
                try {
                    let res = await fetchApp({ action: 'bulkFastTrackRelease', docsToProcess: docs, userData: currentUserData });
                    if (res.status === 'success') {
                        let batchNum = res.summary?.batchNum || null;
                        let succDocs = res.summary?.successfulDocs || [];
                        let succRows = globalBulkRebateData.filter(d => succDocs.includes(d.noDoc));
                        let successDetails = succRows.map(d => ({ noDoc: d.noDoc, kodeCamp: d.codeCampaign, namaCamp: d.campaignName, kodeToko: d.kodeToko, namaToko: d.namaToko, reward: d.cbNet, grossUp: d.grossUpCb || 0 }));
                        logActivity(`Bulk Process (Rebate->Done): ${docs.length} dokumen diproses. No Batch: ${batchNum || '-'}`);
                        showActionResult(`Laporan Bulk Process`, successDetails, [], 'approve', batchNum);
                        if (succRows.length > 0) downloadBulkProcessExcel(succRows);
                        fetchWorkflowData();
                    } else { showNotification(res.message || "Gagal memproses.", "error"); }
                } catch (e) { showNotification("Terjadi kesalahan saat memproses Bulk Process.", "error"); fetchWorkflowData(); }
                finally { hideLoadingOverlay(); }
            }

            // Kartu "Process by", menggantikan kartu Nilai Tagihan atas permintaan pemilik.
            //
            // Nilai tagihan sudah tampil sebagai kolom tersendiri pada barisnya, sementara siapa
            // yang mengerjakan tiap tahap sebelumnya tidak terlihat di mana pun - padahal itulah
            // yang dicari ketika sebuah dokumen dipertanyakan.
            //
            // Tahap yang tidak tercatat pelakunya ditulis sebagai tanda hubung. Sebagian besar
            // dokumen warisan memang dipindahkan dari spreadsheet lama lewat import_snapshot
            // tanpa keterangan pelaku, dan menebak nama di kolom "siapa yang mengerjakan" jauh
            // lebih berbahaya daripada mengakui bahwa catatannya tidak ada.
            function kartuPelaku(r) {
                const tahap = [
                    ['Submitted', r.submittedBy, r.tglUpload],
                    // Tahap persetujuan berada di antara Submitted dan Released sejak modul
                    // Management of Approval ada, dan urutannya di sini mengikuti urutan
                    // sebenarnya - kartu ini dibaca sebagai jejak, jadi melompati satu tahap
                    // akan membuat dokumen tampak berpindah sendiri.
                    ['Approved', r.approvedBy, r.tglApprove],
                    ['Released', r.releasedBy, r.tglRelease],
                    ['Claimed', r.claimedBy, r.tglClaim]
                ];
                const isi = tahap.map(function (t) {
                    const nama = String(t[1] || '').trim();
                    const tgl = String(t[2] || '').trim();
                    return '<span class="block text-[11px] leading-snug truncate" title="'
                        + rcEsc(t[0] + ': ' + (nama || 'tidak tercatat') + (tgl && tgl !== '-' ? ' - ' + tgl : '')) + '">'
                        + '<span class="text-gray-400 font-bold">' + t[0] + '</span> '
                        + (nama
                            ? '<span class="font-black text-gray-800">' + rcEsc(nama) + '</span>'
                            : '<span class="text-gray-300 font-bold">-</span>')
                        + '</span>';
                }).join('');
                const dibuat = String(r.createdBy || '').trim();
                return isi + '<span class="block text-[10px] text-gray-400 mt-1 border-t border-gray-100 pt-1 truncate">'
                    + 'Dibuat: ' + (dibuat ? rcEsc(dibuat) : '-') + '</span>';
            }

            // Mass process pada tab Clearing.
            //
            // Yang dilakukannya hanyalah MENCENTANG baris yang cocok, bukan memposting sendiri.
            // Itu disengaja: Clearing menuntut Tgl Clearing aktual dan memiliki pemeriksaan
            // tersendiri, dan menambah jalur posting kedua berarti aturan itu harus dipelihara
            // di dua tempat - cepat atau lambat keduanya akan berbeda. Dengan cara ini tombol
            // Posting Done tetap satu-satunya pintu.
            //
            // Dokumen yang tidak ditemukan tidak didiamkan. Sebuah No Document dapat salah
            // ketik, sudah diproses orang lain, atau berada di depot lain - ketiganya terlihat
            // sama bila daftarnya hanya dicentang sebagian tanpa keterangan.
            function clearingTandaiDariDaftar() {
                const teks = (document.getElementById('clrMassDocs') || {}).value || '';
                const diminta = teks.split(/[\r\n,;\t]+/)
                    .map(x => x.trim().toUpperCase()).filter(x => x !== '');
                const ringkas = document.getElementById('clrMassRingkas');
                if (diminta.length === 0) {
                    if (ringkas) ringkas.innerText = 'Belum ada No Document yang ditempel.';
                    return;
                }

                // Baris yang sedang tampil saja. Bila hasil filter menyembunyikan sebuah dokumen,
                // mencentangnya diam-diam akan memposting sesuatu yang tidak terlihat di layar.
                const kotak = Array.from(document.querySelectorAll('.cb-clr'));
                const adaDiLayar = new Set(kotak.map(c => String(c.value).trim().toUpperCase()));
                const unik = Array.from(new Set(diminta));
                const ketemu = unik.filter(d => adaDiLayar.has(d));
                const tidak = unik.filter(d => !adaDiLayar.has(d));

                kotak.forEach(c => { c.checked = ketemu.indexOf(String(c.value).trim().toUpperCase()) > -1; });
                updateWorkflowCount('cb-clr', 'btnSubmitClearing', 'clearingSelectedCount');
                validateClearingBtn();

                if (ringkas) {
                    ringkas.innerHTML = '<b class="text-emerald-700">' + ketemu.length + '</b> dari '
                        + unik.length + ' No Document tercentang.'
                        + (tidak.length > 0
                            ? ' <b class="text-red-600">' + tidak.length + ' tidak ada di daftar Clearing</b> '
                              + '(salah ketik, sudah diproses, di luar yurisdiksi Anda, '
                              + 'atau tersembunyi oleh filter yang sedang aktif).'
                            : '');
                }
                if (tidak.length > 0) {
                    rcDialog('No Document yang tidak ditemukan di Clearing',
                        '<p class="text-sm text-gray-600 mb-3">Dokumen berikut tidak ada pada daftar Clearing yang '
                        + 'sedang tampil. Periksa ejaannya, atau bersihkan filter lebih dulu.</p>'
                        + '<div class="max-h-72 overflow-auto border border-gray-200 rounded-lg">'
                        + '<table class="w-full text-sm"><tbody>'
                        + tidak.map(d => '<tr class="border-b border-gray-100"><td class="p-2 font-mono text-red-700">'
                            + rcEsc(d) + '</td></tr>').join('')
                        + '</tbody></table></div>');
                }
            }

            function clearingBersihkanDaftar() {
                const t = document.getElementById('clrMassDocs'); if (t) t.value = '';
                const r = document.getElementById('clrMassRingkas'); if (r) r.innerText = '';
                document.querySelectorAll('.cb-clr').forEach(c => { c.checked = false; });
                const semua = document.getElementById('cbClearingAll'); if (semua) semua.checked = false;
                updateWorkflowCount('cb-clr', 'btnSubmitClearing', 'clearingSelectedCount');
                validateClearingBtn();
            }

            function renderWorkflowTable(type) {
                let data = [], searchId = '', depotDrop = '', campDrop = '', bodyId = '', cbCls = '', countId = '', btnId = '', tglCol = '';
                if (type === 'release') { data = globalReleaseData; searchId = 'relSearch'; depotDrop = 'relDepotDropdown'; campDrop = 'relCampDropdown'; bodyId = 'releaseTableBody'; cbCls = 'cb-rel'; countId = 'releaseSelectedCount'; btnId = 'btnSubmitRelease'; tglCol = 'tglUpload'; }
                else if (type === 'claim') { data = globalClaimFinData; searchId = 'cfSearch'; depotDrop = 'cfDepotDropdown'; campDrop = 'cfCampDropdown'; bodyId = 'claimFinTableBody'; cbCls = 'cb-claim'; countId = 'claimSelectedCount'; btnId = 'btnSubmitClaim'; tglCol = 'tglRelease'; }
                else if (type === 'clearing') { data = globalClearingData; searchId = 'clrSearch'; depotDrop = 'clrDepotDropdown'; campDrop = 'clrCampDropdown'; bodyId = 'clearingTableBody'; cbCls = 'cb-clr'; countId = 'clearingSelectedCount'; btnId = 'btnSubmitClearing'; tglCol = 'tglClaim'; }

                let sv = (document.getElementById(searchId)?.value || "").toLowerCase(); 
                let sd = checkMultiSelect(depotDrop) ? checkMultiSelect(depotDrop).split(', ') : []; 
                let sc = checkMultiSelect(campDrop) ? checkMultiSelect(campDrop).split(', ') : [];
                let fp = 'ALL';
                if (type === 'clearing') fp = document.getElementById('clrFilterPajak')?.value || 'ALL';
                if (type === 'claim') fp = document.getElementById('cfFilterPajak')?.value || 'ALL';

                let filtered = data.filter(r => {
                    let pBatch = '-';
                    if (type === 'release') pBatch = r.batchUpload || '-';
                    else if (type === 'claim') pBatch = r.batchRelease || '-';
                    else if (type === 'clearing') pBatch = r.batchClaim || '-';

                    let cstLocal = globalCustomers.find(c => c.custCode === r.kodeToko) || {};
                    let matchSearch = !sv || Object.values(r).some(val => val !== null && String(val).toLowerCase().includes(sv)) || pBatch.toLowerCase().includes(sv);
                    let matchDepot = (sd.length === 0 || sd.includes(r.depot));
                    let matchCamp = (sc.length === 0 || sc.includes(r.codeCampaign + " - " + r.campaignName));
                    // Dicocokkan lewat kunci hasil rcKunciPajak(). Versi sebelumnya mencari
                    // substring "ditanggung perusahaan" / "ditanggung customer" pada teks mentah
                    // master campaign, padahal tidak satu pun nilai di master memuat kata itu -
                    // kedua pilihan filter selalu menghasilkan tabel kosong.
                    let matchPajak = fp === 'ALL' || rcKunciPajak(r.statusPajakCamp) === fp;
                    const prefix=type==='release'?'rel':type==='claim'?'cf':'clr';
                    const cb=document.getElementById(prefix+'CbType')?.value||'';
                    const year=document.getElementById(prefix+'CampaignYear')?.value||'';
                    if((cb&&rcCbLabel(r.jenisCb)!==cb)||(year&&String(r.campaignYear)!==year))return false;
                    return matchSearch && matchDepot && matchCamp && matchPajak;
                });

                let tb = document.getElementById(bodyId); let rowsHtml = '';

                // Qty Toko, Total Cashback, & Total CB Gross Up (mengikuti hasil filter yang sedang aktif di layar)
                let totTokoElId = type === 'release' ? 'relTotToko' : (type === 'claim' ? 'cfTotToko' : 'clrTotToko');
                let totCbElId = type === 'release' ? 'relTotCB' : (type === 'claim' ? 'cfTotCB' : 'clrTotCB');
                let totGrossUpElId = type === 'claim' ? 'cfTotGrossUp' : (type === 'clearing' ? 'clrTotGrossUp' : null);
                let distinctTokoCount = new Set(filtered.map(r => r.kodeToko).filter(Boolean)).size;
                let totalCbSum = filtered.reduce((sum, r) => sum + (Number(r.cbNet) || 0), 0);
                let totalGrossUpSum = filtered.reduce((sum, r) => sum + (Number(r.grossUpCb) || 0), 0);
                // Judulnya kini ada di kartu, jadi yang ditulis hanya nilainya. Nominal panjang
                // dipendekkan supaya tidak melewati lebar kartu; angka persisnya tetap terbaca
                // saat disorot lewat atribut title.
                rcIsiKartuAngka(totTokoElId, distinctTokoCount.toLocaleString('id-ID'));
                rcIsiKartuAngka(totCbElId, rcNominalRingkas(totalCbSum), rcNominalPenuh(totalCbSum));
                if (totGrossUpElId) rcIsiKartuAngka(totGrossUpElId, rcNominalRingkas(totalGrossUpSum), rcNominalPenuh(totalGrossUpSum));

                filtered.forEach(r => { 
                    let pBatch = '-';
                    if (type === 'release') pBatch = r.batchUpload || '-';
                    else if (type === 'claim') pBatch = r.batchRelease || '-';
                    else if (type === 'clearing') pBatch = r.batchClaim || '-';

                    let cst = globalCustomers.find(c => c.custCode === r.kodeToko) || {};
                    let doc = globalDocuments.find(d => String(d.noDoc).toUpperCase() === String(r.noDoc).toUpperCase()) || {};
                    
                    let valKtp = cst.ktp || r.ktp || '-'; let valNpwp = cst.npwp || r.npwp || '-'; let valTop = doc.top || r.top || '-'; let valLunas = doc.tglLunas || r.tglLunas || '-';
                    let valRek = cst.noRek || r.noRekening || '-'; let valNamaRek = cst.namaRek || r.pemilikRekening || '-'; let valBank = cst.bank || r.bankCust || '-';
                    
                    let valVolume = doc.volume || 0; let valNetValue = doc.netValue || 0;
                    // Label seragam; penulisan berbeda di master tidak lagi tampil sebagai dua
                    // status yang seolah berlainan.
                    let valStatusPajak = rcLabelPajak(r.statusPajakCamp);
                    // Diturunkan dari KTP/NPWP yang berlaku sekarang. Kolom tax_subject yang
                    // tersimpan saat upload dapat tertinggal ketika identitas toko diperbarui.
                    let valSubyekPajak = rcSubyekPajak(valKtp === '-' ? '' : valKtp, valNpwp === '-' ? '' : valNpwp)
                                         || r.statusPajakCust || '-';

                    rowsHtml += `<tr class="hover:bg-blue-50 border-b transition-colors"><td class="p-3.5 text-center"><input type="checkbox" value="${r.noDoc}" class="${cbCls} w-4 h-4 rounded text-blue-600 focus:ring-blue-500" onchange="updateWorkflowCount('${cbCls}', '${btnId}', '${countId}')"></td><td class="p-3.5 text-[10px] font-black text-gray-600 bg-gray-50/50 uppercase">${pBatch}</td><td class="p-3.5 text-xs text-gray-500 font-medium">${r[tglCol]}</td><td class="p-3.5 font-black text-blue-700">${r.noDoc}</td><td class="p-3.5"><span class="font-bold block text-gray-800">${r.namaToko}</span><span class="text-[10px] text-gray-500 bg-gray-100 px-1.5 py-0.5 rounded">${r.kodeToko}</span></td><td class="p-3.5"><span class="text-[10px] text-gray-500 block uppercase font-bold">${r.codeCampaign}</span><span class="text-sm font-medium whitespace-normal" title="${r.campaignName}">${r.campaignName}</span></td><td class="p-3.5 text-right font-black text-red-600">Rp ${Math.trunc(Number(Number(r.cbNet))||0).toLocaleString('id-ID')}</td><td class="p-3.5 text-xs rc-wrap">${rcEsc(rcCbLabel(r.jenisCb))}</td>${type!=='release'?'<td class="p-3.5 text-right text-orange-700 font-bold">'+rcMoney(r.grossUpCb)+'</td>':''}<td class="p-3.5 text-center"><button onclick="toggleWorkflowDetails('det-${type}-${r.noDoc}')" class="bg-blue-50 hover:bg-blue-100 text-blue-600 font-bold px-3 py-1.5 rounded-lg text-[10px] uppercase shadow-sm transition"><i class="fas fa-eye mr-1"></i> Details</button></td></tr><tr id="det-${type}-${r.noDoc}" class="hidden expanded-details"><td colspan="${type==='release'?9:10}" class="p-4 bg-gray-50"><div class="grid grid-cols-2 md:grid-cols-4 gap-4 text-xs"><div class="bg-white p-3 rounded-lg shadow-sm border border-gray-200"><span class="font-bold text-gray-500 block mb-1 uppercase text-[9px]"><i class="fas fa-id-card mr-1"></i> Identitas & Pajak</span> <span class="font-bold text-gray-800 block text-xs truncate">KTP: ${valKtp} | NPWP: ${valNpwp}</span><span class="font-bold text-gray-800 block text-xs truncate">Sbyk: ${valSubyekPajak} | Stat: ${valStatusPajak}</span></div><div class="bg-white p-3 rounded-lg shadow-sm border border-gray-200"><span class="font-bold text-gray-500 block mb-1 uppercase text-[9px]"><i class="fas fa-money-check-alt mr-1"></i> Rekening</span> <span class="font-bold text-gray-800 block text-xs truncate">${valRek}</span><span class="font-bold text-gray-800 block text-xs truncate">${valNamaRek} (${valBank})</span></div><div class="bg-white p-3 rounded-lg shadow-sm border border-gray-200"><span class="font-bold text-gray-500 block mb-1 uppercase text-[9px]"><i class="fas fa-box mr-1"></i> Data Campaign</span> <span class="font-bold text-gray-800 block text-xs truncate">Vol: ${valVolume} | Val: Rp ${Math.trunc(Number(Number(valNetValue))||0).toLocaleString('id-ID')}</span><span class="font-bold text-gray-800 block text-xs truncate">TOP: ${valTop} Hr | Lns: ${valLunas}</span></div><div class="bg-white p-3 rounded-lg shadow-sm border border-gray-200"><span class="font-bold text-gray-500 block mb-1 uppercase text-[9px]"><i class="fas fa-user-check mr-1"></i> Process by</span>${kartuPelaku(r)}</div>${rcDetailCard('Remark',r.remark)}</div></td></tr>`; 
                });
                tb.innerHTML = rowsHtml; updateWorkflowCount(cbCls, btnId, countId);
            }

            // Fungsi pembersih angka - dipakai bersama oleh seluruh fitur export Excel (Claim to Finance & Bulk Process)
            // supaya format angka string (Rp/titik ribuan/koma desimal) selalu diparse konsisten.
            let parseSafeNumber = (val) => {
                if (typeof val === 'number') return val;
                if (!val) return 0;
                let str = String(val).trim();
                str = str.replace(/\./g, '').replace(',', '.');
                return parseFloat(str) || 0;
            };

            // Mesin Kalkulasi Gross Up di Frontend - dipakai bersama oleh seluruh fitur export Excel supaya nilai
            // "Before Tax" selalu 100% akurat meskipun database lama di Google Sheet masih nyangkut/salah.
            let calcGrossUp = (netCB, subyek, statusCamp) => {
                let net = Number(netCB) || 0;
                if (net <= 0) return 0;
                // Memakai penafsiran yang sama dengan filter dan tampilan kolom, sehingga tidak
                // mungkin lagi sebuah campaign terlihat "Ditanggung Perusahaan" di layar tetapi
                // diperlakukan sebagai ditanggung customer saat menghitung gross up.
                let kunciPajak = rcKunciPajak(statusCamp);
                // Ditanggung Perusahaan: toko menerima net penuh tanpa potongan pajak, sehingga
                // nilai "Before Tax" yang perlu ditagihkan ke toko = 0. Rebate Non Tax pun tidak
                // dikenai pajak sama sekali, jadi diperlakukan sama.
                if (kunciPajak === 'perusahaan' || kunciPajak === 'nonTax') return 0;

                let sp = String(subyek || '').trim().toLowerCase();
                // Flat 15% Badan
                if (sp === 'badan') return net / 0.85;

                // Progresif Pribadi / Perorangan
                if (net <= 57000000) return net / 0.95;
                if (net <= 218500000) return 60000000 + ((net - 57000000) / 0.85);
                if (net <= 406000000) return 250000000 + ((net - 218500000) / 0.75);
                if (net <= 3556000000) return 500000000 + ((net - 406000000) / 0.70);
                return 5000000000 + ((net - 3556000000) / 0.65);
            };

           // Excel otomatis saat "Posting Claim" berhasil - kolom lookup dari sheet Compile, diurutkan ascending berdasarkan Jenis CB.
            function downloadClaimToFinanceExcel(rows) {
                if (!rows || rows.length === 0) return;
                let sorted = rows.slice().sort((a, b) => String(a.jenisCb || '').localeCompare(String(b.jenisCb || '')));
                // Dua kolom tambahan atas permintaan pemilik: jumlah digit No Rek tepat setelah
                // No Rek, dan Contact Person di kolom terakhir.
                let header = ["No", "No Doc", "Kode DC", "Depot Name", "Campaign Code", "Periode Campaign Start", "Periode Campaign End", "Campaign Name", "Cust Code", "Cust Name", "Net CB", "Gross Up CB (Before Tax)", "No KTP", "NPWP", "Digit KTP/NPWP", "Subyek Pajak", "Status Pajak", "Jenis CB", "No Rek", "Digit No Rek", "Nama Pemilik Rekening", "Bank", "Contact Person"];
                let aoa = [header];

                // Ubah tanggal dd-MM-yyyy / yyyy-MM-dd / dll menjadi dd-MMM-yyyy (contoh: 15-Apr-2026).
                let monthNamesID = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
                let toDDMMMYYYY = (val) => {
                    let str = String(val || '').trim();
                    if (!str || str === '-') return '';
                    let m = str.match(/^(\d{1,2})[\/\-](\d{1,2})[\/\-](\d{4})$/); // dd-MM-yyyy
                    if (m) { let mm = parseInt(m[2], 10); if (mm >= 1 && mm <= 12) return m[1].padStart(2, '0') + '-' + monthNamesID[mm - 1] + '-' + m[3]; }
                    if (/^\d{1,2}-[A-Za-z]{3}-\d{4}$/.test(str)) return str; // sudah dd-MMM-yyyy
                    let d = new Date(str);
                    return isNaN(d.getTime()) ? str : String(d.getDate()).padStart(2, '0') + '-' + monthNamesID[d.getMonth()] + '-' + d.getFullYear();
                };

                sorted.forEach((r, i) => {
                    // Lookup fallback: sebagian data lama di sheet Compile per-baris bisa kosong (periode,
                    // KTP/NPWP, subyek/status pajak) - kalau kosong, ambil dari master ListCust/ListCampaign
                    // yang selalu terisi & terbaru, supaya nilai di Excel tidak pernah kosong/salah hitung.
                    let cst = globalCustomers.find(c => c.custCode === r.kodeToko) || {};
                    let cmp = globalCampaigns.find(c => c.codeCampaign === r.codeCampaign) || {};

                    let ktpVal = String(r.ktp || cst.ktp || '').trim();
                    let npwpVal = String(r.npwp || cst.npwp || '').trim();
                    let noRekVal = String(r.noRekening || cst.noRek || '').trim();
                    let namaRekVal = String(r.namaRekening || cst.namaRek || '').trim();
                    let bankVal = String(r.bank || cst.bank || '').trim();
                    // Diturunkan dari identitas yang berlaku sekarang, sama seperti di layar,
                    // supaya nilai di berkas tidak pernah berbeda dari yang dilihat pengguna.
                    let subyekVal = rcSubyekPajak(ktpVal, npwpVal)
                                    || String(r.statusPajakCust || cst.subyekPajak || '').trim();
                    let pajakMentah = String(r.statusPajakCamp || cmp.statusPajak || '').trim();
                    let statusPajakCampVal = rcTeksPajak(pajakMentah);
                    let periodeStartVal = toDDMMMYYYY((r.periodeStart && r.periodeStart !== '-') ? r.periodeStart : cmp.periodStart);
                    let periodeEndVal = toDDMMMYYYY((r.periodeEnd && r.periodeEnd !== '-') ? r.periodeEnd : cmp.periodEnd);
                    let idForDigit = ktpVal || npwpVal;
                    let digitCount = idForDigit.replace(/\D/g, '').length;

                    let validNet = parseSafeNumber(r.cbNet);

                    // Dihitung dari teks mentahnya; rcKunciPajak menafsirkan keduanya sama, dan
                    // memakai yang mentah menjaga perhitungan tetap benar seandainya daftar
                    // label berubah kemudian.
                    let validGrossUp = calcGrossUp(validNet, subyekVal, pajakMentah);
                    let digitRek = noRekVal.replace(/\D/g, '').length;
                    let kontakVal = String(r.contactPerson || cst.contactPerson || '').trim();

                    aoa.push([
                        i + 1, r.noDoc, r.kodeDepot, r.depot, r.codeCampaign,
                        periodeStartVal, periodeEndVal, r.campaignName,
                        r.kodeToko, r.namaToko,
                        Math.trunc(validNet),
                        Math.trunc(validGrossUp),   // <-- Menggunakan hasil kalkulasi bersih!
                        ktpVal, npwpVal,
                        digitCount, subyekVal, statusPajakCampVal, r.jenisCb || '',
                        noRekVal, digitRek, namaRekVal, bankVal, kontakVal
                    ]);
                });

                const ws = XLSX.utils.aoa_to_sheet(aoa);
                // Format No KTP, NPWP, dan No Rek agar leading zero tidak hilang
                for (let rowNum = 2; rowNum <= aoa.length; rowNum++) {
                    ['M', 'N', 'S'].forEach(col => { let ref = col + rowNum; if (ws[ref]) ws[ref].z = '@'; });
                }
                
                const wb = XLSX.utils.book_new();
                XLSX.utils.book_append_sheet(wb, ws, "Claim to Finance");
                
                let now = new Date();
                let dd = String(now.getDate()).padStart(2, '0'); let mm = String(now.getMonth() + 1).padStart(2, '0'); let yyyy = now.getFullYear();
                let hh = String(now.getHours()).padStart(2, '0'); let mi = String(now.getMinutes()).padStart(2, '0');
                XLSX.writeFile(wb, `Claim_to_Finance_${dd}${mm}${yyyy}_${hh}${mi}.xlsx`);
            }

            // Excel otomatis saat "Bulk Process" (Rebate -> Done) berhasil - hanya field yang diminta Finance:
            // Code Campaign, Sales Org (selalu kosong), Code Cust, DC, CB After Tax (Net), CB Before Tax (Gross Up).
            // CB Before Tax dihitung ulang di frontend (calcGrossUp) supaya akurat walau nilai Gross Up di sheet nyangkut/salah.
            function downloadBulkProcessExcel(rows) {
                if (!rows || rows.length === 0) return;
                let header = ["Code Campaign", "Sales Org", "Code Cust", "DC", "CB After Tax", "CB Before Tax"];
                let aoa = [header];
                rows.forEach(r => {
                    let netCB = parseSafeNumber(r.cbNet);
                    let grossUp = calcGrossUp(netCB, r.statusPajakCust, r.statusPajakCamp);
                    aoa.push([r.codeCampaign || '', '', r.kodeToko || '', r.kodeDepot || '', Math.trunc(netCB), Math.trunc(grossUp)]);
                });

                const ws = XLSX.utils.aoa_to_sheet(aoa);
                for (let rowNum = 2; rowNum <= aoa.length; rowNum++) {
                    ['E', 'F'].forEach(col => { let ref = col + rowNum; if (ws[ref]) ws[ref].z = XLSX_FMT_ACCOUNTING_RP; });
                }

                const wb = XLSX.utils.book_new();
                XLSX.utils.book_append_sheet(wb, ws, "Bulk Process");

                let now = new Date();
                let dd = String(now.getDate()).padStart(2, '0'); let mm = String(now.getMonth() + 1).padStart(2, '0'); let yyyy = now.getFullYear();
                let hh = String(now.getHours()).padStart(2, '0'); let mi = String(now.getMinutes()).padStart(2, '0');
                XLSX.writeFile(wb, `Bulk_Process_${dd}${mm}${yyyy}_${hh}${mi}.xlsx`);
            }

            async function submitWorkflow(type, cbCls, btnId, actionType = 'approve') {
                let docs = []; document.querySelectorAll('.' + cbCls + ':checked').forEach(c => docs.push(c.value)); if (docs.length === 0) return;
                if (actionType === 'expired') {
                    let confirmedExpire = await showConfirmModal({ title: "Konfirmasi Expired", message: `Yakin ingin menandai ${docs.length} dokumen sebagai EXPIRED? Aksi ini bersifat permanen dan tidak bisa dibatalkan/dikembalikan.`, confirmText: "Ya, Expired-kan", danger: true });
                    if (!confirmedExpire) return;
                }
                setDisabledSafely(btnId, true); showLoadingOverlay(actionType === 'reject' ? `Membatalkan / Reject Data...` : (actionType === 'expired' ? `Menandai Expired...` : `Memproses Tahap ${type.toUpperCase()}...`));
                let tglProses = ""; if (type === 'clearing' && actionType === 'approve') { let dt = document.getElementById('tglClearingInput').value; if (dt) { let pts = dt.split('-'); tglProses = pts[2] + '-' + pts[1] + '-' + pts[0]; } }
                let stageCode = '00', dataSource = [];
                if (type === 'release') { stageCode = '02'; dataSource = globalReleaseData; } else if (type === 'claim') { stageCode = '03'; dataSource = globalClaimFinData; } else if (type === 'clearing') { stageCode = '04'; dataSource = globalClearingData; }
                
                // Hapus batchMapping lokal dan langsung eksekusi try
                try {
                    // Kirim request tanpa menyertakan batchMapping
                    let res = await fetchApp({ action: 'processWorkflow', docsToProcess: docs, workflowType: type, actionType: actionType, tglProses: tglProses, userData: currentUserData });
                    
                    if (res.status === 'success') { 
                        // Ambil batchNum langsung dari summary backend
                        let batchNum = res.summary?.batchNum || null; 
                        let batchMsg = actionType === 'approve' && batchNum ? `. No Batch: ${batchNum}` : '';
                        let succDocs = res.summary?.successfulDocs || [];
                        let successDetails = dataSource.filter(d => succDocs.includes(d.noDoc)).map(d => {
                            let pBatch = '-'; if (type === 'release') pBatch = d.batchUpload; else if (type === 'claim') pBatch = d.batchRelease; else if (type === 'clearing') pBatch = d.batchClaim;
                            return { noDoc: d.noDoc, kodeCamp: d.codeCampaign, namaCamp: d.campaignName, kodeToko: d.kodeToko, namaToko: d.namaToko, reward: d.cbNet, grossUp: d.grossUpCb || 0, prevBatch: pBatch || '-' };
                        });
                        logActivity(`Workflow ${type.toUpperCase()} [${actionType}]: ${docs.length} dokumen diproses${batchMsg}`); showActionResult(`Laporan Workflow ${type.toUpperCase()}`, successDetails, [], actionType, batchNum); 
                        if (type === 'claim' && actionType === 'approve' && succDocs.length > 0) {
                            let fullRowsForExcel = dataSource.filter(d => succDocs.includes(d.noDoc));
                            downloadClaimToFinanceExcel(fullRowsForExcel);
                        }
                        fetchWorkflowData(); 
                    } else { showNotification("Gagal", "error"); }
                } catch (e) { showNotification("Terjadi kesalahan saat memproses workflow.", "error"); fetchWorkflowData(); } finally { hideLoadingOverlay(); }
            }

            // Resolve campaign code individual (kolom A ListCampaign) ke Master Code (kolom V) & Master Code
            // Name (kolom W) - dipakai KHUSUS untuk grouping reporting di Analytics (Summary Chart/Executive
            // Summary), supaya campaign turunan dengan Jenis CB berbeda (mis. 202026=Transfer & 202026B=Rebate)
            // digabung jadi satu baris. Claim Upload/Posting/Release/Claim/Clearing tetap pakai codeCampaign asli,
            // TIDAK memanggil fungsi ini. Kalau Master Code/Name kosong di master, fallback ke campaign code/name
            // individual apa adanya (bukan bikin nilai baru) supaya tetap tertelusuri ke sumber aslinya.
            function resolveMasterCode(codeCampaign) {
                // Cocokkan case-insensitive & trimmed terhadap ListCampaign - codeCampaign yang diinput manual saat
                // upload (Compile) bisa beda kapitalisasi dgn kode di master (mis. "202026b" vs "202026B"), sehingga
                // pencocokan case-sensitive sebelumnya membuat Master Code gagal ketemu padahal sudah ada di master
                // (tampil "belum sinkron"/selalu fallback). Pola normalisasi ini sama seperti campJenisCbMap di Code.gs.
                let target = String(codeCampaign || '').trim().toUpperCase();
                let cmp = globalCampaigns.find(c => String(c.codeCampaign || '').trim().toUpperCase() === target) || {};
                let mc = String(cmp.masterCode || '').trim();
                let mcn = String(cmp.masterCodeName || '').trim();
                if (!mc) mc = codeCampaign;
                if (!mcn) mcn = cmp.campaignName || codeCampaign;
                return { masterCode: mc, masterCodeName: mcn };
            }

            function getValidYear(campaignCode) {
                let cmp = globalCampaigns.find(c => c.codeCampaign === campaignCode);
                if (cmp && cmp.periodStart && cmp.periodStart !== '-') { 
                    let pts = cmp.periodStart.split(/[-\/]/); 
                    if (pts.length === 3) {
                        if (pts[0].length === 4) return pts[0]; 
                        if (pts[2].length >= 4) return pts[2].substring(0,4); 
                    } 
                }
                return new Date().getFullYear().toString();
            }
