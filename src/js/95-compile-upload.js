            // Tanpa kolom Abbr (20261163040000): Abbr selalu diambil server dari Depot Master
            // menurut Kode Depot. Kolom Abbr pada file template lama tidak dibaca sama sekali.
            const COMPILE_HEADERS = ['Kode Depot','Code Campaign','Cust Code','Cust Name','Net Value','Volume','Cashback After Tax','Jenis CB'];
            const COMPILE_KEYS = ['kodeDepot','codeCampaign','custCode','custName','netValue','volume','cbNet','jenisCb'];

            function downloadCompileTemplate() {
                let wb = XLSX.utils.book_new();
                let ws = XLSX.utils.aoa_to_sheet([COMPILE_HEADERS,
                    ['4A','CA3222','C00123','TOKO MAJU JAYA','10000000','250','500000','Transfer']]);
                ws['!cols'] = COMPILE_HEADERS.map(() => ({ wch: 20 }));
                XLSX.utils.book_append_sheet(wb, ws, "Compile");
                XLSX.writeFile(wb, "Template_Compile_Cashback.xlsx");
            }

            // Daftar alasan per baris untuk pratinjau dan hasil simpan. Dulu hasil simpan hanya
            // menampilkan jumlah ("0 dibuat, Ditolak: 1") tanpa alasan, sehingga baris yang
            // ditolak tampak seperti unggahan yang gagal tanpa sebab.
            // Nomor baris Excel setiap baris yang dikirim: server menghitung baris data yang terisi
            // saja (1, 2, 3 ...), sedangkan pengguna mencarinya di Excel dengan nomor barisnya.
            let rcCompileBarisExcel = [];
            function rcDaftarAlasanCompile(res) {
                const baris = [].concat(
                    (res.ditolak || []).map(x => ({ baris: x.baris, jenis: 'Ditolak', alasan: x.alasan })),
                    (res.duplikat || []).map(x => ({ baris: x.baris, jenis: 'Duplikat', alasan: x.alasan || 'Kombinasi campaign dan customer sudah ada' })))
                    .sort((a, b) => a.baris - b.baris);
                if (!baris.length) return '';
                const tampil = baris.slice(0, 50).map(x => '<li><b>Baris ' + (rcCompileBarisExcel[x.baris - 1] || x.baris) + '</b> (' + x.jenis + '): ' + rcEsc(x.alasan) + '</li>').join('');
                return '<ul class="mt-2 text-xs text-red-700 list-disc ml-5 max-h-60 overflow-auto">' + tampil + '</ul>'
                    + (baris.length > 50 ? '<p class="text-xs text-gray-500 mt-1">' + (baris.length - 50) + ' baris lain tidak ditampilkan.</p>' : '');
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
                        let out = [], beresiko = [], barisExcel = [];
                        for (let i = hIdx + 1; i < rows.length; i++) {
                            let raw = rows[i]; if (!raw) continue;
                            let obj = {}, kosong = true;
                            COMPILE_KEYS.forEach(k => {
                                let cell = colMap[k] === undefined ? '' : raw[colMap[k]];
                                if (rcPrecisionRisk(cell)) beresiko.push('baris ' + (i + 1) + ' kolom ' + k);
                                let v = rcCellText(cell);
                                obj[k] = v; if (v) kosong = false;
                            });
                            if (!kosong) { out.push(obj); barisExcel.push(i + 1); }
                        }
                        if (out.length === 0) { showNotification("Tidak ada baris data.", "warning"); return; }
                        if (out.length > 2000) { showNotification("Maksimal 2000 baris per compile.", "error"); return; }
                        if (beresiko.length > 0) {
                            showNotification("Ada angka terlalu panjang sehingga digitnya bisa berubah: "
                                + beresiko.slice(0, 3).join(', ') + ". Format kolom itu sebagai Teks di Excel lalu ulangi.", "error");
                            return;
                        }
                        showLoadingOverlay("Memeriksa " + out.length + " baris...");
                        rcCompileBarisExcel = barisExcel;
                        let res = await fetchApp({ action: 'compilePreview', rows: out });
                        hideLoadingOverlay();
                        if (res.status !== 'success') { showNotification(res.message || "Pemeriksaan gagal.", "error"); return; }
                        rcCompileRows = out;
                        let box = document.getElementById('compileResult');
                        box.className = 'mb-5 p-4 border rounded-xl text-sm bg-white border-gray-200';
                        box.innerHTML = '<p class="font-bold text-gray-800 mb-2">' + res.siap + ' baris siap disimpan dari ' + res.total + ' baris.</p>'
                            + '<p class="text-gray-600">Duplikat: ' + (res.duplikat || []).length + ' &middot; Ditolak: ' + (res.ditolak || []).length + '</p>'
                            + rcDaftarAlasanCompile(res);
                        setHiddenSafely('compileResult', false);
                        setDisabledSafely('btnCommitCompile', res.siap === 0);
                    } catch (err) { hideLoadingOverlay(); showNotification("File tidak dapat dibaca.", "error"); }
                };
                reader.readAsArrayBuffer(file);
            }

            async function commitCompileUpload() {
                if (!rcCompileRows) return;
                let confirmed = await showConfirmModal({ title: "Konfirmasi Compile",
                    message: rcCompileRows.length + " baris akan dikompilasi menjadi cashback baru.\n\nSemua jenis CB mulai Not Yet dan harus diajukan serta disetujui. Rebate Manual dan Voucher selesai (Done) setelah Approved.",
                    confirmText: "Ya, Compile", danger: false });
                if (!confirmed) return;
                setDisabledSafely('btnCommitCompile', true);
                showLoadingOverlay("Mengompilasi cashback...");
                try {
                    let res = await fetchApp({ action: 'compileUpload', rows: rcCompileRows });
                    if (res.status === 'success') {
                        showNotification(res.dibuat + " cashback dibuat. Batch " + (res.batch || '-') + ".", "success");
                        logActivity('Compile cashback: ' + res.dibuat + ' baris. Batch: ' + (res.batch || '-'));
                        let box = document.getElementById('compileResult');
                        const adaTolak = (res.ditolak || []).length + (res.duplikat || []).length > 0;
                        box.className = 'mb-5 p-4 border rounded-xl text-sm ' + (Number(res.dibuat) > 0 ? 'bg-green-50 border-green-300' : 'bg-red-50 border-red-300');
                        box.innerHTML = '<p class="font-black ' + (Number(res.dibuat) > 0 ? 'text-green-900' : 'text-red-800') + '">Compile selesai: ' + res.dibuat + ' baris dibuat, batch ' + rcEsc(res.batch || '-') + '.</p>'
                            + '<p class="' + (Number(res.dibuat) > 0 ? 'text-green-800' : 'text-red-700') + ' text-xs mt-1">Duplikat dilewati: ' + (res.duplikat || []).length + ' &middot; Ditolak: ' + (res.ditolak || []).length
                            + (Number(res.dibuat) > 0 ? '. Hasilnya sudah terlihat di modul Analytics.' : '.') + '</p>'
                            + (adaTolak ? rcDaftarAlasanCompile(res) : '');
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