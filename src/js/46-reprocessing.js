            // ============================================================================
            // CASHBACK COMPILATION - TAB REPROCESSING DOC (ON HOLD)
            // ============================================================================
            // Dokumen yang di-On Hold pada modul Upload mendarat di sini. Alurnya: unduh baris
            // yang perlu direvisi, sunting total cashback-nya di Excel, lalu unggah kembali.
            // Dokumen yang berhasil langsung kembali ke Not Yet dan hilang dari daftar ini.
            //
            // Kunci rujukannya No Doc, bukan nomor baris. Di antara mengunduh dan mengunggah,
            // urutan baris dapat berubah, baris dapat dihapus, dan baris lain disisipkan -
            // mencocokkan berdasarkan posisi akan memindahkan nominal ke dokumen yang salah.

            let reproRows = [];
            let reproPending = null;

            function switchCompilationTab(tab) {
                const selected=tab==='repro'?'reprocess':['list','compile','archive'].find(t=>rcCanTab('compilation.'+t));
                if(!rcEnterTab('compilation',selected))return;
                setHiddenSafely('cmpPanelCompile', tab !== 'compile');
                setHiddenSafely('cmpPanelRepro', tab !== 'repro');
                const aktif = 'px-5 py-2 text-sm font-bold rounded-lg transition bg-cyan-100 text-cyan-700';
                const diam = 'px-5 py-2 text-sm font-bold rounded-lg transition text-gray-500 hover:bg-gray-100';
                const bc = document.getElementById('cmpTabCompile');
                const br = document.getElementById('cmpTabRepro');
                if (bc) bc.className = tab === 'compile' ? aktif : diam;
                if (br) br.className = tab === 'repro' ? aktif : diam;
                if (tab === 'repro') loadReprocessing();
            }

            async function loadReprocessing() {
                showLoadingOverlay();
                try {
                    const res = await fetchApp({
                        action: 'reprocessingList',
                        search: (document.getElementById('reproSearch') || {}).value || ''
                    });
                    if (res.status !== 'success') throw new Error(res.message || 'Gagal memuat Reprocessing Doc.');
                    reproRows = res.rows || [];
                    renderReprocessing(res.total || 0);
                } catch (e) {
                    showNotification((e && e.message) ? e.message : 'Gagal memuat Reprocessing Doc.', 'error');
                } finally { hideLoadingOverlay(); }
            }

            function renderReprocessing(total) {
                const badge = document.getElementById('cmpReproBadge');
                if (badge) badge.innerText = String(total);

                document.getElementById('reproTableBody').innerHTML = reproRows.map(function (r) {
                    const so = r.soStart ? rcTanggalId(r.soStart) + ' s/d ' + rcTanggalId(r.soEnd) : '-';
                    const bi = r.billingStart ? rcTanggalId(r.billingStart) + ' s/d ' + rcTanggalId(r.billingEnd) : '-';
                    return '<tr class="border-b border-gray-100 hover:bg-purple-50">'
                        + '<td class="p-3 text-center"><input type="checkbox" class="cb-repro rounded" value="'
                            + rcEsc(r.noDoc) + '" onchange="updateReproSelection()" checked></td>'
                        + '<td class="p-3 font-black text-blue-700 font-mono text-xs">' + rcEsc(r.noDoc) + '</td>'
                        + '<td class="p-3"><span class="font-bold text-gray-700">' + rcEsc(r.kodeCampaign) + '</span>'
                        + '<span class="text-gray-500 text-xs block max-w-[220px] truncate" title="' + rcEsc(r.namaCampaign) + '">'
                        + rcEsc(r.namaCampaign) + '</span></td>'
                        + '<td class="p-3"><span class="font-bold text-gray-700">' + rcEsc(r.kodeToko) + '</span>'
                        + '<span class="text-gray-500 text-xs block">' + rcEsc(r.namaToko) + '</span></td>'
                        + '<td class="p-3 text-right font-black text-red-600" data-sort="' + Number(r.totalCashback || 0) + '">'
                        + rcEsc(rcNominalPenuh(r.totalCashback)) + '</td>'
                        + '<td class="p-3 text-center text-xs whitespace-nowrap">' + rcEsc(so) + '</td>'
                        + '<td class="p-3 text-center text-xs whitespace-nowrap">' + rcEsc(bi) + '</td>'
                        + '<td class="p-3 text-xs text-gray-600 max-w-[240px] truncate" title="' + rcEsc(r.alasan) + '">'
                        + rcEsc(r.alasan || '-') + '</td>'
                        + '<td class="p-3 text-center text-xs text-gray-500 whitespace-nowrap">' + rcEsc(r.ditahanPada) + '</td>'
                        + '</tr>';
                }).join('') || '<tr><td colspan="9" class="p-6 text-center text-gray-400">Tidak ada dokumen yang tertahan.</td></tr>';

                updateReproSelection();
                rcAktifkanUrutSemua('cmpPanelRepro');
            }

            function toggleAllReprocessing() {
                const on = document.getElementById('reproSelectAll').checked;
                document.querySelectorAll('.cb-repro').forEach(c => { c.checked = on; });
                updateReproSelection();
            }

            function updateReproSelection() {
                const n = document.querySelectorAll('.cb-repro:checked').length;
                document.getElementById('reproRingkas').innerText =
                    n + ' dari ' + reproRows.length + ' dokumen terpilih. '
                    + 'Unduh, revisi kolom Total Cashback di Excel, lalu unggah kembali.';
            }

            function reproTerpilih() {
                const dipilih = [];
                document.querySelectorAll('.cb-repro:checked').forEach(c => dipilih.push(c.value));
                return reproRows.filter(r => dipilih.includes(r.noDoc));
            }

            // Kolom berkas persis seperti yang diminta pemilik. Urutannya dipertahankan saat
            // diunggah kembali dicocokkan berdasarkan JUDUL kolom, bukan posisi, sehingga
            // menambah kolom catatan sendiri di Excel tidak merusak apa pun.
            //
            // SO dan Billing kembali masuk berkas sebagai EMPAT kolom terpisah, beserta Alasan,
            // atas permintaan pemilik. Keempatnya keterangan: yang dibaca kembali saat diunggah
            // hanyalah No Doc dan Total Cashback. Kegunaannya ada pada orang yang merevisi -
            // ia perlu tahu sampai kapan dokumen itu diperpanjang dan mengapa ditahan, tanpa
            // harus membuka layar lain.
            const REPRO_HEADER = ['No Doc', 'Code Campaign', 'Nama Campaign', 'Code Cust', 'Nama Cust',
                                  'Total Cashback', 'SO Start', 'SO End', 'Billing Start', 'Billing End',
                                  'Alasan On Hold'];

            function downloadReprocessing() {
                const rows = reproTerpilih();
                if (rows.length === 0) { showNotification('Pilih minimal satu dokumen.', 'warning'); return; }
                const aoa = [REPRO_HEADER];
                rows.forEach(function (r) {
                    const tgl = function (v) { return v ? rcTanggalId(v) : ''; };
                    aoa.push([
                        r.noDoc, r.kodeCampaign, r.namaCampaign, r.kodeToko, r.namaToko,
                        Math.trunc(Number(r.totalCashback || 0)),
                        tgl(r.soStart), tgl(r.soEnd), tgl(r.billingStart), tgl(r.billingEnd),
                        r.alasan || ''
                    ]);
                });
                const ws = XLSX.utils.aoa_to_sheet(aoa);
                ws['!cols'] = [{ wch: 26 }, { wch: 16 }, { wch: 34 }, { wch: 12 },
                               { wch: 26 }, { wch: 16 }, { wch: 13 }, { wch: 13 },
                               { wch: 14 }, { wch: 14 }, { wch: 40 }];
                // No Doc diformat teks supaya Excel tidak mencoba menafsirkannya.
                for (let i = 2; i <= aoa.length; i += 1) {
                    const ref = 'A' + i;
                    if (ws[ref]) ws[ref].z = '@';
                }
                const wb = XLSX.utils.book_new();
                XLSX.utils.book_append_sheet(wb, ws, 'Reprocessing');
                XLSX.writeFile(wb, 'RC_Reprocessing_Doc.xlsx');
                logActivity('Unduh Reprocessing Doc: ' + rows.length + ' dokumen');
            }

            function previewReprocessingUpload(input) {
                const file = input.files && input.files[0];
                if (!file) return;
                const reader = new FileReader();
                reader.onload = function (e) {
                    try {
                        const wb = XLSX.read(new Uint8Array(e.target.result), { type: 'array' });
                        const rows = XLSX.utils.sheet_to_json(wb.Sheets[wb.SheetNames[0]], { header: 1, defval: '' });
                        if (rows.length < 2) { showNotification('Berkas tidak memuat baris data.', 'warning'); return; }

                        const header = rows[0].map(h => String(h || '').trim().toLowerCase());
                        const iDoc = header.indexOf('no doc');
                        const iCb = header.indexOf('total cashback');
                        if (iDoc === -1 || iCb === -1) {
                            showNotification('Kolom "No Doc" dan "Total Cashback" wajib ada pada berkas.', 'error');
                            return;
                        }

                        reproPending = rows.slice(1)
                            .filter(r => String(r[iDoc] || '').trim() !== '')
                            .map(r => ({
                                noDoc: rcCellText(r[iDoc]).trim(),
                                // Dibersihkan dari pemisah ribuan dan simbol mata uang, karena
                                // Excel kerap menyimpannya sebagai teks berformat.
                                totalCashback: String(rcCellText(r[iCb]))
                                    .replace(/[^0-9,.-]/g, '').replace(/\.(?=\d{3}\b)/g, '').replace(',', '.')
                            }));

                        const kosong = reproPending.filter(r => r.totalCashback === '').length;
                        document.getElementById('reproUploadText').innerText =
                            reproPending.length + ' baris terbaca'
                            + (kosong ? ', ' + kosong + ' tanpa Total Cashback dan akan ditolak' : '')
                            + '. Dokumen yang berhasil akan kembali ke Not Yet.';
                        setHiddenSafely('reproUploadInfo', false);
                    } catch (err) {
                        showNotification('Gagal membaca berkas Excel.', 'error');
                    }
                };
                reader.readAsArrayBuffer(file);
                input.value = '';
            }

            function cancelReprocessingUpload() {
                reproPending = null;
                setHiddenSafely('reproUploadInfo', true);
            }

            async function commitReprocessingUpload() {
                if (!reproPending || reproPending.length === 0) return;
                setDisabledSafely('btnCommitRepro', true);
                showLoadingOverlay('Memproses revisi...');
                try {
                    const res = await fetchApp({ action: 'reprocessingUpload', rows: reproPending });
                    if (res.status !== 'success') {
                        showNotification(res.message || 'Gagal memproses.', 'error'); return;
                    }
                    showNotification(res.message, Number(res.jumlahGagal || 0) > 0 ? 'warning' : 'success');
                    logActivity('Reprocessing Doc: ' + res.berhasil + ' dokumen kembali ke Not Yet');

                    if (Number(res.jumlahGagal || 0) > 0) {
                        rcDialog('Baris yang ditolak',
                            '<table class="w-full text-sm"><thead class="bg-gray-50"><tr>'
                            + '<th class="p-2 text-left text-[10px] font-black uppercase">No Doc</th>'
                            + '<th class="p-2 text-left text-[10px] font-black uppercase">Sebab</th>'
                            + '</tr></thead><tbody>'
                            + (res.gagal || []).map(g => '<tr class="border-b border-gray-100">'
                                + '<td class="p-2 font-mono">' + rcEsc(g.noDoc) + '</td>'
                                + '<td class="p-2 text-red-700">' + rcEsc(g.sebab) + '</td></tr>').join('')
                            + '</tbody></table>');
                    }
                    cancelReprocessingUpload();
                    loadReprocessing();
                    // Dokumen yang kembali ke Not Yet muncul lagi di modul Upload, jadi daftarnya
                    // ikut disegarkan supaya kedua layar tidak menampilkan keadaan berbeda.
                    if (typeof refreshUploadDocuments === 'function') refreshUploadDocuments();
                } catch (e) {
                    showNotification((e && e.message) ? e.message : 'Gagal memproses revisi.', 'error');
                } finally {
                    setDisabledSafely('btnCommitRepro', false);
                    hideLoadingOverlay();
                }
            }
