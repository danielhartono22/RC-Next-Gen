            let rcMasterState = { customer: { offset: 0, rows: [] }, campaign: { offset: 0, rows: [] } };
            let rcCompState = { offset: 0, rows: [], canArchive: false, campaigns: [] };
            let rcPendingUpload = { Customer: null, Campaign: null };
            // Nomor baris Excel tiap baris rcPendingUpload, untuk menunjuk baris yang ditolak server.
            let rcPendingBaris = { Customer: null, Campaign: null };
            // Customer Master boleh puluhan ribu baris: layar memecahnya per RC_BAGIAN_UNGGAH baris
            // (batas satu panggilan server). Campaign tetap satu kiriman.
            const RC_BAGIAN_UNGGAH = 2000;
            const RC_MAKS_BARIS = { Customer: 50000, Campaign: 2000 };
            const RC_MAKS_MB = { Customer: 20, Campaign: 5 };
            let rcEditorKind = null, rcEditorRow = null;

            function openRcModule(mod) {
                const selected=rcFirstTab(mod,{keyMaster:'customer',compilation:'list',approval:'wpt',report:'dashboard',timetable:'matrix',people:'osc'}[mod]);
                if(!rcEnterTab(mod,selected))return;
                setHiddenSafely('dashboardSection', true); setHiddenSafely('navBackBtn', false);
                setHiddenSafely('workspaceSection', false); setHiddenSafely('profileSection', true);
                document.querySelectorAll('.module-section').forEach(el => el.classList.add('hidden'));
                if (mod === 'people') {
                    document.getElementById('modPeople').classList.remove('hidden');
                    switchPeopleTab(rcFirstTab('people','osc'));
                } else if (mod === 'keyMaster') {
                    document.getElementById('modKeyMaster').classList.remove('hidden');
                    switchKeyMasterTab(selected);
                } else if (mod === 'compilation') {
                    document.getElementById('modCompilation').classList.remove('hidden');
                    initCompilation(); switchCompilationTab(selected==='reprocess'?'repro':selected==='amend'?'amend':'compile'); if(selected==='archive')toggleArchivedList();
                } else if (mod === 'approval') {
                    document.getElementById('modApproval').classList.remove('hidden');
                    openApprovalModule();
                } else if (mod === 'report') {
                    document.getElementById('modReport').classList.remove('hidden');
                    switchReportTab(selected);
                } else if (mod === 'timetable') {
                    document.getElementById('modTimetable').classList.remove('hidden');
                    loadTimetable();
                }
            }

            function switchKeyMasterTab(tab) {
                if(!rcEnterTab('keyMaster',tab))return;
                setHiddenSafely('kmPanelCustomer', tab !== 'customer');
                setHiddenSafely('kmPanelCampaign', tab !== 'campaign');
                setHiddenSafely('kmPanelDepot', tab !== 'depot');
                let active = "px-5 py-2 text-sm font-bold rounded-lg transition bg-emerald-100 text-emerald-700";
                let idle = "px-5 py-2 text-sm font-bold rounded-lg transition text-gray-500 hover:bg-gray-100";
                document.getElementById('kmTabCustomer').className = tab === 'customer' ? active : idle;
                document.getElementById('kmTabCampaign').className = tab === 'campaign' ? active : idle;
                document.getElementById('kmTabDepot').className = tab === 'depot' ? active : idle;
                if (tab === 'customer') loadCustomerMaster(rcMasterState.customer.offset);
                else if (tab === 'campaign') loadCampaignMaster(rcMasterState.campaign.offset);
                else loadDepotMaster(0);
            }

            function rcMoney(v) { return rcNominalPenuh(v); }

            // ---------- Customer Master ----------
            async function loadCustomerMaster(offset) {
                showLoadingOverlay("Memuat Customer Master...");
                try {
                    let res = await fetchApp({ action: 'customerList', search: document.getElementById('customerSearch').value.trim(), offset: offset });
                    if (res.status !== 'success') { showNotification(res.message || "Gagal memuat.", "error"); return; }
                    rcMasterState.customer = { offset: offset, rows: res.rows || [] };
                    // Customer tanpa Kode Depot tidak pernah muncul di daftar (RLS), jadi hanya
                    // server yang dapat memberitahukannya (20261163090000).
                    const tdp = res.tanpaDepot || {};
                    const elTdp = document.getElementById('customerTanpaDepot');
                    if (elTdp) {
                        if (Number(tdp.jumlah || 0) > 0) {
                            elTdp.innerHTML = '<i class="fas fa-triangle-exclamation mr-1.5"></i><b>' + Number(tdp.jumlah).toLocaleString('id-ID')
                                + ' customer belum punya Kode Depot</b> sehingga tidak terlihat di daftar maupun di modul lain. '
                                + 'Pulihkan lewat Tambah (Customer Code yang sama + Kode Depot) atau unggah template dengan kolom Kode Depot. '
                                + '<span class="text-amber-700">' + (tdp.kode || []).slice(0, 10).map(rcEsc).join('; ')
                                + (Number(tdp.jumlah) > 10 ? '; ...' : '') + '</span>';
                            setHiddenSafely('customerTanpaDepot', false);
                        } else setHiddenSafely('customerTanpaDepot', true);
                    }
                    let html = '';
                    (res.rows || []).forEach((r, i) => {
                        let badge = r.subyekPajak === 'Badan' ? 'bg-purple-100 text-purple-700'
                                  : (r.subyekPajak === 'Perorangan' ? 'bg-orange-100 text-orange-700' : 'bg-gray-100 text-gray-500');
                        html += '<tr class="border-b border-gray-100 hover:bg-emerald-50/40">'
                            + '<td class="p-3 text-center"><input type="checkbox" class="cb-customer w-4 h-4 rounded" '
                              + 'value="' + rcEsc(r.custCode) + '" onchange="updateCustomerArsipCount()"></td>'
                            + '<td class="p-3 whitespace-normal break-words">' + rcEsc((r.depotCodes || []).join(', ')) + '</td>'
                            + '<td class="p-3 whitespace-normal break-words min-w-[160px]">' + rcEsc((r.depotNames || []).join(', ')) + '</td>'
                            + '<td class="p-3 whitespace-normal break-words">' + rcEsc((r.regions || []).join(', ')) + '</td>'
                            + '<td class="p-3 font-black text-gray-800">' + rcEsc(r.custCode) + '</td>'
                            + '<td class="p-3 text-gray-700">' + rcEsc(r.custName) + '</td>'
                            + '<td class="p-3 text-center">' + rcEsc(r.top || '-') + '</td>'
                            + '<td class="p-3 text-gray-600 font-mono whitespace-nowrap">' + rcEsc(rcFull(r.ktp) || '-') + '</td>'
                            + '<td class="p-3 text-gray-600 font-mono whitespace-nowrap">' + rcEsc(rcFull(r.npwp) || '-') + '</td>'
                            + '<td class="p-3 text-center"><span class="' + badge + ' px-2 py-1 rounded text-[10px] font-black uppercase">' + rcEsc(r.subyekPajak || 'Belum ada') + '</span></td>'
                            + '<td class="p-3 text-xs text-gray-600 font-mono whitespace-nowrap">' + rcEsc(rcFull(r.noRek) || '-') + '<br><span class="text-gray-400">' + rcEsc(r.namaRek || '-') + ' / ' + rcEsc(r.bank || '-') + '</span></td>'
                            + '<td class="p-3 text-gray-600">' + rcEsc(r.contactPerson || '-') + '</td>'
                            + '<td class="p-3 text-center"><button onclick="openRcRowEditor(\'customer\',' + i + ')" class="px-3 py-1.5 bg-white border border-gray-300 hover:bg-emerald-50 text-emerald-700 font-bold rounded-lg text-xs">Ubah</button></td></tr>';
                    });
                    document.getElementById('customerTableBody').innerHTML = html
                        || '<tr><td colspan="13" class="p-8 text-center text-gray-500">Tidak ada data.</td></tr>';
                    rcPilihanPulihkan('cb-customer', 'cbCustomerAll');
                    updateCustomerArsipCount();
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
                                  : (jc === 'rebate' ? 'bg-pink-100 text-pink-800'
                                  : (jc === 'voucher' ? 'bg-indigo-100 text-indigo-800' : 'bg-red-100 text-red-700')));
                        let st = String(r.status || 'active').toLowerCase();
                        let stCls = RC_STATUS_CAMPAIGN[st] ? RC_STATUS_CAMPAIGN[st].kelas : 'bg-gray-100 text-gray-600';
                        let stLbl = RC_STATUS_CAMPAIGN[st] ? RC_STATUS_CAMPAIGN[st].label : st;
                        // Hanya campaign tanpa dokumen yang boleh dicentang untuk dihapus.
                        // Kotak yang dimatikan lebih jujur daripada kotak yang bisa dicentang
                        // lalu ditolak server - alasannya terbaca sebelum tombolnya ditekan.
                        let bolehHapus = Number(r.jumlahClaim || 0) === 0;
                        html += '<tr class="border-b border-gray-100 hover:bg-emerald-50/40">'
                            + '<td class="p-3 text-center"><input type="checkbox" class="cb-campaign w-4 h-4 rounded"'
                                + ' value="' + rcEsc(r.codeCampaign) + '"' + (bolehHapus ? '' : ' disabled')
                                + ' title="' + (bolehHapus ? 'Dapat dihapus' : 'Sudah memiliki dokumen, tidak dapat dihapus') + '"'
                                + ' onchange="updateCampaignHapusCount()"></td>'
                            + '<td class="p-3 font-black text-gray-800">' + rcEsc(r.codeCampaign) + '</td>'
                            + '<td class="p-3 text-gray-700">' + rcEsc(r.campaignName) + '</td>'
                            + '<td class="p-3 text-center"><span class="' + stCls + ' px-2 py-1 rounded text-[10px] font-black uppercase">' + rcEsc(stLbl) + '</span></td>'
                            + '<td class="p-3 text-center text-gray-600">' + rcEsc(r.periodStart || '-') + '</td>'
                            + '<td class="p-3 text-center text-gray-600">' + rcEsc(r.periodEnd || '-') + '</td>'
                            // Periode SO dan Billing ditampilkan sebagai satu sel "a s/d b":
                            // keduanya selalu dibaca berpasangan, dan empat kolom terpisah hanya
                            // membuat tabelnya melebar tanpa menambah keterangan.
                            + '<td class="p-3 text-center text-gray-600 whitespace-nowrap">'
                              + (r.soStart || r.soEnd
                                 ? rcEsc((r.soStart || '?') + ' s/d ' + (r.soEnd || '?')) : '-') + '</td>'
                            + '<td class="p-3 text-center text-gray-600 whitespace-nowrap">'
                              + (r.billingStart || r.billingEnd
                                 ? rcEsc((r.billingStart || '?') + ' s/d ' + (r.billingEnd || '?')) : '-') + '</td>'
                            + '<td class="p-3 text-center"><span class="' + jcCls + ' px-2 py-1 rounded text-[10px] font-black uppercase">' + rcEsc(r.jenisCb || 'BELUM DIISI') + '</span></td>'
                            + '<td class="p-3 text-center text-xs">' + rcLabelPajak(r.statusPajak) + '</td>'
                            + '<td class="p-3 text-center">' + kolomNotParticipating(r) + '</td>'
                            + '<td class="p-3 text-center font-bold text-gray-700">' + rcEsc(r.jumlahClaim) + '</td>'
                            + '<td class="p-3 text-right font-black text-gray-700" data-sort="' + Number(r.nilaiClaim || 0) + '">' + rcEsc(rcMoney(r.nilaiClaim)) + '</td>'
                            + '<td class="p-3 text-center">' + kolomMemo(r, i) + '</td>'
                            + '<td class="p-3 text-center text-[11px] text-gray-500 whitespace-nowrap">' + rcEsc(r.createdOn || '-')
                                + '<br><span class="text-gray-400">' + rcEsc(r.createdBy || '-') + '</span></td>'
                            + '<td class="p-3 text-center"><button onclick="openRcRowEditor(\'campaign\',' + i + ')" class="px-3 py-1.5 bg-white border border-gray-300 hover:bg-emerald-50 text-emerald-700 font-bold rounded-lg text-xs">Ubah</button></td></tr>';
                    });
                    document.getElementById('campaignTableBody').innerHTML = html
                        || '<tr><td colspan="16" class="p-8 text-center text-gray-500">Tidak ada data.</td></tr>';
                    rcPilihanPulihkan('cb-campaign', 'cbCampaignAll');
                    updateCampaignHapusCount();
                    renderRcPager('campaignPager', offset, (res.rows || []).length, res.total, 'loadCampaignMaster');
                } catch (e) { showNotification("Gagal memuat Campaign Master.", "error"); }
                finally { hideLoadingOverlay(); }
            }

            // langkah = jumlah baris per halaman. Bawaannya 50 (Customer/Campaign Master);
            // Document Center menampilkan 100, dan dulu tombolnya tetap melangkah 50 sehingga
            // setiap halaman berikutnya mengulang 50 baris terakhir halaman sebelumnya.
            function renderRcPager(containerId, offset, shown, total, fnName, langkah) {
                langkah = langkah || 50;
                let el = document.getElementById(containerId); if (!el) return;
                let from = total === 0 ? 0 : offset + 1, to = offset + shown;
                el.innerHTML = '<div class="flex justify-between items-center text-xs text-gray-600 bg-white p-3 border rounded-xl">'
                    + '<span>Menampilkan <b>' + from + '</b> - <b>' + to + '</b> dari <b>' + total + '</b></span>'
                    + '<span class="flex gap-2">'
                    + '<button ' + (offset === 0 ? 'disabled' : '') + ' onclick="' + fnName + '(' + Math.max(0, offset - langkah) + ')" class="px-3 py-1.5 bg-white border rounded-lg disabled:opacity-40">Sebelumnya</button>'
                    + '<button ' + (to >= total ? 'disabled' : '') + ' onclick="' + fnName + '(' + (offset + langkah) + ')" class="px-3 py-1.5 bg-white border rounded-lg disabled:opacity-40">Berikutnya</button>'
                    + '</span></div>';
            }

            // ---------- Status campaign, penghapusan, dan memo PDF ----------
            // Status campaign menentukan apakah dokumen baru boleh masuk. Aturannya ditegakkan
            // server lewat trigger pada tabel claims, bukan di sini; yang ada di layar hanyalah
            // cara mengubahnya dan cara membacanya.
            const RC_STATUS_CAMPAIGN = {
                active:   { label: 'Active',   kelas: 'bg-emerald-100 text-emerald-700' },
                inactive: { label: 'Inactive', kelas: 'bg-red-100 text-red-700' },
                cleared:  { label: 'Cleared',  kelas: 'bg-slate-200 text-slate-700' }
            };

            function kolomMemo(r, i) {
                if (r.memoPath) {
                    const ukuran = Number(r.memoSize || 0);
                    const kb = ukuran > 0 ? ' (' + Math.max(1, Math.round(ukuran / 1024)) + ' KB)' : '';
                    return '<button onclick="bukaMemoCampaign(' + i + ')" class="px-2 py-1 bg-red-50 border border-red-200 text-red-700 font-bold rounded text-[10px]" title="'
                        + rcEsc(r.memoName + kb + (r.memoUploadedOn ? ' - ' + r.memoUploadedOn : ''))
                        + '"><i class="fas fa-file-pdf mr-1"></i>Buka</button>';
                }
                return '<span class="text-gray-300 text-xs">-</span>';
            }

            // ---------- Pemilihan baris untuk diarsipkan ----------
            function toggleSemuaCustomer(src) {
                const nyala = src ? src.checked : false;
                document.querySelectorAll('.cb-customer').forEach(c => { c.checked = nyala; });
                updateCustomerArsipCount();
            }
            // Jumlahnya mencakup pilihan di semua halaman (28-pilihan-lintas-halaman.js).
            function updateCustomerArsipCount() {
                const n = rcPilihanSerap('cb-customer', null, 'cbCustomerAll');
                setTextSafely('customerArsipCount', n);
                setDisabledSafely('btnArsipCustomer', n === 0);
            }

            // ---------- Arsip Key Master ----------
            // Satu panel dipakai ketiga master; jenis yang sedang dibuka disimpan di sini supaya
            // tombol Pulihkan tahu ia sedang menangani customer, campaign atau depot.
            let kmArsipJenis = 'customer';
            const KM_ARSIP_JUDUL = {
                customer: 'Arsip Customer Master',
                campaign: 'Arsip Campaign Master',
                depot: 'Arsip Depot Master'
            };
            const KM_ARSIP_KELAS = { customer: 'cb-customer', campaign: 'cb-campaign', depot: 'cb-depot' };
            const KM_PANEL = { customer: 'kmPanelCustomer', campaign: 'kmPanelCampaign', depot: 'kmPanelDepot' };
            const KM_MUAT = {
                customer: () => loadCustomerMaster(0),
                campaign: () => loadCampaignMaster(0),
                depot: () => loadDepotMaster(0)
            };

            async function kmArsipkan(jenis) {
                // Seluruh pilihan, termasuk yang dicentang di halaman lain.
                const kode = rcPilihanKunci(KM_ARSIP_KELAS[jenis]);
                if (!kode.length) { showNotification('Tidak ada baris yang dipilih.', 'error'); return; }
                if (kode.length > 200) {
                    showNotification(kode.length + ' baris dipilih; satu kali arsip maksimal 200 baris. Kurangi pilihannya lebih dulu.', 'warning');
                    return;
                }

                // window.prompt dipakai di sini karena itulah cara modul lain meminta alasan -
                // Posting Exception dan penghapusan akun. Ia mengembalikan null bila dibatalkan.
                const alasan = window.prompt('Arsipkan ' + kode.length + ' baris.\n\n'
                    + 'Baris yang diarsipkan hilang dari daftar aktif dan tidak dapat dipakai untuk '
                    + 'dokumen baru. Dokumen lama yang merujuknya tetap utuh, dan baris ini dapat '
                    + 'dipulihkan kapan saja.\n\nAlasan (boleh dikosongkan):', '');
                if (alasan === null) return;

                showLoadingOverlay('Mengarsipkan...');
                try {
                    const res = await fetchApp({ action: 'masterArchive', jenis: jenis, kode: kode, alasan: alasan || '' });
                    if (res.status !== 'success') { showNotification(res.message || 'Gagal mengarsipkan.', 'error'); return; }
                    kmLaporkanHasil(res);
                    rcPilihanKosongkan(KM_ARSIP_KELAS[jenis]);
                    await KM_MUAT[jenis]();
                } catch (e) { showNotification('Gagal mengarsipkan.', 'error'); }
                finally { hideLoadingOverlay(); }
            }

            // Kegagalan per baris disebut satu per satu: "3 diarsipkan, 2 ditolak" tanpa menyebut
            // baris mana dan mengapa akan membuat pengguna menebak-nebak.
            function kmLaporkanHasil(res) {
                const gagal = res.gagal || [];
                if (!gagal.length) { showNotification(res.message || 'Selesai.', 'success'); return; }
                const rincian = gagal.map(g => (g.kode || '-') + ': ' + (g.sebab || '-')).join('\n');
                showNotification((res.message || 'Selesai.') + '\n' + rincian, gagal.length && !res.berhasil ? 'error' : 'warning');
            }

            function kmBukaArsip(jenis) {
                kmArsipJenis = jenis;
                setTextSafely('kmArsipJudul', KM_ARSIP_JUDUL[jenis] || 'Arsip');
                Object.values(KM_PANEL).forEach(id => setHiddenSafely(id, true));
                setHiddenSafely('kmPanelArsip', false);
                setValueSafely('kmArsipSearch', '');
                kmMuatArsip();
            }

            function kmTutupArsip() {
                setHiddenSafely('kmPanelArsip', true);
                setHiddenSafely(KM_PANEL[kmArsipJenis], false);
            }

            async function kmMuatArsip() {
                showLoadingOverlay('Memuat arsip...');
                try {
                    const res = await fetchApp({
                        action: 'masterArchived', jenis: kmArsipJenis,
                        search: getValueSafely('kmArsipSearch')
                    });
                    if (res.status !== 'success') { showNotification(res.message || 'Gagal memuat arsip.', 'error'); return; }
                    const rows = res.rows || [];
                    document.getElementById('kmArsipBody').innerHTML = rows.map(r =>
                        '<tr class="border-b border-gray-100 hover:bg-amber-50/40">'
                        + '<td class="p-3 text-center"><input type="checkbox" class="cb-arsip w-4 h-4 rounded" '
                          + 'value="' + rcEsc(r.kode) + '" onchange="updateArsipCount()"></td>'
                        + '<td class="p-3 font-black text-gray-800">' + rcEsc(r.kode) + '</td>'
                        + '<td class="p-3 text-gray-700">' + rcEsc(r.nama || '-') + '</td>'
                        + '<td class="p-3 text-center text-gray-600">' + Number(r.dokumen || 0) + '</td>'
                        + '<td class="p-3 text-center text-gray-600 whitespace-nowrap">' + rcEsc(r.diarsipkanPada || '-') + '</td>'
                        + '<td class="p-3 text-gray-600">' + rcEsc(r.diarsipkanOleh || '-') + '</td>'
                        + '<td class="p-3 text-gray-500 text-xs">' + rcEsc(r.alasan || '-') + '</td></tr>'
                    ).join('') || '<tr><td colspan="7" class="p-8 text-center text-gray-500">Arsip masih kosong.</td></tr>';
                    const semua = document.getElementById('cbArsipAll');
                    if (semua) semua.checked = false;
                    updateArsipCount();
                } catch (e) { showNotification('Gagal memuat arsip.', 'error'); }
                finally { hideLoadingOverlay(); }
            }

            function toggleSemuaArsip(src) {
                const nyala = src ? src.checked : false;
                document.querySelectorAll('.cb-arsip').forEach(c => { c.checked = nyala; });
                updateArsipCount();
            }
            function updateArsipCount() {
                const n = document.querySelectorAll('.cb-arsip:checked').length;
                setTextSafely('kmArsipCount', n);
                setDisabledSafely('btnPulihkanArsip', n === 0);
            }

            async function kmPulihkanTerpilih() {
                const kode = [];
                document.querySelectorAll('.cb-arsip:checked').forEach(c => kode.push(c.value));
                if (!kode.length) { showNotification('Tidak ada baris yang dipilih.', 'error'); return; }
                const ya = await showConfirmModal({
                    title: 'Pulihkan ' + kode.length + ' baris',
                    message: 'Baris ini akan kembali muncul di daftar aktif dan dapat dipakai lagi untuk dokumen baru.',
                    confirmText: 'Pulihkan'
                });
                if (!ya) return;
                showLoadingOverlay('Memulihkan...');
                try {
                    const res = await fetchApp({ action: 'masterUnarchive', jenis: kmArsipJenis, kode: kode });
                    if (res.status !== 'success') { showNotification(res.message || 'Gagal memulihkan.', 'error'); return; }
                    kmLaporkanHasil(res);
                    await kmMuatArsip();
                    await KM_MUAT[kmArsipJenis]();
                } catch (e) { showNotification('Gagal memulihkan.', 'error'); }
                finally { hideLoadingOverlay(); }
            }

            function toggleSemuaCampaign(src) {
                document.querySelectorAll('.cb-campaign').forEach(c => { if (!c.disabled) c.checked = src.checked; });
                updateCampaignHapusCount();
            }

            function updateCampaignHapusCount() {
                const n = rcPilihanSerap('cb-campaign', null, 'cbCampaignAll');
                setTextSafely('campaignArsipCount', n);
                setDisabledSafely('btnArsipCampaign', n === 0);
                const el = document.getElementById('campaignHapusCount'); if (el) el.innerText = n;
                setDisabledSafely('btnHapusCampaign', n === 0);
            }

            async function hapusCampaignTerpilih() {
                const kode = rcPilihanKunci('cb-campaign');
                if (kode.length === 0) return;
                const setuju = await showConfirmModal({
                    title: 'Konfirmasi Hapus Campaign',
                    message: kode.length + ' campaign akan dihapus permanen dari master. '
                        + 'Hanya campaign yang belum memiliki dokumen yang dapat dihapus; sisanya akan ditolak '
                        + 'beserta alasannya.',
                    confirmText: 'Ya, Hapus', danger: true
                });
                if (!setuju) return;
                showLoadingOverlay('Menghapus campaign...');
                try {
                    const res = await fetchApp({ action: 'campaignDelete', campaigns: kode });
                    if (res.status !== 'success') { showNotification(res.message || 'Gagal menghapus.', 'error'); return; }
                    showNotification(res.message, Number(res.jumlahGagal || 0) > 0 ? 'warning' : 'success');
                    logActivity('Hapus campaign: ' + res.berhasil + ' dari ' + kode.length);
                    if (Number(res.jumlahGagal || 0) > 0) {
                        rcDialog('Campaign yang tidak dapat dihapus',
                            '<table class="w-full text-sm"><thead class="bg-gray-50"><tr>'
                            + '<th class="p-2 text-left text-[10px] font-black uppercase">Kode</th>'
                            + '<th class="p-2 text-left text-[10px] font-black uppercase">Sebab</th></tr></thead><tbody>'
                            + (res.gagal || []).map(g => '<tr class="border-b border-gray-100">'
                                + '<td class="p-2 font-mono">' + rcEsc(g.kode) + '</td>'
                                + '<td class="p-2 text-red-700">' + rcEsc(g.sebab) + '</td></tr>').join('')
                            + '</tbody></table>');
                    }
                    rcPilihanKosongkan('cb-campaign');
                    loadCampaignMaster(rcMasterState.campaign.offset);
                } catch (e) { showNotification('Gagal menghapus campaign.', 'error'); }
                finally { hideLoadingOverlay(); }
            }

            async function bukaMemoCampaign(i) {
                const r = rcMasterState.campaign.rows[i]; if (!r || !r.memoPath) return;
                showLoadingOverlay('Membuka memo...');
                try {
                    const res = await fetchApp({ action: 'campaignMemoUrl', path: r.memoPath });
                    if (res.status !== 'success' || !res.url) {
                        showNotification(res.message || 'Gagal membuka memo.', 'error'); return;
                    }
                    window.open(res.url, '_blank', 'noopener');
                } catch (e) { showNotification('Gagal membuka memo.', 'error'); }
                finally { hideLoadingOverlay(); }
            }

            // Unggah memo dari dalam editor baris. Campaign harus sudah tersimpan lebih dulu,
            // karena jalur berkasnya memakai id campaign - berkas tanpa baris pemilik hanya akan
            // menjadi objek yatim di Storage.
            async function unggahMemoCampaign(input) {
                const berkas = input.files && input.files[0];
                input.value = '';
                if (!berkas) return;
                if (!rcEditorRow || !rcEditorRow.id) {
                    showNotification('Simpan campaign-nya lebih dulu, baru lampirkan memo.', 'warning'); return;
                }
                showLoadingOverlay('Mengunggah memo...');
                try {
                    const res = await fetchApp({
                        action: 'campaignMemoUpload', campaign: rcEditorRow.codeCampaign,
                        campaignId: rcEditorRow.id, file: berkas
                    });
                    if (res.status !== 'success') { showNotification(res.message || 'Gagal mengunggah memo.', 'error'); return; }
                    showNotification('Memo tersimpan.', 'success');
                    logActivity('Lampirkan memo campaign ' + rcEditorRow.codeCampaign);
                    closeRcRowEditor();
                    loadCampaignMaster(rcMasterState.campaign.offset);
                } catch (e) { showNotification('Gagal mengunggah memo.', 'error'); }
                finally { hideLoadingOverlay(); }
            }

            async function lepasMemoCampaign() {
                if (!rcEditorRow || !rcEditorRow.memoPath) return;
                const setuju = await showConfirmModal({
                    title: 'Lepas Memo',
                    message: 'Memo "' + (rcEditorRow.memoName || '') + '" akan dilepas dari campaign ini.',
                    confirmText: 'Ya, Lepas', danger: true
                });
                if (!setuju) return;
                showLoadingOverlay('Melepas memo...');
                try {
                    const res = await fetchApp({ action: 'campaignMemoClear', campaign: rcEditorRow.codeCampaign });
                    if (res.status !== 'success') { showNotification(res.message || 'Gagal melepas memo.', 'error'); return; }
                    showNotification('Memo dilepas.', 'success');
                    closeRcRowEditor();
                    loadCampaignMaster(rcMasterState.campaign.offset);
                } catch (e) { showNotification('Gagal melepas memo.', 'error'); }
                finally { hideLoadingOverlay(); }
            }

            // ---------- Editor satu baris ----------
            const RC_FIELDS = {
                // Kode Depot (20261163090000): tanpa kaitan depot, customer tidak terlihat oleh
                // siapa pun, jadi toko baru tampak "tidak tersimpan". Wajib, satu atau lebih kode.
                customer: [['custCode','Customer Code',true],['custName','Nama Pelanggan',true],
                           ['kodeDepot','Kode Depot',true],['top','TOP',false],
                           ['ktp','No KTP',false],['npwp','No NPWP',false],['namaRek','Nama Rekening',false],
                           ['noRek','Nomor Rekening',false],['bank','Nama Bank',false],['contactPerson','Contact Person',false]],
                // Unsur keempat menandai jenis kolom. Tanpa penanda, seluruh kolom dirender
                // sebagai kotak teks - dan status campaign yang diketik bebas akan ditolak
                // server setelah formulirnya dikirim, bukan dicegah saat diisi.
                // Tiga periode berdiri sendiri-sendiri. Periode Campaign adalah masa berlaku
                // programnya; Periode SO dan Periode Billing adalah rentang dokumen yang boleh
                // diklaim atasnya, dan keduanya kerap berbeda - itulah sebabnya dipisah, bukan
                // diturunkan dari satu periode saja.
                campaign: [['codeCampaign','Code Campaign',true],['campaignName','Nama Campaign',true],
                           ['status','Status Campaign',false,'select'],
                           ['periodStart','Periode Campaign Start',false],['periodEnd','Periode Campaign End',false],
                           ['soStart','Periode SO Start',false],['soEnd','Periode SO End',false],
                           ['billingStart','Periode Billing Start',false],['billingEnd','Periode Billing End',false],
                           ['jenisCb','Jenis CB (Transfer / CN / Voucher / Rebate)',false],['statusPajak','Status Pajak',false]]
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
                    if (key === 'kodeDepot' && rcEditorRow) val = (rcEditorRow.depotCodes || []).join(', ');
                    // Kode pelanggan dan kode campaign adalah identitas baris. Mengubahnya akan
                    // memutus kaitan dengan claim yang sudah ada, jadi pada mode ubah field itu
                    // dibuat readonly, bukan disabled: nilainya tetap terbaca, dapat disalin,
                    // dan alasannya dinyatakan di layar alih-alih terlihat seperti kerusakan.
                    let kunci = rcEditorRow && key === RC_FIELDS[kind][0][0];
                    // Identitas panjang seperti KTP, NPWP dan rekening ditulis penuh dengan
                    // huruf lebar tetap supaya tidak pernah terbaca terpotong.
                    let identitas = ['ktp','npwp','noRek','top'].indexOf(key) !== -1;
                    if (f[3] === 'select' && key === 'status') {
                        let aktif = String(val || 'active').toLowerCase();
                        html += '<div><label class="block text-sm font-medium text-gray-700 mb-1">' + label + '</label>'
                            + '<select id="rcField_status" class="w-full px-4 py-2.5 border rounded-lg text-sm bg-gray-50 focus:bg-white">'
                            + Object.keys(RC_STATUS_CAMPAIGN).map(function (k) {
                                return '<option value="' + k + '"' + (k === aktif ? ' selected' : '') + '>'
                                    + RC_STATUS_CAMPAIGN[k].label + '</option>';
                            }).join('')
                            + '</select>'
                            + '<p class="text-[11px] text-gray-500 mt-1">Inactive: dokumen baru ditolak dan dokumen '
                            + 'yang ada tidak dapat dimajukan. Cleared: campaign sudah selesai, dokumen baru ditolak '
                            + 'tetapi yang sedang berjalan tetap dapat diselesaikan.</p></div>';
                        return;
                    }
                    html += '<div><label class="block text-sm font-medium text-gray-700 mb-1">' + label
                        + (required ? ' <span class="text-red-500">*</span>' : '')
                        + (kunci ? ' <span class="text-[10px] font-normal text-gray-400">(kunci, tidak dapat diubah)</span>' : '')
                        + '</label>'
                        + '<input id="rcField_' + key + '" value="' + rcEsc(rcFull(val)) + '"'
                        + (kunci ? ' readonly' : '')
                        + (identitas ? ' inputmode="numeric" autocomplete="off"' : '')
                        + ' class="w-full px-4 py-2.5 border rounded-lg text-sm bg-gray-50 focus:bg-white'
                        + (kunci ? ' bg-gray-100 text-gray-600 cursor-not-allowed' : '')
                        + (identitas ? ' font-mono tracking-wide' : '') + '">'
                        + (key === 'kodeDepot'
                            ? '<p class="text-[11px] text-gray-500 mt-1">Satu atau lebih kode dari Depot Master, dipisah koma (contoh: 4A, 5K). '
                              + 'Toko hanya terlihat oleh depot yang tercantum di sini.</p>'
                            : '')
                        + '</div>';
                });
                if (kind === 'customer') {
                    html += '<p class="text-xs text-gray-500 bg-gray-50 border border-gray-200 rounded-lg p-3">Subyek pajak tidak diisi manual. NPWP terisi berarti <b>Badan</b>; bila KTP juga diisi, KTP hanya tersimpan di sini dan tidak dipakai di dokumen klaim. Hanya KTP berarti <b>Perorangan</b>. Tanpa KTP maupun NPWP, upload klaim pelanggan ini ditolak.</p>';
                }
                if (kind === 'campaign') {
                    // Memo hanya dapat dilampirkan pada campaign yang sudah tersimpan: jalur
                    // berkasnya memakai id campaign, dan campaign baru belum punya id.
                    html += '<div class="border border-gray-200 rounded-lg p-3 bg-gray-50">'
                        + '<label class="block text-sm font-medium text-gray-700 mb-2">Memo (PDF, maks 10 MB)</label>';
                    if (!rcEditorRow || !rcEditorRow.id) {
                        html += '<p class="text-xs text-gray-500">Simpan campaign-nya lebih dulu, baru memo dapat dilampirkan.</p>';
                    } else if (rcEditorRow.memoPath) {
                        html += '<div class="flex flex-wrap items-center gap-2">'
                            + '<span class="text-xs font-bold text-gray-700"><i class="fas fa-file-pdf text-red-600 mr-1"></i>'
                            + rcEsc(rcEditorRow.memoName || 'memo.pdf') + '</span>'
                            + '<span class="text-[11px] text-gray-400">' + rcEsc(rcEditorRow.memoUploadedOn || '') + '</span>'
                            + '<button type="button" onclick="lepasMemoCampaign()" class="px-3 py-1.5 bg-white border border-red-200 text-red-700 font-bold rounded-lg text-xs">Lepas</button>'
                            + '<label class="px-3 py-1.5 bg-white border border-gray-300 text-gray-700 font-bold rounded-lg text-xs cursor-pointer">Ganti'
                            + '<input type="file" accept="application/pdf" class="hidden" onchange="unggahMemoCampaign(this)"></label></div>';
                    } else {
                        html += '<label class="px-4 py-2 bg-white border border-gray-300 hover:bg-gray-100 text-gray-700 font-bold rounded-lg text-xs cursor-pointer inline-block">'
                            + '<i class="fas fa-upload mr-2 text-blue-600"></i>Pilih PDF'
                            + '<input type="file" accept="application/pdf" class="hidden" onchange="unggahMemoCampaign(this)"></label>';
                    }
                    html += '</div>';
                }
                document.getElementById('rcRowEditorFields').innerHTML = html;
                setHiddenSafely('rcRowEditorModal', false);
            }
            function closeRcRowEditor() { setHiddenSafely('rcRowEditorModal', true); }

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
                        if ((res.tanpaDepot || []).length) showNotification('Tersimpan, tetapi ' + res.tanpaDepot.join(', ')
                            + ' belum punya Kode Depot sehingga tidak terlihat. Isi Kode Depot lalu simpan lagi.', 'warning');
                        else showNotification("Data master tersimpan.", "success");
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
                // Kode Depot wajib untuk customer baru (20261163090000); lebih dari satu dipisah koma.
                // Pada customer lama, kolom kosong membiarkan kaitan depotnya seperti semula.
                Customer: { headers: ['Customer Code','Customer Name','Kode Depot','TOP','No KTP','No NPWP','Nama Rekening','Nomor Rekening','Nama Bank','Contact Person'],
                            keys: ['custCode','custName','kodeDepot','top','ktp','npwp','namaRek','noRek','bank','contactPerson'],
                            contoh: ['C00123','TOKO MAJU JAYA','4A','30','','012345678901234','TOKO MAJU JAYA','0081234567','BCA','Budi 0812xxxx'] },
                // Urutan kolom template MENGIKUTI urutan keys di bawahnya; menambah satu tanpa
                // yang lain akan menggeser seluruh pembacaan. Keduanya diubah bersama di sini.
                Campaign: { headers: ['Code Campaign','Nama Campaign','Periode Start','Periode End',
                                      'Periode SO Start','Periode SO End','Periode Billing Start','Periode Billing End',
                                      'Jenis CB','Status Pajak','Status Campaign'],
                            keys: ['codeCampaign','campaignName','periodStart','periodEnd',
                                   'soStart','soEnd','billingStart','billingEnd',
                                   'jenisCb','statusPajak','status'],
                            contoh: ['CMP2601','PROMO AWAL TAHUN','01-01-2026','31-03-2026',
                                     '01-01-2026','31-03-2026','01-02-2026','30-04-2026',
                                     'Transfer','PKP','active'] }
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
                if (file.size > RC_MAKS_MB[kind] * 1024 * 1024) { showNotification("File maksimal " + RC_MAKS_MB[kind] + " MB.", "error"); fileInput.value = ''; return; }
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
                        let out = [], baris = [], beresiko = [];
                        for (let i = hIdx + 1; i < rows.length; i++) {
                            let raw = rows[i]; if (!raw) continue;
                            let obj = {}, kosong = true;
                            t.keys.forEach(k => {
                                let cell = colMap[k] === undefined ? '' : raw[colMap[k]];
                                if (rcPrecisionRisk(cell)) beresiko.push('baris ' + (i + 1) + ' kolom ' + k);
                                let v = rcCellText(cell);
                                if (v) kosong = false;
                                // Customer Master (pemilik, 16 Oktober 2026): "jika yg diupload kosong maka akan
                                // menggunakan data yang lama". Sel kosong tidak dikirim, dan server membiarkan
                                // kolom yang tidak dikirim. "-" berarti sengaja dikosongkan. Formulir Ubah tetap
                                // mengirim semua kolom, jadi masih bisa mengosongkan.
                                if (kind === 'Customer' && k !== t.keys[0]) {
                                    if (v === '') return;
                                    if (v === '-') { obj[k] = ''; return; }
                                }
                                obj[k] = v;
                            });
                            if (kosong) continue;
                            if (!obj[t.keys[0]]) { showNotification("Baris " + (i + 1) + ": " + t.headers[0] + " kosong.", "error"); return; }
                            out.push(obj); baris.push(i + 1);
                        }
                        if (out.length === 0) { showNotification("Tidak ada baris data.", "warning"); return; }
                        if (out.length > RC_MAKS_BARIS[kind]) {
                            showNotification("Maksimal " + RC_MAKS_BARIS[kind].toLocaleString('id-ID') + " baris per unggahan.", "error"); return; }
                        if (beresiko.length > 0) {
                            showNotification("Ada angka terlalu panjang sehingga digitnya bisa berubah: "
                                + beresiko.slice(0, 3).join(', ') + ". Format kolom itu sebagai Teks di Excel lalu ulangi.", "error");
                            return;
                        }
                        rcPendingUpload[kind] = out;
                        rcPendingBaris[kind] = baris;
                        const tanpaDepot = kind === 'Customer' ? out.filter(o => !o.kodeDepot).length : 0;
                        // Kode yang muncul lebih dari sekali: baris paling bawah yang berlaku (disimpan terakhir).
                        const hitung = {};
                        out.forEach(o => { const k = String(o[t.keys[0]] || '').trim().toUpperCase(); hitung[k] = (hitung[k] || 0) + 1; });
                        const ganda = Object.keys(hitung).filter(k => hitung[k] > 1);
                        const bagian = Math.ceil(out.length / RC_BAGIAN_UNGGAH);
                        document.getElementById(kind.toLowerCase() + 'UploadText').innerText =
                            out.length.toLocaleString('id-ID') + ' baris siap disimpan. '
                            + (kind === 'Customer' ? 'Untuk kode yang sudah ada, kolom terisi menimpa data lama, kolom kosong memakai data lama, dan "-" mengosongkan.'
                                : 'Kode yang sudah ada akan ditimpa oleh data ini.')
                            + (bagian > 1 ? ' Disimpan otomatis dalam ' + bagian + ' bagian @ ' + RC_BAGIAN_UNGGAH.toLocaleString('id-ID')
                                + ' baris; seluruh berkas diperiksa dulu, jadi bila ada satu baris salah tidak ada yang tersimpan.' : '')
                            + (ganda.length ? ' ' + ganda.length + ' kode muncul lebih dari sekali (mis. ' + ganda.slice(0, 3).join(', ')
                                + '); baris paling bawah yang berlaku.' : '')
                            + (tanpaDepot ? ' ' + tanpaDepot + ' baris tanpa Kode Depot: customer BARU di antaranya akan ditolak, '
                                + 'customer lama tetap memakai depot yang sudah tercatat.' : '');
                        setHiddenSafely(kind.toLowerCase() + 'UploadInfo', false);
                    } catch (err) { showNotification("File tidak dapat dibaca.", "error"); }
                };
                reader.readAsArrayBuffer(file);
            }

            function cancelMasterUpload(kind) {
                rcPendingUpload[kind] = null;
                rcPendingBaris[kind] = null;
                setHiddenSafely(kind.toLowerCase() + 'UploadInfo', true);
                let f = document.getElementById(kind.toLowerCase() + 'File'); if (f) f.value = '';
            }

            function commitCustomerUpload() { commitRcUpload('Customer', 'customerUpsert', loadCustomerMaster); }
            function commitCampaignUpload() { commitRcUpload('Campaign', 'campaignUpsert', loadCampaignMaster); }

            // Pesan galat server menyebut Customer Code; tambahkan nomor baris Excel-nya.
            function rcBarisDariPesan(pesan, rows, baris, kunci) {
                const teks = String(pesan || '').toUpperCase();
                for (let i = 0; i < rows.length; i++) {
                    const kode = String(rows[i][kunci] || '').trim().toUpperCase();
                    if (!kode) continue;
                    const pola = new RegExp('(^|[^A-Z0-9])' + kode.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '([^A-Z0-9]|$)');
                    if (pola.test(teks)) return ' (baris Excel ' + baris[i] + ')';
                }
                return '';
            }

            // Unggahan lebih dari RC_BAGIAN_UNGGAH baris (Customer Master): semua bagian DIPERIKSA
            // dulu dengan aturan simpan yang sama lalu dibatalkan server, baru disimpan bagian demi
            // bagian. Simpan Customer Master menimpa data yang sama, jadi mengulang berkas yang sama
            // setelah gangguan jaringan aman.
            async function commitRcUploadBertahap(kind, action, reload, rows, baris) {
                const n = rows.length, kunci = RC_TEMPLATE[kind].keys[0];
                const jumlahBagian = Math.ceil(n / RC_BAGIAN_UNGGAH);
                const potong = i => rows.slice(i * RC_BAGIAN_UNGGAH, (i + 1) * RC_BAGIAN_UNGGAH);
                const rentang = i => (i * RC_BAGIAN_UNGGAH + 1).toLocaleString('id-ID') + '-' + Math.min(n, (i + 1) * RC_BAGIAN_UNGGAH).toLocaleString('id-ID');
                for (let i = 0; i < jumlahBagian; i++) {
                    showLoadingOverlay('Memeriksa ' + kind + ' Master: bagian ' + (i + 1) + ' dari ' + jumlahBagian + ' (baris data ' + rentang(i) + ' dari ' + n.toLocaleString('id-ID') + ')...');
                    const res = await fetchApp({ action: action + 'Periksa', rows: potong(i) });
                    if (res.status !== 'success') {
                        const b = baris.slice(i * RC_BAGIAN_UNGGAH, (i + 1) * RC_BAGIAN_UNGGAH);
                        showNotification('Tidak ada yang disimpan. ' + (res.message || 'Pemeriksaan gagal.') + rcBarisDariPesan(res.message, potong(i), b, kunci)
                            + '. Perbaiki berkas lalu unggah ulang.', 'error');
                        return;
                    }
                }
                let dibuat = 0, diperbarui = 0, tanpa = [];
                for (let i = 0; i < jumlahBagian; i++) {
                    showLoadingOverlay('Menyimpan ' + kind + ' Master: bagian ' + (i + 1) + ' dari ' + jumlahBagian + ' (baris data ' + rentang(i) + ' dari ' + n.toLocaleString('id-ID') + ')...');
                    const res = await fetchApp({ action: action, rows: potong(i) });
                    if (res.status !== 'success') {
                        showNotification('Bagian ' + (i + 1) + ' dari ' + jumlahBagian + ' gagal: ' + (res.message || 'Gagal menyimpan.')
                            + '. ' + (i > 0 ? 'Baris data 1-' + (i * RC_BAGIAN_UNGGAH).toLocaleString('id-ID') + ' sudah tersimpan. ' : '')
                            + 'Unggah ulang berkas yang sama; baris yang sudah tersimpan aman ditimpa ulang.', 'error');
                        logActivity('Mass upload ' + kind + ' Master terhenti di bagian ' + (i + 1) + '/' + jumlahBagian + ': ' + n + ' baris');
                        reload(0);
                        return;
                    }
                    dibuat += res.dibuat || 0; diperbarui += res.diperbarui || 0; tanpa = tanpa.concat(res.tanpaDepot || []);
                }
                showNotification(dibuat.toLocaleString('id-ID') + ' baris baru, ' + diperbarui.toLocaleString('id-ID') + ' diperbarui (' + jumlahBagian + ' bagian).'
                    + (tanpa.length ? ' ' + tanpa.length + ' customer belum punya Kode Depot sehingga tidak terlihat: '
                        + tanpa.slice(0, 5).join(', ') + (tanpa.length > 5 ? ', ...' : '') : ''), tanpa.length ? "warning" : "success");
                logActivity('Mass upload ' + kind + ' Master: ' + n + ' baris dalam ' + jumlahBagian + ' bagian');
                cancelMasterUpload(kind); reload(0);
            }

            async function commitRcUpload(kind, action, reload) {
                let rows = rcPendingUpload[kind];
                if (!rows) return;
                const bertahap = rows.length > RC_BAGIAN_UNGGAH;
                let confirmed = await showConfirmModal({ title: "Konfirmasi Upload Master",
                    message: rows.length.toLocaleString('id-ID') + " baris akan disimpan ke " + kind + " Master.\n\n"
                        + (kind === 'Customer' ? "Kode yang sudah ada: kolom terisi MENIMPA data lama, kolom kosong memakai data lama, \"-\" mengosongkan."
                            : "Kode yang sudah ada akan DITIMPA oleh data dari file ini.")
                        + (bertahap ? "\n\nBerkas besar: diperiksa seluruhnya dulu, lalu disimpan otomatis dalam "
                            + Math.ceil(rows.length / RC_BAGIAN_UNGGAH) + " bagian. Jangan tutup halaman sampai selesai." : ""),
                    confirmText: "Ya, Simpan", danger: false });
                if (!confirmed) return;
                setDisabledSafely('btnCommit' + kind, true);
                showLoadingOverlay("Menyimpan " + kind + " Master...");
                if (bertahap) {
                    try { await commitRcUploadBertahap(kind, action, reload, rows, rcPendingBaris[kind] || []); }
                    catch (e) { showNotification("Gagal terhubung ke server. Unggah ulang berkas yang sama; baris yang sudah tersimpan aman ditimpa ulang.", "error"); }
                    finally { setDisabledSafely('btnCommit' + kind, false); hideLoadingOverlay(); }
                    return;
                }
                try {
                    let res = await fetchApp({ action: action, rows: rows });
                    if (res.status === 'success') {
                        const tanpa = res.tanpaDepot || [];
                        showNotification((res.dibuat || 0) + " baris baru, " + (res.diperbarui || 0) + " diperbarui."
                            + (tanpa.length ? ' ' + tanpa.length + ' customer belum punya Kode Depot sehingga tidak terlihat: '
                                + tanpa.slice(0, 5).join(', ') + (tanpa.length > 5 ? ', ...' : '') : ''), tanpa.length ? "warning" : "success");
                        logActivity('Mass upload ' + kind + ' Master: ' + rows.length + ' baris');
                        cancelMasterUpload(kind); reload(0);
                    } else { showNotification(res.message || "Gagal menyimpan.", "error"); }
                } catch (e) { showNotification("Gagal terhubung ke server.", "error"); }
                finally { setDisabledSafely('btnCommit' + kind, false); hideLoadingOverlay(); }
            }

            // ---------- Cashback Compilation ----------