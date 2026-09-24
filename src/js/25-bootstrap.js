            let globalHistoryData = []; let globalCompileData = []; let globalReleaseData = []; let globalClaimFinData = []; let globalClearingData = []; let globalBulkRebateData = []; let globalProfileRequests = []; let summaryChartInstance = null; let detailChartInstance = null; let currentManageableUsers = []; let globalDepotList = []; let pinAttempts = {};
            
            let histCurrentPage = 1; let histItemsPerPage = 10;
            let logCurrentPage = 1; let logItemsPerPage = 20;
            let runtimeInterval;

            document.addEventListener('DOMContentLoaded', function() {
                // Dua hal yang diminta pemilik, keduanya soal tidak membuang waktu pengguna:
                //   1. Sesi yang masih sah dipulihkan, jadi muat ulang tidak memaksa login lagi.
                //   2. Enter menjalankan aksi utama, jadi tangan tidak perlu pindah ke mouse.
                if (typeof restoreSessionIfAny === 'function') restoreSessionIfAny();
                pasangEnterSebagaiAksi();
 
                initInputGrid(); 
                document.getElementById('inputGridBody').addEventListener('keydown', function(e) {
                    if (['ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight'].includes(e.key)) {
                        let cell = e.target.closest('td'); let row = e.target.closest('tr');
                        if (!cell || !row) return;
                        let cIdx = cell.cellIndex; let rIdx = parseInt(row.getAttribute('data-idx'));
                        let allRows = document.querySelectorAll('.row-input');
                        let nextRow = rIdx, nextCol = cIdx;
                        if (e.key === 'ArrowUp') nextRow = Math.max(0, rIdx - 1);
                        if (e.key === 'ArrowDown') nextRow = Math.min(currentInputRows - 1, rIdx + 1);
                        if (e.key === 'ArrowLeft') nextCol = Math.max(1, cIdx - 1); 
                        if (e.key === 'ArrowRight') nextCol = Math.min(row.children.length - 1, cIdx + 1);
                        if (nextRow !== rIdx || nextCol !== cIdx) {
                            e.preventDefault(); 
                            let getValidInput = (r, c, direction) => {
                                if (!allRows[r] || !allRows[r].children[c]) return null;
                                let targetCell = allRows[r].children[c];
                                let input = targetCell.querySelector('input:not([readonly]), select');
                                if (input) return input;
                                if (direction === 'ArrowRight' && c < row.children.length - 1) return getValidInput(r, c + 1, direction);
                                if (direction === 'ArrowLeft' && c > 1) return getValidInput(r, c - 1, direction);
                                return null;
                            };
                            let targetInput = getValidInput(nextRow, nextCol, e.key);
                            if (targetInput) { targetInput.focus(); if (targetInput.tagName === 'INPUT') targetInput.select(); }
                        }
                    }
                });
            });

            function startRuntimeCounter() {
                if (runtimeInterval) clearInterval(runtimeInterval); let sT = Date.now(); let cE = document.getElementById('runtimeCounter');
                if (cE) { runtimeInterval = setInterval(() => { let d = Math.floor((Date.now() - sT) / 1000); let h = String(Math.floor(d / 3600)).padStart(2, '0'); let m = String(Math.floor((d % 3600) / 60)).padStart(2, '0'); let s = String(d % 60).padStart(2, '0'); cE.innerText = `${h}:${m}:${s}`; }, 1000); }
            }

            function normalizeName(name) { if (!name) return ""; let n = name.toString().trim(); if (n.toLowerCase().indexOf("jatiasih") !== -1) { n = n.replace(/jatiasih/gi, "Bekasi"); } return n; }

            // Jenis CB tidak pernah menjadi bukti bahwa dokumen sudah Done;
            // status kosong/blank di spreadsheet dianggap "Not Yet".
            function normalizeClaimStatus(raw) {
                let s = String(raw === null || raw === undefined ? "" : raw).trim();
                let sLow = s.toLowerCase();
                if (sLow === "ra07" || sLow === "ra7") return "Not Yet";
                if (s === "") return "Not Yet";
                return s;
            }

            // Update status dokumen di globalDocuments secara lokal (tanpa round-trip ke server) setelah
            // sebuah aksi (submit claim / posting exception) berhasil, supaya validasi berikutnya di modul
            // Upload langsung akurat tanpa harus menunggu klik "Refresh Data" - efisien untuk dataset besar.
            function patchLocalDocStatus(noDocs, newStatus) {
                if (!noDocs || noDocs.length === 0) return;
                let set = new Set(noDocs.map(d => String(d).trim().toUpperCase()));
                globalDocuments.forEach(d => { if (set.has(String(d.noDoc).trim().toUpperCase())) d.status = newStatus; });
            }

            // Gunakan status yang diakui server, termasuk keberhasilan parsial Posting Exception.
            function patchLocalApprovalResult(rows) {
                const statusLabels = { not_yet: 'Not Yet', approved: 'Approved', done: 'Done',
                    submitted: 'Submitted', released: 'Released', claimed: 'Claimed',
                    on_hold: 'On Hold', expired: 'Expired' };
                const hasil = new Map((rows || []).map(r => [String(r.noDoc || r.no_doc).trim().toUpperCase(), r]));
                globalDocuments.forEach(d => {
                    const r = hasil.get(String(d.noDoc).trim().toUpperCase());
                    if (!r) return;
                    d.status = statusLabels[r.status] || normalizeClaimStatus(r.status);
                    d.pendingApproval = !!(r.pendingApproval ?? r.pending_approval);
                    d.versionNo = r.versionNo ?? r.version_no;
                });
            }

            // Tombol "Refresh Data" di modul Claim Upload - memuat ulang daftar dokumen (status terbaru)
            // dari server tanpa perlu logout/login ulang. Endpoint ringan, hanya sheet Compile.
            async function refreshUploadDocuments() {
                setDisabledSafely('btnRefreshUploadDocs', true);
                showLoadingOverlay("Menyegarkan data dokumen...");
                try {
                    let res = await fetchApp({ action: 'refreshDocuments' });
                    if (res.status === 'success') {
                        globalDocuments = res.documents || [];
                        globalDocuments.forEach(d => d.status = normalizeClaimStatus(d.status));
                        showNotification("Data dokumen berhasil disegarkan.", "success");
                    } else { showNotification(res.message || "Gagal menyegarkan data.", "error"); }
                } catch (e) { showNotification("Terjadi kesalahan saat menyegarkan data.", "error"); }
                finally { setDisabledSafely('btnRefreshUploadDocs', false); hideLoadingOverlay(); }
            }

            function normalizeMonthUI(val) {
                if (!val) return ""; let str = val.toString().trim().toLowerCase(); let dM = str.match(/^(\d{1,2})[\/\-](\d{1,2})[\/\-](\d{2,4})$/);
                if (dM) { let m = parseInt(dM[2], 10); let y = dM[3].length === 4 ? dM[3].substring(2) : dM[3]; let mN = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec']; if (m >= 1 && m <= 12) return mN[m - 1] + "-" + y; }
                const map = { 'jan': 'Jan', 'peb': 'Feb', 'feb': 'Feb', 'mar': 'Mar', 'apr': 'Apr', 'mei': 'May', 'may': 'May', 'jun': 'Jun', 'jul': 'Jul', 'agu': 'Aug', 'ags': 'Aug', 'sep': 'Sep', 'okt': 'Oct', 'oct': 'Oct', 'nov': 'Nov', 'des': 'Dec', 'dec': 'Dec' };
                str = str.replace(/\s+/g, '-'); let p = str.split("-");
                if (p.length === 2) { let mT = p[0].replace(/[^a-z]/g, ''); let m = map[mT] || p[0]; let y = p[1].length === 4 ? p[1].substring(2) : p[1]; return m.charAt(0).toUpperCase() + m.slice(1) + "-" + y; }
                return val;
            }

            // Enam bentuk masukan yang diterima, atas ketetapan pemilik - dan TIDAK ADA yang lain:
            //
            //   dd.mm.yyyy   dd-mm-yyyy   dd.mm.yy   dd-mm-yy   ddmmyy   ddmmyyyy
            //
            // Seluruhnya dinormalkan menjadi satu bentuk baca: 22-Jan-2026.
            //
            // Sebelumnya fungsi ini jauh lebih longgar: bila pola pertamanya gagal, ia menyerahkan
            // teksnya ke new Date(). Itu berbahaya justru karena jarang gagal - new Date('01/02/2026')
            // dibaca sebagai 2 Januari menurut aturan Amerika, bukan 1 Februari, dan hasilnya
            // diterima tanpa keluhan. Dan bila new Date pun menyerah, teks aslinya dikembalikan
            // apa adanya, sehingga masukan ngawur lolos dari layar dan baru gagal di server.
            //
            // Sekarang yang tidak cocok mengembalikan string kosong, dan pemanggilnya yang
            // memutuskan cara menolaknya. Nama bulan ditulis singkat Inggris karena itulah yang
            // dipakai di seluruh data lama (Jan-Dec).
            const RC_BULAN_SINGKAT = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
                                      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

            function normalizeDateUI(val) {
                if (val === null || val === undefined) return '';
                const str = String(val).trim();
                if (!str) return '';

                let d = 0, m = 0, y = 0;

                // dd.mm.yyyy / dd-mm-yyyy / dd.mm.yy / dd-mm-yy - pemisahnya hanya titik atau strip
                const cocok = str.match(/^(\d{1,2})[.-](\d{1,2})[.-](\d{2}|\d{4})$/);
                if (cocok) {
                    d = Number(cocok[1]); m = Number(cocok[2]); y = Number(cocok[3]);
                    if (cocok[3].length === 2) y += 2000;
                } else if (/^\d{6}$/.test(str)) {          // ddmmyy
                    d = Number(str.slice(0, 2)); m = Number(str.slice(2, 4)); y = 2000 + Number(str.slice(4));
                } else if (/^\d{8}$/.test(str)) {          // ddmmyyyy
                    d = Number(str.slice(0, 2)); m = Number(str.slice(2, 4)); y = Number(str.slice(4));
                } else {
                    return '';
                }

                // Tanggalnya harus benar-benar ada. 31-04-2026 dan 29-02-2027 cocok polanya tetapi
                // bukan tanggal; tanpa pemeriksaan ini keduanya lolos dan baru ditolak server.
                if (m < 1 || m > 12 || d < 1 || d > 31 || y < 1900 || y > 2999) return '';
                const uji = new Date(Date.UTC(y, m - 1, d));
                if (uji.getUTCFullYear() !== y || uji.getUTCMonth() !== m - 1 || uji.getUTCDate() !== d) return '';

                return String(d).padStart(2, '0') + '-' + RC_BULAN_SINGKAT[m - 1] + '-' + y;
            }

            // Enter di dalam sebuah kolom menjalankan tombol utama wadah terdekatnya: modal yang
            // sedang terbuka, atau bagian halaman yang sedang tampil. Textarea dikecualikan karena
            // di sana Enter memang berarti baris baru, dan tombol yang sedang dinonaktifkan tidak
            // pernah diklik supaya satu Enter tidak mengirim dua kali.
            function pasangEnterSebagaiAksi() {
                document.addEventListener('keydown', function (e) {
                    if (e.key !== 'Enter' || e.shiftKey || e.ctrlKey || e.altKey || e.metaKey) return;
                    const el = e.target;
                    if (!el || !el.tagName) return;
                    const tag = el.tagName.toLowerCase();
                    if (tag === 'textarea' || tag === 'button' || tag === 'select') return;
                    if (tag !== 'input') return;

                    // Halaman login punya penanganannya sendiri lewat handleLoginEnter.
                    if (el.id === 'userid' || el.id === 'pin') return;

                    const wadah = el.closest('.fixed:not(.hidden), form, #workspaceSection, #profileSection') || document;
                    const tombol = Array.from(wadah.querySelectorAll('button'))
                        .filter(b => !b.disabled && b.offsetParent !== null)
                        .find(b => /simpan|kirim|proses|ajukan|masuk|tambah|preview|cari|submit|update|daftar/i.test(b.innerText || ''));
                    if (!tombol) return;
                    e.preventDefault();
                    tombol.click();
                });
            }
