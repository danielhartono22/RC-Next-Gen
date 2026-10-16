            let rcOpenState = { offset: 0, rows: [] };
            let rcCompileRows = null;
            let rcPermissionCatalog = null;

            function openRcOpenTab() {
                if(!rcEnterTab('upload','open'))return;
                currentUploadMode = 'open';
                setHiddenSafely('tab_mass', true); setHiddenSafely('tab_single', true);
                setHiddenSafely('tab_open', false);
                let idle = "px-5 py-2 text-sm font-bold rounded-lg text-gray-500 hover:bg-gray-100 transition";
                let active = "px-5 py-2 text-sm font-bold rounded-lg bg-blue-100 text-blue-700 transition";
                ['subnav_mass','subnav_single'].forEach(id => { let e = document.getElementById(id); if (e) e.className = idle; });
                let so = document.getElementById('subnav_open'); if (so) so.className = active;
                // Pilihan Campaign dan Jenis CB diisi dari jawaban server (opsiOpenFilter), bukan
                // dari seluruh Campaign Master: yang ditawarkan hanya yang benar-benar ada di
                // antara dokumen Not Yet, sehingga tidak ada pilihan yang berujung tabel kosong.
                loadOpenClaims(0);
            }

            // Mengisi ulang pilihan filter tanpa membuang pilihan yang sedang aktif. Pilihan
            // yang sudah tidak ada di data tetap dipertahankan supaya tabel tidak berubah diam-
            // diam di tangan pengguna.
            function opsiOpenFilter(opsi) {
                if (!opsi) return;
                const isi = function (id, semua, daftar) {
                    const sel = document.getElementById(id);
                    if (!sel) return;
                    const kini = sel.value;
                    const ada = daftar.some(d => d.v === kini);
                    sel.innerHTML = '<option value="">' + rcEsc(semua) + '</option>'
                        + (kini && !ada ? '<option value="' + rcEsc(kini) + '">' + rcEsc(kini) + '</option>' : '')
                        + daftar.map(d => '<option value="' + rcEsc(d.v) + '">' + rcEsc(d.t) + '</option>').join('');
                    sel.value = kini;
                };
                isi('openCampaign', '-- Semua Campaign --',
                    (opsi.campaigns || []).map(c => ({ v: c.kode, t: c.kode + ' - ' + (c.nama || '') })));
                isi('openCbType', 'Semua Jenis CB',
                    (opsi.jenisCb || []).map(j => ({ v: j, t: j })));
            }

            // Susunan kolom tab Open. "baku" menandai kolom yang tampil tanpa dipilih, yaitu
            // susunan yang sudah ada sebelumnya - pemilik meminta tampilan awalnya tidak
            // berubah. Kolom tambahan ada tetapi dimatikan, supaya tabel tidak langsung penuh
            // bagi orang yang tidak membutuhkannya.
            const OPEN_KOLOM = [
                { k: 'noDoc',        judul: 'No Document',   baku: true,  sel: r => '<span class="font-black text-blue-700">' + rcEsc(r.noDoc) + '</span>' },
                { k: 'toko',         judul: 'Toko',          baku: true,  sel: r => '<b>' + rcEsc(r.namaToko) + '</b><br><span class="text-gray-500">' + rcEsc(r.kodeToko) + '</span>', kelas: 'text-xs' },
                { k: 'campaign',     judul: 'Campaign',      baku: true,  sel: r => '<b>' + rcEsc(r.codeCampaign) + '</b><br><span class="text-gray-500">' + rcEsc(r.campaignName) + '</span>', kelas: 'text-xs' },
                { k: 'jenisCb',      judul: 'Jenis CB',      baku: true,  sel: r => rcEsc(r.jenisCb || '-'), kelas: 'text-center text-xs font-bold' },
                { k: 'cbNet',        judul: 'Cashback',      baku: true,  sel: r => rcMoney(r.cbNet), kelas: 'text-right font-black text-red-600 whitespace-nowrap' }, // "Rp" dan angkanya tidak boleh terpisah baris
                { k: 'kelengkapan',  judul: 'Kelengkapan',   baku: true,  sel: null, kelas: 'text-center' },
                { k: 'createdOn',    judul: 'Created On',    baku: false, sel: r => rcEsc(r.createdOn || '-'), kelas: 'text-center text-xs whitespace-nowrap' },
                { k: 'createdBy',    judul: 'Created By',    baku: false, sel: r => rcEsc(r.createdBy || '-'), kelas: 'text-center text-xs' },
                // Periode dari Campaign Master; billing mengikuti SO bila belum diisi, dan
                // keduanya mengikuti periode campaign bila master belum memuatnya.
                { k: 'soStart',      judul: 'Start SO',      baku: false, sel: r => rcEsc(r.soStart || '-'), kelas: 'text-center text-xs whitespace-nowrap' },
                { k: 'soEnd',        judul: 'End SO',        baku: false, sel: r => rcEsc(r.soEnd || '-'), kelas: 'text-center text-xs whitespace-nowrap' },
                { k: 'billingStart', judul: 'Start Billing', baku: false, sel: r => rcEsc(r.billingStart || '-'), kelas: 'text-center text-xs whitespace-nowrap' },
                { k: 'billingEnd',   judul: 'End Billing',   baku: false, sel: r => rcEsc(r.billingEnd || '-'), kelas: 'text-center text-xs whitespace-nowrap' },
                { k: 'noRek',        judul: 'No Rekening',   baku: false, sel: r => rcEsc(r.noRek || '-'), kelas: 'text-xs font-mono' },
                { k: 'namaRek',      judul: 'Nama Rekening', baku: false, sel: r => rcEsc(r.namaRek || '-'), kelas: 'text-xs' },
                { k: 'bank',         judul: 'Bank',          baku: false, sel: r => rcEsc(r.bank || '-'), kelas: 'text-xs' },
                { k: 'ktp',          judul: 'No KTP',        baku: false, sel: r => rcEsc(r.ktp || '-'), kelas: 'text-xs font-mono' },
                { k: 'npwp',         judul: 'No NPWP',       baku: false, sel: r => rcEsc(r.npwp || '-'), kelas: 'text-xs font-mono' },
                { k: 'contactPerson',judul: 'Contact Person',baku: false, sel: r => rcEsc(r.contactPerson || '-'), kelas: 'text-xs' }
            ];

            // Pilihan kolom disimpan di browser masing-masing. Ini kenyamanan per orang, bukan
            // data bersama, jadi localStorage memang tempatnya - dan seluruh pembacaannya
            // dibungkus try/catch karena penyimpanan itu dapat ditolak di jendela penyamaran.
            let openKolomAktif = null;

            function openKolomMuat() {
                if (openKolomAktif) return openKolomAktif;
                let simpan = null;
                try { simpan = JSON.parse(window.localStorage.getItem('rcOpenKolom') || 'null'); }
                catch (e) { simpan = null; }
                openKolomAktif = {};
                OPEN_KOLOM.forEach(function (c) {
                    openKolomAktif[c.k] = (simpan && typeof simpan[c.k] === 'boolean') ? simpan[c.k] : c.baku;
                });
                return openKolomAktif;
            }

            function openKolomSimpan() {
                try { window.localStorage.setItem('rcOpenKolom', JSON.stringify(openKolomAktif)); }
                catch (e) { /* penyimpanan ditolak; pilihan tetap berlaku untuk sesi ini */ }
            }

            function toggleOpenKolomPanel() {
                const panel = document.getElementById('openKolomPanel');
                const buka = panel.classList.contains('hidden');
                setHiddenSafely('openKolomPanel', !buka);
                if (buka) openKolomRender();
            }

            function openKolomRender() {
                const aktif = openKolomMuat();
                document.getElementById('openKolomDaftar').innerHTML = OPEN_KOLOM.map(function (c) {
                    return '<label class="flex items-center gap-2 text-sm text-gray-700">'
                        + '<input type="checkbox" class="rounded text-blue-600" '
                        + 'onchange="openKolomUbah(\'' + c.k + '\', this.checked)"'
                        + (aktif[c.k] ? ' checked' : '') + '>' + rcEsc(c.judul) + '</label>';
                }).join('');
            }

            function openKolomUbah(kunci, nyala) {
                openKolomMuat()[kunci] = nyala;
                openKolomSimpan();
                renderOpenClaims();
            }

            function openKolomSemua(semua) {
                const aktif = openKolomMuat();
                OPEN_KOLOM.forEach(function (c) { aktif[c.k] = semua ? true : c.baku; });
                openKolomSimpan();
                openKolomRender();
                renderOpenClaims();
            }

            // 20261163060000: filter diterapkan langsung (Campaign dan Jenis CB saat diganti, kotak
            // cari setengah detik setelah berhenti mengetik, Enter seketika); penyaringannya tetap
            // di server. Jawaban yang datang sesudah permintaan yang lebih baru diabaikan.
            let rcOpenMuatKe = 0;
            function openCariOtomatis() { debounceSearch(() => loadOpenClaims(0), 500); }

            async function loadOpenClaims(offset) {
                const ke = ++rcOpenMuatKe;
                setHiddenSafely('openMuat', false);
                try {
                    const res = await fetchApp({ action: 'openClaims',
                        search: document.getElementById('openSearch').value.trim(),
                        campaign: document.getElementById('openCampaign').value, cbType: (document.getElementById('openCbType') || {}).value || '', offset: offset });
                    if (ke !== rcOpenMuatKe) return;
                    if (res.status !== 'success') { showNotification(res.message || "Gagal memuat.", "error"); return; }
                    rcOpenState = { offset: offset, rows: res.rows || [], total: res.total || 0 };
                    opsiOpenFilter(res.opsi);
                    renderOpenClaims();
                    renderOpenPager();
                } catch (e) {
                    if (ke === rcOpenMuatKe) showNotification((e && e.message) ? e.message : "Gagal memuat dokumen.", "error");
                } finally { if (ke === rcOpenMuatKe) setHiddenSafely('openMuat', true); }
            }

            // Halaman tab Open: 200 dokumen per halaman. Wadahnya sudah ada di markup tetapi tidak
            // pernah diisi, sehingga selama ini hanya 200 dokumen pertama yang dapat dilihat.
            const OPEN_PER_HALAMAN = 200;
            function renderOpenPager() {
                const el = document.getElementById('openPager');
                if (!el) return;
                const total = Number(rcOpenState.total) || 0;
                const awal = total === 0 ? 0 : rcOpenState.offset + 1;
                const akhir = Math.min(rcOpenState.offset + (rcOpenState.rows || []).length, total);
                const adaSebelum = rcOpenState.offset > 0;
                const adaSesudah = rcOpenState.offset + OPEN_PER_HALAMAN < total;
                el.innerHTML = '<div class="flex flex-wrap justify-between items-center gap-3 text-xs text-gray-600">'
                    + '<span>Menampilkan <b>' + awal.toLocaleString('id-ID') + ' - ' + akhir.toLocaleString('id-ID')
                    + '</b> dari <b>' + total.toLocaleString('id-ID') + '</b> dokumen Not Yet</span>'
                    + '<span class="flex gap-2">'
                    + '<button type="button" ' + (adaSebelum ? '' : 'disabled ') + 'onclick="loadOpenClaims(' + Math.max(0, rcOpenState.offset - OPEN_PER_HALAMAN) + ')" class="px-3 py-1.5 rounded-lg border border-gray-300 bg-white font-bold disabled:opacity-40"><i class="fas fa-chevron-left"></i></button>'
                    + '<button type="button" ' + (adaSesudah ? '' : 'disabled ') + 'onclick="loadOpenClaims(' + (rcOpenState.offset + OPEN_PER_HALAMAN) + ')" class="px-3 py-1.5 rounded-lg border border-gray-300 bg-white font-bold disabled:opacity-40"><i class="fas fa-chevron-right"></i></button>'
                    + '</span></div>';
            }

            // Isi satu kolom sebagai teks/angka untuk berkas Excel. Kolom yang di layar
            // menggabungkan dua nilai (Toko, Campaign) dipecah menjadi dua kolom.
            // Isinya sama dengan layar: Cashback bulat seperti rcMoney, dan teks (No KTP, NPWP,
            // No Rekening, kode) ditulis sebagai sel teks supaya Excel tidak membuang nol di depan.
            function openKolomUntukUnduh(c) {
                if (c.k === 'toko') return [['Kode Toko', r => rcSelTeks(r.kodeToko)], ['Nama Toko', r => r.namaToko || '']];
                if (c.k === 'campaign') return [['Kode Campaign', r => rcSelTeks(r.codeCampaign)], ['Nama Campaign', r => r.campaignName || '']];
                if (c.k === 'kelengkapan') return [['Kelengkapan', r => (r.ktp || r.npwp) ? 'Lengkap' : 'Perlu Dilengkapi']];
                if (c.k === 'cbNet') return [['Cashback', r => Math.trunc(Number(r.cbNet) || 0)]];
                return [[c.judul, r => rcSelTeks(r[c.k])]];
            }

            // Mengunduh HANYA dokumen yang dicentang, dengan kolom yang dipilih lewat Pilih Kolom
            // (permintaan pemilik 7 Oktober 2026: "untuk download pada tab open cukup yang dipilih
            // aja sesuai field yang ditunjuk juga"). Menggantikan Unduh Semua, yang mengunduh
            // seluruh hasil penyaring.
            function openUnduhDipilih() {
                const dipilih = rcSelectedOpenRows();
                if (dipilih.length === 0) { showNotification('Centang dokumen yang akan diunduh lebih dulu.', 'warning'); return; }
                const aktif = openKolomMuat();
                const kolom = OPEN_KOLOM.filter(c => aktif[c.k]).flatMap(openKolomUntukUnduh);
                if (kolom.length === 0) { showNotification('Pilih minimal satu kolom lewat Pilih Kolom.', 'warning'); return; }
                const aoa = [kolom.map(k => k[0])].concat(dipilih.map(r => kolom.map(k => k[1](r))));
                const wb = XLSX.utils.book_new();
                const ws = XLSX.utils.aoa_to_sheet(aoa);
                ws['!cols'] = kolom.map(k => ({ wch: Math.max(12, Math.min(40, k[0].length + 4)) }));
                XLSX.utils.book_append_sheet(wb, ws, 'Open');
                XLSX.writeFile(wb, 'Open_Not_Yet_' + new Date().toISOString().slice(0, 10) + '.xlsx');
                showNotification(dipilih.length.toLocaleString('id-ID') + ' dokumen diunduh.', 'success');
            }

            function renderOpenClaims() {
                const aktif = openKolomMuat();
                const kolom = OPEN_KOLOM.filter(c => aktif[c.k]);
                const rows = (rcOpenState && rcOpenState.rows) || [];

                document.getElementById('openTableHead').innerHTML =
                    '<th class="p-3 text-center font-bold" data-rc-no-sort="1">'
                    + '<input type="checkbox" id="openSelectAll" onchange="toggleAllOpen()" class="rounded"></th>'
                    + kolom.map(c => '<th class="p-3 text-left font-bold whitespace-nowrap">' + rcEsc(c.judul) + '</th>').join('');

                document.getElementById('openTableBody').innerHTML = rows.map(function (r, i) {
                    const lengkap = !!(r.ktp || r.npwp);
                    const badge = lengkap
                        ? '<span class="px-2 py-0.5 rounded text-[10px] font-black bg-green-100 text-green-700">Lengkap</span>'
                        : '<span class="px-2 py-0.5 rounded text-[10px] font-black bg-orange-100 text-orange-700">Perlu Dilengkapi</span>';
                    return '<tr class="border-b border-gray-100 hover:bg-blue-50">'
                        + '<td class="p-3 text-center"><input type="checkbox" class="cb-open w-4 h-4 rounded" data-idx="'
                        + i + '" value="' + rcEsc(r.noDoc) + '" onchange="updateOpenSelection()"></td>'
                        + kolom.map(function (c) {
                            const isi = c.sel ? c.sel(r) : badge;
                            return '<td class="p-3 ' + (c.kelas || '') + '">' + isi + '</td>';
                        }).join('')
                        + '</tr>';
                }).join('') || '<tr><td colspan="' + (kolom.length + 1)
                        + '" class="p-8 text-center text-gray-500">Tidak ada dokumen berstatus Not Yet.</td></tr>';

                const n = OPEN_KOLOM.length;
                document.getElementById('openKolomRingkas').innerText =
                    kolom.length + ' dari ' + n + ' kolom ditampilkan';
                rcPilihanPulihkan('cb-open', 'openSelectAll');
                updateOpenSelection();
                rcAktifkanUrutSemua('tab_open');
            }

            // Markup tab ini memanggil toggleAllOpen() TANPA argumen, sementara fungsinya dulu
            // menuntut src. Akibatnya src.checked melempar TypeError dan tidak satu pun baris
            // ikut tercentang - centang di header seolah-olah tidak berfungsi. Sekarang kotak
            // headernya dicari sendiri bila tidak dioper, sehingga kedua cara pemanggilan sah.
            function toggleAllOpen(src) {
                const induk = src || document.getElementById('openSelectAll');
                const nyala = induk ? induk.checked : false;
                document.querySelectorAll('.cb-open').forEach(c => c.checked = nyala);
                if (induk && induk !== src) induk.checked = nyala;
                updateOpenSelection();
            }
            // Pilihan bertahan lintas halaman dan filter (28-pilihan-lintas-halaman.js); data
            // barisnya ikut disimpan karena Pindahkan, Template dan Unduh memerlukan isinya.
            function updateOpenSelection() {
                let n = rcPilihanSerap('cb-open', c => rcOpenState.rows[Number(c.dataset.idx)], 'openSelectAll');
                document.getElementById('openSelectedCount').innerText = n;
                setDisabledSafely('btnOpenToMass', n === 0);
                setDisabledSafely('btnOpenToTemplate', n === 0);
                setDisabledSafely('btnOpenUnduh', n === 0);
            }
            function rcSelectedOpenRows() {
                return rcPilihanData('cb-open').filter(Boolean);
            }

            // Memindahkan pilihan ke grid Mass Upload, lengkap dengan nilai yang sudah ada di
            // Customer Master, sehingga pengguna hanya mengisi kolom yang benar-benar kosong.
            // Ditulis berdasarkan ATRIBUT NAME, bukan nomor urut kolom.
            //
            // Versi sebelumnya memakai inputs[0], inputs[2] .. inputs[7]. Itu benar selama grid
            // hanya punya satu susunan kolom. Sejak Posting Exception memakai grid yang sama
            // dengan susunan berbeda - hanya lima kolom - inputs[5] dan seterusnya bernilai
            // undefined, dan baris pertama melempar TypeError sebelum baris kedua sempat diisi.
            // Akibatnya yang masuk hanya satu dokumen, betapapun banyak yang dicentang, tanpa
            // pesan kesalahan apa pun di layar. Inilah sebab "hanya 1 toko yang bisa dimasukkan".
            function openToMassUpload() {
                let picked = rcSelectedOpenRows();
                if (picked.length === 0) return;
                if (picked.length > 500) { showNotification("Maksimal 500 dokumen sekali pindah.", "warning"); return; }
                switchSubTab('upload', 'mass');
                currentInputRows = picked.length;
                initInputGrid();
                let trs = document.getElementById('inputGridBody').querySelectorAll('.row-input');
                picked.forEach((r, i) => {
                    const tr = trs[i]; if (!tr) return;
                    const isi = {
                        noDoc: r.noDoc, ktp: r.ktp, npwp: r.npwp,
                        noRekening: r.noRek, namaRekening: r.namaRek, bank: r.bank, top: r.top
                    };
                    // Kolom yang tidak ada pada susunan yang sedang aktif dilewati begitu saja.
                    Object.keys(isi).forEach(function (nama) {
                        const el = tr.querySelector('[name="' + nama + '"]');
                        if (el) el.value = (isi[nama] === null || isi[nama] === undefined) ? '' : String(isi[nama]);
                    });
                    // Melengkapi sisanya dari database: KTP/NPWP bagi mode Claim, dan keempat
                    // tanggal periode campaign bagi mode Posting Exception.
                    if (typeof autoFillGridRowFromDoc === 'function') autoFillGridRowFromDoc(tr);
                });
                showNotification(picked.length + " dokumen dipindahkan"
                    + (currentPostingMode === 'exception'
                        ? ". SO dan Billing terisi dari periode campaign; perpanjang salah satunya untuk On Hold."
                        : ". Lengkapi Tgl Lunas dan kolom lain yang kosong."), "success");
                // Pilihannya sudah dipakai: dokumennya kini ada di grid Mass Upload.
                rcPilihanKosongkan('cb-open', 'openSelectAll');
                updateOpenSelection();
            }

            // Template mengikuti Template_Upload_Claim.xlsx yang sudah dipakai depot.
            function openToTemplate() {
                let picked = rcSelectedOpenRows();
                if (picked.length === 0) return;
                // Sama dengan Template_Upload_Claim.xlsx (20-template-excel.js): kolom Approval
                // sudah dicabut pemilik - kelayakan TOP ditentukan saat approval, bukan saat unggah.
                let header = ["No Document", "Tgl Lunas", "No Rekening", "Nama Rekening", "Bank", "TOP", "Jenis CB"];
                let aoa = [header];
                picked.forEach(r => aoa.push([rcSelTeks(r.noDoc), '', rcSelTeks(r.noRek), r.namaRek || '', r.bank || '', rcSelTeks(r.top), '']));
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