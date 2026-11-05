            let rcOpenState = { offset: 0, rows: [] };
            let rcCompileRows = null;
            let rcPermissionCatalog = null;

            function openRcOpenTab() {
                if(!rcEnterTab('upload','open'))return;
                currentUploadMode = 'open';
                setHiddenSafely('tab_mass', true); setHiddenSafely('tab_single', true);
                setHiddenSafely('tab_open', false);
                setHiddenSafely('tab_restricted', true); // 20261163170000
                setHiddenSafely('openBarisZdage', !rcZdageAktif()); // 20261163680000
                const sr = document.getElementById('subnav_restricted');
                if (sr) sr.className = 'px-5 py-2 text-sm font-bold rounded-lg text-gray-500 hover:bg-gray-100 transition';
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
                // 20261163170000: batas proses toko lunas dari Upload Debtor (ZDAGE).
                { k: 'deadline',     judul: 'Deadline',      baku: true,  zdage: true,  sel: r => openSelDeadline(r), kelas: 'text-center text-xs whitespace-nowrap' },
                { k: 'toko',         judul: 'Toko',          baku: true,  sel: r => '<b>' + rcEsc(r.namaToko) + '</b>' + openLabelBadDebt(r) + '<br><span class="text-gray-500">' + rcEsc(r.kodeToko) + '</span>', kelas: 'text-xs' },
                { k: 'campaign',     judul: 'Campaign',      baku: true,  sel: r => '<b>' + rcEsc(r.codeCampaign) + '</b><br><span class="text-gray-500">' + rcEsc(r.campaignName) + '</span>', kelas: 'text-xs' },
                { k: 'jenisCb',      judul: 'Jenis CB',      baku: true,  sel: r => rcEsc(r.jenisCb || '-'), kelas: 'text-center text-xs font-bold' },
                { k: 'cbNet',        judul: 'Cashback',      baku: true,  sel: r => rcMoney(r.cbNet), kelas: 'text-right font-black text-red-600 whitespace-nowrap' },
                // Pemilik, 27 Oktober 2026: Net Value dan Volume tampil tanpa harus dipilih lewat Pilih Kolom.
                { k: 'netValue',     judul: 'Net Value',     baku: true,  sel: r => rcMoney(r.netValue), kelas: 'text-right text-xs whitespace-nowrap' },
                { k: 'volume',       judul: 'Volume',        baku: true,  sel: r => rcEsc(Number(r.volume || 0).toLocaleString('id-ID')), kelas: 'text-right text-xs whitespace-nowrap' },
                // 20261163270000: tagihan toko dari Upload Debtor (ZDAGE) yang berlaku untuk depotnya.
                { k: 'tagihan',      judul: 'Tagihan',       baku: true,  zdage: true,  sel: r => rcTagihanSel(r.noDoc), kelas: 'text-right text-xs whitespace-nowrap' },
                { k: 'bulanTagihan', judul: 'Final Billing Month', baku: true, zdage: true, sel: r => rcEsc(rcTagihanBulan(r.noDoc)), kelas: 'text-xs whitespace-nowrap' }, // "Rp" dan angkanya tidak boleh terpisah baris
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

            // Deadline tawaran toko lunas: 7-5 hari hijau, 4-3 kuning, 2-1 oranye, hari ini merah,
            // lewat merah tua dengan label "Lewat X hari" (spesifikasi pemilik, 16 Oktober 2026).
            function openWarnaDeadline(sisa) {
                if (sisa < 0) return 'bg-red-800 text-white';
                if (sisa === 0) return 'bg-red-100 text-red-700';
                if (sisa <= 2) return 'bg-orange-100 text-orange-800';
                if (sisa <= 4) return 'bg-yellow-100 text-yellow-800';
                return 'bg-green-100 text-green-800';
            }
            function openSelDeadline(r) {
                // Dipindah dari tab Restricted oleh Editor: tanpa batas proses, berlabel Restricted.
                if (r.restricted) return '<span class="inline-block px-2 py-1 rounded font-black bg-slate-200 text-slate-800" title="Dipindah dari Restricted; boleh diajukan">Restricted</span>';
                if (!r.deadline) return '<span class="text-gray-400">-</span>';
                const sisa = Number(r.sisaHari);
                const label = sisa < 0 ? 'Lewat ' + Math.abs(sisa) + ' hari' : sisa === 0 ? 'Hari ini' : sisa + ' hari lagi';
                return '<span class="inline-block px-2 py-1 rounded font-bold ' + openWarnaDeadline(sisa) + '" data-sort="' + sisa + '">'
                    + rcEsc(r.deadline) + '<span class="block text-[10px] font-black">' + rcEsc(label) + '</span></span>';
            }
            function openLabelBadDebt(r) {
                return r.badDebt ? ' <span class="px-1.5 py-0.5 rounded text-[10px] font-black bg-red-700 text-white" title="'
                    + rcEsc(r.badDebtAlasan || '') + '">Bad Debt</span>' : '';
            }

            // Pilihan kolom disimpan di browser masing-masing. Ini kenyamanan per orang, bukan
            // data bersama, jadi localStorage memang tempatnya - dan seluruh pembacaannya
            // dibungkus try/catch karena penyimpanan itu dapat ditolak di jendela penyamaran.
            // 20261163680000: kolom ZDAGE (Deadline, Tagihan, Final Billing Month) hanya saat saklar hidup.
            function openKolomDaftar() { return OPEN_KOLOM.filter(c => !c.zdage || rcZdageAktif()); }
            let openKolomAktif = null;

            function openKolomMuat() {
                if (openKolomAktif) return openKolomAktif;
                let simpan = null;
                try { simpan = JSON.parse(window.localStorage.getItem('rcOpenKolom') || 'null'); }
                catch (e) { simpan = null; }
                openKolomAktif = {};
                openKolomDaftar().forEach(function (c) {
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
                document.getElementById('openKolomDaftar').innerHTML = openKolomDaftar().map(function (c) {
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
                openKolomDaftar().forEach(function (c) { aktif[c.k] = semua ? true : c.baku; });
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
                    // 20261163270000: tagihan Upload Debtor untuk baris halaman ini.
                    if (offset === 0) rcTagihanKosongkan();
                    await rcTagihanMuat(rcOpenState.rows.map(r => r.noDoc));
                    if (ke !== rcOpenMuatKe) return;
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
                    + '</b> dari <b>' + total.toLocaleString('id-ID') + '</b> dokumen siap diajukan</span>'
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
                if (c.k === 'toko') return [['Kode Toko', r => rcSelTeks(r.kodeToko)], ['Nama Toko', r => r.namaToko || ''], ['Bad Debt', r => r.badDebt ? 'Bad Debt' : '']];
                if (c.k === 'deadline') return [['Deadline', r => r.deadline || ''], ['Sisa Hari', r => r.deadline ? Number(r.sisaHari) : '']];
                if (c.k === 'campaign') return [['Kode Campaign', r => rcSelTeks(r.codeCampaign)], ['Nama Campaign', r => r.campaignName || '']];
                if (c.k === 'kelengkapan') return [['Kelengkapan', r => (r.ktp || r.npwp) ? 'Lengkap' : 'Perlu Dilengkapi']];
                if (c.k === 'cbNet') return [['Cashback', r => Math.trunc(Number(r.cbNet) || 0)]];
                if (c.k === 'netValue') return [['Net Value', r => Math.trunc(Number(r.netValue) || 0)]];
                if (c.k === 'volume') return [['Volume', r => Number(r.volume) || 0]];
                if (c.k === 'tagihan') return [['Tagihan', r => rcTagihanUnduh(r.noDoc)]];
                if (c.k === 'bulanTagihan') return [['Final Billing Month', r => rcTagihanBulanUnduh(r.noDoc)]];
                return [[c.judul, r => rcSelTeks(r[c.k])]];
            }

            // Mengunduh HANYA dokumen yang dicentang, dengan kolom yang dipilih lewat Pilih Kolom
            // (permintaan pemilik 7 Oktober 2026: "untuk download pada tab open cukup yang dipilih
            // aja sesuai field yang ditunjuk juga"). Menggantikan Unduh Semua, yang mengunduh
            // seluruh hasil penyaring.
            async function openUnduhDipilih() {
                const dipilih = rcSelectedOpenRows();
                if (dipilih.length === 0) { showNotification('Centang dokumen yang akan diunduh lebih dulu.', 'warning'); return; }
                await rcTagihanMuat(dipilih.map(r => r.noDoc)); // 20261163270000: baris dari halaman lain
                const aktif = openKolomMuat();
                const kolom = openKolomDaftar().filter(c => aktif[c.k]).flatMap(openKolomUntukUnduh);
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
                const kolom = openKolomDaftar().filter(c => aktif[c.k]);
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
                        + '" class="p-8 text-center text-gray-500">Tidak ada dokumen yang siap diajukan.' + (rcZdageAktif() ? ' Dokumen Not Yet lain ada di tab Restricted.' : '') + '</td></tr>';

                const n = openKolomDaftar().length;
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
                // 20261163170000: Kembalikan hanya untuk dokumen yang sedang ditawarkan.
                const dipilih = rcSelectedOpenRows();
                setDisabledSafely('btnOpenKembalikan', !dipilih.some(r => r.offerStatus === 'offered' || r.offerStatus === 'overdue'));
                setHiddenSafely('openBarisZdage', !rcZdageAktif()); // 20261163680000: Kembalikan, Bad Debt, keterangan ZDAGE
                setDisabledSafely('btnOpenBadDebt', !dipilih.some(r => !r.badDebt));
                setDisabledSafely('btnOpenCabutBadDebt', !dipilih.some(r => r.badDebt));
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
                        noDoc: r.noDoc, ktp: r.ktp, npwp: r.npwp, tglLunas: r.tglLunasIsi || '', // 20261163170000
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
                picked.forEach(r => aoa.push([rcSelTeks(r.noDoc), r.tglLunasIsi || '', rcSelTeks(r.noRek), r.namaRek || '', r.bank || '', rcSelTeks(r.top), '']));
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

            // ---- 20261163170000: tawaran toko lunas dan Bad Debt ---------------------------------
            // Dialog alasan wajib (minimal 3 karakter). Mengembalikan teks alasan, atau null bila batal.
            function rcMintaAlasan(judul, pesan, tombol) {
                return new Promise(function (selesai) {
                    window.__rcAlasanSelesai = function (ok) {
                        const v = ok ? String((document.getElementById('rcAlasanIsi') || {}).value || '').trim() : null;
                        if (ok && v.length < 3) { showNotification('Alasan wajib diisi (minimal 3 karakter).', 'warning'); return; }
                        window.__rcAlasanSelesai = null; rcTutupDialog(); selesai(v);
                    };
                    rcDialog(judul, '<div class="space-y-3 text-sm"><p>' + rcEsc(pesan) + '</p>'
                        + '<textarea id="rcAlasanIsi" rows="3" maxlength="300" class="w-full px-3 py-2 border border-gray-300 rounded-lg" placeholder="Alasan (wajib)"></textarea>'
                        + '<div class="flex justify-end gap-2"><button type="button" onclick="window.__rcAlasanSelesai && window.__rcAlasanSelesai(false)" class="px-4 py-2 border border-gray-300 rounded-lg font-bold">Batal</button>'
                        + '<button type="button" id="rcAlasanOk" onclick="window.__rcAlasanSelesai && window.__rcAlasanSelesai(true)" class="px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white rounded-lg font-bold">' + rcEsc(tombol) + '</button></div></div>');
                    setTimeout(function () { const el = document.getElementById('rcAlasanIsi'); if (el) el.focus(); }, 50);
                });
            }

            async function openKembalikanNotYet() {
                const docs = rcSelectedOpenRows().filter(r => r.offerStatus === 'offered' || r.offerStatus === 'overdue').map(r => r.noDoc);
                if (!docs.length) return;
                const alasan = await rcMintaAlasan('Kembalikan ke Not Yet', docs.length + ' dokumen toko lunas tidak diproses sekarang. '
                    + 'Dokumen tetap Not Yet tetapi tidak akan ditawarkan otomatis lagi; OSC dapat menawarkannya ulang.', 'Kembalikan');
                if (alasan === null) return;
                try {
                    const res = await fetchApp({ action: 'clearingReturn', docs: docs, alasan: alasan });
                    if (res.status !== 'success') throw new Error(res.message || 'Gagal mengembalikan.');
                    showNotification(res.message, 'success');
                    rcPilihanKosongkan('cb-open', 'openSelectAll');
                    loadOpenClaims(rcOpenState.offset || 0);
                } catch (e) { showNotification((e && e.message) ? e.message : 'Gagal mengembalikan.', 'error'); }
            }

            async function openTandaiBadDebt(tandai) {
                const rows = rcSelectedOpenRows().filter(r => tandai ? !r.badDebt : r.badDebt);
                if (!rows.length) return;
                const toko = Array.from(new Set(rows.map(r => r.kodeToko)));
                const alasan = await rcMintaAlasan(tandai ? 'Tandai Bad Debt' : 'Cabut Bad Debt',
                    tandai ? toko.length + ' toko ditandai Bad Debt. Klaimnya tetap di Open (paling bawah) dan tidak ditawarkan sebagai toko lunas; tawaran yang sedang berjalan dibatalkan.'
                           : toko.length + ' toko dicabut dari Bad Debt.', tandai ? 'Tandai Bad Debt' : 'Cabut Bad Debt');
                if (alasan === null) return;
                try {
                    const res = await fetchApp({ action: tandai ? 'badDebtSet' : 'badDebtRevoke', docs: rows.map(r => r.noDoc), alasan: alasan });
                    if (res.status !== 'success') throw new Error(res.message || 'Gagal.');
                    showNotification(res.message, 'success');
                    rcPilihanKosongkan('cb-open', 'openSelectAll');
                    loadOpenClaims(rcOpenState.offset || 0);
                } catch (e) { showNotification((e && e.message) ? e.message : 'Gagal menyimpan Bad Debt.', 'error'); }
            }
