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
                // Pilihan Depot dari server: hanya depot yang boleh dilihat akun ini.
                let selDepot = document.getElementById('compDepot');
                if (selDepot && selDepot.options.length <= 1 && rcCanTab('compilation.list')) {
                    try {
                        let res = await fetchApp({ action: 'compilationDepots' });
                        if (res.status === 'success') {
                            (res.rows || []).forEach(d => {
                                let o = document.createElement('option');
                                o.value = d.kode;
                                o.textContent = d.kode + ' - ' + d.nama;
                                selDepot.appendChild(o);
                            });
                        }
                    } catch (e) { showNotification("Gagal memuat daftar depot.", "error"); }
                }
                if(rcCanTab('compilation.list'))loadCompilation(0);
            }

            // ---- Daftar Document Center -------------------------------------------------
            // 20261163060000: filter diterapkan langsung, penyaringan tetap di server. Setiap
            // permintaan diberi nomor urut; jawaban yang datang sesudah permintaan yang lebih
            // baru diabaikan, supaya hasil ketikan lama tidak menimpa hasil ketikan terakhir.
            let rcCompMuatKe = 0;
            const COMP_PILIH_MAKS = 5000;   // Pilih semua hasil
            const COMP_ARSIP_MAKS = 2000;   // satu kali arsip

            function compFilterLayar() {
                return {
                    campaign: document.getElementById('compCampaign').value,
                    depot: (document.getElementById('compDepot') || {}).value || '',
                    batch: document.getElementById('compBatch').value.trim(),
                    status: document.getElementById('compStatus').value,
                    search: document.getElementById('compSearch').value.trim(),
                    // Created On (20261163090000): yyyy-mm-dd dari input tanggal; kosong = tidak disaring.
                    dibuatDari: (document.getElementById('compDibuatDari') || {}).value || '',
                    dibuatSampai: (document.getElementById('compDibuatSampai') || {}).value || ''
                };
            }

            // Kotak teks: mencari setengah detik setelah pengguna berhenti mengetik.
            function compCariOtomatis() { debounceSearch(() => loadCompilation(0), 500); }

            async function loadCompilation(offset) {
                const ke = ++rcCompMuatKe;
                const filter = compFilterLayar();
                if (filter.dibuatDari && filter.dibuatSampai && filter.dibuatDari > filter.dibuatSampai) {
                    showNotification('Tanggal Created On "dari" lebih akhir daripada "sampai".', 'warning');
                    return;
                }
                setHiddenSafely('compMuat', false);
                try {
                    let res = await fetchApp(Object.assign({ action: 'compilationList', offset: offset }, filter));
                    if (ke !== rcCompMuatKe) return;
                    if (res.status !== 'success') { showNotification(res.message || "Gagal menarik data.", "error"); return; }
                    rcCompState = Object.assign(rcCompState, { offset: offset, rows: res.rows || [], canArchive: !!res.canArchive,
                        total: Number(res.total) || 0, filter: filter });
                    setHiddenSafely('btnArchivedList', !res.canArchive);
                    setHiddenSafely('compArchiveBar', !res.canArchive);
                    renderCompilation();
                } catch (e) { if (ke === rcCompMuatKe) showNotification("Gagal menarik data cashback.", "error"); }
                finally { if (ke === rcCompMuatKe) setHiddenSafely('compMuat', true); }
            }

            // Susunan kolom Document Center, mengikuti pola tab Open. "baku" = susunan yang sudah
            // ada sebelumnya; kolom tambahan dimatikan lebih dulu. unduh = kolom Excel-nya: sel
            // gabungan di layar (Depot, Toko, Campaign, Batch) dipecah menjadi kolomnya masing-
            // masing, kode ditulis sebagai teks supaya nol di depan tidak hilang, dan nominal
            // dipotong bulat seperti di layar.
            const compKosong = (v) => v === null || v === undefined || v === '' || v === '-';
            const compUang = (v) => compKosong(v) ? '-' : rcMoney(v);
            const compUangUnduh = (v) => compKosong(v) ? '' : Math.trunc(Number(v) || 0);
            const compTgl = (v) => compKosong(v) ? '-' : rcDisplayDate(v);
            const compTglUnduh = (v) => compKosong(v) ? '' : rcDisplayDate(v);
            const compTeks = (v) => compKosong(v) ? '-' : rcEsc(v);
            const compTeksUnduh = (v) => compKosong(v) ? '' : rcSelTeks(v);
            const COMP_KOLOM = [
                { k: 'noDoc', judul: 'No Doc', baku: true, kelas: 'font-black text-blue-700', sel: r => rcEsc(r.noDoc),
                  unduh: [['No Doc', r => rcSelTeks(r.noDoc)]] },
                { k: 'status', judul: 'Status', baku: true, kelas: 'text-center',
                  sel: r => '<span class="' + rcStatusClass(r.status) + ' px-2 py-1 rounded text-[10px] font-black uppercase">' + rcEsc(r.status) + '</span>',
                  unduh: [['Status', r => r.status || '']] },
                { k: 'depot', judul: 'Depot', baku: true, kelas: 'text-xs',
                  sel: r => '<b>' + rcEsc(r.kodeDepot || '-') + '</b><br><span class="text-gray-500">' + rcEsc(r.depot || '') + '</span>',
                  unduh: [['Kode Depot', r => compTeksUnduh(r.kodeDepot)], ['Nama Depot', r => r.depot || '']] },
                { k: 'toko', judul: 'Toko', baku: true, kelas: 'text-xs',
                  sel: r => '<b>' + rcEsc(r.namaToko) + '</b><br><span class="text-gray-500">' + rcEsc(r.kodeToko) + '</span>'
                      + (r.contactPerson ? '<br><span class="text-gray-400">' + rcEsc(r.contactPerson) + '</span>' : ''),
                  unduh: [['Kode Toko', r => compTeksUnduh(r.kodeToko)], ['Nama Toko', r => r.namaToko || '']] },
                { k: 'campaign', judul: 'Campaign', baku: true, kelas: 'text-xs',
                  sel: r => '<b>' + rcEsc(r.codeCampaign) + '</b><br><span class="text-gray-500">' + rcEsc(r.campaignName) + '</span>',
                  unduh: [['Kode Campaign', r => compTeksUnduh(r.codeCampaign)], ['Nama Campaign', r => r.campaignName || '']] },
                { k: 'jenisCb', judul: 'Jenis CB', baku: true, kelas: 'text-center text-xs font-bold', sel: r => compTeks(r.jenisCb),
                  unduh: [['Jenis CB', r => r.jenisCb || '']] },
                { k: 'subyekPajak', judul: 'Subyek', baku: true, kelas: 'text-center text-xs', sel: r => compTeks(r.subyekPajak),
                  unduh: [['Subyek Pajak', r => r.subyekPajak || '']] },
                { k: 'cbNet', judul: 'Cashback', baku: true, kelas: 'text-right font-black text-red-600 whitespace-nowrap', sel: r => rcMoney(r.cbNet),
                  unduh: [['Cashback', r => Math.trunc(Number(r.cbNet) || 0)]] },
                { k: 'grossUpCb', judul: 'Gross Up', baku: true, kelas: 'text-right font-bold text-orange-700 whitespace-nowrap', sel: r => rcMoney(r.grossUpCb),
                  unduh: [['Gross Up', r => Math.trunc(Number(r.grossUpCb) || 0)]] },
                { k: 'batch', judul: 'Batch', baku: true, kelas: 'text-[10px] text-gray-500',
                  sel: r => [r.batchUpload, r.batchRelease, r.batchClaim, r.batchClearing].map(rcFull).filter(Boolean).map(rcEsc).join('<br>') || '-',
                  unduh: [['Batch Upload', r => compTeksUnduh(r.batchUpload)], ['Batch Release', r => compTeksUnduh(r.batchRelease)],
                          ['Batch Claim', r => compTeksUnduh(r.batchClaim)], ['Batch Clearing', r => compTeksUnduh(r.batchClearing)]] },
                { k: 'region', judul: 'Region', baku: false, kelas: 'text-xs', sel: r => compTeks(r.region),
                  unduh: [['Region', r => r.region || '']] },
                { k: 'contactPerson', judul: 'Contact Person', baku: false, kelas: 'text-xs', sel: r => compTeks(r.contactPerson),
                  unduh: [['Contact Person', r => r.contactPerson || '']] },
                { k: 'statusPajak', judul: 'Status Pajak', baku: false, kelas: 'text-xs', sel: r => compTeks(r.statusPajak),
                  unduh: [['Status Pajak', r => r.statusPajak || '']] },
                { k: 'netValue', judul: 'Net Value', baku: false, kelas: 'text-right text-xs whitespace-nowrap', sel: r => compUang(r.netValue),
                  unduh: [['Net Value', r => compUangUnduh(r.netValue)]] },
                { k: 'volume', judul: 'Volume', baku: false, kelas: 'text-right text-xs whitespace-nowrap',
                  sel: r => compKosong(r.volume) ? '-' : Math.trunc(Number(r.volume) || 0).toLocaleString('id-ID'),
                  unduh: [['Volume', r => compUangUnduh(r.volume)]] },
                { k: 'totTagih', judul: 'Total Tagihan', baku: false, kelas: 'text-right text-xs whitespace-nowrap', sel: r => compUang(r.totTagih),
                  unduh: [['Total Tagihan', r => compUangUnduh(r.totTagih)]] },
                { k: 'soStart', judul: 'Start SO', baku: false, kelas: 'text-center text-xs whitespace-nowrap', sel: r => compTgl(r.soStart),
                  unduh: [['Start SO', r => compTglUnduh(r.soStart)]] },
                { k: 'soEnd', judul: 'End SO', baku: false, kelas: 'text-center text-xs whitespace-nowrap', sel: r => compTgl(r.soEnd),
                  unduh: [['End SO', r => compTglUnduh(r.soEnd)]] },
                { k: 'billingStart', judul: 'Start Billing', baku: false, kelas: 'text-center text-xs whitespace-nowrap', sel: r => compTgl(r.billingStart),
                  unduh: [['Start Billing', r => compTglUnduh(r.billingStart)]] },
                { k: 'billingEnd', judul: 'End Billing', baku: false, kelas: 'text-center text-xs whitespace-nowrap', sel: r => compTgl(r.billingEnd),
                  unduh: [['End Billing', r => compTglUnduh(r.billingEnd)]] },
                { k: 'tglUpload', judul: 'Tgl Upload', baku: false, kelas: 'text-center text-xs whitespace-nowrap', sel: r => compTeks(r.tglUpload),
                  unduh: [['Tgl Upload', r => compKosong(r.tglUpload) ? '' : r.tglUpload]] },
                // Tanggal Done = tanggal proses pilihan pengguna di Clearing, dengan jam proses
                // (20261163130000). Dulu kolom ini berisi waktu tombol ditekan di sistem.
                { k: 'tglClearing', judul: 'Tgl Done (Clearing)', baku: false, kelas: 'text-center text-xs whitespace-nowrap', sel: r => compTeks(r.tglClearing),
                  unduh: [['Tgl Done (Clearing)', r => compKosong(r.tglClearing) ? '' : r.tglClearing]] },
                { k: 'tglAktual', judul: 'Tgl Transfer / Proses Aktual', baku: false, kelas: 'text-center text-xs whitespace-nowrap', sel: r => compTeks(r.tglAktual),
                  unduh: [['Tgl Transfer / Proses Aktual', r => compKosong(r.tglAktual) ? '' : r.tglAktual]] },
                { k: 'createdOn', judul: 'Created On', baku: false, kelas: 'text-center text-xs whitespace-nowrap', sel: r => compTeks(r.createdOn),
                  unduh: [['Created On', r => compKosong(r.createdOn) ? '' : r.createdOn]] },
                { k: 'createdBy', judul: 'Created By', baku: false, kelas: 'text-center text-xs', sel: r => compTeks(r.createdBy),
                  unduh: [['Created By', r => compTeksUnduh(r.createdBy)]] }
            ];

            // Pilihan kolom disimpan per browser, sama seperti tab Open.
            let compKolomAktif = null;
            function compKolomMuat() {
                if (compKolomAktif) return compKolomAktif;
                let simpan = null;
                try { simpan = JSON.parse(window.localStorage.getItem('rcCompKolom') || 'null'); } catch (e) { simpan = null; }
                compKolomAktif = {};
                COMP_KOLOM.forEach(c => { compKolomAktif[c.k] = (simpan && typeof simpan[c.k] === 'boolean') ? simpan[c.k] : c.baku; });
                return compKolomAktif;
            }
            function compKolomSimpan() {
                try { window.localStorage.setItem('rcCompKolom', JSON.stringify(compKolomAktif)); }
                catch (e) { /* penyimpanan ditolak; pilihan tetap berlaku untuk sesi ini */ }
            }
            function toggleCompKolomPanel() {
                const buka = document.getElementById('compKolomPanel').classList.contains('hidden');
                setHiddenSafely('compKolomPanel', !buka);
                if (buka) compKolomRender();
            }
            function compKolomRender() {
                const aktif = compKolomMuat();
                document.getElementById('compKolomDaftar').innerHTML = COMP_KOLOM.map(c =>
                    '<label class="flex items-center gap-2 text-sm text-gray-700"><input type="checkbox" class="rounded text-cyan-600" '
                    + 'onchange="compKolomUbah(\'' + c.k + '\', this.checked)"' + (aktif[c.k] ? ' checked' : '') + '>' + rcEsc(c.judul) + '</label>').join('');
            }
            function compKolomUbah(kunci, nyala) { compKolomMuat()[kunci] = nyala; compKolomSimpan(); renderCompilation(); }
            function compKolomSemua(semua) {
                const aktif = compKolomMuat();
                COMP_KOLOM.forEach(c => { aktif[c.k] = semua ? true : c.baku; });
                compKolomSimpan(); compKolomRender(); renderCompilation();
            }

            function renderCompilation() {
                const rows = rcCompState.rows || [];
                const aktif = compKolomMuat();
                const kolom = COMP_KOLOM.filter(c => aktif[c.k]);
                rcCompState.perId = new Map(rows.map(r => [String(r.id), r]));

                let totalCb = rows.reduce((s, r) => s + (Number(r.cbNet) || 0), 0);
                let totalGu = rows.reduce((s, r) => s + (Number(r.grossUpCb) || 0), 0);
                let toko = new Set(rows.map(r => r.kodeToko).filter(Boolean)).size;
                document.getElementById('compSummary').innerHTML =
                    '<span class="px-3 py-2 bg-gray-100 rounded-lg font-bold text-gray-700">Total baris: ' + (rcCompState.total || 0) + '</span>'
                    + '<span class="px-3 py-2 bg-purple-50 rounded-lg font-bold text-purple-800">Qty Toko: ' + toko + '</span>'
                    + '<span class="px-3 py-2 bg-red-50 rounded-lg font-bold text-red-700">Cashback: ' + rcMoney(totalCb) + '</span>'
                    + '<span class="px-3 py-2 bg-orange-50 rounded-lg font-bold text-orange-700">Gross Up: ' + rcMoney(totalGu) + '</span>';

                const rata = c => /text-right/.test(c.kelas || '') ? 'text-right' : (/text-center/.test(c.kelas || '') ? 'text-center' : 'text-left');
                document.getElementById('compTableHead').innerHTML =
                    '<th class="p-3 text-center font-bold" data-rc-no-sort="1"><input type="checkbox" id="compSelectAll" onchange="toggleAllCompilation(this)" class="w-4 h-4 rounded"></th>'
                    + kolom.map(c => '<th class="p-3 ' + rata(c) + ' font-bold whitespace-nowrap">' + rcEsc(c.judul) + '</th>').join('');
                document.getElementById('compTableBody').innerHTML = rows.map(r =>
                    '<tr class="border-b border-gray-100 hover:bg-cyan-50/40">'
                    + '<td class="p-3 text-center"><input type="checkbox" class="cb-comp w-4 h-4 rounded" value="' + rcEsc(r.id) + '" onchange="updateCompSelection()"></td>'
                    + kolom.map(c => '<td class="p-3 ' + (c.kelas || '') + '">' + c.sel(r) + '</td>').join('')
                    + '</tr>').join('')
                    || '<tr><td colspan="' + (kolom.length + 1) + '" class="p-8 text-center text-gray-500">Tidak ada data untuk filter ini.</td></tr>';
                setTextSafely('compKolomRingkas', kolom.length + ' dari ' + COMP_KOLOM.length + ' kolom ditampilkan');
                setTextSafely('compTotalHasil', Number(rcCompState.total || 0).toLocaleString('id-ID'));
                setDisabledSafely('btnCompPilihSemua', !rcCompState.total);
                renderRcPager('compPager', rcCompState.offset || 0, rows.length, rcCompState.total || 0, 'loadCompilation', 100);
                rcPilihanPulihkan('cb-comp', 'compSelectAll');
                updateCompSelection();
            }

            function toggleAllCompilation(src) {
                document.querySelectorAll('.cb-comp').forEach(c => c.checked = src.checked);
                updateCompSelection();
            }
            // Jumlahnya mencakup pilihan di semua halaman dan filter (28-pilihan-lintas-halaman.js).
            // Data barisnya ikut disimpan karena unduhan memerlukan isinya.
            function updateCompSelection() {
                let n = rcPilihanSerap('cb-comp', c => (rcCompState.perId && rcCompState.perId.get(c.value)) || true, 'compSelectAll');
                setTextSafely('compSelectedCount', n.toLocaleString('id-ID'));
                setTextSafely('compArsipCount', n.toLocaleString('id-ID'));
                setDisabledSafely('btnArchiveComp', n === 0);
                setDisabledSafely('btnCompUnduh', n === 0);
            }

            // Memilih SELURUH baris hasil filter terakhir, bukan hanya halaman yang tampil. Diambil
            // dari server per 500 baris memakai filter yang sama persis dengan tabel.
            async function compPilihSemuaHasil() {
                const total = Number(rcCompState.total) || 0;
                if (!total) return;
                if (total > COMP_PILIH_MAKS) {
                    showNotification('Hasil filter ' + total.toLocaleString('id-ID') + ' baris; Pilih semua hasil maksimal '
                        + COMP_PILIH_MAKS.toLocaleString('id-ID') + ' baris. Persempit filternya lebih dulu.', 'warning');
                    return;
                }
                const filter = rcCompState.filter || compFilterLayar();
                showLoadingOverlay('Memilih ' + total.toLocaleString('id-ID') + ' baris...');
                try {
                    const peta = rcPilihanPeta('cb-comp');
                    let n = 0;
                    for (let offset = 0; offset < total; offset += 500) {
                        const res = await fetchApp(Object.assign({ action: 'compilationList', offset: offset, limit: 500 }, filter));
                        if (res.status !== 'success') throw new Error(res.message || 'Gagal memuat hasil filter.');
                        const rows = res.rows || [];
                        rows.forEach(r => { peta.set(String(r.id), r); n++; });
                        if (rows.length === 0) break;
                    }
                    rcPilihanPulihkan('cb-comp', 'compSelectAll');
                    updateCompSelection();
                    showNotification(n.toLocaleString('id-ID') + ' baris hasil filter dipilih.', 'success');
                } catch (e) { showNotification((e && e.message) || 'Gagal memilih hasil filter.', 'error'); }
                finally { hideLoadingOverlay(); }
            }

            // Mengunduh HANYA baris yang dicentang (semua halaman), dengan kolom dari Pilih Kolom,
            // persis seperti Unduh yang Dipilih di tab Open.
            function compUnduhDipilih() {
                const dipilih = rcPilihanData('cb-comp').filter(r => r && typeof r === 'object');
                if (dipilih.length === 0) { showNotification('Centang baris yang akan diunduh lebih dulu.', 'warning'); return; }
                const aktif = compKolomMuat();
                const kolom = COMP_KOLOM.filter(c => aktif[c.k]).flatMap(c => c.unduh);
                if (kolom.length === 0) { showNotification('Pilih minimal satu kolom lewat Pilih Kolom.', 'warning'); return; }
                const aoa = [kolom.map(k => k[0])].concat(dipilih.map(r => kolom.map(k => k[1](r))));
                const wb = XLSX.utils.book_new();
                const ws = XLSX.utils.aoa_to_sheet(aoa);
                ws['!cols'] = kolom.map(k => ({ wch: Math.max(12, Math.min(40, k[0].length + 4)) }));
                XLSX.utils.book_append_sheet(wb, ws, 'Document Center');
                XLSX.writeFile(wb, 'Document_Center_' + new Date().toISOString().slice(0, 10) + '.xlsx');
                showNotification(dipilih.length.toLocaleString('id-ID') + ' baris diunduh.', 'success');
            }

            async function archiveCompilationRows() {
                let ids = rcPilihanKunci('cb-comp');
                if (ids.length === 0) return;
                if (ids.length > COMP_ARSIP_MAKS) {
                    showNotification(ids.length.toLocaleString('id-ID') + ' baris dipilih; satu kali arsip maksimal '
                        + COMP_ARSIP_MAKS.toLocaleString('id-ID') + ' baris. Kurangi pilihannya lebih dulu.', 'warning');
                    return;
                }
                let reason = document.getElementById('compArchiveReason').value.trim();
                if (!reason) { showNotification("Alasan pengarsipan wajib diisi.", "error"); return; }
                let confirmed = await showConfirmModal({ title: "Konfirmasi Arsip",
                    message: ids.length + " baris cashback akan diarsipkan dan hilang dari seluruh layar serta laporan.\n\nBaris tetap tersimpan dan dapat dikembalikan lewat daftar arsip.",
                    confirmText: "Ya, Arsipkan", danger: true });
                if (!confirmed) return;
                showLoadingOverlay("Mengarsipkan...");
                try {
                    let res = await fetchApp({ action: 'archiveCompilation', ids: ids, reason: reason });
                    if (res.status === 'success') {
                        showNotification(res.jumlah + " baris diarsipkan.", "success");
                        logActivity('Arsip cashback: ' + res.jumlah + ' baris. Alasan: ' + reason);
                        document.getElementById('compArchiveReason').value = '';
                        rcPilihanKosongkan('cb-comp', 'compSelectAll');
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
                            + '<td class="p-3 text-center"><button onclick="unarchiveCompilationRow(\'' + rcEsc(r.id) + '\')" class="px-3 py-1.5 bg-white border border-gray-300 hover:bg-green-50 text-green-700 font-bold rounded-lg text-xs">Kembalikan</button></td></tr>';
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