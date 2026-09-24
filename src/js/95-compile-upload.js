            const COMPILE_HEADERS = ['Kode Depot','Abbr','Code Campaign','Cust Code','Cust Name','Net Value','Volume','Cashback After Tax','Jenis CB'];
            const COMPILE_KEYS = ['kodeDepot','abbr','codeCampaign','custCode','custName','netValue','volume','cbNet','jenisCb'];

            function downloadCompileTemplate() {
                let wb = XLSX.utils.book_new();
                let ws = XLSX.utils.aoa_to_sheet([COMPILE_HEADERS,
                    ['4A','MDN','CA3222','C00123','TOKO MAJU JAYA','10000000','250','500000','Transfer']]);
                ws['!cols'] = COMPILE_HEADERS.map(() => ({ wch: 20 }));
                XLSX.utils.book_append_sheet(wb, ws, "Compile");
                XLSX.writeFile(wb, "Template_Compile_Cashback.xlsx");
            }

            function previewCompileUpload(fileInput) {
                let file = fileInput.files && fileInput.files[0];
                if (!file) return;
                if (file.size > 10 * 1024 * 1024) { showNotification("File maksimal 10 MB.", "error"); fileInput.value = ''; return; }
                let reader = new FileReader();
                reader.onload = async function (e) {
                    try {
                        let wb = XLSX.read(new Uint8Array(e.target.result), { type: 'array' });
                        let rows = XLSX.utils.sheet_to_json(wb.Sheets[wb.SheetNames[0]], { header: 1, raw: true, defval: '' });
                        let hIdx = rows.findIndex(r => String((r && r[0]) || '').trim().toLowerCase() === COMPILE_HEADERS[0].toLowerCase());
                        if (hIdx < 0) { showNotification("Header 'Kode Depot' tidak ditemukan. Gunakan template.", "error"); return; }
                        let colMap = {};
                        rows[hIdx].forEach((h, i) => {
                            let pos = COMPILE_HEADERS.findIndex(x => x.toLowerCase() === String(h || '').trim().toLowerCase());
                            if (pos >= 0) colMap[COMPILE_KEYS[pos]] = i;
                        });
                        let out = [], beresiko = [];
                        for (let i = hIdx + 1; i < rows.length; i++) {
                            let raw = rows[i]; if (!raw) continue;
                            let obj = {}, kosong = true;
                            COMPILE_KEYS.forEach(k => {
                                let cell = colMap[k] === undefined ? '' : raw[colMap[k]];
                                if (rcPrecisionRisk(cell)) beresiko.push('baris ' + (i + 1) + ' kolom ' + k);
                                let v = rcCellText(cell);
                                obj[k] = v; if (v) kosong = false;
                            });
                            if (!kosong) out.push(obj);
                        }
                        if (out.length === 0) { showNotification("Tidak ada baris data.", "warning"); return; }
                        if (out.length > 2000) { showNotification("Maksimal 2000 baris per compile.", "error"); return; }
                        if (beresiko.length > 0) {
                            showNotification("Ada angka terlalu panjang sehingga digitnya bisa berubah: "
                                + beresiko.slice(0, 3).join(', ') + ". Format kolom itu sebagai Teks di Excel lalu ulangi.", "error");
                            return;
                        }
                        showLoadingOverlay("Memeriksa " + out.length + " baris...");
                        let res = await fetchApp({ action: 'compilePreview', rows: out });
                        hideLoadingOverlay();
                        if (res.status !== 'success') { showNotification(res.message || "Pemeriksaan gagal.", "error"); return; }
                        rcCompileRows = out;
                        let box = document.getElementById('compileResult');
                        let tolakHtml = (res.ditolak || []).slice(0, 20).map(x => '<li>Baris ' + x.baris + ': ' + rcEsc(x.alasan) + '</li>').join('');
                        box.className = 'mb-5 p-4 border rounded-xl text-sm bg-white border-gray-200';
                        box.innerHTML = '<p class="font-bold text-gray-800 mb-2">' + res.siap + ' baris siap disimpan dari ' + res.total + ' baris.</p>'
                            + '<p class="text-gray-600">Duplikat: ' + (res.duplikat || []).length + ' &middot; Ditolak: ' + (res.ditolak || []).length + '</p>'
                            + (tolakHtml ? '<ul class="mt-2 text-xs text-red-700 list-disc ml-5">' + tolakHtml + '</ul>' : '');
                        setHiddenSafely('compileResult', false);
                        setDisabledSafely('btnCommitCompile', res.siap === 0);
                    } catch (err) { hideLoadingOverlay(); showNotification("File tidak dapat dibaca.", "error"); }
                };
                reader.readAsArrayBuffer(file);
            }

            async function commitCompileUpload() {
                if (!rcCompileRows) return;
                let confirmed = await showConfirmModal({ title: "Konfirmasi Compile",
                    message: rcCompileRows.length + " baris akan dikompilasi menjadi cashback baru.\n\nSemua jenis CB mulai Not Yet dan harus diajukan serta disetujui. Rebate Manual selesai setelah Approved.",
                    confirmText: "Ya, Compile", danger: false });
                if (!confirmed) return;
                setDisabledSafely('btnCommitCompile', true);
                showLoadingOverlay("Mengompilasi cashback...");
                try {
                    let res = await fetchApp({ action: 'compileUpload', rows: rcCompileRows });
                    if (res.status === 'success') {
                        showNotification(res.dibuat + " cashback dibuat. Batch " + (res.batch || '-') + ".", "success");
                        logActivity('Compile cashback: ' + res.dibuat + ' baris, batch ' + (res.batch || '-'));
                        let box = document.getElementById('compileResult');
                        box.className = 'mb-5 p-4 border rounded-xl text-sm bg-green-50 border-green-300';
                        box.innerHTML = '<p class="font-black text-green-900">Compile selesai: ' + res.dibuat + ' baris dibuat, batch ' + rcEsc(res.batch || '-') + '.</p>'
                            + '<p class="text-green-800 text-xs mt-1">Duplikat dilewati: ' + (res.duplikat || []).length + ' &middot; Ditolak: ' + (res.ditolak || []).length + '. Hasilnya sudah terlihat di modul Analytics.</p>';
                        rcCompileRows = null;
                        document.getElementById('compileFile').value = '';
                        loadCompilation(0);
                    } else { showNotification(res.message || "Compile gagal.", "error"); setDisabledSafely('btnCommitCompile', false); }
                } catch (e) { showNotification("Gagal terhubung ke server.", "error"); setDisabledSafely('btnCommitCompile', false); }
                finally { hideLoadingOverlay(); }
            }
            // Modal ini melayani dua keadaan yang berbeda dan tidak boleh tertukar:
            //   ganti  pengguna sudah masuk dan ingin PIN baru -> perlu persetujuan
            //   lupa   pengguna tidak bisa masuk sama sekali  -> dikirim tanpa sesi, hanya kode
            let rcPinMode = 'ganti';

            function openRequestPinModal() {
                rcPinMode = 'ganti';
                document.getElementById('reqPinTitle').innerText = 'Ganti PIN Keamanan';
                document.getElementById('reqPinHelp').innerText =
                    'Pengajuan PIN baru menunggu persetujuan Supervisor wilayah Anda atau System Manager.';
                setHiddenSafely('reqPinUserWrap', true);
                setHiddenSafely('reqPinNewWrap', false);
                document.getElementById('reqNewPin').value = '';
                setHiddenSafely('requestPinModal', false);
            }

            function openForgotPinModal() {
                rcPinMode = 'lupa';
                document.getElementById('reqPinTitle').innerText = 'Lupa PIN';
                document.getElementById('reqPinHelp').innerText =
                    'Sebutkan User ID Anda dan PIN yang Anda inginkan. PIN itu berlaku setelah disetujui Supervisor wilayah atau System Manager.';
                setHiddenSafely('reqPinUserWrap', false);
                // Kolom PIN tetap ditampilkan: pemilik menghendaki pengguna mengajukan PIN yang
                // ia inginkan, dan persetujuanlah yang memberi izin - bukan penyetuju yang
                // menentukan PIN-nya. Yang tersimpan selama menunggu hanyalah hash-nya.
                setHiddenSafely('reqPinNewWrap', false);
                document.getElementById('reqNewPin').value = '';
                document.getElementById('reqPinUser').value = document.getElementById('userid').value.trim();
                setHiddenSafely('requestPinModal', false);
            }

            function closeRequestPinModal() { setHiddenSafely('requestPinModal', true); }

            async function submitRequestPin() {
                setHiddenSafely('loadSubmitReqPin', false); setDisabledSafely('btnSubmitReqPin', true);
                try {
                    let res;
                    if (rcPinMode === 'lupa') {
                        const kode = document.getElementById('reqPinUser').value.trim();
                        const pinBaru = document.getElementById('reqNewPin').value.trim();
                        if (!kode) { showNotification('User ID wajib diisi.', 'error'); return; }
                        if (pinBaru.length < 8) { showNotification('PIN yang diajukan minimal 8 karakter.', 'error'); return; }
                        res = await fetchApp({ action: 'forgotPin', userId: kode, newPin: pinBaru });
                    } else {
                        res = await fetchApp({
                            action: 'requestPinChange',
                            userId: (currentUserData && currentUserData.userId) || '',
                            newPin: document.getElementById('reqNewPin').value.trim()
                        });
                    }
                    if (res.status === 'success') {
                        showNotification(res.message || 'Permintaan terkirim.', 'success');
                        closeRequestPinModal();
                    } else {
                        showNotification(res.message || 'Permintaan gagal dikirim.', 'error');
                    }
                } catch (e) {
                    showNotification((e && e.message) ? e.message : 'Terjadi kesalahan jaringan.', 'error');
                } finally {
                    setHiddenSafely('loadSubmitReqPin', true); setDisabledSafely('btnSubmitReqPin', false);
                }
            }