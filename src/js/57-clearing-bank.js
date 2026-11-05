            // =====================================================================================
            // Claim Process > Clearing: Upload File Bank KlikBCA Bisnis - 20261163710000
            // =====================================================================================
            // File "MultiTransactionAutoTransferDownload_DDMMYYYYHHMMSS.txt": teks fixed-width, baris 1 =
            // header. Kolom TIDAK dipecah per spasi - setiap kolom dipotong dari posisi awal judulnya di
            // header sampai awal judul kolom berikutnya. Yang dipakai: Eff Date, Trans ID, Equivalent
            // Amount, Remark 1 (No Doc), Remark 2 (bank), Status, Reason, To Acc.
            //
            // Eff Date tertulis terpotong ("26 Oct 202"): tahunnya diambil dari nama file
            // (_DDMMYYYYHHMMSS); tanpa pola itu pengguna mengisi Tahun di form. Bulan Inggris (Oct) dan
            // Indonesia (Okt) sama-sama dibaca. Transfer tidak mungkin sesudah file diunduh, jadi Eff
            // Date yang jatuh sesudah tanggal file dianggap tahun sebelumnya (file Januari, transfer
            // Desember).
            //
            // Penilaian per baris dan proses Clearing ada di server (rc_clearing_bank_preview /
            // rc_clearing_bank_proses), memakai alur Clearing lama apa adanya. Fungsi parser di bawah
            // tidak menyentuh layar, supaya dapat diuji di Node (scripts/test_clearing_bank_parser.mjs).

            const CLR_BANK_KOLOM = ['Eff Date', 'Trans ID', 'Equivalent Amount', 'Remark 1', 'Remark 2', 'Status', 'Reason', 'To Acc'];
            // 20261163730000: kolom untuk Bukti Transfer - tidak wajib (kosong bila tidak ada di file).
            // "Bank Name" dan "SWIFT Code" di header hanya dipisah satu spasi, jadi posisinya dicatat
            // sebagai batas kolom juga.
            const CLR_BANK_KOLOM_OPSI = ['Channel', 'Trsfr Service', 'From Acc', 'Acc Name', 'SWIFT Code', 'Bank Name', 'Total Charges', 'Charges To'];

            // {tahun, bulan, hari} dari pola _DDMMYYYYHHMMSS pada nama file, atau null.
            function rcBankInfoNamaFile(nama) {
                const m = String(nama || '').match(/_(\d{2})(\d{2})(\d{4})(\d{6})(?!\d)/);
                if (!m) return null;
                const hari = Number(m[1]), bulan = Number(m[2]), tahun = Number(m[3]);
                if (bulan < 1 || bulan > 12 || hari < 1 || hari > 31 || tahun < 2000) return null;
                return { tahun: tahun, bulan: bulan, hari: hari };
            }

            function rcBankBulan(teks) {
                const t = String(teks || '').toLowerCase().replace(/[^a-z]/g, '');
                const peta = { jan: 1, feb: 2, peb: 2, mar: 3, apr: 4, may: 5, mei: 5, jun: 6, jul: 7, aug: 8, agu: 8, ags: 8, agt: 8,
                               sep: 9, okt: 10, oct: 10, nov: 11, nop: 11, dec: 12, des: 12 };
                return peta[t.slice(0, 3)] || null;
            }

            function rcBankIso(y, m, d) {
                const dt = new Date(Date.UTC(y, m - 1, d));
                if (dt.getUTCFullYear() !== y || dt.getUTCMonth() !== m - 1 || dt.getUTCDate() !== d) return null;
                return y + '-' + String(m).padStart(2, '0') + '-' + String(d).padStart(2, '0');
            }

            // "26 Oct 202" -> 'YYYY-MM-DD' memakai tahun file/form; tahun 4 digit di teks didahulukan.
            function rcBankTanggal(teks, tahun, infoFile) {
                const m = String(teks || '').trim().match(/^(\d{1,2})[\s\-\/.]+([A-Za-z]{3,9})\.?(?:[\s\-\/.]+(\d{1,4}))?/);
                if (!m) return null;
                const hari = Number(m[1]), bulan = rcBankBulan(m[2]);
                if (!bulan) return null;
                if (m[3] && m[3].length === 4) return rcBankIso(Number(m[3]), bulan, hari);
                if (!tahun) return null;
                let y = Number(tahun);
                // Eff Date sesudah tanggal file = tahun sebelumnya (transfer tidak terjadi sesudah file diunduh).
                if (infoFile && infoFile.tahun === y && (bulan > infoFile.bulan || (bulan === infoFile.bulan && hari > infoFile.hari))) y -= 1;
                return rcBankIso(y, bulan, hari);
            }

            // "Rp. 1250000" / "Rp. 1.250.000,00" -> 1250000 (dipotong, tanpa desimal); null bila tidak terbaca.
            function rcBankNominal(teks) {
                let t = String(teks || '').trim().replace(/^Rp\.?\s*/i, '').replace(/\s+/g, '');
                if (t === '') return null;
                if (/^\d+$/.test(t)) return Number(t);
                if (/^[\d.,]+$/.test(t)) {
                    if (/[.,]\d{1,2}$/.test(t) && !/^\d{1,3}([.,]\d{3})+$/.test(t)) t = t.replace(/[.,]\d{1,2}$/, '');
                    t = t.replace(/[.,]/g, '');
                    return /^\d+$/.test(t) ? Number(t) : null;
                }
                return null;
            }

            // Posisi awal setiap judul kolom di header: huruf pertama sesudah >= 2 spasi (atau awal baris),
            // ditambah posisi judul kolom wajib. Batas akhir satu kolom = awal judul berikutnya.
            function rcBankPosisiKolom(header) {
                const posisi = {}, awal = new Set();
                for (let i = 0; i < header.length; i++) {
                    if (header[i] !== ' ' && (i === 0 || (header[i - 1] === ' ' && (i < 2 || header[i - 2] === ' ')))) awal.add(i);
                }
                const hilang = [];
                CLR_BANK_KOLOM.forEach(k => {
                    const p = header.indexOf(k);
                    if (p < 0) hilang.push(k); else { posisi[k] = p; awal.add(p); }
                });
                CLR_BANK_KOLOM_OPSI.forEach(k => { const p = header.indexOf(k); if (p >= 0) { posisi[k] = p; awal.add(p); } });
                const urut = [...awal].sort((a, b) => a - b);
                const batas = {};
                Object.keys(posisi).forEach(k => {
                    const a = posisi[k], b = urut.find(x => x > a);
                    batas[k] = [a, b === undefined ? Infinity : b];
                });
                return { batas: batas, hilang: hilang };
            }

            // teks = isi file utuh; opsi = { namaFile, tahun (isian form, dipakai bila nama file tanpa pola) }.
            function rcBankParse(teks, opsi) {
                opsi = opsi || {};
                const info = rcBankInfoNamaFile(opsi.namaFile);
                const tahun = info ? info.tahun : (Number(opsi.tahun) || null);
                const hasil = { ok: false, galat: '', perluTahun: false, tahun: tahun, tahunSumber: info ? 'nama_file' : 'form',
                                baris: [], ringkas: { jumlah: 0, berhasil: 0, total: 0 }, peringatan: [] };
                const baris = String(teks || '').replace(/^﻿/, '').split(/\r\n|\n|\r/);
                const iHeader = baris.findIndex(b => b.trim() !== '');
                if (iHeader < 0) { hasil.galat = 'File kosong.'; return hasil; }
                const { batas, hilang } = rcBankPosisiKolom(baris[iHeader]);
                if (hilang.length) {
                    hasil.galat = 'Header file bukan format KlikBCA MultiTransactionAutoTransfer: kolom ' + hilang.join(', ') + ' tidak ditemukan.';
                    return hasil;
                }
                if (!tahun) {
                    hasil.perluTahun = true;
                    hasil.galat = 'Nama file tidak memuat tanggal (_DDMMYYYYHHMMSS). Isi Tahun transfer lebih dulu.';
                    return hasil;
                }
                const ambil = (b, k) => batas[k] ? b.slice(batas[k][0], batas[k][1] === Infinity ? undefined : batas[k][1]).trim() : '';
                let no = 0;
                for (let i = iHeader + 1; i < baris.length; i++) {
                    const b = baris[i];
                    if (b.trim() === '') continue;
                    no++;
                    const status = ambil(b, 'Status'), eff = ambil(b, 'Eff Date'), nomTeks = ambil(b, 'Equivalent Amount');
                    const nominal = rcBankNominal(nomTeks), tgl = rcBankTanggal(eff, tahun, info);
                    const r = { baris: no, transId: ambil(b, 'Trans ID'), effDate: eff, tglTransfer: tgl, nominal: nominal,
                                remark1: ambil(b, 'Remark 1'), bank: ambil(b, 'Remark 2'), toAcc: ambil(b, 'To Acc'),
                                status: status, reason: ambil(b, 'Reason'), berhasil: status.toLowerCase() === 'berhasil',
                                // 20261163730000: data Bukti Transfer.
                                channel: ambil(b, 'Channel'), layanan: ambil(b, 'Trsfr Service'), dariRek: ambil(b, 'From Acc'), dariNama: ambil(b, 'Acc Name'),
                                swift: ambil(b, 'SWIFT Code'), namaBank: ambil(b, 'Bank Name'), biaya: rcBankNominal(ambil(b, 'Total Charges')), biayaOleh: ambil(b, 'Charges To') };
                    if (nominal === null) hasil.peringatan.push('Baris ' + no + ': nominal "' + nomTeks + '" tidak terbaca');
                    if (!tgl) hasil.peringatan.push('Baris ' + no + ': Eff Date "' + eff + '" tidak terbaca');
                    hasil.baris.push(r);
                    hasil.ringkas.jumlah++;
                    if (r.berhasil) hasil.ringkas.berhasil++;
                    hasil.ringkas.total += nominal || 0;
                }
                if (!hasil.baris.length) { hasil.galat = 'File tidak berisi baris transaksi.'; return hasil; }
                hasil.ok = true;
                return hasil;
            }

            // ---------- Layar ----------
            const CLR_BANK_LABEL = {
                ok: ['Siap Clearing', 'bg-emerald-100 text-emerald-800'], ok_bukti: ['Sudah Done - simpan Bukti TF', 'bg-sky-100 text-sky-800'], // ok_bukti: 20261163750000
                nominal_beda: ['Nominal beda', 'bg-amber-100 text-amber-800'],
                tidak_ditemukan: ['Tidak ditemukan', 'bg-gray-200 text-gray-700'], terpotong: ['No Doc terpotong', 'bg-orange-100 text-orange-800'],
                sudah_clearing: ['Sudah clearing', 'bg-blue-100 text-blue-800'], belum_siap: ['Belum siap Clearing', 'bg-purple-100 text-purple-800'],
                sudah_diproses: ['Sudah diproses (file lain)', 'bg-blue-100 text-blue-800'], gagal_transfer: ['Gagal transfer', 'bg-red-100 text-red-700'],
                duplikat: ['Duplikat dalam file', 'bg-red-100 text-red-700'], tanggal_salah: ['Tanggal salah', 'bg-red-100 text-red-700']
            };
            let rcClrBank = { file: null, teks: '', sidik: '', baca: null, hasil: null, saring: '' };

            async function rcBankSidik(buf) {
                const h = await crypto.subtle.digest('SHA-256', buf);
                return [...new Uint8Array(h)].map(x => x.toString(16).padStart(2, '0')).join('');
            }

            async function clrBankPilih(input) {
                const f = input.files && input.files[0];
                rcClrBank = { file: null, teks: '', sidik: '', baca: null, hasil: null, saring: '' };
                setHiddenSafely('clrBankHasil', true);
                setDisabledSafely('btnClrBankPratinjau', true);
                if (!f) return;
                if (f.size > 5 * 1024 * 1024) { showNotification('File maksimal 5 MB.', 'error'); input.value = ''; return; }
                const buf = await f.arrayBuffer();
                rcClrBank.file = f;
                rcClrBank.teks = new TextDecoder('windows-1252').decode(buf);
                rcClrBank.sidik = await rcBankSidik(buf);
                setHiddenSafely('clrBankTahunWrap', !!rcBankInfoNamaFile(f.name));
                setDisabledSafely('btnClrBankPratinjau', false);
                // 20261163740000: pratinjau langsung jalan bila tahun terbaca dari nama file.
                if (rcBankInfoNamaFile(f.name)) clrBankPratinjau();
                else showNotification('Nama file tanpa tanggal: isi Tahun transfer, lalu klik Pratinjau.', 'warning');
            }

            // 20261163750000: tanpa pilihan Mode (Mode tertinggal di Arsip membuat file Clearing tidak
            // ter-Clearing). Server menilai tiap baris: Pending Finance = Clearing, sudah Done = Bukti TF saja.
            function clrBankMode() { return 'otomatis'; }

            function clrBankBatal() {
                const el = document.getElementById('clrBankFile'); if (el) el.value = '';
                rcClrBank = { file: null, teks: '', sidik: '', baca: null, hasil: null, saring: '' };
                setHiddenSafely('clrBankHasil', true); setHiddenSafely('clrBankTahunWrap', true);
                setDisabledSafely('btnClrBankPratinjau', true);
            }

            async function clrBankPratinjau() {
                if (!rcClrBank.file) return;
                const baca = rcBankParse(rcClrBank.teks, { namaFile: rcClrBank.file.name, tahun: (document.getElementById('clrBankTahun') || {}).value });
                if (!baca.ok) {
                    if (baca.perluTahun) setHiddenSafely('clrBankTahunWrap', false);
                    showNotification(baca.galat, 'warning'); return;
                }
                // 20261163760000: server menerima maksimal 1.000 baris per file.
                if (baca.baris.length > 1000) { showNotification('File berisi ' + baca.baris.length.toLocaleString('id-ID') + ' baris; maksimal 1.000 baris per file. Pecah file lebih dulu.', 'warning'); return; }
                rcClrBank.baca = baca;
                showLoadingOverlay('Mencocokkan ' + baca.ringkas.jumlah + ' baris dengan klaim RC...');
                try {
                    const res = await fetchApp({ action: 'clearingBankPreview', namaFile: rcClrBank.file.name, sidik: rcClrBank.sidik,
                        tahun: baca.tahun, tahunSumber: baca.tahunSumber, mode: clrBankMode(),
                        baris: baca.baris.map(r => ({ baris: r.baris, transId: r.transId, effDate: r.effDate, tglTransfer: r.tglTransfer,
                            nominal: r.nominal === null ? '' : String(r.nominal), remark1: r.remark1, bank: r.bank, toAcc: r.toAcc, status: r.status, reason: r.reason,
                            channel: r.channel, layanan: r.layanan, dariRek: r.dariRek, dariNama: r.dariNama, swift: r.swift, namaBank: r.namaBank,
                            biaya: r.biaya === null || r.biaya === undefined ? '' : String(r.biaya), biayaOleh: r.biayaOleh })) });
                    if (res.status !== 'success') throw new Error(res.message || 'Pratinjau gagal.');
                    rcClrBank.hasil = res; rcClrBank.saring = '';
                    clrBankGambar();
                    showNotification(res.message, 'success');
                } catch (e) { showNotification((e && e.message) || 'Pratinjau gagal.', 'error'); }
                finally { hideLoadingOverlay(); }
            }

            function clrBankSaring(h) { rcClrBank.saring = rcClrBank.saring === h ? '' : h; clrBankGambar(); }

            function clrBankGambar() {
                const res = rcClrBank.hasil, box = document.getElementById('clrBankHasil');
                if (!res || !box) return;
                const rk = res.ringkasan || {}, per = rk.perHasil || {}, up = res.upload || {}, sudah = up.status === 'diproses', arsip = up.mode === 'arsip';
                const nClr = arsip ? 0 : Number(per.ok || 0), nBtf = arsip ? Number(per.ok || 0) : Number(per.ok_bukti || 0);
                const nOk = sudah ? 0 : nClr + nBtf;
                const chip = Object.keys(CLR_BANK_LABEL).filter(k => per[k]).map(k => '<button type="button" onclick="clrBankSaring(\'' + k + '\')" class="px-2.5 py-1 rounded-lg text-xs font-bold '
                    + CLR_BANK_LABEL[k][1] + (rcClrBank.saring === k ? ' ring-2 ring-offset-1 ring-sky-500' : '') + '">' + CLR_BANK_LABEL[k][0] + ' <b>' + per[k] + '</b></button>').join('');
                const rows = (res.rows || []).filter(r => !rcClrBank.saring || r.hasil === rcClrBank.saring);
                const peringatan = (rcClrBank.baca && rcClrBank.baca.peringatan || []);
                box.innerHTML =
                    '<div class="grid grid-cols-2 md:grid-cols-4 gap-3 mb-3">'
                    + '<div class="bg-white border border-sky-100 rounded-xl p-3"><p class="text-[10px] font-black uppercase text-gray-500">Jumlah baris</p><p class="text-lg font-black">' + Number(rk.baris || 0).toLocaleString('id-ID') + '</p></div>'
                    + '<div class="bg-white border border-sky-100 rounded-xl p-3"><p class="text-[10px] font-black uppercase text-gray-500">Total nominal</p><p class="text-lg font-black">' + rcEsc(rcNominalPenuh(rk.totalNominal)) + '</p></div>'
                    + '<div class="bg-white border border-emerald-100 rounded-xl p-3"><p class="text-[10px] font-black uppercase text-gray-500">' + (sudah ? 'Sudah diproses' : 'Siap diproses') + '</p><p class="text-lg font-black text-emerald-700">'
                        + (sudah ? Number(up.jumlahDiproses || 0) : nOk).toLocaleString('id-ID') + '</p>'
                        + '<p class="text-[10px] text-gray-500">Clearing ' + nClr.toLocaleString('id-ID') + ' &middot; Bukti TF saja ' + nBtf.toLocaleString('id-ID') + '</p></div>'
                    + '<div class="bg-white border border-emerald-100 rounded-xl p-3"><p class="text-[10px] font-black uppercase text-gray-500">Nominal OK</p><p class="text-lg font-black text-emerald-700">' + rcEsc(rcNominalPenuh(rk.totalOk)) + '</p></div>'
                    + '</div>'
                    + '<p class="text-xs text-gray-600 mb-2">' + (up.mode === 'otomatis' ? '' : '<b>' + (arsip ? 'Mode Arsip Bukti TF' : 'Mode Clearing') + '</b> &middot; ') + rcEsc(up.namaFile || '') + ' &middot; tahun ' + rcEsc(String(up.tahun || '')) + ' (' + (up.tahunSumber === 'form' ? 'isian form' : 'dari nama file') + ')'
                        + (sudah ? ' &middot; <b class="text-emerald-700">Sudah diproses ' + rcEsc(up.diproses || '') + (arsip ? '' : ', batch ' + rcEsc(up.batch || '-')) + '</b>' : '') + '</p>'
                    + (peringatan.length ? '<p class="text-xs text-amber-700 mb-2">' + peringatan.slice(0, 5).map(rcEsc).join('; ') + (peringatan.length > 5 ? ' ...' : '') + '</p>' : '')
                    + '<div class="flex flex-wrap gap-2 mb-3">' + chip + (rcClrBank.saring ? '<button type="button" onclick="clrBankSaring(\'\')" class="px-2.5 py-1 rounded-lg text-xs font-bold bg-white border">Semua</button>' : '') + '</div>'
                    + '<div class="overflow-auto max-h-[480px] border border-gray-200 rounded-xl bg-white"><table class="w-full text-xs"><thead class="bg-gray-50 text-gray-600 sticky top-0"><tr>'
                    + ['No', 'Trans ID', 'Tgl Transfer', 'No Doc (file)', 'No Doc RC', 'Toko', 'Bank', 'Nominal Transfer', 'Nominal Klaim', 'Hasil', 'Keterangan']
                        .map((h, i) => '<th class="p-2 ' + (i === 7 || i === 8 ? 'text-right' : 'text-left') + ' whitespace-nowrap">' + h + '</th>').join('')
                    + '</tr></thead><tbody>'
                    + (rows.map(r => {
                        const lb = CLR_BANK_LABEL[r.hasil] || [r.hasil, 'bg-gray-100'];
                        return '<tr class="border-t border-gray-100">'
                            + '<td class="p-2">' + r.baris + '</td><td class="p-2 font-mono whitespace-nowrap">' + rcEsc(r.transId) + '</td>'
                            + '<td class="p-2 whitespace-nowrap">' + rcEsc(r.tglTransfer || r.effDate) + '</td>'
                            + '<td class="p-2 font-mono whitespace-nowrap">' + rcEsc(r.remark1) + '</td><td class="p-2 font-mono whitespace-nowrap">' + rcEsc(r.noDocRc || '-') + '</td>'
                            + '<td class="p-2">' + (r.kodeToko ? '<b>' + rcEsc(r.kodeToko) + '</b> ' + rcEsc(r.namaToko) : '-') + '</td>'
                            + '<td class="p-2 whitespace-nowrap">' + rcEsc(r.bank) + '</td>'
                            + '<td class="p-2 text-right whitespace-nowrap font-bold">' + rcEsc(rcNominalPenuh(r.nominal)) + '</td>'
                            + '<td class="p-2 text-right whitespace-nowrap">' + (r.nominalKlaim === null || r.nominalKlaim === undefined ? '-' : rcEsc(rcNominalPenuh(r.nominalKlaim))) + '</td>'
                            + '<td class="p-2 whitespace-nowrap"><span class="px-2 py-0.5 rounded font-bold ' + lb[1] + '">' + lb[0] + '</span>' + (r.diproses ? ' <i class="fas fa-check text-emerald-600" title="Sudah diproses"></i>' : '') + '</td>'
                            + '<td class="p-2">' + rcEsc(r.keterangan) + '</td></tr>';
                    }).join('') || '<tr><td colspan="11" class="p-6 text-center text-gray-400">Tidak ada baris.</td></tr>')
                    + '</tbody></table></div>'
                    + '<div class="mt-3 flex flex-wrap justify-end gap-2">'
                    + '<button type="button" onclick="clrBankExcel()" class="px-4 py-2 bg-white border border-gray-300 hover:bg-gray-50 font-bold rounded-lg text-sm"><i class="fas fa-file-excel mr-1.5 text-green-600"></i>Export Excel</button>'
                    + '<button type="button" onclick="clrBankProses()" ' + (nOk ? '' : 'disabled ') + 'class="px-5 py-2 bg-emerald-600 hover:bg-emerald-700 text-white font-bold rounded-lg text-sm shadow disabled:opacity-40">'
                        + '<i class="fas fa-check-double mr-1.5"></i>' + (arsip ? 'Simpan Bukti TF (' + nOk + ' baris OK)'
                            : 'Proses (' + nClr + ' Clearing' + (nBtf ? ' + ' + nBtf + ' Bukti TF' : '') + ')') + '</button>'
                    + '</div>';
                setHiddenSafely('clrBankHasil', false);
            }

            async function clrBankProses() {
                const res = rcClrBank.hasil; if (!res || !res.upload) return;
                const per = (res.ringkasan && res.ringkasan.perHasil) || {}, arsip = res.upload.mode === 'arsip';
                const nClr = arsip ? 0 : Number(per.ok || 0), nBtf = arsip ? Number(per.ok || 0) : Number(per.ok_bukti || 0), n = nClr + nBtf;
                if (!n) return;
                const setuju = await showConfirmModal({ title: arsip ? 'Simpan Bukti TF dari File Bank' : 'Proses File Bank',
                    message: arsip
                        ? n + ' dokumen yang sudah Done akan disimpan data transfernya sebagai Bukti TF (ikut di Tanda Terima PDA). Status dan batch klaim tidak diubah.'
                        : (nClr ? nClr + ' dokumen Pending Finance akan di-Clearing (Done) dengan Tgl Transfer = Eff Date masing-masing' : 'Tidak ada dokumen Pending Finance untuk di-Clearing')
                          + (nBtf ? '; ' + nBtf + ' dokumen yang sudah Done hanya disimpan Bukti TF-nya (status tidak berubah)' : '')
                          + '. Baris lain tidak disentuh. File yang sama tidak bisa diproses lagi.',
                    confirmText: 'Ya, Proses', danger: false });
                if (!setuju) return;
                showLoadingOverlay((arsip || !nClr ? 'Menyimpan Bukti TF ' : 'Memproses Clearing ') + n + ' dokumen...');
                try {
                    const hasil = await fetchApp({ action: 'clearingBankProses', uploadId: res.upload.id });
                    if (hasil.status !== 'success') throw new Error(hasil.message || 'Proses Clearing gagal.');
                    rcClrBank.hasil = hasil; rcClrBank.saring = '';
                    clrBankGambar();
                    clrBankLaporan(hasil);
                    if (typeof fetchWorkflowData === 'function') fetchWorkflowData();
                } catch (e) { showNotification((e && e.message) || 'Proses Clearing gagal.', 'error'); }
                finally { hideLoadingOverlay(); }
            }

            // 20261163740000: sesudah proses tampil Laporan Workflow yang sama dengan Posting Done - dokumen
            // yang di-Clearing, total, dan No Batch; baris lain tercantum sebagai gagal beserta alasannya.
            // 20261163750000: dokumen yang sudah Done (Bukti TF saja) tidak dihitung Berhasil / Total Cashback,
            // melainkan didaftar terpisah dengan penanda "Bukti TF disimpan".
            function clrBankLaporan(hasil) {
                const arsip = (hasil.upload || {}).mode === 'arsip', rows = hasil.rows || [];
                const butir = r => ({ noDoc: rcEsc(r.noDocRc), kodeCamp: rcEsc(r.campaign), namaCamp: rcEsc(r.namaCampaign),
                    kodeToko: rcEsc(r.kodeToko), namaToko: rcEsc(r.namaToko), reward: Math.trunc(Number(r.nominalKlaim) || 0), grossUp: Math.trunc(Number(r.grossUp) || 0) });
                const sukses = rows.filter(r => r.diproses && r.hasil === 'ok' && !arsip).map(butir);
                const bukti = rows.filter(r => r.diproses && (r.hasil === 'ok_bukti' || arsip)).map(butir);
                const gagal = rows.filter(r => !r.diproses).map(r => ({ noDoc: rcEsc(r.noDocRc || r.remark1 || '-'),
                    toko: r.kodeToko ? rcEsc(r.kodeToko + ' - ' + r.namaToko) : '-', reason: rcEsc((CLR_BANK_LABEL[r.hasil] || [r.hasil])[0]) }));
                showActionResult(sukses.length ? 'Laporan Workflow CLEARING (File Bank)' : 'Laporan Bukti TF (File Bank)', sukses, gagal, 'approve', sukses.length ? hasil.batch : null);
                if (!bukti.length) return;
                const stat = document.getElementById('actionResultStats'), body = document.getElementById('actionResultBody');
                if (stat) stat.insertAdjacentHTML('beforeend', '<div class="flex-1 bg-sky-50 border border-sky-200 p-3 rounded-xl"><span class="block text-[10px] uppercase font-bold text-sky-700 mb-1">Bukti TF saja (sudah Done)</span><span class="text-2xl font-black text-sky-800">' + bukti.length + '</span></div>');
                if (body) body.insertAdjacentHTML('beforeend', bukti.map(s => '<tr class="hover:bg-gray-50 transition-colors border-b border-gray-100"><td class="p-3 font-bold text-sky-700">' + s.noDoc + '</td>'
                    + '<td class="p-3 text-xs"><span class="font-bold text-gray-800">' + (s.kodeCamp || '-') + '</span><br><span class="text-gray-500">' + (s.namaCamp || '-') + '</span></td>'
                    + '<td class="p-3 text-xs"><span class="font-bold text-gray-800">' + (s.kodeToko || '-') + '</span><br><span class="text-gray-500">' + (s.namaToko || '-') + '</span></td>'
                    + '<td class="p-3 text-right border-l border-gray-100"><span class="text-gray-500 font-bold">Rp ' + s.reward.toLocaleString('id-ID') + '</span></td>'
                    + '<td class="p-3 text-center"><span class="bg-sky-100 text-sky-800 px-2 py-1 rounded text-[10px] font-bold" title="Dokumen sudah Done sebelumnya; status dan batch tidak berubah">Bukti TF disimpan</span></td></tr>').join(''));
            }

            // Excel sama dengan layar: seluruh baris (bukan hanya saringan), ID sebagai teks, nominal tanpa desimal.
            function clrBankExcel() {
                const res = rcClrBank.hasil; if (!res) return;
                const aoa = [['No', 'Trans ID', 'Eff Date', 'Tgl Transfer', 'No Doc (file)', 'No Doc RC', 'Depot', 'Kode Toko', 'Nama Toko', 'Campaign',
                              'Bank', 'To Acc', 'Nominal Transfer', 'Nominal Klaim', 'Selisih', 'Status Bank', 'Hasil', 'Keterangan', 'Sudah diproses']];
                (res.rows || []).forEach(r => {
                    const nt = Math.trunc(Number(r.nominal) || 0), nk = r.nominalKlaim === null || r.nominalKlaim === undefined ? '' : Math.trunc(Number(r.nominalKlaim));
                    aoa.push([r.baris, String(r.transId || ''), String(r.effDate || ''), String(r.tglTransfer || ''), String(r.remark1 || ''), String(r.noDocRc || ''),
                              String(r.depot || ''), String(r.kodeToko || ''), String(r.namaToko || ''), String(r.campaign || ''), String(r.bank || ''), String(r.toAcc || ''),
                              nt, nk, nk === '' ? '' : nt - nk, String(r.statusBank || ''), (CLR_BANK_LABEL[r.hasil] || [r.hasil])[0], String(r.keterangan || ''), r.diproses ? 'Ya' : '']);
                });
                const ws = XLSX.utils.aoa_to_sheet(aoa);
                ws['!cols'] = aoa[0].map((h, i) => ({ wch: [5, 22, 12, 13, 22, 26, 7, 10, 28, 16, 10, 14, 15, 15, 12, 11, 22, 60, 9][i] || 14 }));
                const wb = XLSX.utils.book_new(); XLSX.utils.book_append_sheet(wb, ws, 'Pratinjau Clearing');
                const nama = String((res.upload && res.upload.namaFile) || 'file-bank').replace(/\.txt$/i, '');
                XLSX.writeFile(wb, 'Clearing_' + nama + '.xlsx');
            }
