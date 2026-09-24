/*
 * Handler JavaScript untuk tambahan 17 September 2026: tab Open pada Claim Upload, matriks
 * permission modul tambahan pada konsol Otorisasi, dan mass upload Cashback Compilation.
 *
 * Dipisah dari rc-modules-ui.mjs supaya tiap berkas tetap dapat dibaca utuh; build menyatukan
 * keduanya sebagai penambahan yang terdaftar, sehingga bukti markup legacy tetap berlaku.
 */

export const EXTRA_SCRIPT = `
            // ===================== TAB OPEN, MATRIKS AKSES, COMPILE UPLOAD =================
            let rcOpenState = { offset: 0, rows: [] };
            let rcCompileRows = null;
            let rcPermissionCatalog = null;

            function openRcOpenTab() {
                currentUploadMode = 'open';
                setHiddenSafely('tab_mass', true); setHiddenSafely('tab_single', true);
                setHiddenSafely('tab_open', false);
                let idle = "px-5 py-2 text-sm font-bold rounded-lg text-gray-500 hover:bg-gray-100 transition";
                let active = "px-5 py-2 text-sm font-bold rounded-lg bg-blue-100 text-blue-700 transition";
                ['subnav_mass','subnav_single'].forEach(id => { let e = document.getElementById(id); if (e) e.className = idle; });
                let so = document.getElementById('subnav_open'); if (so) so.className = active;
                let sel = document.getElementById('openCampaign');
                if (sel && sel.options.length <= 1) {
                    (globalCampaigns || []).forEach(c => {
                        let o = document.createElement('option');
                        o.value = c.codeCampaign; o.textContent = c.codeCampaign + ' - ' + c.campaignName;
                        sel.appendChild(o);
                    });
                }
                loadOpenClaims(0);
            }

            async function loadOpenClaims(offset) {
                showLoadingOverlay("Memuat dokumen Not Yet...");
                try {
                    let res = await fetchApp({ action: 'openClaims',
                        search: document.getElementById('openSearch').value.trim(),
                        campaign: document.getElementById('openCampaign').value, offset: offset });
                    if (res.status !== 'success') { showNotification(res.message || "Gagal memuat.", "error"); return; }
                    rcOpenState = { offset: offset, rows: res.rows || [] };
                    let html = '';
                    (res.rows || []).forEach((r, i) => {
                        // Tandai apa yang masih kosong supaya pengguna tahu yang harus dilengkapi.
                        let kurang = [];
                        if (!r.ktp && !r.npwp) kurang.push('KTP/NPWP');
                        if (String(r.jenisCb || '').toLowerCase() === 'transfer' && (!r.noRek || !r.namaRek || !r.bank)) kurang.push('Rekening');
                        if (!r.top) kurang.push('TOP');
                        let badge = kurang.length === 0
                            ? '<span class="bg-green-100 text-green-800 px-2 py-1 rounded text-[10px] font-black">Lengkap</span>'
                            : '<span class="bg-orange-100 text-orange-800 px-2 py-1 rounded text-[10px] font-black">' + rcEsc(kurang.join(', ')) + '</span>';
                        html += '<tr class="border-b border-gray-100 hover:bg-blue-50/40">'
                            + '<td class="p-3 text-center"><input type="checkbox" class="cb-open w-4 h-4 rounded" data-idx="' + i + '" onchange="updateOpenSelection()"></td>'
                            + '<td class="p-3 font-black text-blue-700">' + rcEsc(r.noDoc) + '</td>'
                            + '<td class="p-3 text-xs"><b>' + rcEsc(r.namaToko) + '</b><br><span class="text-gray-500">' + rcEsc(r.kodeToko) + '</span></td>'
                            + '<td class="p-3 text-xs"><b>' + rcEsc(r.codeCampaign) + '</b><br><span class="text-gray-500">' + rcEsc(r.campaignName) + '</span></td>'
                            + '<td class="p-3 text-center text-xs font-bold">' + rcEsc(r.jenisCb || '-') + '</td>'
                            + '<td class="p-3 text-right font-black text-red-600">' + rcMoney(r.cbNet) + '</td>'
                            + '<td class="p-3 text-center">' + badge + '</td></tr>';
                    });
                    document.getElementById('openTableBody').innerHTML = html
                        || '<tr><td colspan="7" class="p-8 text-center text-gray-500">Tidak ada dokumen berstatus Not Yet.</td></tr>';
                    renderRcPager('openPager', offset, (res.rows || []).length, res.total, 'loadOpenClaims');
                    document.getElementById('openSelectAll').checked = false;
                    updateOpenSelection();
                } catch (e) { showNotification("Gagal memuat dokumen Open.", "error"); }
                finally { hideLoadingOverlay(); }
            }

            function toggleAllOpen(src) {
                document.querySelectorAll('.cb-open').forEach(c => c.checked = src.checked);
                updateOpenSelection();
            }
            function updateOpenSelection() {
                let n = document.querySelectorAll('.cb-open:checked').length;
                document.getElementById('openSelectedCount').innerText = n;
                setDisabledSafely('btnOpenToMass', n === 0);
                setDisabledSafely('btnOpenToTemplate', n === 0);
            }
            function rcSelectedOpenRows() {
                let out = [];
                document.querySelectorAll('.cb-open:checked').forEach(c => {
                    let r = rcOpenState.rows[Number(c.dataset.idx)];
                    if (r) out.push(r);
                });
                return out;
            }

            // Memindahkan pilihan ke grid Mass Upload, lengkap dengan nilai yang sudah ada di
            // Customer Master, sehingga pengguna hanya mengisi kolom yang benar-benar kosong.
            function openToMassUpload() {
                let picked = rcSelectedOpenRows();
                if (picked.length === 0) return;
                if (picked.length > 200) { showNotification("Maksimal 200 dokumen sekali pindah.", "warning"); return; }
                switchSubTab('upload', 'mass');
                currentInputRows = picked.length;
                initInputGrid();
                let trs = document.getElementById('inputGridBody').querySelectorAll('.row-input');
                picked.forEach((r, i) => {
                    let inputs = trs[i].querySelectorAll('input');
                    inputs[0].value = r.noDoc;
                    inputs[2].value = r.ktp || '';
                    inputs[3].value = r.npwp || '';
                    inputs[4].value = r.noRek || '';
                    inputs[5].value = r.namaRek || '';
                    inputs[6].value = r.bank || '';
                    inputs[7].value = r.top || '';
                });
                showNotification(picked.length + " dokumen dipindahkan. Lengkapi Tgl Lunas dan kolom lain yang kosong.", "success");
            }

            // Template mengikuti Template_Upload_Claim.xlsx yang sudah dipakai depot.
            function openToTemplate() {
                let picked = rcSelectedOpenRows();
                if (picked.length === 0) return;
                let header = ["No Document", "Tgl Lunas", "No Rekening", "Nama Rekening", "Bank", "TOP", "Approval"];
                let aoa = [header];
                picked.forEach(r => aoa.push([r.noDoc, '', r.noRek || '', r.namaRek || '', r.bank || '', r.top || '', '']));
                let wb = XLSX.utils.book_new();
                let ws = XLSX.utils.aoa_to_sheet(aoa);
                ws['!cols'] = [{ wch: 24 }, { wch: 12 }, { wch: 20 }, { wch: 22 }, { wch: 12 }, { wch: 8 }, { wch: 12 }];
                // Nomor rekening tetap teks supaya angka nol di depan tidak hilang.
                for (let r = 2; r <= picked.length + 1; r++) {
                    let ref = 'C' + r;
                    if (!ws[ref]) ws[ref] = { t: 's', v: '' };
                    ws[ref].z = '@';
                }
                XLSX.utils.book_append_sheet(wb, ws, "Template");
                XLSX.writeFile(wb, "Template_Upload_Claim_Open.xlsx");
                showNotification(picked.length + " dokumen diekspor ke template.", "success");
            }

            // ---------- Matriks permission modul tambahan ----------
            async function renderPermissionMatrix(user) {
                let host = document.getElementById('editModuleMatrix');
                if (!host) return;
                if (!rcPermissionCatalog) {
                    try {
                        let res = await fetchApp({ action: 'permissionCatalog' });
                        rcPermissionCatalog = res.status === 'success' ? (res.rows || []) : [];
                    } catch (e) { rcPermissionCatalog = []; }
                }
                // Modul lama tetap dikendalikan select bawaan; di sini hanya yang belum ada.
                let legacy = ['j','k','l','m','n','p','s','q'];
                let held = user && user.permissions ? user.permissions : [];
                let html = '';
                rcPermissionCatalog.filter(c => legacy.indexOf(c.key) === -1).forEach(c => {
                    let on = held.indexOf(c.code) !== -1;
                    html += '<div><label class="block text-[10px] font-bold text-gray-500 uppercase mb-1.5 ml-1">'
                        + rcEsc(c.modul) + '<span class="text-gray-400 normal-case font-normal"> &mdash; ' + rcEsc(c.sub) + '</span></label>'
                        + '<select data-permkey="' + rcEsc(c.key) + '" class="perm-matrix w-full px-3 py-2 text-sm border border-gray-300 rounded-lg bg-white">'
                        + '<option value="Yes"' + (on ? ' selected' : '') + '>Yes</option>'
                        + '<option value="No"' + (on ? '' : ' selected') + '>No</option></select></div>';
                });
                host.innerHTML = html || '<p class="text-xs text-gray-500">Tidak ada modul tambahan.</p>';
            }
            function rcMatrixValues() {
                let out = {};
                document.querySelectorAll('.perm-matrix').forEach(s => { out[s.dataset.permkey] = s.value; });
                return out;
            }

            // Excel menyimpan KTP, NPWP dan nomor rekening sebagai angka bila kolomnya
            // berformat General. Membacanya sebagai teks tampilan menghasilkan "3.17501E+15",
            // dan membacanya sebagai angka membuat digit ke-16 ke atas hilang presisinya.
            // Fungsi ini menulis seluruh digit tanpa notasi eksponen, lalu pemanggilnya
            // memperingatkan bila nilainya sudah melewati batas aman JavaScript.
            function rcCellText(v) {
                if (v === null || v === undefined) return '';
                if (typeof v === 'number') {
                    if (!isFinite(v)) return '';
                    return v.toLocaleString('fullwide', { useGrouping: false, maximumFractionDigits: 20 });
                }
                let s = String(v).trim();
                // Sel yang terlanjur berisi teks eksponen dikembalikan ke bentuk penuh.
                if (/^-?\\d+(\\.\\d+)?[eE][+-]?\\d+$/.test(s)) {
                    let n = Number(s);
                    if (isFinite(n)) return n.toLocaleString('fullwide', { useGrouping: false, maximumFractionDigits: 20 });
                }
                return s;
            }
            function rcPrecisionRisk(v) {
                return typeof v === 'number' && Math.abs(v) > Number.MAX_SAFE_INTEGER;
            }

            // ---------- Warna status: satu sumber untuk seluruh modul ----------
            // Sebelumnya tiap tabel memakai peta warnanya sendiri dan saling berbeda:
            // Bulk Process menandai Submitted kuning dan Claimed ungu, sementara History
            // menandai semua yang bukan Done dan bukan Not Yet dengan oranye. Warna yang
            // sama karena itu bisa berarti status yang berbeda tergantung layar.
            const RC_STATUS_CLASS = {
                'not yet':   'bg-gray-200 text-gray-700',
                'submitted': 'bg-orange-100 text-orange-800',
                'released':  'bg-yellow-100 text-yellow-800',
                'claimed':   'bg-blue-100 text-blue-800',
                'done':      'bg-green-100 text-green-800',
                'on hold':   'bg-purple-100 text-purple-800',
                'expired':   'bg-gray-800 text-white'
            };
            function rcStatusClass(status) {
                return RC_STATUS_CLASS[String(status || '').trim().toLowerCase()] || 'bg-gray-100 text-gray-700';
            }

            // Angka panjang seperti nomor batch (15 digit), KTP, NPWP dan nomor rekening
            // tidak boleh pernah tampil sebagai 1.0011E+14. Nilai apa pun dilewatkan ke sini
            // sebelum ditampilkan maupun sebelum ditulis ke Excel.
            function rcFull(v) {
                if (v === null || v === undefined) return '';
                if (typeof v === 'number') {
                    if (!isFinite(v)) return '';
                    return v.toLocaleString('fullwide', { useGrouping: false, maximumFractionDigits: 20 });
                }
                let s = String(v).trim();
                if (/^-?\\d+(\\.\\d+)?[eE][+-]?\\d+$/.test(s)) {
                    let n = Number(s);
                    if (isFinite(n)) return n.toLocaleString('fullwide', { useGrouping: false, maximumFractionDigits: 20 });
                }
                return s;
            }

            // ---------- Compile cashback ----------
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
                    message: rcCompileRows.length + " baris akan dikompilasi menjadi cashback baru.\\n\\nBaris dengan Jenis CB RA07 atau RA7 langsung berstatus Done.",
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
`;
