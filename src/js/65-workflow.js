            // Baris yang terkunci (dokumen tanpa Customer Master, 20261162260000) tidak ikut dicentang.
            function toggleAllWorkflow(src, cbClass, btnId, countId) { document.querySelectorAll('.' + cbClass + ':not(:disabled)').forEach(c => c.checked = src.checked); updateWorkflowCount(cbClass, btnId, countId); }

            // Kolom toko. Dokumen tanpa Customer Master ditandai merah dengan kode sumbernya,
            // bukan "null"; centangnya dikunci karena server pasti menolaknya.
            function rcSelToko(r) {
                const nama = r.masterKosong
                    ? '<span class="font-bold block text-red-600"><i class="fas fa-exclamation-triangle mr-1"></i>Customer Master belum ada</span>'
                    : '<span class="font-bold block text-gray-800">' + rcEsc(r.namaToko || '') + '</span>';
                return nama + '<span class="text-[10px] text-gray-500 bg-gray-100 px-1.5 py-0.5 rounded">' + rcEsc(r.kodeToko || '-') + '</span>';
            }
            function updateWorkflowCount(cbClass, btnId, countId) { let n = document.querySelectorAll('.' + cbClass + ':checked').length; document.getElementById(countId).innerText = n; setDisabledSafely(btnId, n === 0 || (btnId === 'btnSubmitClearing' && !document.getElementById('tglClearingInput').value)); if (btnId === 'btnSubmitBulk') setDisabledSafely('btnRejectBulk', n === 0); }
            function validateClearingBtn() { let n = document.querySelectorAll('.cb-clr:checked').length; let d = document.getElementById('tglClearingInput').value; setDisabledSafely('btnSubmitClearing', n === 0 || !d); }

            // Dropdown filter dan kotak centang keempat antrean, dijaga selama sisa halaman
            // dimuat di latar belakang (lihat 27-muat-bertahap.js).
            const RC_WF_DROPDOWN = ['relDepotDropdown', 'relCampDropdown', 'cfDepotDropdown', 'cfCampDropdown',
                                    'clrDepotDropdown', 'clrCampDropdown', 'bulkDepotDropdown', 'bulkCampDropdown'];

            // false selama antrean masih dimuat bertahap; Mass Process Clearing memakainya untuk
            // membedakan "belum dimuat" dari "tidak ada di antrean".
            let rcWorkflowLengkap = false;

            async function fetchWorkflowData() {
                rcWorkflowLengkap = false;
                showLoadingOverlay("Memuat Data Operasional...");
                let overlay = true;
                const role = currentUserData.sysRole || currentUserData.role || '';
                const rel = [], cf = [], clr = [], bulk = [];
                try {
                    // Antrean dimuat per halaman: halaman pertama kecil supaya tabel segera
                    // tampil, berikutnya 1000 baris per permintaan sampai habis.
                    const selesai = await rcMuatBertahap({
                        kunci: 'workflow', label: 'Data operasional',
                        ambil: (setelah, pertama) => fetchApp({ action: 'getWorkflowData', requesterId: currentUserData.userId, requesterRole: role, managedDepots: currentUserData.managedDepots, setelah: setelah, limit: pertama ? 300 : 1000 }),
                        terima: async function (res) {
                            rel.push(...(res.releaseData || [])); cf.push(...(res.claimFinData || []));
                            clr.push(...(res.clearingData || [])); bulk.push(...(res.bulkRebateData || []));
                            globalReleaseData = rel; globalClaimFinData = cf;
                            globalClearingData = clr; globalBulkRebateData = bulk;
                            // Master pelanggan diambil sekali untuk seluruh baris yang baru datang,
                            // sebelum tabelnya digambar. Tanpa ini, kolom yang berasal dari master
                            // akan kosong pada tampilan pertama dan terisi entah kapan.
                            await pastikanMasterDariBaris(
                                [].concat(res.releaseData || [], res.claimFinData || [],
                                          res.clearingData || [], res.bulkRebateData || []));
                        },
                        gambar: (pertama) => {
                            const pilihan = pertama ? null : rcSimpanPilihanMulti(RC_WF_DROPDOWN);
                            const centang = pertama ? null : rcSimpanCentang(['cb-rel', 'cb-claim', 'cb-clr', 'cb-bulk']);
                            popWorkflowFilters();
                            if (pilihan) rcPulihkanPilihanMulti(pilihan);
                            renderWorkflowTable('release'); renderWorkflowTable('claim');
                            renderWorkflowTable('clearing'); renderBulkTable();
                            if (centang) {
                                rcPulihkanCentang(centang);
                                updateWorkflowCount('cb-rel', 'btnSubmitRelease', 'releaseSelectedCount');
                                updateWorkflowCount('cb-claim', 'btnSubmitClaim', 'claimSelectedCount');
                                updateWorkflowCount('cb-clr', 'btnSubmitClearing', 'clearingSelectedCount');
                                updateWorkflowCount('cb-bulk', 'btnSubmitBulk', 'bulkSelectedCount');
                            }
                            if (overlay) { hideLoadingOverlay(); overlay = false; }
                        }
                    });
                    if (selesai) rcWorkflowLengkap = true;
                    // Keempat antrean kosong setelah SELURUH halaman dimuat: tanyakan sebabnya
                    // ke server (tidak ada data, atau ada tetapi di luar jangkauan akun ini).
                    if (selesai && !rel.length && !cf.length && !clr.length && !bulk.length) {
                        fetchApp({ action: 'workflowDiagnostic' }).catch(function () {});
                    }
                } catch (e) { showNotification("Gagal memuat data operasi dari server.", "error"); } finally { if (overlay) hideLoadingOverlay(); }
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
                let rowsHtml = filtered.map(r => `<tr class="hover:bg-pink-50 border-b transition-colors"><td class="p-3.5 text-center"><input type="checkbox" value="${r.noDoc}" class="cb-bulk w-4 h-4 rounded text-pink-600 focus:ring-pink-500" onchange="updateWorkflowCount('cb-bulk', 'btnSubmitBulk', 'bulkSelectedCount')"${r.masterKosong ? ' disabled title="Customer Master belum ada. Lengkapi di Key Master &gt; Customer Master lebih dulu."' : ''}></td><td class="p-3.5 text-center"><span class="${rcStatusClass(r.status)} text-[10px] font-black px-2 py-1 rounded uppercase">${r.status}</span></td><td class="p-3.5 text-xs text-gray-500 font-medium">${rcEsc(r.tglUpload || '-')}</td><td class="p-3.5 font-black text-blue-700">${r.noDoc}</td><td class="p-3.5">${rcSelToko(r)}</td><td class="p-3.5"><span class="text-[10px] text-gray-500 block uppercase font-bold">${r.codeCampaign}</span><span class="text-sm font-medium whitespace-normal" title="${r.campaignName}">${r.campaignName}</span></td><td class="p-3.5 text-right font-black text-red-600">Rp ${Math.trunc(Number(Number(r.cbNet))||0).toLocaleString('id-ID')}</td></tr>`).join('');
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
                } catch (e) { showNotification((e && e.message) ? "Gagal: " + e.message : "Terjadi kesalahan saat memproses Bulk Process.", "error"); fetchWorkflowData(); }
                finally { hideLoadingOverlay(); }
            }

            // Tolak dari Bulk Process: dokumen Rebate kembali ke depot (Not Yet) dari tahap mana
            // pun, supaya depot memperbaiki dan mengajukan ulang. Alasan wajib (20261162120000).
            async function rejectBulkProcess() {
                let docs = []; document.querySelectorAll('.cb-bulk:checked').forEach(c => docs.push(c.value)); if (docs.length === 0) return;
                let alasan = window.prompt('Alasan penolakan ' + docs.length + ' dokumen (akan tercatat di riwayat dokumen):', '') || '';
                if (!alasan.trim()) { showNotification('Penolakan memerlukan alasan.', 'warning'); return; }
                let yakin = await showConfirmModal({ title: "Tolak Dokumen Bulk", message: `${docs.length} dokumen akan dikembalikan ke depot (status Not Yet) dan keluar dari antrean Bulk Process. Depot perlu mengajukan ulang.\n\nAlasan: ${alasan.trim()}`, confirmText: "Ya, Tolak" });
                if (!yakin) return;

                setDisabledSafely('btnRejectBulk', true); setDisabledSafely('btnSubmitBulk', true);
                showLoadingOverlay('Mengembalikan dokumen ke depot...');
                try {
                    let res = await fetchApp({ action: 'bulkReject', docsToProcess: docs, reason: alasan.trim() });
                    if (res.status === 'success') {
                        logActivity(`Bulk Process (Tolak -> Not Yet): ${docs.length} dokumen. Alasan: ${alasan.trim()}`);
                        showNotification(docs.length + ' dokumen dikembalikan ke depot.', 'success');
                        fetchWorkflowData();
                    } else { showNotification(res.message || "Gagal menolak dokumen.", "error"); }
                } catch (e) { showNotification((e && e.message) ? "Gagal: " + e.message : "Terjadi kesalahan saat menolak dokumen.", "error"); fetchWorkflowData(); }
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
                    ['Claimed', r.claimedBy, r.tglClaim],
                    // Clearing ditambahkan atas permintaan pemilik 9 Oktober 2026: seluruh tahap,
                    // dari Submitted sampai Clearing, terbaca di satu kartu.
                    ['Clearing', r.clearedBy, r.tglClearing]
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
                // 20261163150000: pelaku Amend, merah.
                const amend = (Array.isArray(r.amendBy) ? r.amendBy : []).map(function (a) {
                    return '<span class="block text-[11px] leading-snug truncate text-red-600 font-black" title="' + rcEsc('Amend (' + (a.dari || '-') + '): ' + (a.oleh || '-') + (a.waktu ? ' - ' + a.waktu : '')) + '">'
                        + 'Amend (' + rcEsc(a.dari || '-') + ') ' + rcEsc(a.oleh || '-') + '</span>';
                }).join('');
                return isi + amend + '<span class="block text-[10px] text-gray-400 mt-1 border-t border-gray-100 pt-1 truncate">'
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
                // Tempelan dari Excel kerap membawa karakter tak terlihat (spasi tak-putus, zero-width)
                // dan kolom lain yang ikut tersalin. No Document tidak pernah berspasi dan selalu
                // memuat "/", jadi potongan lain (nama toko, nominal) diabaikan, bukan dilaporkan
                // sebagai No Document yang tidak ditemukan.
                const diminta = teks.replace(/[ ​-‍﻿]/g, ' ').split(/[\s,;]+/)
                    .map(x => x.trim().toUpperCase()).filter(x => x !== '' && x.indexOf('/') > -1);
                const ringkas = document.getElementById('clrMassRingkas');
                if (diminta.length === 0) {
                    if (ringkas) ringkas.innerText = 'Belum ada No Document yang ditempel.';
                    return;
                }

                // Baris yang sedang tampil saja. Bila hasil filter menyembunyikan sebuah dokumen,
                // mencentangnya diam-diam akan memposting sesuatu yang tidak terlihat di layar.
                const kotak = Array.from(document.querySelectorAll('.cb-clr'));
                const adaDiLayar = new Set(kotak.map(c => String(c.value).trim().toUpperCase()));
                // Dokumen tanpa Customer Master tampil di daftar tetapi tidak dapat diproses;
                // mencentangnya akan menggagalkan seluruh posting (20261162260000).
                const terkunci = new Set(kotak.filter(c => c.disabled).map(c => String(c.value).trim().toUpperCase()));
                const unik = Array.from(new Set(diminta));
                const ketemu = unik.filter(d => adaDiLayar.has(d) && !terkunci.has(d));
                const tanpaMaster = unik.filter(d => terkunci.has(d));
                const tidak = unik.filter(d => !adaDiLayar.has(d));

                kotak.forEach(c => { c.checked = !c.disabled && ketemu.indexOf(String(c.value).trim().toUpperCase()) > -1; });
                updateWorkflowCount('cb-clr', 'btnSubmitClearing', 'clearingSelectedCount');
                validateClearingBtn();

                if (tidak.length > 0 && !rcWorkflowLengkap) {
                    if (ringkas) ringkas.innerHTML = '<b class="text-emerald-700">' + ketemu.length + '</b> dari ' + unik.length
                        + ' No Document tercentang. <b class="text-orange-600">Data Clearing masih dimuat</b> - '
                        + tidak.length + ' No Document belum terlihat. Tunggu sampai indikator pemuatan selesai, lalu klik Centang lagi.';
                    return;
                }
                if (ringkas) {
                    ringkas.innerHTML = '<b class="text-emerald-700">' + ketemu.length + '</b> dari '
                        + unik.length + ' No Document tercentang.'
                        + (tanpaMaster.length > 0
                            ? ' <b class="text-red-600">' + tanpaMaster.length + ' belum punya Customer Master</b> '
                              + '(tidak dicentang; lengkapi di Key Master &gt; Customer Master lebih dulu).'
                            : '')
                        + (tidak.length > 0
                            ? ' <b class="text-red-600">' + tidak.length + ' tidak ada di daftar Clearing</b> '
                              + '(salah ketik, sudah diproses, di luar yurisdiksi Anda, '
                              + 'atau tersembunyi oleh filter yang sedang aktif).'
                            : '');
                }
                if (tidak.length > 0 || tanpaMaster.length > 0) {
                    const baris = (daftar, sebab) => daftar.map(d => '<tr class="border-b border-gray-100"><td class="p-2 font-mono text-red-700">'
                        + rcEsc(d) + '</td><td class="p-2 text-gray-600">' + sebab + '</td></tr>').join('');
                    rcDialog('No Document yang tidak dapat dicentang',
                        '<p class="text-sm text-gray-600 mb-3">Dokumen berikut tidak ikut dicentang. Dokumen lain tetap dapat '
                        + 'diposting.</p>'
                        + '<div class="max-h-72 overflow-auto border border-gray-200 rounded-lg">'
                        + '<table class="w-full text-sm"><tbody>'
                        + baris(tanpaMaster, 'Customer Master belum ada - lengkapi di Key Master lebih dulu')
                        + baris(tidak, 'Tidak ada di daftar Clearing yang tampil (salah ketik, sudah diproses, di luar yurisdiksi, atau tersembunyi filter)')
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
                // Tanggal transfer/proses aktual tidak boleh sesudah hari ini (WIB), sama dengan
                // aturan server (20261162270000).
                if (type === 'clearing') { const tgl = document.getElementById('tglClearingInput'); if (tgl) tgl.max = new Date(Date.now() + 7 * 3600 * 1000).toISOString().slice(0, 10); }

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

                    let idn = rcIdentitasDokumen(r);
                    let doc = rcCariDokumen(r.noDoc) || {};
                    
                    let valKtp = idn.ktp || '-'; let valNpwp = idn.npwp || '-'; let valTop = doc.top || r.top || '-'; let valLunas = doc.tglLunas || r.tglLunas || '-';
                    let valRek = idn.noRek || '-'; let valNamaRek = idn.namaRek || '-'; let valBank = idn.bank || '-';
                    
                    let valVolume = doc.volume || 0; let valNetValue = doc.netValue || 0;
                    // Label seragam; penulisan berbeda di master tidak lagi tampil sebagai dua
                    // status yang seolah berlainan.
                    let valStatusPajak = rcLabelPajak(r.statusPajakCamp);
                    // Diturunkan dari KTP/NPWP yang berlaku sekarang. Kolom tax_subject yang
                    // tersimpan saat upload dapat tertinggal ketika identitas toko diperbarui.
                    let valSubyekPajak = idn.subyek || '-';

                    rowsHtml += `<tr class="hover:bg-blue-50 border-b transition-colors"><td class="p-3.5 text-center"><input type="checkbox" value="${r.noDoc}" class="${cbCls} w-4 h-4 rounded text-blue-600 focus:ring-blue-500" onchange="updateWorkflowCount('${cbCls}', '${btnId}', '${countId}')"${r.masterKosong ? ' disabled title="Customer Master belum ada. Lengkapi di Key Master &gt; Customer Master lebih dulu."' : ''}></td><td class="p-3.5 text-[10px] font-black text-gray-600 bg-gray-50/50 uppercase">${pBatch}</td><td class="p-3.5 text-xs text-gray-500 font-medium">${r[tglCol]}</td><td class="p-3.5 font-black text-blue-700">${r.noDoc}</td><td class="p-3.5">${rcSelToko(r)}</td><td class="p-3.5"><span class="text-[10px] text-gray-500 block uppercase font-bold">${r.codeCampaign}</span><span class="text-sm font-medium whitespace-normal" title="${r.campaignName}">${r.campaignName}</span></td><td class="p-3.5 text-right font-black text-red-600">Rp ${Math.trunc(Number(Number(r.cbNet))||0).toLocaleString('id-ID')}</td><td class="p-3.5 text-xs rc-wrap">${rcEsc(rcCbLabel(r.jenisCb))}</td>${type!=='release'?'<td class="p-3.5 text-right text-orange-700 font-bold">'+rcMoney(r.grossUpCb)+'</td>':''}<td class="p-3.5 text-center"><button onclick="toggleWorkflowDetails('det-${type}-${r.noDoc}')" class="bg-blue-50 hover:bg-blue-100 text-blue-600 font-bold px-3 py-1.5 rounded-lg text-[10px] uppercase shadow-sm transition"><i class="fas fa-eye mr-1"></i> Details</button></td></tr><tr id="det-${type}-${r.noDoc}" class="hidden expanded-details"><td colspan="${type==='release'?9:10}" class="p-4 bg-gray-50"><div class="grid grid-cols-2 md:grid-cols-4 gap-4 text-xs"><div class="bg-white p-3 rounded-lg shadow-sm border border-gray-200"><span class="font-bold text-gray-500 block mb-1 uppercase text-[9px]"><i class="fas fa-id-card mr-1"></i> Identitas & Pajak</span> <span class="font-bold text-gray-800 block text-xs truncate">KTP: ${valKtp} | NPWP: ${valNpwp}</span><span class="font-bold text-gray-800 block text-xs truncate">Sbyk: ${valSubyekPajak} | Stat: ${valStatusPajak}</span></div><div class="bg-white p-3 rounded-lg shadow-sm border border-gray-200"><span class="font-bold text-gray-500 block mb-1 uppercase text-[9px]"><i class="fas fa-money-check-alt mr-1"></i> Rekening</span> <span class="font-bold text-gray-800 block text-xs truncate">${valRek}</span><span class="font-bold text-gray-800 block text-xs truncate">${valNamaRek} (${valBank})</span></div><div class="bg-white p-3 rounded-lg shadow-sm border border-gray-200"><span class="font-bold text-gray-500 block mb-1 uppercase text-[9px]"><i class="fas fa-box mr-1"></i> Data Campaign</span> <span class="font-bold text-gray-800 block text-xs truncate">Vol: ${valVolume} | Val: Rp ${Math.trunc(Number(Number(valNetValue))||0).toLocaleString('id-ID')}</span><span class="font-bold text-gray-800 block text-xs truncate">TOP: ${valTop} Hr | Lns: ${valLunas}</span></div><div class="bg-white p-3 rounded-lg shadow-sm border border-gray-200"><span class="font-bold text-gray-500 block mb-1 uppercase text-[9px]"><i class="fas fa-user-check mr-1"></i> Process by</span>${kartuPelaku(r)}</div>${rcDetailCardHtml('Remark',rcRemarkHtml(r.remark))}</div></td></tr>`; 
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

            // Identitas, rekening dan subyek pajak sebuah dokumen: SATU sumber untuk layar Release /
            // Claim Process / Clearing dan berkas Claim to Finance. Sebelumnya layar mendahulukan
            // Customer Master sedangkan berkas mendahulukan nilai per klaim, sehingga NPWP yang nol
            // depannya hilang di data klaim tampil benar di layar tetapi terunduh tanpa nol
            // (pemilik, 12 Oktober 2026). Urutan layar dipertahankan: Customer Master lebih dulu.
            function rcIdentitasDokumen(r) {
                const cst = rcCariCustomer(r.kodeToko) || {};
                const t = v => String(v === null || v === undefined ? '' : v).trim();
                const ktp = t(cst.ktp || r.ktp), npwp = t(cst.npwp || r.npwp);
                return {
                    cst: cst, ktp: ktp, npwp: npwp,
                    noRek: t(cst.noRek || r.noRekening), namaRek: t(cst.namaRek || r.pemilikRekening),
                    bank: t(cst.bank || r.bankCust),
                    // Diturunkan dari KTP/NPWP yang berlaku sekarang; tax_subject yang tersimpan saat
                    // upload dapat tertinggal ketika identitas toko diperbarui.
                    subyek: rcSubyekPajak(ktp, npwp) || t(r.statusPajakCust)
                };
            }

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
                    // Identitas, rekening, subyek pajak, Jenis CB dan Gross Up diambil persis dari
                    // yang tampil di layar Claim Process (rcIdentitasDokumen, rcCbLabel,
                    // grossUpCb), supaya isi berkas tidak pernah berbeda dari yang dilihat.
                    // Periode yang kosong per dokumen tetap diambil dari Campaign Master.
                    let idn = rcIdentitasDokumen(r);
                    let cst = idn.cst;
                    let cmp = rcCariCampaign(r.codeCampaign) || {};

                    let ktpVal = idn.ktp, npwpVal = idn.npwp, noRekVal = idn.noRek;
                    let namaRekVal = idn.namaRek, bankVal = idn.bank, subyekVal = idn.subyek;
                    let statusPajakCampVal = rcTeksPajak(r.statusPajakCamp);
                    let periodeStartVal = toDDMMMYYYY((r.periodeStart && r.periodeStart !== '-') ? r.periodeStart : cmp.periodStart);
                    let periodeEndVal = toDDMMMYYYY((r.periodeEnd && r.periodeEnd !== '-') ? r.periodeEnd : cmp.periodEnd);
                    let idForDigit = ktpVal || npwpVal;
                    let digitCount = idForDigit.replace(/\D/g, '').length;

                    let validNet = parseSafeNumber(r.cbNet);
                    let validGrossUp = Number(r.grossUpCb) || 0;
                    let digitRek = noRekVal.replace(/\D/g, '').length;
                    let kontakVal = String(r.contactPerson || cst.contactPerson || '').trim();

                    aoa.push([
                        i + 1, rcSelTeks(r.noDoc), rcSelTeks(r.kodeDepot), r.depot, rcSelTeks(r.codeCampaign),
                        periodeStartVal, periodeEndVal, r.campaignName,
                        rcSelTeks(r.kodeToko), r.namaToko,
                        Math.trunc(validNet),
                        Math.trunc(validGrossUp),
                        rcSelTeks(ktpVal), rcSelTeks(npwpVal),
                        digitCount, subyekVal, statusPajakCampVal, rcCbLabel(r.jenisCb),
                        rcSelTeks(noRekVal), digitRek, namaRekVal, bankVal, kontakVal
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
            // CB Before Tax = Gross Up yang sama dengan Laporan Bulk Process di layar (grossUpCb).
            function downloadBulkProcessExcel(rows) {
                if (!rows || rows.length === 0) return;
                let header = ["Code Campaign", "Sales Org", "Code Cust", "DC", "CB After Tax", "CB Before Tax"];
                let aoa = [header];
                rows.forEach(r => {
                    let netCB = parseSafeNumber(r.cbNet);
                    let grossUp = Number(r.grossUpCb) || 0;
                    aoa.push([rcSelTeks(r.codeCampaign), '', rcSelTeks(r.kodeToko), rcSelTeks(r.kodeDepot), Math.trunc(netCB), Math.trunc(grossUp)]);
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
                    } else { showNotification(res.message || "Gagal memproses dokumen.", "error"); }
                } catch (e) { showNotification((e && e.message) ? "Gagal: " + e.message : "Terjadi kesalahan saat memproses workflow.", "error"); fetchWorkflowData(); } finally { hideLoadingOverlay(); }
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
                let cmp = rcCariCampaignNorm(target) || {};
                let mc = String(cmp.masterCode || '').trim();
                let mcn = String(cmp.masterCodeName || '').trim();
                if (!mc) mc = codeCampaign;
                if (!mcn) mcn = cmp.campaignName || codeCampaign;
                return { masterCode: mc, masterCodeName: mcn };
            }

            function getValidYear(campaignCode) {
                let cmp = rcCariCampaign(campaignCode);
                if (cmp && cmp.periodStart && cmp.periodStart !== '-') { 
                    let pts = cmp.periodStart.split(/[-\/]/); 
                    if (pts.length === 3) {
                        if (pts[0].length === 4) return pts[0]; 
                        if (pts[2].length >= 4) return pts[2].substring(0,4); 
                    } 
                }
                return new Date().getFullYear().toString();
            }
