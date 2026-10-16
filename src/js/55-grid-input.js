            // Daftar resmi Jenis CB. Penulisannya harus persis seperti di sini; ini yang
            // dipakai validasi grid maupun formulir tunggal, dan server memakai daftar yang sama.
            const RC_JENIS_CB = ['Transfer', 'CN', 'Voucher', 'Rebate', 'Rebate Manual'];
            // Susunan kolom grid, dipilih menurut mode posting.
            //
            // Posting Exception memakai TABEL YANG SAMA dengan Mass Upload - bukan kotak
            // tempelan tersendiri - hanya kolomnya yang berbeda. Dengan begitu cara kerjanya
            // tetap satu: tempel dari Excel, periksa, lalu posting.
            const GRID_KOLOM = {
                claim: [
                    { nama: 'noDoc',        judul: 'No Document*', lebar: '150px', kelas: 'font-bold text-blue-700 uppercase', ph: 'DOC-...' },
                    { nama: 'tglLunas',     judul: 'Tgl Lunas*',   lebar: '130px', ph: 'dd-mm-yyyy' },
                    { nama: 'ktp',          judul: 'No KTP',       lebar: '150px', ro: true, ph: 'Auto DB' },
                    { nama: 'npwp',         judul: 'No NPWP',      lebar: '150px', ro: true, ph: 'Auto DB' },
                    { nama: 'noRekening',   judul: 'No Rekening',  lebar: '150px', ph: 'Wajib (Transfer)' },
                    { nama: 'namaRekening', judul: 'Nama Rekening',lebar: '150px', ph: 'Wajib (Transfer)' },
                    { nama: 'bank',         judul: 'Bank',         lebar: '120px', ph: 'Wajib (Transfer)' },
                    { nama: 'top',          judul: 'TOP Actual',   lebar: '95px',  tipe: 'number', kelas: 'text-center', ph: 'Opsional' },
                    { nama: 'jenisCb',      judul: 'Jenis CB*',    lebar: '110px', kelas: 'text-center uppercase font-bold text-emerald-700', ph: 'Auto master', list: 'rcJenisCbOptions' }
                ],
                // Keempat kolom tanggal memakai <input type="date">, sehingga kalender bawaan
                // peramban langsung tersedia - itu yang diminta pemilik.
                //
                // <input type="date"> menyimpan nilainya dalam ISO dan MENOLAK apa pun yang
                // bukan ISO, sehingga menempel "01.02.2026" dari Excel akan menghasilkan kolom
                // kosong tanpa pesan apa pun. Karena itu jalur tempel di bawah menormalkan
                // nilainya lebih dulu lewat rcUraiTanggal() sebelum menuliskannya.
                exception: [
                    { nama: 'noDoc',        judul: 'No Document*',   lebar: '170px', kelas: 'font-bold text-blue-700 uppercase', ph: 'DOC-...' },
                    { nama: 'soStart', judul: 'SO Start', lebar: '150px', kelas: 'text-center', tipe: 'date' },
                    { nama: 'soEnd', judul: 'SO End', lebar: '150px', kelas: 'text-center', tipe: 'date' },
                    { nama: 'billingStart', judul: 'Billing Start', lebar: '150px', kelas: 'text-center', tipe: 'date' },
                    { nama: 'billingEnd', judul: 'Billing End', lebar: '150px', kelas: 'text-center', tipe: 'date' }
                ]
            };

            function gridKolomAktif() {
                return GRID_KOLOM[currentPostingMode === 'exception' ? 'exception' : 'claim'];
            }

            // Status yang boleh menerima tiap tindakan Posting Exception. Daftarnya disalin
            // persis dari rc_posting_exception di server, supaya layar tidak menolak dokumen
            // yang sebenarnya diterima server.
            //
            // Versi sebelumnya hanya menerima "Not Yet". Itu jauh lebih sempit daripada aturan
            // sebenarnya, dan menjadi sebab kedua mengapa unggahan massal On Hold seolah cuma
            // memuat satu dokumen: begitu daftar yang ditempel memuat dokumen Submitted atau
            // Released - keadaan yang lumrah, karena On Hold justru dipakai setelah dokumen
            // berjalan - semuanya ditandai merah dan hanya yang kebetulan masih Not Yet lolos.
            const EXC_STATUS_BOLEH = {
                hold: ['not yet', 'submitted', 'released', 'claimed'],
                expired: ['not yet', 'submitted', 'released', 'claimed', 'on hold']
            };
            // Pratinjau belum tahu tombol mana yang akan ditekan, jadi yang dipakai adalah
            // gabungan keduanya; penyaringan per tindakan terjadi di submitPostingException().
            const EXC_STATUS_PRATINJAU = EXC_STATUS_BOLEH.expired;

            // Susunan kolom tabel pratinjau, mengikuti Tipe Posting. Mode Exception memuat
            // kolom tanggal, bukan rekening dan pajak, sehingga memakai judul mode Claim akan
            // menaruh SO Start di bawah judul "No Rekening".
            const PREVIEW_HEAD = {
                claim: ['Status', 'No Document', 'Kode Toko', 'Nama Toko', 'Kode Campaign', 'Nama Campaign',
                        'Total Reward', 'No Rekening', 'Nama Rekening', 'Bank', 'No KTP', 'No NPWP',
                        'Subyek Pajak', 'TOP Setting', 'TOP Actual', 'Jenis CB'],
                exception: ['Status', 'No Document', 'Kode Toko', 'Nama Toko', 'Kode Campaign', 'Nama Campaign',
                            'Total Reward', 'SO Start s/d SO End', 'Billing Start s/d Billing End',
                            'Status Saat Ini']
            };

            function pasangPreviewHead() {
                const tr = document.getElementById('uploadPreviewHead');
                if (!tr) return;
                const judul = PREVIEW_HEAD[currentPostingMode === 'exception' ? 'exception' : 'claim'];
                tr.innerHTML = '<th class="text-center w-12"><input type="checkbox" id="cbUploadAll"'
                    + ' onchange="toggleAllUpload(this)" class="w-4 h-4 text-blue-600 rounded" checked></th>'
                    + judul.map(function (t) {
                        const rata = (t === 'Total Reward') ? ' class="text-right text-blue-700"'
                            : (t === 'Status' || t === 'Status Saat Ini' || t === 'Subyek Pajak'
                               || t === 'TOP Setting' || t === 'TOP Actual' || t === 'Jenis CB'
                               || t.indexOf('s/d') > -1) ? ' class="text-center"' : '';
                        return '<th' + rata + '>' + t + '</th>';
                    }).join('');
            }

            function initInputGrid() {
                const tbody = document.getElementById('inputGridBody');
                const thead = document.getElementById('inputGridHead');
                if (!tbody || !thead) return;
                const kolom = gridKolomAktif();

                thead.innerHTML = '<th class="w-10 text-center">#</th>'
                    + kolom.map(k => '<th style="min-width:' + k.lebar + '">' + k.judul + '</th>').join('');

                let html = '';
                for (let i = 0; i < 500; i++) {
                    const tampil = i < currentInputRows ? '' : ' style="display:none;"';
                    html += '<tr class="border-b border-gray-200 row-input transition-colors"' + tampil + ' data-idx="' + i + '">'
                        + '<td class="text-center text-gray-400 bg-gray-50 border-r border-gray-200 w-10">' + (i + 1) + '</td>'
                        + kolom.map(function (k, j) {
                            const akhir = j === kolom.length - 1;
                            return '<td class="p-0' + (akhir ? '' : ' border-r border-gray-200') + '">'
                                + '<input type="' + (k.tipe || 'text') + '" name="' + k.nama + '"'
                                + ' class="excel-input ' + (k.kelas || 'text-gray-700')
                                + (k.ro ? ' font-bold bg-gray-100 cursor-not-allowed' : '') + '"'
                                + (k.ro ? ' readonly' : '')
                                + (k.ph ? ' placeholder="' + k.ph + '"' : '')
                                + (k.list ? ' list="' + k.list + '"' : '')
                                + '></td>';
                        }).join('')
                        + '</tr>';
                }
                tbody.innerHTML = html;
                updateRowCountDisplay();
            }
            document.getElementById('inputGridBody').addEventListener('paste', function(e) {
                e.preventDefault(); let clipboardData = e.clipboardData || window.clipboardData; let pastedData = clipboardData.getData('Text'); if(!pastedData) return;
                let rows = pastedData.split(/\r\n|\n|\r/); if (rows.length > 0 && rows[rows.length - 1] === '') { rows.pop(); }
                let targetInput = e.target; if (!targetInput.classList.contains('excel-input')) return;
                let tr = targetInput.closest('tr'); let startRowIdx = parseInt(tr.getAttribute('data-idx'));
                if(startRowIdx + rows.length > 500){showNotification('Maksimal 500 toko/baris. Paste dibatalkan agar tidak ada data terpotong.','error');return;}
                let inputsInRow = Array.from(tr.querySelectorAll('.excel-input')); let startColIdx = inputsInRow.indexOf(targetInput);
                let allTrs = document.getElementById('inputGridBody').querySelectorAll('.row-input'); let pasteCount = 0;
                for (let i = 0; i < rows.length; i++) {
                    if (startRowIdx + pasteCount >= 500) break; let cells = rows[i].split('\t');
                    let rowTr = allTrs[startRowIdx + pasteCount]; rowTr.style.display = ''; 
                    let inputs = rowTr.querySelectorAll('.excel-input');
                    for (let j = 0; j < cells.length; j++) {
                        let targetColIdx = startColIdx + j;
                        if (targetColIdx < inputs.length) {
                            let inputEl = inputs[targetColIdx];
                            if (!inputEl.readOnly) {
                                let nilai = cells[j].trim();
                                // Kolom tanggal hanya menerima ISO. Nilai dari Excel datang
                                // sebagai dd.mm.yyyy atau 01-Feb-25; diurai lebih dulu di sini,
                                // karena bila tidak, peramban membuang nilainya tanpa suara.
                                if (inputEl.type === 'date') nilai = rcUraiTanggal(nilai);
                                inputEl.value = nilai;
                            }
                        }
                    }
                    autoFillGridRowFromDoc(rowTr);
                    pasteCount++;
                }
                if (startRowIdx + pasteCount > currentInputRows) { currentInputRows = startRowIdx + pasteCount; }
                updateRowCountDisplay();
            });

            // Isi otomatis KTP/NPWP/No Rekening/Nama Rekening/Bank dari database begitu No Document diketik/di-paste,
            // supaya data yang sistem sudah punya langsung terlihat di grid (bukan baru muncul saat Preview) -
            // Rekening/Nama Rekening/Bank tetap bisa diedit manual (tidak ditimpa kalau sudah diisi user).
            // async sejak master tidak lagi diunduh saat login: barisnya diambil lebih dulu,
            // baru dicari. Pemanggilnya tidak wajib menunggu - pengisian otomatis yang datang
            // sepersekian detik kemudian tetap benar, dan tidak ada yang menunggu hasilnya.
            async function autoFillGridRowFromDoc(tr) {
                if (!tr) return;
                let ndInput = tr.querySelector('[name="noDoc"]'); if (!ndInput) return;
                let nd = ndInput.value.trim().toUpperCase(); if (!nd) return;
                await pastikanMaster([], [nd]);
                let db = globalDocuments.find(d => String(d.noDoc).trim().toUpperCase() === nd); if (!db) return;
                await pastikanMaster([db.custCode], []);
                let cst = globalCustomers.find(c => c.custCode === db.custCode) || {};
                let ktpEl = tr.querySelector('[name="ktp"]'), npwpEl = tr.querySelector('[name="npwp"]');
                let rekEl = tr.querySelector('[name="noRekening"]'), namaRekEl = tr.querySelector('[name="namaRekening"]'), bankEl = tr.querySelector('[name="bank"]');
                if (ktpEl) ktpEl.value = cst.ktp || '';
                if (npwpEl) npwpEl.value = cst.npwp || '';
                if (rekEl && !rekEl.value.trim()) rekEl.value = cst.noRek || '';
                if (namaRekEl && !namaRekEl.value.trim()) namaRekEl.value = cst.namaRek || '';
                if (bankEl && !bankEl.value.trim()) bankEl.value = cst.bank || '';

                // Keempat tanggal Posting Exception diisi dari periode campaign dokumen itu.
                // Nilai awal yang benar jauh lebih berguna daripada kolom kosong: pengguna
                // tinggal memperpanjang salah satunya, dan itulah yang memang dituntut On Hold.
                const camp = (typeof globalCampaigns !== 'undefined' ? globalCampaigns : [])
                    .find(c => String(c.codeCampaign) === String(db.codeCampaign));
                if (camp) {
                    // ISO, bukan dd.mm.yyyy: kolomnya kini <input type="date">, yang menyimpan
                    // dan menampilkan sendiri menurut setelan wilayah peramban.
                    const mulai = rcUraiTanggal(camp.periodStart);
                    const selesai = rcUraiTanggal(camp.periodEnd);
                    [['soStart', mulai], ['soEnd', selesai],
                     ['billingStart', mulai], ['billingEnd', selesai]].forEach(function (pasangan) {
                        const el = tr.querySelector('[name="' + pasangan[0] + '"]');
                        // Hanya mengisi yang masih kosong; ketikan pengguna tidak pernah ditimpa.
                        if (el && !el.value.trim() && pasangan[1]) el.value = pasangan[1];
                    });
                }
            }
            document.getElementById('inputGridBody').addEventListener('blur', function(e) {
                if (!e.target.classList || !e.target.classList.contains('excel-input') || e.target.name !== 'noDoc') return;
                autoFillGridRowFromDoc(e.target.closest('tr'));
            }, true);

            function updateRowCountDisplay() { let countEl = document.getElementById('rowCountDisplay'); if(countEl) countEl.innerText = `${currentInputRows} / 500 Baris`; }
            function addInputRow() { if (currentInputRows >= 500) { showNotification("Maksimal 500 baris.", "warning"); return; } let tbody = document.getElementById('inputGridBody'); tbody.querySelector(`[data-idx="${currentInputRows}"]`).style.display = ''; currentInputRows++; updateRowCountDisplay(); }
            function removeInputRow() { if (currentInputRows <= 1) return; let tbody = document.getElementById('inputGridBody'); currentInputRows--; let row = tbody.querySelector(`[data-idx="${currentInputRows}"]`); row.style.display = 'none'; row.querySelectorAll('input').forEach(i => i.value = ''); updateRowCountDisplay(); }
            function resetInputGrid() { currentInputRows = 5; initInputGrid(); }
            function cancelPreview() { setHiddenSafely('uploadPreviewContainer', true); setHiddenSafely('tab_mass', currentUploadMode !== 'mass'); setHiddenSafely('tab_single', currentUploadMode !== 'single');  setHiddenSafely('uploadModuleTabs', false); hasMasterUpdateFlag = false; massUploadDataValid = []; }

            // Mengumpulkan seluruh nomor dokumen yang sedang diketik, supaya master-nya dapat
            // diambil sekali jalan sebelum baris-barisnya diperiksa.
            function rcNoDocPratinjau(mode) {
                if (mode === 'single') {
                    const el = document.getElementById('singleNoDoc');
                    return el && el.value.trim() ? [el.value] : [];
                }
                const trs = document.getElementById('inputGridBody').querySelectorAll('.row-input');
                const out = [];
                for (let i = 0; i < currentInputRows; i++) {
                    if (!trs[i] || trs[i].style.display === 'none') continue;
                    const el = trs[i].querySelector('input[name="noDoc"]');
                    if (el && el.value.trim()) out.push(el.value);
                }
                return out;
            }

            // async sejak master diambil saat perlu. Pengambilannya dilakukan SEKALI untuk
            // seluruh baris sebelum pemeriksaan dimulai - bukan satu permintaan per baris,
            // yang pada unggahan 500 dokumen berarti 500 perjalanan ke server.
            async function previewUploadData(mode) {
                const nd = rcNoDocPratinjau(mode);
                if (nd.length) {
                    await pastikanMaster([], nd);
                    // Pelanggannya baru diketahui setelah dokumennya ada.
                    const kode = [];
                    nd.forEach(function (n) {
                        const db = globalDocuments.find(d =>
                            String(d.noDoc).trim().toUpperCase() === String(n).trim().toUpperCase());
                        if (db && db.custCode) kode.push(db.custCode);
                    });
                    if (kode.length) await pastikanMaster(kode, []);
                }

                massUploadDataValid = []; hasMasterUpdateFlag = false; let v = 0;
                let isSysMgr = currentUserData && (currentUserData.sysRole || currentUserData.role || '').toLowerCase() === 'system manager';
                let managed = currentUserData.managedDepots ? currentUserData.managedDepots.map(x => String(x).toUpperCase()) : [];
                let rowsHtml = '';

                let processRow = function(inputData) {
                    let nd = String(inputData.noDoc || "").trim().toUpperCase(); if (!nd) return;
                    let db = globalDocuments.find(d => String(d.noDoc).trim().toUpperCase() === nd);
                    let trInfo = ""; let isValid = true; let docDc = db ? String(db.dcCode || '').toUpperCase() : '';

                    // MODE POSTING EXCEPTION: hanya menandai dokumen sebagai On Hold/Expired, tidak butuh kelengkapan data klaim
                    // (Tgl Lunas, TOP, Rekening, dst). Hanya dokumen berstatus "Not Yet" yang boleh diproses lewat
                    // modul Upload ini - dokumen yang sudah Submitted/Released/Claimed harus di-reject dulu di
                    // tahapnya masing-masing sampai kembali ke Not Yet.
                    if (currentPostingMode === 'exception') {
                        let stLow = db ? String(db.status || '').trim().toLowerCase() : '';
                        if (!db) { isValid = false; trInfo = `<span class="bg-orange-100 text-orange-700 px-2 py-0.5 rounded shadow-sm font-bold"><i class="fas fa-exclamation-triangle"></i> Tdk di DB</span>`; }
                        else if (!isSysMgr && !managed.includes(docDc)) { isValid = false; trInfo = `<span class="bg-red-100 text-red-700 px-2 py-0.5 rounded shadow-sm font-bold"><i class="fas fa-ban"></i> Beda DC</span>`; }
                        else if (db.pendingApproval) { isValid = false; trInfo = 'Menunggu approval'; }
                        else if (stLow !== "" && EXC_STATUS_PRATINJAU.indexOf(stLow) === -1) { isValid = false; trInfo = `<span class="bg-red-100 text-red-700 px-2 py-0.5 rounded shadow-sm font-bold"><i class="fas fa-ban"></i> Status ${db.status || '-'} tidak dapat diproses</span>`; }
                        else { trInfo = `<span class="bg-blue-100 text-blue-700 px-2 py-0.5 rounded shadow-sm font-bold">Siap Diproses</span>`; massUploadDataValid.push({ noDoc: nd, custCode: db.custCode, custName: normalizeName(db.custName), codeCampaign: db.codeCampaign, campaignName: db.campaignName, cbNet: db.cbNet, currentStatus: db.status || '', soStart: inputData.soStart || '', soEnd: inputData.soEnd || '', billingStart: inputData.billingStart || '', billingEnd: inputData.billingEnd || '' }); v++; }

                        if (isValid) { rowsHtml += `<tr class="hover:bg-blue-50 transition-colors border-b border-gray-100"><td class="p-3 text-center"><input type="checkbox" class="cb-upload w-4 h-4 text-blue-600 rounded focus:ring-blue-500" value="${nd}" checked onchange="updateUploadCount()"></td><td class="p-3 text-center">${trInfo}</td><td class="p-3 font-black text-blue-700">${nd}</td><td class="p-3 font-semibold text-gray-500">${db.custCode || '-'}</td><td class="p-3 font-bold text-gray-800">${normalizeName(db.custName)}</td><td class="p-3 font-semibold text-gray-500">${db.codeCampaign || '-'}</td><td class="p-3 max-w-[150px] truncate" title="${db.campaignName}">${db.campaignName || '-'}</td><td class="p-3 text-right font-black text-red-600">Rp ${Math.trunc(Number(Number(db.cbNet || 0))||0).toLocaleString('id-ID')}</td><td class="p-3 text-center text-xs">${inputData.soStart ? rcTanggalId(inputData.soStart) + ' s/d ' + rcTanggalId(inputData.soEnd) : '-'}</td><td class="p-3 text-center text-xs">${inputData.billingStart ? rcTanggalId(inputData.billingStart) + ' s/d ' + rcTanggalId(inputData.billingEnd) : '-'}</td><td class="p-3 text-center text-xs font-bold text-gray-600">${db.status || '-'}</td></tr>`; }
                        else { rowsHtml += `<tr class="bg-red-50/50 opacity-80 border-b border-red-100"><td class="p-3 text-center"><i class="fas fa-times text-red-400"></i></td><td class="p-3 text-center">${trInfo}</td><td class="p-3 font-bold text-gray-800">${nd}</td><td colspan="${PREVIEW_HEAD.exception.length - 2}" class="p-3 text-red-500 font-medium italic">Data tidak valid dan diabaikan.</td></tr>`; }
                        return;
                    }

                    if (!db) { isValid = false; trInfo = `<span class="bg-orange-100 text-orange-700 px-2 py-0.5 rounded shadow-sm font-bold"><i class="fas fa-exclamation-triangle"></i> Tdk di DB</span>`; }
                    else if (!isSysMgr && !managed.includes(docDc)) { isValid = false; trInfo = `<span class="bg-red-100 text-red-700 px-2 py-0.5 rounded shadow-sm font-bold"><i class="fas fa-ban"></i> Beda DC</span>`; }
                    else if (db.pendingApproval) { isValid = false; trInfo = 'Menunggu approval'; }
                    // SECURITY: dokumen berstatus Expired/On Hold dikunci permanen dari jalur upload klaim biasa -
                    // perubahan status ini hanya boleh lewat Posting Exception.
                    else if (String(db.status || "").trim().toLowerCase() === "expired") { isValid = false; trInfo = `<span class="bg-gray-800 text-white px-2 py-0.5 rounded shadow-sm font-bold"><i class="fas fa-times-circle"></i> Expired (Permanen)</span>`; }
                    else if (String(db.status || "").trim().toLowerCase() === "on hold") { isValid = false; trInfo = `<span class="bg-purple-100 text-purple-700 px-2 py-0.5 rounded shadow-sm font-bold"><i class="fas fa-pause-circle"></i> Sedang Ditahan (On Hold)</span>`; }
                    else if (String(db.status || "").trim().toLowerCase() !== "not yet" && String(db.status || "").trim() !== "") { isValid = false; trInfo = `<span class="bg-red-100 text-red-700 px-2 py-0.5 rounded shadow-sm font-bold"><i class="fas fa-ban"></i> Duplikat</span>`; }
                    else {
                        let cmp = globalCampaigns.find(c => c.codeCampaign === db.codeCampaign) || {}; let cst = globalCustomers.find(c => c.custCode === db.custCode) || {};
                        let db_ktp = String(cst.ktp || '').trim(), db_npwp = String(cst.npwp || '').trim(), final_subyekpajak = "";
                        // 20261163110000: NPWP terisi = Badan walaupun KTP juga ada (KTP hanya tampil di Customer
                        // Master, tidak dipakai dokumen). Dulu baris ini ditolak "KTP & NPWP Ganda".
                        if (db_npwp) { final_subyekpajak = "Badan"; } else if (db_ktp) { final_subyekpajak = "Perorangan"; } 
                        else { isValid = false; trInfo = `<span class="bg-red-100 text-red-700 px-2 py-0.5 rounded shadow-sm font-bold">KTP/NPWP Kosong (Update DB)</span>`; }

                        let ex_norek = inputData.norek, ex_namarek = inputData.namarek, ex_bank = inputData.bank, in_top = parseFloat(inputData.top), in_tglLunas = normalizeDateUI(inputData.tglLunas);
                        

                        let final_norek = ex_norek || String(cst.noRek || '').trim(), final_namarec = ex_namarek || String(cst.namaRek || '').trim(), final_bank = ex_bank || String(cst.bank || '').trim(), final_top = isNaN(in_top) ? '' : in_top, master_top = parseFloat(cst.top || 0);

                        // Dibedakan: kosong dan salah format bukan kesalahan yang sama, dan pesan
                        // "wajib diisi" pada kolom yang JELAS terisi hanya membuat bingung.
                        const tglLunasDiketik = String(inputData.tglLunas || '').trim();
                        if (isValid && !tglLunasDiketik) { isValid = false; trInfo = `<span class="bg-red-100 text-red-700 px-2 py-0.5 rounded shadow-sm font-bold">Tgl Lunas Wajib</span>`; }
                        else if (isValid && !in_tglLunas) { isValid = false; trInfo = `<span class="bg-red-100 text-red-700 px-2 py-0.5 rounded shadow-sm font-bold">Format Tgl Lunas salah: ${rcEsc(tglLunasDiketik)} - pakai dd-mm-yyyy, dd.mm.yy, ddmmyyyy atau ddmmyy</span>`; }
                        // TOP boleh dibiarkan kosong atas instruksi pemilik. Kosong berarti tidak
                        // ada permintaan kelonggaran: dokumen memakai TOP pada Customer Master apa
                        // adanya. Yang diisi TETAP diperiksa - angka negatif atau nol bukan tempo
                        // pembayaran, dan meloloskannya hanya memindahkan kekeliruan ke hilir.
                        if (isValid && String(inputData.top || '').trim() !== '' && (isNaN(in_top) || in_top <= 0)) {
                            isValid = false;
                            trInfo = `<span class="bg-red-100 text-red-700 px-2 py-0.5 rounded shadow-sm font-bold">TOP harus angka lebih dari 0, atau dikosongkan</span>`;
                        }
                        // TOP yang melebihi Master Customer dulu ditolak di sini kecuali kolom
                        // Approval diisi. Atas instruksi pemilik penjagaan itu dicabut: seluruh
                        // dokumen boleh diunggah, dan layak-tidaknya TOP ditentukan di modul
                        // Management of Approval - bukan oleh orang yang mengetik unggahannya.
                        
                        // Jenis CB terisi otomatis dari Campaign Master, tetapi pengguna boleh
                        // menimpanya. Penulisannya harus persis salah satu dari daftar resmi:
                        // salah ketik seperti "RA 07" atau "transferr" ditolak di sini, bukan
                        // diterima lalu menjadi status yang salah di database.
                        let in_jenis = String(inputData.jenisCb || '').trim();
                        let final_jenis = rcCbLabel(in_jenis || db.jenisCb || cmp.jenisCb);
                        if (isValid && !final_jenis) { isValid = false; trInfo = `<span class="bg-red-100 text-red-700 px-2 py-0.5 rounded shadow-sm font-bold">Jenis CB Wajib</span>`; }
                        // Yang divalidasi ketat hanyalah nilai yang DIKETIK pengguna. Nilai warisan
                        // dari Campaign Master diterima apa adanya, karena master memang masih memuat
                        // jenis lama seperti Voucher, dan menolaknya di sini akan memblokir campaign
                        // yang sah hanya karena daftar resmi yang baru lebih pendek.
                        if (isValid && in_jenis && RC_JENIS_CB.indexOf(in_jenis) === -1) { isValid = false; trInfo = `<span class="bg-red-100 text-red-700 px-2 py-0.5 rounded shadow-sm font-bold">Jenis CB harus persis: ${RC_JENIS_CB.join(' / ')}</span>`; }
                        if (isValid && final_jenis.toLowerCase() === 'transfer') {
                            if (!final_norek || !final_namarec || !final_bank) { isValid = false; trInfo = `<span class="bg-red-100 text-red-700 px-2 py-0.5 rounded shadow-sm font-bold">No Rekening/Nama Rekening/Bank Wajib Diisi (Jenis CB: Transfer)</span>`; }
                        }

                        if (isValid) {
                            let isChangeRek = (ex_norek && ex_norek !== String(cst.noRek || '').trim()) || (ex_namarek && ex_namarek !== String(cst.namaRek || '').trim()) || (ex_bank && ex_bank !== String(cst.bank || '').trim());
                            if(isChangeRek) { trInfo = `<span class="bg-red-500 text-white px-2 py-0.5 rounded font-black text-[9px] animate-pulse shadow-sm">⚠️ Update Master Rek</span>`; hasMasterUpdateFlag = true; } 
                            else { trInfo = `<span class="bg-green-100 text-green-700 px-2 py-0.5 rounded font-bold shadow-sm">Valid</span>`; }

                            // Bulan potong dan total tagihan sudah dihapus dari layar atas permintaan pemilik.
                            massUploadDataValid.push({ noDoc: nd, dcCode: db.dcCode, depotName: normalizeName(db.depotName), codeCampaign: db.codeCampaign, campaignName: db.campaignName, custCode: db.custCode, custName: normalizeName(db.custName), netValue: db.netValue, volume: db.volume, cbNet: db.cbNet, periodStart: cmp.periodStart, campaignEnd: cmp.periodEnd, npwp: db_npwp, ktp: db_ktp, statusPajakCust: final_subyekpajak, tglLunas: in_tglLunas, top: final_top, subyekPajak: final_subyekpajak, statusPajakCampaign: cmp.statusPajak, jenisCashback: final_jenis, jenisCashbackInput: in_jenis, noRekening: final_norek, pemilikRekening: final_namarec, bankCust: final_bank }); v++;

                            // PERBAIKAN: Menampilkan nilai murni di tabel preview
                            rowsHtml += `<tr class="hover:bg-blue-50 transition-colors border-b border-gray-100"><td class="p-3 text-center"><input type="checkbox" class="cb-upload w-4 h-4 text-blue-600 rounded focus:ring-blue-500" value="${nd}" checked onchange="updateUploadCount()"></td><td class="p-3 text-center">${trInfo}</td><td class="p-3 font-black text-blue-700">${nd}</td><td class="p-3 font-semibold text-gray-500">${db.custCode || '-'}</td><td class="p-3 font-bold text-gray-800">${normalizeName(db.custName)}</td><td class="p-3 font-semibold text-gray-500">${db.codeCampaign || '-'}</td><td class="p-3 max-w-[150px] truncate" title="${db.campaignName}">${db.campaignName || '-'}</td><td class="p-3 text-right font-black text-red-600">Rp ${Math.trunc(Number(Number(db.cbNet || 0))||0).toLocaleString('id-ID')}</td><td class="p-3 font-medium text-gray-700 ${isChangeRek ? 'bg-orange-50 text-orange-700' : ''}">${final_norek || '-'}</td><td class="p-3 font-medium text-gray-700 ${isChangeRek ? 'bg-orange-50 text-orange-700' : ''}">${final_namarec || '-'}</td><td class="p-3 font-medium text-gray-700 ${isChangeRek ? 'bg-orange-50 text-orange-700' : ''}">${final_bank || '-'}</td><td class="p-3 text-gray-700">${db_ktp || '-'}</td><td class="p-3 text-gray-700">${db_npwp || '-'}</td><td class="p-3 text-center font-bold text-gray-700">${final_subyekpajak || '-'}</td><td class="p-3 text-center text-gray-600">${isNaN(master_top) || !master_top ? '-' : master_top}</td><td class="p-3 text-center font-black ${final_top !== '' && !isNaN(master_top) && master_top > 0 && Number(final_top) > master_top ? 'bg-amber-50 text-amber-700' : ''}">${final_top === '' ? '-' : final_top}</td><td class="p-3 text-center font-bold ${in_jenis && in_jenis !== String(cmp.jenisCb || '').trim() ? 'bg-amber-50 text-amber-700' : ''}">${final_jenis || '-'}</td></tr>`;
                        }
                    }
                    if (!isValid) { rowsHtml += `<tr class="bg-red-50/50 opacity-80 border-b border-red-100"><td class="p-3 text-center"><i class="fas fa-times text-red-400"></i></td><td class="p-3 text-center">${trInfo}</td><td class="p-3 font-bold text-gray-800">${nd}</td><td colspan="16" class="p-3 text-red-500 font-medium italic">Data tidak valid dan diabaikan.</td></tr>`; }
                };

                if (mode === 'mass') {
                    let trs = document.getElementById('inputGridBody').querySelectorAll('.row-input');
                    for (let i = 0; i < currentInputRows; i++) {
                        if (trs[i].style.display === 'none') continue; let inputs = trs[i].querySelectorAll('input');
                        // Dibaca berdasarkan atribut name, bukan urutan kolom. Grid kini
                        // memiliki dua susunan kolom yang berbeda (Claim dan Exception), dan
                        // indeks tetap akan membaca kolom yang salah pada salah satunya.
                        const isi = {};
                        trs[i].querySelectorAll('input[name]').forEach(el => { isi[el.name] = el.value; });
                        processRow({
                            noDoc: isi.noDoc, tglLunas: isi.tglLunas, ktp: isi.ktp, npwp: isi.npwp,
                            norek: isi.noRekening, namarek: isi.namaRekening, bank: isi.bank,
                            top: isi.top, jenisCb: isi.jenisCb,
                            // Diurai menjadi ISO di sini. Bila tidak dikenali hasilnya string
                            // kosong, dan server menolaknya dengan sebab yang jelas.
                            soStart: rcUraiTanggal(isi.soStart), soEnd: rcUraiTanggal(isi.soEnd),
                            billingStart: rcUraiTanggal(isi.billingStart), billingEnd: rcUraiTanggal(isi.billingEnd)
                        });
                    }
                    // Grid disembunyikan supaya pratinjau menggantikannya, bukan menumpuk di
                    // bawahnya. Sebelumnya yang disembunyikan 'uploadInputContainer' - id yang
                    // tidak ada di markup mana pun, sehingga baris ini tidak melakukan apa-apa
                    // dan grid tetap terlihat. cancelPreview() sendiri sudah memunculkan kembali
                    // 'tab_mass', jadi itulah id yang dimaksud sejak semula.
                    setHiddenSafely('tab_mass', true); setHiddenSafely('tab_single', true);
                } else if (mode === 'single') {
                    processRow({ noDoc: document.getElementById('singleNoDoc').value, tglLunas: document.getElementById('singleTglLunas').value, ktp: document.getElementById('singleKtp').value, npwp: document.getElementById('singleNpwp').value, norek: document.getElementById('singleRek').value, namarek: document.getElementById('singleNamaRek').value, bank: document.getElementById('singleBank').value, top: document.getElementById('singleTop').value, jenisCb: document.getElementById('singleJenisCbInput').value });
                    setHiddenSafely('tab_mass', true); setHiddenSafely('tab_single', true); setHiddenSafely('uploadModuleTabs', true);
                }

                pasangPreviewHead();
                document.getElementById('uploadPreviewBody').innerHTML = rowsHtml; updateUploadCount(v); setHiddenSafely('uploadPreviewContainer', false); setHiddenSafely('masterUpdateWarning', !hasMasterUpdateFlag);
                setHiddenSafely('claimSubmitGroup', currentPostingMode !== 'claim'); setHiddenSafely('exceptionSubmitGroup', currentPostingMode !== 'exception');
                let canUpload = false; if (currentUserData) { let uAuth = currentUserData.auth || {}; if ((currentUserData.sysRole || currentUserData.role || '').toLowerCase() === 'system manager' || parseAuthBool(uAuth.j)) canUpload = true; } setDisabledSafely('btnSubmitUpload', (v === 0) || !canUpload);
                setDisabledSafely('btnPostHold', (v === 0) || !canUpload); setDisabledSafely('btnPostExpired', (v === 0) || !canUpload);
            }
