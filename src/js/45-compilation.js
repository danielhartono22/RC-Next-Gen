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
                if(rcCanTab('compilation.list'))loadCompilation(0);
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