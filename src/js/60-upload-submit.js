            function updateUploadCount(manualCount = null) { let n = manualCount !== null ? manualCount : document.querySelectorAll('.cb-upload:checked').length; document.getElementById('previewCount').innerText = `${n} Baris Terpilih`; setDisabledSafely('btnSubmitUpload', n === 0); setDisabledSafely('btnPostHold', n === 0); setDisabledSafely('btnPostExpired', n === 0); }
            function toggleAllUpload(src) { document.querySelectorAll('.cb-upload').forEach(c => c.checked = src.checked); updateUploadCount(); }

            function submitUploadAction() { if (hasMasterUpdateFlag) { document.getElementById('confirmMasterModal').classList.remove('hidden'); } else { submitMassClaim(); } }
            function confirmAndSubmitMass() { document.getElementById('confirmMasterModal').classList.add('hidden'); submitMassClaim(); }

        async function submitMassClaim() {
                setDisabledSafely('btnSubmitUpload', true); setHiddenSafely('submitLoaderUpload', false);
                let checkedDocs = []; document.querySelectorAll('.cb-upload:checked').forEach(c => checkedDocs.push(c.value)); let dataToSubmit = massUploadDataValid.filter(d => checkedDocs.includes(d.noDoc));
                try {
                    // Langsung kirim dataToSubmit tanpa generate batch
                    let res = await fetchApp({ action: 'submitData', userData: currentUserData, data: dataToSubmit });
                    
                    if (res.status === 'success' || res.status === 'warning') { 
                        let batchNum = res.summary?.batchNum || "-"; // Ambil batch dari response backend
                        let succDocs = res.summary?.successfulDocs || [];
                        let grossUpMap = res.summary?.grossUpMap || {};
                        
                        // BAGIAN YANG DIPERBAIKI (Tanda kurung disesuaikan)
                        let successDetails = dataToSubmit.filter(d => succDocs.includes(d.noDoc.toUpperCase())).map(d => ({
                            noDoc: d.noDoc, kodeCamp: d.codeCampaign, namaCamp: d.campaignName, kodeToko: d.custCode, namaToko: d.custName, reward: d.cbNet || d.totTagih, grossUp: grossUpMap[d.noDoc.toUpperCase()] || 0
                        }));
                        
                        logActivity(`Claim Upload Web: ${res.summary?.successCount || dataToSubmit.length} dokumen. No Batch: ${batchNum}`);
                        showActionResult("Laporan Posting Upload Data", successDetails, [], "Upload", batchNum);
                        patchLocalApprovalResult(res.summary?.processed || []);
                        resetInputGrid(); cancelPreview(); setHiddenSafely('uploadModuleTabs', false);
                    } else { showNotification(res.message, "error"); }
                } catch (e) { showNotification("Terjadi kesalahan saat upload.", "error"); resetInputGrid(); cancelPreview(); setHiddenSafely('uploadModuleTabs', false); }
                finally { setHiddenSafely('submitLoaderUpload', true); }
            }

            // Posting Exception: menahan (On Hold) atau menghanguskan (Expired) dokumen lewat modul Upload -
            // menggantikan mekanisme tick-by-tick lama di Analytics/History. Memakai action backend yang sama
            // (toggleOnHold / markExpired) sehingga tidak perlu perubahan di sisi Apps Script.
            async function submitPostingException(actionType) {
                // Baris diambil dari tabel pratinjau yang dicentang, sama seperti Mass Upload.
                // Yang berbeda hanya muatannya: No Doc beserta empat tanggal, bukan data klaim.
                const dicentang = [];
                document.querySelectorAll('.cb-upload:checked').forEach(c => dicentang.push(c.value));
                if (dicentang.length === 0) {
                    showNotification('Tidak ada baris yang dicentang.', 'warning'); return;
                }
                const rows = massUploadDataValid
                    .filter(d => dicentang.includes(d.noDoc))
                    .map(d => ({
                        noDoc: d.noDoc,
                        soStart: d.soStart || null, soEnd: d.soEnd || null,
                        billingStart: d.billingStart || null, billingEnd: d.billingEnd || null
                    }));

                // Pratinjau menerima gabungan status yang sah bagi KEDUA tindakan, karena saat
                // itu belum diketahui tombol mana yang akan ditekan. Penyaringan per tindakan
                // terjadi di sini. Daftarnya sama persis dengan yang dipakai server.
                const bolehStatus = EXC_STATUS_BOLEH[actionType === 'expired' ? 'expired' : 'hold'];
                const salahStatus = massUploadDataValid
                    .filter(d => dicentang.includes(d.noDoc))
                    .filter(d => {
                        const st = String(d.currentStatus || '').trim().toLowerCase();
                        return st !== '' && bolehStatus.indexOf(st) === -1;
                    });
                if (salahStatus.length > 0) {
                    showNotification(salahStatus.length + ' dokumen berstatus '
                        + [...new Set(salahStatus.map(d => d.currentStatus))].join(', ')
                        + ' tidak dapat di-' + (actionType === 'expired' ? 'Expired' : 'On Hold')
                        + '. Hapus centangnya lebih dulu.', 'error');
                    return;
                }

                // Diperiksa lebih dulu di layar supaya pengguna tidak menunggu perjalanan ke
                // server hanya untuk diberi tahu ada kolom kosong. Server memeriksanya lagi.
                if (actionType === 'hold') {
                    const kurang = rows.filter(r => !r.soStart || !r.soEnd || !r.billingStart || !r.billingEnd);
                    if (kurang.length > 0) {
                        showNotification(kurang.length + ' baris belum lengkap SO/Billing Start dan End. '
                            + 'On Hold memerlukan keempatnya.', 'error');
                        return;
                    }
                    // Cerminan aturan server: setidaknya satu tanggal harus berbeda dari periode
                    // campaign. Diperiksa di sini hanya supaya pengguna tahu seketika - keempat
                    // kolom memang terisi otomatis dengan periode campaign, sehingga menekan
                    // On Hold tanpa mengubah apa pun adalah kekeliruan yang mudah terjadi.
                    const takBerubah = rows.filter(function (r) {
                        const db = globalDocuments.find(d => String(d.noDoc).trim().toUpperCase() === r.noDoc);
                        if (!db) return false;
                        const camp = (globalCampaigns || []).find(c => String(c.codeCampaign) === String(db.codeCampaign));
                        if (!camp) return false;
                        const a = rcUraiTanggal(camp.periodStart), b = rcUraiTanggal(camp.periodEnd);
                        if (!a || !b) return false;
                        return r.soStart === a && r.soEnd === b && r.billingStart === a && r.billingEnd === b;
                    });
                    if (takBerubah.length > 0) {
                        showNotification(takBerubah.length + ' baris masih persis sama dengan periode campaign. '
                            + 'On Hold menuntut perpanjangan nyata - ubah setidaknya satu tanggal.', 'error');
                        return;
                    }
                }

                // Alasan wajib untuk On Hold.
                //
                // Alasannya ikut ke tab Reprocessing Doc dan ke berkas unduhannya, sehingga orang
                // yang merevisi nominalnya tahu mengapa dokumen itu ditahan tanpa perlu bertanya.
                // Untuk penahanan massal cukup SATU alasan untuk seluruh batch, sesuai permintaan
                // pemilik - meminta alasan per dokumen pada 200 baris hanya akan menghasilkan
                // dua ratus kalimat yang sama.
                let alasan = '';
                if (actionType === 'hold') {
                    alasan = window.prompt('Alasan On Hold untuk ' + rows.length
                        + (rows.length > 1 ? ' dokumen ini (satu alasan untuk seluruh batch):' : ' dokumen ini:'), '') || '';
                    if (!alasan.trim()) {
                        showNotification('On Hold memerlukan alasan.', 'warning'); return;
                    }
                }

                const pesan = actionType === 'expired'
                    ? rows.length + ' dokumen diajukan untuk Expired. Status tetap sampai disetujui.'
                    : rows.length + ' dokumen diajukan untuk On Hold. Status tetap sampai disetujui. Alasan: ' + alasan.trim();
                const setuju = await showConfirmModal({
                    title: actionType === 'expired' ? 'Konfirmasi Expired' : 'Konfirmasi On Hold',
                    message: pesan,
                    confirmText: 'Ajukan Approval',
                    danger: actionType === 'expired'
                });
                if (!setuju) return;

                const loaderId = actionType === 'expired' ? 'loaderPostExpired' : 'loaderPostHold';
                setDisabledSafely('btnPostHold', true); setDisabledSafely('btnPostExpired', true);
                setHiddenSafely(loaderId, false);
                showLoadingOverlay(actionType === 'expired'
                    ? 'Mengajukan approval Expired...' : 'Mengajukan approval On Hold...');
                try {
                    const res = await fetchApp({
                        action: 'postingException', tindakan: actionType, rows: rows,
                        alasan: alasan.trim()
                    });
                    if (res.status !== 'success') {
                        showNotification(res.message || 'Gagal memproses.', 'error'); return;
                    }

                    showNotification(res.message, Number(res.jumlahGagal || 0) > 0 ? 'warning' : 'success');
                    logActivity('Posting Exception [' + actionType.toUpperCase() + ']: ' + res.berhasil + ' dokumen');

                    // Penolakan selalu disertai sebabnya per baris; penolakan tanpa sebab akan
                    // dibaca sebagai kerusakan.
                    if (Number(res.jumlahGagal || 0) > 0) {
                        rcDialog('Dokumen yang ditolak',
                            '<table class="w-full text-sm"><thead class="bg-gray-50"><tr>'
                            + '<th class="p-2 text-left text-[10px] font-black uppercase">No Doc</th>'
                            + '<th class="p-2 text-left text-[10px] font-black uppercase">Sebab</th>'
                            + '</tr></thead><tbody>'
                            + (res.gagal || []).map(g => '<tr class="border-b border-gray-100">'
                                + '<td class="p-2 font-mono">' + rcEsc(g.noDoc) + '</td>'
                                + '<td class="p-2 text-red-700">' + rcEsc(g.sebab) + '</td></tr>').join('')
                            + '</tbody></table>');
                    }

                    if (Number(res.berhasil || 0) > 0) {
                        patchLocalApprovalResult(res.processed || []);
                        resetInputGrid(); cancelPreview();
                        setHiddenSafely('uploadModuleTabs', false);
                    }
                } catch (e) {
                    showNotification((e && e.message) ? e.message : 'Gagal memproses Posting Exception.', 'error');
                } finally {
                    setHiddenSafely(loaderId, true);
                    setDisabledSafely('btnPostHold', false); setDisabledSafely('btnPostExpired', false);
                    hideLoadingOverlay();
                }
            }
