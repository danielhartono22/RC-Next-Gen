            function setDisabledSafely(id, dis) { let e = document.getElementById(id); if (e) { e.disabled = dis; if (dis) e.classList.add('bg-gray-400', 'cursor-not-allowed', 'opacity-50'); else e.classList.remove('bg-gray-400', 'cursor-not-allowed', 'opacity-50'); } }


            function showLoadingOverlay(text = "Menyinkronkan...") { document.getElementById('loadingOverlayText').innerText = text; setHiddenSafely('loadingOverlay', false); }
            function hideLoadingOverlay() { setHiddenSafely('loadingOverlay', true); }

            // Pengganti confirm()/alert() bawaan browser (yang menampilkan "This page says") dengan modal
            // custom mengikuti theme UI sistem. showConfirmModal() -> Promise<boolean> (true = Proceed/Confirm,
            // false = Cancel/Batal). showAlertModal() -> Promise<void>, dipakai untuk notifikasi yang wajib
            // di-acknowledge user dulu sebelum lanjut (mis. sesi berakhir sebelum reload halaman).
            function showConfirmModal(opts) {
                opts = opts || {};
                let title = opts.title || 'Konfirmasi';
                let message = opts.message || '';
                let confirmText = opts.confirmText || 'Ya, Lanjutkan';
                let cancelText = opts.cancelText || 'Batal';
                let danger = opts.danger !== false;
                let alertOnly = !!opts.alertOnly;

                document.getElementById('gcmTitle').innerText = title;
                document.getElementById('gcmMessage').innerText = message;

                let header = document.getElementById('gcmHeader'), iconWrap = document.getElementById('gcmIconWrap'), icon = document.getElementById('gcmIcon');
                header.className = "p-6 text-center border-b relative " + (danger ? "bg-red-50 border-red-100" : "bg-blue-50 border-blue-100");
                iconWrap.className = "w-16 h-16 bg-white rounded-full flex items-center justify-center mx-auto mb-3 shadow-sm border text-3xl " + (danger ? "border-red-100 text-red-500" : "border-blue-100 text-blue-500");
                icon.className = "fas " + (danger ? "fa-exclamation-triangle" : "fa-info-circle");

                let cancelBtn = document.getElementById('gcmCancelBtn'), confirmBtn = document.getElementById('gcmConfirmBtn');
                confirmBtn.innerText = confirmText;
                confirmBtn.className = (alertOnly ? "w-full" : "w-1/2") + " py-3 font-bold rounded-xl shadow-md transition " + (danger ? "bg-red-600 hover:bg-red-700 text-white" : "bg-blue-600 hover:bg-blue-700 text-white");
                if (alertOnly) { cancelBtn.style.display = 'none'; } else { cancelBtn.style.display = ''; cancelBtn.innerText = cancelText; }

                document.getElementById('genericConfirmModal').classList.remove('hidden');

                return new Promise(resolve => {
                    confirmBtn.onclick = () => { document.getElementById('genericConfirmModal').classList.add('hidden'); resolve(true); };
                    cancelBtn.onclick = () => { document.getElementById('genericConfirmModal').classList.add('hidden'); resolve(false); };
                });
            }
            function showAlertModal(title, message) {
                return showConfirmModal({ title: title, message: message, alertOnly: true, confirmText: 'OK', danger: false });
            }

            function formatCurrencyInput(elem) {
                let v = elem.value.replace(/[^,\d]/g, ''), s = v.split(','), ss = s[0].length % 3, r = s[0].substr(0, ss), rb = s[0].substr(ss).match(/\d{3}/gi);
                if (rb) { let sep = ss ? '.' : ''; r += sep + rb.join('.'); } r = s[1] != undefined ? r + ',' + s[1] : r; elem.value = r;
            }

            async function fetchApp(bodyData) {
                try {
                    // [PERBAIKAN]: Injeksi otomatis JWT Token keamanan ke setiap request ke backend
                    if (typeof currentUserData !== 'undefined' && currentUserData && currentUserData.token) {
                        bodyData.token = currentUserData.token;
                    }

                    let res = await window.RCBackend.call(bodyData);
                    
                    // [PERBAIKAN]: Tangkap penolakan backend jika sesi/token sudah kadaluarsa (12 jam)
                    if (res.status === 'error' && res.message && res.message.includes('Sesi tidak valid')) {
                        setHiddenSafely('loadingOverlay', true);
                        await showAlertModal("Sesi Berakhir", "Sesi Anda telah berakhir atau tidak valid demi keamanan. Silakan login kembali.");
                        location.reload();
                        throw new Error("Session Invalid");
                    }

                    if (res.status === 'kicked') { setHiddenSafely('loadingOverlay', true); await showAlertModal("Sesi Berakhir", "Sesi Anda telah berakhir karena akun digunakan di perangkat lain."); location.reload(); throw new Error("Kicked"); }
                    return res;
                } catch(e) { throw e; }
            }

            function logActivity(actionDetail) {
                if (!currentUserData) return; let ts = new Date().toLocaleString('id-ID', { timeZone: 'Asia/Jakarta' });
                fetchApp({ action: 'logActivity', userId: currentUserData.userId, role: currentUserData.role, detail: actionDetail, timestamp: ts }).catch(e => {});
            }

            // Menulis nilai ke sebuah kolom TANPA meledak bila kolomnya sudah tidak ada.
            //
            // Ini bukan kenyamanan, melainkan perbaikan atas kegagalan nyata: ketika kolom
            // Bulan Potong dan Total Tagihan dihapus atas instruksi pemilik, satu baris di
            // resetSingleForm masih menulis ke singleTotTagih. Baris itu melempar
            // "Cannot set properties of null", dan karena ia dipanggil saat membuka Claim
            // Upload maupun sesudah posting, SELURUH modul upload berhenti bekerja - manual
            // maupun massal - dengan pesan yang terbaca sebagai "field tidak ditemukan".
            //
            // setHiddenSafely dan setDisabledSafely sudah lama memakai pola ini; yang
            // kurang justru pasangannya untuk nilai.
            function setValueSafely(id, nilai) {
                const el = document.getElementById(id);
                if (el) el.value = nilai == null ? '' : nilai;
                return !!el;
            }

            function setTextSafely(id, teks) {
                const el = document.getElementById(id);
                if (el) el.innerText = teks == null ? '' : teks;
                return !!el;
            }

            // Membaca nilai sebuah kolom tanpa meledak bila kolomnya tidak ada. Pasangan baca
            // dari setValueSafely; tanpa keduanya, satu kolom yang dihapus dapat mematikan
            // seluruh fungsi yang kebetulan menyentuhnya.
            function getValueSafely(id) {
                const el = document.getElementById(id);
                return el ? el.value : '';
            }
