            let currentUserData = null; let globalCampaigns = []; let globalCustomers = []; let globalDocuments = []; let massUploadDataValid = []; let hasMasterUpdateFlag = false; let currentInputRows = 5; let currentUploadMode = 'mass'; let currentPostingMode = 'claim';

            // Tipe Posting: "claim" (posting normal, memerlukan kelengkapan data) vs
            // "exception" (hanya untuk menahan/menghanguskan dokumen lewat modul Upload, bukan tick-by-tick di Analytics).
            function setPostingMode(mode) {
                currentPostingMode = mode;
                let bC = document.getElementById('modeBtnClaim'), bE = document.getElementById('modeBtnException');
                if (bC) bC.className = "px-5 py-2 text-sm font-bold rounded-lg transition " + (mode === 'claim' ? "bg-green-100 text-green-700" : "text-gray-500 hover:bg-gray-100");
                if (bE) bE.className = "px-5 py-2 text-sm font-bold rounded-lg transition " + (mode === 'exception' ? "bg-red-100 text-red-700" : "text-gray-500 hover:bg-gray-100");
                setHiddenSafely('modeExceptionHint', mode !== 'exception');
                // Mode Posting Exception memakai tabel yang sama dengan Mass Upload, hanya
                // kolomnya yang berbeda. Grid dibangun ulang supaya header dan barisnya
                // berganti bersamaan - bila hanya salah satunya, kolom dan judulnya bergeser.
                if (typeof initInputGrid === 'function') initInputGrid();
                // Field klaim (Tgl Lunas, TOP) tidak wajib di Manual Input saat mode Posting Exception.
                let reqTgl = document.getElementById('singleTglLunas'), reqTop = document.getElementById('singleTop');
                if (reqTgl) reqTgl.required = (mode === 'claim');
                if (reqTop) reqTop.required = (mode === 'claim');
                cancelPreview();
                // Ganti mode Posting = mulai proses Posting baru - No Doc & input lain dari mode sebelumnya
                // harus bersih, bukan ikut terbawa (lihat catatan resetPostingInputs()).
                resetPostingInputs();
                if (typeof autoFillSingleDoc === 'function') autoFillSingleDoc();
            }
            
            function downloadUploadTemplate() {
            // Template mengikuti Tipe Posting yang sedang aktif. Menurunkan satu template untuk
            // dua susunan kolom akan membuat berkasnya tidak pernah cocok dengan grid yang
            // sedang dilihat, dan kolom yang tidak dikenali diam-diam diabaikan saat diimpor.
            if (currentPostingMode === 'exception') {
                const ws_x = XLSX.utils.aoa_to_sheet([
                    ["No Document", "SO Start", "SO End", "Billing Start", "Billing End"],
                    ["DOC-001", "01.02.2026", "31.03.2026", "01.02.2026", "30.04.2026"]
                ]);
                ws_x['!cols'] = [{ wch: 24 }, { wch: 14 }, { wch: 14 }, { wch: 14 }, { wch: 14 }];
                const wb_x = XLSX.utils.book_new();
                XLSX.utils.book_append_sheet(wb_x, ws_x, "Posting Exception");
                XLSX.writeFile(wb_x, "Template_Posting_Exception.xlsx");
                return;
            }
            // Kolom yang dihapus dari template (No KTP, No NPWP, Bln Potong 1-4, Total Tagihan, dan kolom
            // bantu simulasi pajak Net Cashback/Subyek/Gross Up) adalah field opsional, sudah otomatis
            // terisi dari database (KTP/NPWP ditarik dari ListCust begitu No Document diketik - lihat
            // autoFillGridRowFromDoc), atau cuma alat bantu hitung pajak yang tidak lagi diperlukan.
            // Gross up tetap dihitung otomatis di server (calcGrossUpCB) saat submitData, terlepas dari
            // ada/tidaknya kolom simulasi ini. Kolom yang tersisa adalah yang mandatory/dibutuhkan saja.
            const ws_data = [
                ["No Document", "Tgl Lunas", "No Rekening", "Nama Rekening", "Bank", "TOP", "Jenis CB"],
                ["DOC-001", "15-04-2026", "", "", "", "30", "Transfer"]
            ];

            const wb = XLSX.utils.book_new();
            const ws = XLSX.utils.aoa_to_sheet(ws_data);

            // Set format lebar kolom agar rapi saat dibuka
            ws['!cols'] = [
                { wch: 15 }, { wch: 12 }, { wch: 18 }, { wch: 20 }, { wch: 10 },
                { wch: 8 }, { wch: 10 }
            ];

            // Kolom No Rekening (C) diformat Text supaya leading zero/angka panjang tidak berubah jadi notasi ilmiah
            for (let rowNum = 2; rowNum <= 101; rowNum++) {
                let ref = 'C' + rowNum;
                if (!ws[ref]) ws[ref] = { t: 's', v: '' };
                ws[ref].z = '@';
            }

            XLSX.utils.book_append_sheet(wb, ws, "Template");
            XLSX.writeFile(wb, "Template_Upload_Claim.xlsx");
        }

            // Konversi 1 nilai sel Excel (bisa berupa Date, angka, atau teks) menjadi string yang siap ditampilkan di grid.
            function excelCellToDisplayString(raw) {
                if (raw === null || raw === undefined) return '';
                if (raw instanceof Date) {
                    let d = String(raw.getDate()).padStart(2, '0'); let m = String(raw.getMonth() + 1).padStart(2, '0'); let y = raw.getFullYear();
                    return `${d}-${m}-${y}`;
                }
                return String(raw).trim();
            }

            // Header template -> nama field grid. Dipetakan berdasarkan NAMA kolom (bukan posisi tetap) supaya
            // template yang sudah disederhanakan (No KTP/No NPWP/Bln Potong 1-4/Total Tagihan dihapus karena
            // opsional atau otomatis dari database) tetap terbaca benar, dan kalau ada depot yang masih pakai
            // file template versi lama (kolom lebih banyak), kolom yang sudah tidak dipakai lagi otomatis
            // diabaikan tanpa menggeser/merusak kolom lain.
            const TEMPLATE_HEADER_TO_FIELD = {
                'no document': 'noDoc', 'tgl lunas': 'tglLunas', 'no rekening': 'noRekening',
                'nama rekening': 'namaRekening', 'bank': 'bank', 'top': 'top',
                // Kolom baru. Kosongkan bila ingin memakai Jenis CB dari Campaign Master;
                // bila diisi, penulisannya harus persis salah satu dari RC_JENIS_CB.
                'jenis cb': 'jenisCb', 'jeniscb': 'jenisCb',
                // Kolom Posting Exception. Berkasnya dibaca lewat jalur yang sama; kolom yang
                // tidak ada pada susunan grid yang sedang aktif diabaikan dengan sendirinya.
                'so start': 'soStart', 'so end': 'soEnd',
                'billing start': 'billingStart', 'billing end': 'billingEnd'
            };

            // Baca file .xlsx/.xls yang diupload depot (mengikuti kolom Template_Upload_Claim.xlsx),
            // lalu otomatis isi ke grid Mass Upload - tanpa perlu copy-paste satu per satu. Maksimal 100 baris.
            function handleMassUploadExcelFile(fileInputEl) {
                let file = fileInputEl.files && fileInputEl.files[0];
                if (!file) return;
                let reader = new FileReader();
                reader.onload = function(e) {
                    try {
                        let data = new Uint8Array(e.target.result);
                        let wb = XLSX.read(data, { type: 'array', cellDates: true });
                        let sheet = wb.Sheets[wb.SheetNames[0]];
                        let rows = XLSX.utils.sheet_to_json(sheet, { header: 1, raw: true, defval: '' });

                        // Cari baris header template ("No Document"); baris setelahnya dianggap data.
                        let headerIdx = rows.findIndex(r => String((r && r[0]) || '').trim().toLowerCase() === 'no document');
                        if (headerIdx < 0) { showNotification("Header 'No Document' tidak ditemukan. Pastikan file sesuai Template.", "error"); return; }

                        let colIdxToField = {};
                        rows[headerIdx].forEach((h, idx) => {
                            let field = TEMPLATE_HEADER_TO_FIELD[String(h || '').trim().toLowerCase()];
                            if (field) colIdxToField[idx] = field;
                        });

                        let dataRows = rows.slice(headerIdx + 1);
                        dataRows = dataRows.filter(r => r && r.some(cell => String(cell || '').trim() !== ''));

                        if (dataRows.length === 0) { showNotification("Tidak ada data yang terbaca dari file Excel.", "warning"); return; }

                        let truncated = false;
                        if (dataRows.length > 500) { showNotification("Maksimal 500 toko/baris per upload. Bagi file menjadi beberapa batch.", "error"); return; }

                        currentInputRows = dataRows.length;
                        initInputGrid();

                        let allRows = document.querySelectorAll('#inputGridBody .row-input');
                        dataRows.forEach((rowData, rIdx) => {
                            let tr = allRows[rIdx]; if (!tr) return;
                            Object.keys(colIdxToField).forEach(colIdx => {
                                let fieldName = colIdxToField[colIdx];
                                let cellInput = tr.querySelector('[name="' + fieldName + '"]');
                                if (!cellInput || cellInput.readOnly) return; // lewati kolom No KTP / No NPWP (Auto DB)
                                let val = excelCellToDisplayString(rowData[colIdx]);
                                // Kolom <input type="date"> hanya menerima ISO; nilai dari Excel
                                // datang sebagai dd.mm.yyyy atau 01-Feb-25 dan akan dibuang diam-diam
                                // oleh peramban bila tidak diurai lebih dulu.
                                if (cellInput.type === 'date') val = rcUraiTanggal(val);
                                cellInput.value = val;

                            });
                            // Melengkapi dari database persis seperti jalur tempel: KTP/NPWP dan
                            // rekening pada mode Claim, keempat tanggal periode campaign pada mode
                            // Posting Exception. Sebelumnya langkah ini hanya ada pada jalur tempel,
                            // sehingga berkas Excel selalu mendarat dengan kolom tanggal kosong.
                            if (typeof autoFillGridRowFromDoc === 'function') autoFillGridRowFromDoc(tr);
                        });

                        updateRowCountDisplay();
                        showNotification(`${dataRows.length} baris berhasil dimuat dari Excel${truncated ? ' (dipotong maksimal 500 baris)' : ''}.`, "success");
                    } catch (err) {
                        showNotification("Gagal membaca file Excel. Pastikan formatnya sesuai Template.", "error");
                    } finally {
                        fileInputEl.value = '';
                    }
                };
                reader.readAsArrayBuffer(file);
            }
