            // ============================================================================
            // DOCUMENT CENTER - TAB UPLOAD DEBTOR (ZDAGE), 20261163170000
            // ============================================================================
            // OSC mengunggah ekspor debtor SAP ZDAGE apa adanya. Berkas dibaca di browser
            // (SheetJS), diperiksa, lalu dikirim per 500 baris; penilaian lunas sepenuhnya di
            // server, bertahap per depot (20261163860000), supaya pratinjau dan penerapan memakai
            // satu rumus yang sama. Kolom A berisi kode depot: depot yang tidak ada di file
            // memakai data lama, kecuali dicentang "Tidak ada tagihan" (keputusan pemilik).
            // 20261163780000: tanpa penjagaan yurisdiksi; siapa pun yang punya tab ini boleh mengunggah depot apa pun.

            const ZD_BULAN = { jan: 1, feb: 2, mar: 3, apr: 4, may: 5, jun: 6, jul: 7, aug: 8, sep: 9, oct: 10, nov: 11, dec: 12 };
            const ZD_NAMA_BULAN = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
            // Header A-F dicocokkan setelah trim, huruf kecil, dan spasi ganda dirapatkan.
            const ZD_KEPALA = ['distribution channel', 'customer', 'customer name', 'term-fi', 'over due amt', 'total'];
            const ZD_BAGIAN = 500;

            function zdRapat(v) { return String(v == null ? '' : v).replace(/\s+/g, ' ').trim().toLowerCase(); }

            // "Oct-2026", "Feb2026" (tanpa tanda hubung) -> { y, m }. Bukan bulan -> null.
            function zdBacaBulan(v) {
                const m = String(v == null ? '' : v).trim().match(/^(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)-?(\d{4})$/i);
                return m ? { y: Number(m[2]), m: ZD_BULAN[m[1].toLowerCase()] } : null;
            }
            function zdKunci(b) { return b.y + '-' + String(b.m).padStart(2, '0'); }
            function zdLabelBulan(k) {
                const m = String(k || '').match(/^(<)?(\d{4})-(\d{2})$/);
                return m ? (m[1] || '') + ZD_NAMA_BULAN[Number(m[3]) - 1] + '-' + m[2] : String(k || '');
            }

            // Angka E..T. Sel kosong = 0. Sel angka dipakai apa adanya. Teks diterima dalam
            // format umum ekspor SAP (pemisah ribuan titik/koma, minus di depan atau belakang,
            // kurung). Yang tidak terbaca mengembalikan null - barisnya MENGHENTIKAN upload,
            // bukan dilewati, karena toko yang hilang dari data dianggap lunas (aturan 4).
            function zdAngka(v) {
                if (v === null || v === undefined) return 0;
                if (typeof v === 'number') return isFinite(v) ? v : null;
                let s = String(v).replace(/[\s ]/g, '');
                if (s === '' || s === '-') return 0;
                let neg = false;
                if (/^\(.*\)$/.test(s)) { neg = true; s = s.slice(1, -1); }
                if (/-$/.test(s)) { neg = !neg; s = s.slice(0, -1); }
                if (/^-/.test(s)) { neg = !neg; s = s.slice(1); }
                if (!/^\d[\d.,]*$/.test(s)) return null;
                const titik = s.lastIndexOf('.'), koma = s.lastIndexOf(',');
                if (titik >= 0 && koma >= 0) {
                    s = titik > koma ? s.replace(/,/g, '') : s.replace(/\./g, '').replace(',', '.');
                } else if (koma >= 0) {
                    s = /,\d{1,2}$/.test(s) && (s.match(/,/g) || []).length === 1 ? s.replace(',', '.') : s.replace(/,/g, '');
                } else if ((s.match(/\./g) || []).length > 1 || /^\d{1,3}\.\d{3}$/.test(s)) {
                    // Rupiah tidak pernah bertiga desimal: "42.000" adalah empat puluh dua ribu.
                    s = s.replace(/\./g, '');
                }
                const n = Number(s);
                return isFinite(n) ? (neg ? -n : n) : null;
            }

            // EXPORT_YYYYMMDD_HHMMSS pada nama berkas -> "YYYY-MM-DDTHH:MM" (WIB). Tidak ada -> ''.
            function zdTanggalDariNama(nama) {
                const m = String(nama || '').match(/EXPORT_(\d{4})(\d{2})(\d{2})_(\d{2})(\d{2})(\d{2})/i);
                if (!m) return '';
                const d = new Date(Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3])));
                if (d.getUTCMonth() !== Number(m[2]) - 1 || Number(m[4]) > 23 || Number(m[5]) > 59) return '';
                return m[1] + '-' + m[2] + '-' + m[3] + 'T' + m[4] + ':' + m[5];
            }

            // Membaca seluruh baris sheet (array of array, baris 1 = header). Hasil:
            // { galat:[], peringatan:[], asOf, bulan:[13 kunci], baris:[...], depot:{kode:jumlah} }.
            function zdParse(aoa) {
                const hasil = { galat: [], peringatan: [], asOf: '', bulan: [], baris: [], depot: {}, totalBeda: 0 };
                const h = (aoa && aoa[0]) || [];
                ZD_KEPALA.forEach(function (harap, i) {
                    if (zdRapat(h[i]) !== harap) hasil.galat.push('Header kolom ' + String.fromCharCode(65 + i) + ' harus "'
                        + harap.replace(/\b\w/g, c => c.toUpperCase()) + '", tertulis "' + String(h[i] == null ? '' : h[i]).trim() + '".');
                });
                const bln = [];
                for (let i = 6; i <= 18; i++) {
                    const b = zdBacaBulan(h[i]);
                    if (!b) { hasil.galat.push('Header kolom ' + String.fromCharCode(65 + i) + ' bukan bulan (contoh: Oct-2026): "' + String(h[i] == null ? '' : h[i]).trim() + '".'); continue; }
                    bln.push(b);
                }
                if (bln.length === 13) {
                    for (let i = 1; i < 13; i++) {
                        const seb = bln[i - 1].y * 12 + bln[i - 1].m, ini = bln[i].y * 12 + bln[i].m;
                        if (seb - ini !== 1) { hasil.galat.push('Kolom bulan G..S harus 13 bulan berurutan mundur; ' + zdLabelBulan(zdKunci(bln[i - 1])) + ' lalu ' + zdLabelBulan(zdKunci(bln[i])) + '.'); break; }
                    }
                    const t = String(h[19] == null ? '' : h[19]).trim();
                    const bt = t.charAt(0) === '<' ? zdBacaBulan(t.slice(1)) : null;
                    if (!bt || zdKunci(bt) !== zdKunci(bln[12])) hasil.galat.push('Header kolom T harus "<' + zdLabelBulan(zdKunci(bln[12])) + '", tertulis "' + t + '".');
                    hasil.bulan = bln.map(zdKunci);
                    hasil.asOf = hasil.bulan[0];
                }
                if (hasil.galat.length) return hasil;

                const tak = [], kunci = {};
                for (let r = 1; r < aoa.length; r++) {
                    const x = aoa[r] || [];
                    const kode = String(x[1] == null ? '' : x[1]).trim();
                    if (kode === '') continue;                    // baris grand total di bawah
                    const nomor = r + 1;                          // nomor baris Excel
                    const angka = [];
                    let rusak = false;
                    for (let c = 4; c <= 19; c++) { const n = zdAngka(x[c]); if (n === null) rusak = true; angka.push(n); }
                    if (rusak) { tak.push(nomor); continue; }
                    const k = kode.replace(/^0+/, '');
                    if (k === '') { tak.push(nomor); continue; }
                    if (kunci[k]) { hasil.galat.push('Kode toko duplikat ' + kode + ' (baris ' + kunci[k] + ' dan ' + nomor + ').'); continue; }
                    kunci[k] = nomor;
                    const buckets = {};
                    hasil.bulan.forEach(function (b, i) { buckets[b] = angka[2 + i]; });
                    const jumlah = angka.slice(2).reduce((a, v) => a + v, 0);
                    if (Math.abs(jumlah - angka[1]) > 1) hasil.totalBeda++;
                    const ch = String(x[0] == null ? '' : x[0]).trim();
                    hasil.depot[ch || '(kosong)'] = (hasil.depot[ch || '(kosong)'] || 0) + 1;
                    hasil.baris.push({ rowNo: nomor, channel: ch, customerCode: kode, customerName: String(x[2] == null ? '' : x[2]).trim(),
                        termFi: String(x[3] == null ? '' : x[3]).trim(), overdueAmt: angka[0], totalAmt: angka[1],
                        buckets: buckets, bucketOlder: angka[15] });
                }
                if (tak.length) hasil.galat.push('Angka kolom E..T tidak terbaca pada baris ' + tak.slice(0, 30).join(', ')
                    + (tak.length > 30 ? ' dan ' + (tak.length - 30) + ' baris lain' : '') + '. Perbaiki berkasnya lalu unggah ulang.');
                if (hasil.totalBeda) hasil.peringatan.push(hasil.totalBeda + ' toko: Total (kolom F) berbeda lebih dari Rp 1 dari jumlah kolom G..T.');
                if (!hasil.baris.length && !hasil.galat.length) hasil.galat.push('Tidak ada baris toko pada berkas.');
                return hasil;
            }

            // Sheet "Data"; bila tidak ada, sheet pertama asalkan header-nya cocok.
            function zdBacaBuku(wb) {
                const nama = wb.SheetNames.includes('Data') ? 'Data' : wb.SheetNames[0];
                return XLSX.utils.sheet_to_json(wb.Sheets[nama], { header: 1, defval: null, raw: true });
            }

            // ---- Layar ----------------------------------------------------------------------
            let zdState = { file: '', parsed: null, uploadId: null, kosong: [], preview: null, filter: 'semua', depot: '', cari: '', depotDitanya: false };

            const ZD_HASIL = {
                LUNAS: ['Lunas', 'bg-green-100 text-green-800'],
                GAGAL: ['Belum Lunas', 'bg-red-100 text-red-700'],
                BLOCKED_BAD_DEBT: ['Bad Debt', 'bg-red-700 text-white'],
                PERIODE_SALAH: ['Periode Salah', 'bg-amber-100 text-amber-800'],
                SUPPRESSED: ['Dikembalikan depot', 'bg-gray-200 text-gray-700'],
                SUDAH_DITAWARKAN: ['Sudah ditawarkan', 'bg-blue-100 text-blue-700'],
                TANPA_MASTER: ['Tanpa Customer Master', 'bg-orange-100 text-orange-800']
            };
            // Nomor = skala prioritas pemilik (16 Oktober 2026): over due dicek lebih dulu, lalu tagihan
            // selama periode campaign, lalu tagihan sebelum periode campaign. Server memakai nomor yang sama.
            const ZD_ATURAN = { 1: 'Over due', 2: 'Tagihan selama periode campaign', 3: 'Tagihan sebelum periode campaign' };
            const ZD_ATURAN_SINGKAT = { 1: 'Over due', 2: 'Selama campaign', 3: 'Sebelum campaign' };

            function bukaUploadDebtor() {
                zdMuatRiwayat();
                zdMuatDikembalikan();
                if (!zdState.preview) zdRenderParse();
            }

            function zdPilihFile(input) {
                const file = input.files && input.files[0];
                if (!file) return;
                const reader = new FileReader();
                reader.onload = function (e) {
                    try {
                        const wb = XLSX.read(new Uint8Array(e.target.result), { type: 'array' });
                        zdState = { file: file.name, parsed: zdParse(zdBacaBuku(wb)), uploadId: null, kosong: [], preview: null,
                            filter: 'semua', depot: '', cari: '', depotDitanya: false };
                        const tgl = zdTanggalDariNama(file.name);
                        const el = document.getElementById('zdTarikan');
                        if (el) el.value = tgl;
                        zdRenderParse();
                    } catch (err) { showNotification('Berkas tidak dapat dibaca sebagai Excel.', 'error'); }
                    finally { input.value = ''; }
                };
                reader.readAsArrayBuffer(file);
            }

            function zdRenderParse() {
                const box = document.getElementById('zdParse');
                if (!box) return;
                setHiddenSafely('zdPratinjau', !zdState.preview);
                const p = zdState.parsed;
                if (!p) { box.innerHTML = '<p class="text-sm text-gray-500">Pilih berkas ekspor ZDAGE (sheet "Data", kolom A-T) untuk mulai.</p>'; setDisabledSafely('btnZdKirim', true); return; }
                const depot = Object.keys(p.depot).sort().map(k => rcEsc(k) + ' (' + p.depot[k].toLocaleString('id-ID') + ')').join(', ');
                box.innerHTML = '<div class="grid md:grid-cols-4 gap-3 text-sm">'
                    + '<div class="p-3 bg-white border border-gray-200 rounded-lg"><span class="block text-[10px] uppercase font-black text-gray-500">Berkas</span><b class="break-all">' + rcEsc(zdState.file) + '</b></div>'
                    + '<div class="p-3 bg-white border border-gray-200 rounded-lg"><span class="block text-[10px] uppercase font-black text-gray-500">Toko</span><b>' + p.baris.length.toLocaleString('id-ID') + '</b></div>'
                    + '<div class="p-3 bg-white border border-gray-200 rounded-lg"><span class="block text-[10px] uppercase font-black text-gray-500">Bulan tarikan (kolom G)</span><b>' + rcEsc(zdLabelBulan(p.asOf) || '-') + '</b></div>'
                    + '<div class="p-3 bg-white border border-gray-200 rounded-lg"><span class="block text-[10px] uppercase font-black text-gray-500">Depot di file (kolom A)</span><b>' + (depot || '-') + '</b></div></div>'
                    + (p.galat.length ? '<div class="mt-3 p-3 bg-red-50 border border-red-200 rounded-lg text-sm text-red-800"><b>Berkas ditolak:</b><ul class="list-disc ml-5 mt-1">'
                        + p.galat.map(g => '<li>' + rcEsc(g) + '</li>').join('') + '</ul></div>' : '')
                    + (p.peringatan.length ? '<div class="mt-3 p-3 bg-amber-50 border border-amber-200 rounded-lg text-sm text-amber-900"><b>Peringatan:</b><ul class="list-disc ml-5 mt-1">'
                        + p.peringatan.map(g => '<li>' + rcEsc(g) + '</li>').join('') + '</ul></div>' : '');
                setDisabledSafely('btnZdKirim', p.galat.length > 0 || !p.baris.length);
            }

            // Tanggal tarikan dari nama berkas, atau diisi OSC bila nama berkas tidak memuatnya.
            function zdTarikanIso() {
                const v = (document.getElementById('zdTarikan') || {}).value || '';
                return /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/.test(v) ? v + ':00+07:00' : '';
            }

            // 20261163860000: setiap langkah bertahap dicoba ulang bila server sedang sesak atau jaringan
            // terputus. Aman: bagian yang sudah tersimpan dikenali server dan tidak dikerjakan dua kali.
            async function zdCoba(payload) {
                let res = null;
                for (let i = 0; i < 3; i++) {
                    try { res = await fetchApp(payload); }
                    catch (e) { res = { status: 'error', message: (e && e.message) || 'Gagal terhubung ke server.' }; }
                    if (res && res.status === 'success') return res;
                    if (!/timeout|terhubung|fetch|network|upstream|canceling|gateway|schema cache/i.test(String(res && res.message))) return res;
                    await new Promise(r => setTimeout(r, 3000 * (i + 1)));
                }
                return res;
            }

            async function zdKirim() {
                const p = zdState.parsed;
                if (!p || p.galat.length) return;
                const tarikan = zdTarikanIso();
                if (!tarikan) { showNotification('Isi tanggal dan jam tarikan ZDAGE (nama berkas tidak memuat EXPORT_YYYYMMDD_HHMMSS).', 'warning'); return; }
                showLoadingOverlay('Mengirim data debtor...');
                try {
                    let id = null;
                    const n = p.baris.length, jumlah = Math.ceil(n / ZD_BAGIAN);
                    for (let i = 0; i < n; i += ZD_BAGIAN) {
                        showLoadingOverlay('Mengirim data debtor: bagian ' + (i / ZD_BAGIAN + 1) + ' dari ' + jumlah + ' (baris ' + (i + 1).toLocaleString('id-ID') + '-' + Math.min(n, i + ZD_BAGIAN).toLocaleString('id-ID') + ' dari ' + n.toLocaleString('id-ID') + ')...');
                        const res = await zdCoba({ action: 'zdageStage', fileName: zdState.file, extractedAt: tarikan,
                            rows: p.baris.slice(i, i + ZD_BAGIAN), uploadId: id });
                        if (res.status !== 'success') throw new Error((res.message || 'Gagal mengirim data debtor.') + ' Kirim ulang berkas yang sama; belum ada yang diterapkan.');
                        id = res.uploadId;
                    }
                    zdState.uploadId = id;
                    zdState.kosong = [];
                    zdState.depotDitanya = false;
                    await zdPratinjau();
                } catch (e) {
                    showNotification((e && e.message) ? e.message : 'Gagal mengirim data debtor.', 'error');
                } finally { hideLoadingOverlay(); }
            }

            // Ringkasan pratinjau dari baris per depot; hitungannya sama dengan rc_zdage_preview.
            function zdRingkasDari(rows) {
                const g = { total: rows.length, lunas: 0, lunasCb: 0, gagal: 0, gagal1: 0, gagal2: 0, gagal3: 0, badDebt: 0, suppressed: 0, sudahDitawarkan: 0,
                    periodeSalah: 0, campaignBermasalah: 0, kembaliRestricted: 0, tanpaMaster: 0, campaign: [] };
                const kamp = new Map(), kode = new Set();
                rows.forEach(function (r) {
                    const a = r.alasan || {};
                    if (a.tawaranAktif && r.hasil !== 'SUDAH_DITAWARKAN') g.kembaliRestricted++;
                    if (r.hasil === 'LUNAS') { g.lunas++; g.lunasCb += Number(r.netCb) || 0; }
                    else if (r.hasil === 'GAGAL') { g.gagal++; if ([1, 2, 3].includes(Number(a.utama))) g['gagal' + Number(a.utama)]++; }
                    else if (r.hasil === 'BLOCKED_BAD_DEBT') g.badDebt++;
                    else if (r.hasil === 'SUPPRESSED') g.suppressed++;
                    else if (r.hasil === 'SUDAH_DITAWARKAN') g.sudahDitawarkan++;
                    else if (r.hasil === 'TANPA_MASTER') g.tanpaMaster++;
                    else if (r.hasil === 'PERIODE_SALAH') {
                        g.periodeSalah++; kode.add(r.kodeCampaign);
                        const k = [r.kodeCampaign, r.namaCampaign, a.masalah].join('|');
                        const c = kamp.get(k) || { kode: r.kodeCampaign, nama: r.namaCampaign, masalah: a.masalah, bulanSo: null, bulanBill: null, klaim: 0, netCb: 0 };
                        if (r.bulanSo && (!c.bulanSo || r.bulanSo < c.bulanSo)) c.bulanSo = r.bulanSo;
                        if (r.bulanBill && (!c.bulanBill || r.bulanBill < c.bulanBill)) c.bulanBill = r.bulanBill;
                        c.klaim++; c.netCb += Number(r.netCb) || 0;
                        kamp.set(k, c);
                    }
                });
                g.campaignBermasalah = kode.size;
                g.campaign = Array.from(kamp.values()).sort((x, y) => y.klaim - x.klaim || String(x.kode).localeCompare(String(y.kode)));
                return g;
            }

            async function zdPratinjau() {
                showLoadingOverlay('Menyiapkan penilaian...');
                try {
                    const res = await zdCoba({ action: 'zdagePreviewAwal', uploadId: zdState.uploadId, kosong: zdState.kosong });
                    if (res.status !== 'success') throw new Error(res.message || 'Pratinjau gagal.');
                    const bagian = res.bagian || [], rows = [];
                    for (let i = 0; i < bagian.length; i++) {
                        showLoadingOverlay('Menilai klaim Not Yet: depot ' + (i + 1) + ' dari ' + bagian.length + ' (' + bagian[i].kode + ')...');
                        const b = await zdCoba({ action: 'zdagePreviewBagian', uploadId: zdState.uploadId, kosong: zdState.kosong, depot: bagian[i].kode });
                        if (b.status !== 'success') throw new Error('Pratinjau depot ' + bagian[i].kode + ' gagal: ' + (b.message || 'tanpa keterangan') + '. Klik Kirim & Pratinjau lagi; belum ada yang diterapkan.');
                        rows.push(...(b.rows || []));
                    }
                    res.rows = rows;
                    res.ringkasan = zdRingkasDari(rows);
                    zdState.preview = res;
                    zdRenderParse();
                    zdRenderPratinjau();
                    // Pop up depot yang tidak ada di file, sekali per upload (dapat dibuka lagi lewat tombolnya).
                    if (!zdState.depotDitanya && (res.depotTidakAda || []).length) { zdState.depotDitanya = true; zdTanyaDepot(); }
                } catch (e) {
                    showNotification((e && e.message) ? e.message : 'Pratinjau gagal.', 'error');
                } finally { hideLoadingOverlay(); }
            }

            function zdTanyaDepot() {
                const daftar = (zdState.preview && zdState.preview.depotTidakAda) || [];
                if (!daftar.length) { showNotification('Semua depot yang punya klaim Not Yet ada di file.', 'success'); return; }
                rcDialog('Depot yang tidak ada di file', '<div class="space-y-3 text-sm" data-rc-dialog-wide="1">'
                    + '<p>Depot di bawah tidak ada di kolom A berkas ini. Depot yang <b>tidak</b> dicentang memakai <b>data debtor lama</b>-nya; '
                    + 'depot tanpa data lama tidak dinilai. Centang <b>Tidak ada tagihan</b> bila depot memang tidak punya debtor - seluruh tokonya dianggap lunas.</p>'
                    + '<div class="overflow-auto border border-gray-200 rounded-lg max-h-[50vh]"><table class="w-full text-xs"><thead class="bg-gray-50"><tr>'
                    + '<th class="p-2 text-center">Tidak ada tagihan</th><th class="p-2 text-left">Depot</th><th class="p-2 text-right">Not Yet</th><th class="p-2 text-left">Data yang dipakai bila tidak dicentang</th></tr></thead><tbody>'
                    + daftar.map(d => '<tr class="border-t border-gray-100"><td class="p-2 text-center"><input type="checkbox" class="zd-kosong w-4 h-4" value="' + rcEsc(d.kode) + '"'
                        + (zdState.kosong.includes(d.kode) ? ' checked' : '') + '></td><td class="p-2"><b>' + rcEsc(d.kode) + '</b> ' + rcEsc(d.nama || '') + '</td>'
                        + '<td class="p-2 text-right">' + Number(d.notYet || 0).toLocaleString('id-ID') + '</td><td class="p-2">'
                        + (d.dataLama ? (d.dataLama.kosong ? 'Lama: tidak ada tagihan (' + rcEsc(d.dataLama.tarikan) + ')' : 'Lama: tarikan ' + rcEsc(d.dataLama.tarikan) + ', bulan ' + rcEsc(d.dataLama.asOf))
                            : '<span class="text-gray-500">Belum ada data - tidak dinilai</span>') + '</td></tr>').join('')
                    + '</tbody></table></div><div class="flex justify-end gap-2"><button type="button" onclick="rcTutupDialog()" class="px-4 py-2 border border-gray-300 rounded-lg font-bold">Tutup</button>'
                    + '<button type="button" onclick="zdSimpanDepot()" class="px-4 py-2 bg-cyan-600 hover:bg-cyan-700 text-white rounded-lg font-bold">OK</button></div></div>');
            }

            async function zdSimpanDepot() {
                zdState.kosong = Array.from(document.querySelectorAll('.zd-kosong:checked')).map(c => c.value);
                rcTutupDialog();
                await zdPratinjau();
            }

            // Penyebab per baris: satu butir per aturan yang gagal, urut prioritas (sumber: server).
            function zdPenyebabDaftar(r) {
                const a = r.alasan || {};
                if (r.hasil === 'LUNAS') return [a.tidakDiFile ? 'Tidak ada di data debtor' + (a.sumber === 'kosong' || a.sumber === 'lama_kosong' ? ' (depot tanpa tagihan)' : '') : 'Tidak ada tagihan s/d Bulan Bill'];
                if (r.hasil === 'BLOCKED_BAD_DEBT') return ['Bad Debt: ' + (a.badDebt || '')];
                if (r.hasil === 'SUPPRESSED') return ['Dikembalikan depot: ' + (a.alasanKembali || '')];
                if (r.hasil === 'SUDAH_DITAWARKAN') return ['Tawaran aktif, batas ' + (a.deadlineAktif || '')];
                if (r.hasil === 'PERIODE_SALAH') return [a.masalah === 'tanggal_salah'
                    ? 'SO start (' + zdLabelBulan(a.bulanSo) + ') sesudah Billing end (' + zdLabelBulan(a.bulanBill) + ')'
                    : 'SO / Billing belum diisi di Campaign Master'];
                if (r.hasil === 'TANPA_MASTER') return ['Lengkapi Customer Master lebih dulu'];
                return (a.rincian || []).map(x => x.aturan + '. ' + ZD_ATURAN[x.aturan] + ': '
                    + (x.aturan === 1 ? '' : (x.bulan === 'jumlah' ? 'jumlah s/d Bulan Bill ' : zdLabelBulan(x.bulan) + ' ')) + rcNominalPenuh(x.nilai))
                    .concat(a.tawaranAktif && a.tawaranJenis !== 'RESTRICTED' ? ['Tawaran aktif dibatalkan saat Terapkan (kembali ke Restricted)'] : []);
            }
            function zdPenyebab(r) { return zdPenyebabDaftar(r).join('; '); }

            function zdSumber(s) {
                return { baru: 'Data baru', lama: 'Data lama', kosong: 'Tidak ada tagihan', lama_kosong: 'Tidak ada tagihan (lama)' }[s] || '-';
            }

            function zdBarisTersaring() {
                const pv = zdState.preview || {};
                const kata = zdState.cari.toLowerCase().split(/\s+/).filter(Boolean);
                return (pv.rows || []).filter(function (r) {
                    const f = zdState.filter;
                    if (f !== 'semua') {
                        // gagal1..3: Belum Lunas menurut penyebab UTAMA (prioritas tertinggi yang gagal).
                        if (/^gagal[123]$/.test(f)) { if (r.hasil !== 'GAGAL' || Number((r.alasan || {}).utama) !== Number(f.slice(-1))) return false; }
                        else if (r.hasil !== f) return false;
                    }
                    if (zdState.depot && r.kodeDepot !== zdState.depot) return false;
                    const teks = [r.noDoc, r.kodeToko, r.namaToko, r.kodeCampaign, r.namaCampaign].join(' ').toLowerCase();
                    return kata.every(k => teks.indexOf(k) >= 0);
                });
            }

            function zdSaring(f) {
                if (f === 'campaign') { zdRingkasCampaign(); return; }
                zdState.filter = f; zdRenderPratinjau();
            }

            // Campaign Bermasalah: ringkasan per campaign dari klaim Periode Salah, bahan perbaikan
            // Campaign Master (SO / Billing).
            function zdRingkasCampaign() {
                const daftar = ((zdState.preview || {}).ringkasan || {}).campaign || [];
                rcDialog('Campaign Bermasalah', daftar.length ? '<div class="space-y-3 text-sm" data-rc-dialog-wide="1"><p>Campaign yang periodenya perlu dibetulkan di Key Master &gt; Campaign Master. Klaimnya tidak dapat dinilai lunas dan tetap di Restricted.</p>'
                    + '<div class="overflow-auto border border-gray-200 rounded-lg max-h-[55vh]"><table class="w-full text-xs"><thead class="bg-gray-50"><tr><th class="p-2 text-left">Campaign</th><th class="p-2 text-left">Masalah</th><th class="p-2 text-left">SO - Billing</th><th class="p-2 text-right">Klaim</th><th class="p-2 text-right">Net CB</th></tr></thead><tbody>'
                    + daftar.map(c => '<tr class="border-t border-gray-100"><td class="p-2"><b>' + rcEsc(c.kode) + '</b><span class="block text-gray-500">' + rcEsc(c.nama || '') + '</span></td>'
                        + '<td class="p-2 whitespace-nowrap">' + (c.masalah === 'tanggal_salah' ? 'SO start sesudah Billing end' : 'SO / Billing belum diisi') + '</td>'
                        + '<td class="p-2 whitespace-nowrap">' + rcEsc(zdLabelBulan(c.bulanSo) || '-') + ' s/d ' + rcEsc(zdLabelBulan(c.bulanBill) || '-') + '</td>'
                        + '<td class="p-2 text-right">' + Number(c.klaim || 0).toLocaleString('id-ID') + '</td><td class="p-2 text-right whitespace-nowrap">' + rcNominalPenuh(c.netCb) + '</td></tr>').join('')
                    + '</tbody></table></div><div class="flex justify-end gap-2"><button type="button" onclick="zdState.filter=\'PERIODE_SALAH\';rcTutupDialog();zdRenderPratinjau()" class="px-4 py-2 border border-gray-300 rounded-lg font-bold">Lihat klaimnya</button>'
                    + '<button type="button" onclick="rcTutupDialog()" class="px-4 py-2 bg-cyan-600 text-white rounded-lg font-bold">Tutup</button></div></div>'
                    : '<p class="text-sm">Tidak ada campaign bermasalah.</p>');
            }

            function zdRenderPratinjau() {
                const pv = zdState.preview;
                setHiddenSafely('zdPratinjau', !pv);
                if (!pv) return;
                const g = pv.ringkasan || {};
                // Lima kelompok utama (pemilik, 16 Oktober 2026). Belum Lunas dirinci menurut penyebab
                // utamanya; kelompok lain yang jarang tampil sebagai pilihan kecil di bawahnya.
                const kartu = [
                    ['GAGAL', 'Belum Lunas', g.gagal, 'border-red-400', [['gagal1', ZD_ATURAN_SINGKAT[1], g.gagal1], ['gagal2', ZD_ATURAN_SINGKAT[2], g.gagal2], ['gagal3', ZD_ATURAN_SINGKAT[3], g.gagal3]]],
                    ['LUNAS', 'Lunas', g.lunas, 'border-green-400', null, 'ditawarkan saat Terapkan &middot; ' + rcNominalPenuh(g.lunasCb)],
                    ['BLOCKED_BAD_DEBT', 'Bad Debt', g.badDebt, 'border-red-700', null, 'tidak ditawarkan'],
                    ['PERIODE_SALAH', 'Periode Salah', g.periodeSalah, 'border-amber-400', null, 'tanpa tanggal SO / Billing, atau tanggal salah'],
                    ['campaign', 'Campaign Bermasalah', g.campaignBermasalah, 'border-purple-400', null, 'ringkasan per campaign (klik)']];
                const lain = [['semua', 'Semua dinilai', g.total], ['SUDAH_DITAWARKAN', 'Sudah ditawarkan', g.sudahDitawarkan],
                    ['SUPPRESSED', 'Dikembalikan depot', g.suppressed], ['TANPA_MASTER', 'Tanpa Customer Master', g.tanpaMaster]]
                    .filter(k => k[0] === 'semua' || Number(k[2] || 0) > 0);
                const aktif = (k) => zdState.filter === k ? ' ring-2 ring-cyan-500' : '';
                const up = pv.upload || {};
                document.getElementById('zdRingkas').innerHTML =
                    '<div class="mb-3 text-sm text-gray-700">Tarikan <b>' + rcEsc(up.tarikan || '-') + '</b> &middot; bulan <b>' + rcEsc(up.asOf || '-') + '</b> &middot; '
                    + Number(up.baris || 0).toLocaleString('id-ID') + ' toko &middot; toleransi <b>' + rcNominalPenuh(pv.toleransi) + '</b> &middot; mode <b>'
                    + (pv.mode === 'jumlah' ? 'dijumlah' : 'per kolom') + '</b>'
                    + ' &middot; Lunas ditawarkan senilai <b>' + rcNominalPenuh(g.lunasCb) + '</b></div>'
                    + ((pv.galat || []).length ? '<div class="mb-3 p-3 bg-red-50 border border-red-200 rounded-lg text-sm text-red-800"><b>Tidak dapat diterapkan:</b> ' + pv.galat.map(rcEsc).join(' ') + '</div>' : '')
                    + zdPeringatanServer(pv)
                    + '<div class="grid grid-cols-2 md:grid-cols-5 gap-2">' + kartu.map(k => '<div class="p-3 bg-white border-2 rounded-lg ' + k[3] + aktif(k[0]) + '">'
                        + '<button type="button" onclick="zdSaring(\'' + k[0] + '\')" class="block w-full text-left"><span class="block text-[10px] uppercase font-black text-gray-500">' + rcEsc(k[1])
                        + '</span><b class="text-lg">' + Number(k[2] || 0).toLocaleString('id-ID') + '</b></button>'
                        + (k[4] ? '<div class="mt-1 flex flex-wrap gap-1">' + k[4].map(s => '<button type="button" onclick="zdSaring(\'' + s[0] + '\')" class="px-1.5 py-0.5 rounded text-[10px] font-bold whitespace-nowrap bg-red-50 text-red-800'
                            + aktif(s[0]) + '">' + rcEsc(s[1]) + ' ' + Number(s[2] || 0).toLocaleString('id-ID') + '</button>').join('') + '</div>'
                            : '<span class="block mt-1 text-[10px] text-gray-500">' + (k[5] || '') + '</span>')
                        + '</div>').join('') + '</div>'
                    + '<div class="mt-2 flex flex-wrap gap-2 text-xs">' + lain.map(k => '<button type="button" onclick="zdSaring(\'' + k[0] + '\')" class="px-2 py-1 rounded-lg border border-gray-300 bg-white font-bold whitespace-nowrap'
                        + aktif(k[0]) + '">' + rcEsc(k[1]) + ' ' + Number(k[2] || 0).toLocaleString('id-ID') + '</button>').join('') + '</div>';

                const dep = document.getElementById('zdDepot');
                if (dep) {
                    const ada = Array.from(new Set((pv.rows || []).map(r => r.kodeDepot))).sort();
                    dep.innerHTML = '<option value="">Semua depot</option>' + ada.map(k => '<option value="' + rcEsc(k) + '">' + rcEsc(k) + '</option>').join('');
                    dep.value = ada.includes(zdState.depot) ? zdState.depot : '';
                }
                const rows = zdBarisTersaring();
                const tampil = rows.slice(0, 1000);
                document.getElementById('zdBody').innerHTML = tampil.map(function (r) {
                    const h = ZD_HASIL[r.hasil] || [r.hasil, 'bg-gray-100'];
                    return '<tr class="border-b border-gray-100 align-top"><td class="p-2 font-black text-blue-700 whitespace-nowrap">' + rcEsc(r.noDoc) + '</td>'
                        + '<td class="p-2 whitespace-nowrap">' + rcEsc(r.kodeDepot) + '</td>'
                        + '<td class="p-2"><b>' + rcEsc(r.namaToko) + '</b><br><span class="text-gray-500">' + rcEsc(r.kodeToko) + '</span></td>'
                        + '<td class="p-2"><b>' + rcEsc(r.kodeCampaign) + '</b><br><span class="text-gray-500">' + rcEsc(r.namaCampaign) + '</span></td>'
                        + '<td class="p-2 whitespace-nowrap">' + rcEsc(zdLabelBulan(r.bulanSo) || '-') + ' s/d ' + rcEsc(zdLabelBulan(r.bulanBill) || '-') + '</td>'
                        + '<td class="p-2 text-right whitespace-nowrap font-bold" data-sort="' + Number(r.netCb || 0) + '">' + rcNominalPenuh(r.netCb) + '</td>'
                        // Hasil tidak boleh terpotong menjadi dua baris; penyebab satu butir per baris.
                        + '<td class="p-2 whitespace-nowrap"><span class="inline-block px-2 py-0.5 rounded text-[10px] font-black whitespace-nowrap ' + h[1] + '">' + rcEsc(h[0]) + '</span>'
                          + (r.hasil === 'GAGAL' && (r.alasan || {}).utama ? '<span class="block mt-0.5 text-[10px] text-red-700 font-bold whitespace-nowrap">' + rcEsc(ZD_ATURAN_SINGKAT[r.alasan.utama]) + '</span>' : '') + '</td>'
                        + '<td class="p-2 text-xs">' + zdPenyebabDaftar(r).map(t => '<div class="leading-snug">' + rcEsc(t) + '</div>').join('') + '</td>'
                        + '<td class="p-2 text-xs whitespace-nowrap">' + rcEsc(zdSumber((r.alasan || {}).sumber)) + '</td></tr>';
                }).join('') || '<tr><td colspan="9" class="p-6 text-center text-gray-400">Tidak ada klaim pada saringan ini.</td></tr>';
                document.getElementById('zdJumlah').innerText = rows.length.toLocaleString('id-ID') + ' klaim'
                    + (rows.length > tampil.length ? ' (1.000 pertama ditampilkan; unduh untuk seluruhnya)' : '');
                setDisabledSafely('btnZdTerapkan', (pv.galat || []).length > 0 || !g.total);
                setHiddenSafely('btnZdDepot', !(pv.depotTidakAda || []).length);
                rcAktifkanUrutSemua('zdPratinjau');
            }

            function zdPeringatanServer(pv) {
                // Kode toko yang tidak ada di Customer Master dibiarkan (keputusan pemilik): tidak diperingatkan.
                const w = [];
                if (pv.totalBeda) w.push(pv.totalBeda.toLocaleString('id-ID') + ' toko: Total berbeda dari jumlah kolom G..T.');
                if ((pv.kodeDepotAsing || []).length) w.push('Kode di kolom A yang bukan depot: ' + pv.kodeDepotAsing.map(x => x.kode + ' (' + x.toko + ')').join(', ') + '.');
                if (zdState.kosong.length) w.push('Tidak ada tagihan: ' + zdState.kosong.join(', ') + '.');
                if ((pv.ringkasan || {}).kembaliRestricted) w.push(pv.ringkasan.kembaliRestricted.toLocaleString('id-ID') + ' tawaran yang sedang berjalan tidak lunas lagi menurut data ini; saat Terapkan tawarannya dibatalkan dan klaimnya kembali ke Restricted.');
                return w.length ? '<div class="mb-3 p-3 bg-amber-50 border border-amber-200 rounded-lg text-sm text-amber-900"><ul class="list-disc ml-5">'
                    + w.map(x => '<li>' + rcEsc(x) + '</li>').join('') + '</ul></div>' : '';
            }

            function zdUnduhPratinjau() {
                const rows = zdBarisTersaring();
                if (!rows.length) { showNotification('Tidak ada baris untuk diunduh.', 'warning'); return; }
                const aoa = [['No Doc', 'Kode Depot', 'Kode Toko', 'Nama Toko', 'Kode Campaign', 'Nama Campaign', 'Bulan SO', 'Bulan Bill', 'Net CB', 'Hasil', 'Penyebab Utama', 'Penyebab', 'Sumber Data']]
                    .concat(rows.map(r => [rcSelTeks(r.noDoc), rcSelTeks(r.kodeDepot), rcSelTeks(r.kodeToko), r.namaToko || '', rcSelTeks(r.kodeCampaign), r.namaCampaign || '',
                        zdLabelBulan(r.bulanSo), zdLabelBulan(r.bulanBill), Math.trunc(Number(r.netCb) || 0), (ZD_HASIL[r.hasil] || [r.hasil])[0],
                        r.hasil === 'GAGAL' ? (ZD_ATURAN[(r.alasan || {}).utama] || '') : '', zdPenyebab(r), zdSumber((r.alasan || {}).sumber)]));
                const wb = XLSX.utils.book_new();
                XLSX.utils.book_append_sheet(wb, XLSX.utils.aoa_to_sheet(aoa), 'Pratinjau Debtor');
                XLSX.writeFile(wb, 'Pratinjau_Upload_Debtor_' + new Date().toISOString().slice(0, 10) + '.xlsx');
            }

            async function zdTerapkan() {
                const pv = zdState.preview;
                if (!pv || !zdState.uploadId) return;
                const g = pv.ringkasan || {};
                const ok = await showConfirmModal({ title: 'Terapkan Upload Debtor',
                    message: Number(g.lunas || 0).toLocaleString('id-ID') + ' klaim toko lunas akan ditawarkan ke depot di Claim Upload > Open dengan batas proses 7 hari. '
                        + (g.kembaliRestricted ? Number(g.kembaliRestricted).toLocaleString('id-ID') + ' tawaran yang tidak lunas lagi dibatalkan (kembali ke Restricted). ' : '')
                        + 'Tgl Lunas yang masih kosong diisi tanggal tarikan. Lanjutkan?', confirmText: 'Terapkan', danger: false });
                if (!ok) return;
                await zdJalankanTerapkan(zdState.uploadId, zdState.kosong);
            }

            // 20261163860000: per depot, setiap depot satu transaksi di server. Bila terhenti, depot yang
            // sudah selesai tetap tersimpan dan penerapan dapat dilanjutkan dari kotak di Riwayat.
            async function zdJalankanTerapkan(uploadId, kosong) {
                showLoadingOverlay('Menyiapkan penerapan...');
                try {
                    const m = await zdCoba({ action: 'zdageApplyMulai', uploadId: uploadId, kosong: kosong });
                    if (m.status !== 'success') throw new Error(m.message || 'Gagal menerapkan.');
                    let res = m;
                    if (!m.sudahDiterapkan) {
                        const bagian = m.bagian || [], selesai = new Set(m.selesai || []);
                        for (let i = 0; i < bagian.length; i++) {
                            if (selesai.has(bagian[i].kode)) continue;
                            showLoadingOverlay('Menerapkan: depot ' + (i + 1) + ' dari ' + bagian.length + ' (' + bagian[i].kode + ')...');
                            const b = await zdCoba({ action: 'zdageApplyBagian', uploadId: uploadId, depot: bagian[i].kode });
                            if (b.status !== 'success') throw new Error('Terhenti di depot ' + bagian[i].kode + ': ' + (b.message || 'tanpa keterangan') + '. ' + selesai.size + ' depot sudah diterapkan; lanjutkan dari kotak di bagian Riwayat.');
                            selesai.add(bagian[i].kode);
                        }
                        showLoadingOverlay('Menyelesaikan penerapan...');
                        res = await zdCoba({ action: 'zdageApplySelesai', uploadId: uploadId });
                        if (res.status !== 'success') throw new Error((res.message || 'Gagal menyelesaikan.') + ' Lanjutkan dari kotak di bagian Riwayat.');
                    }
                    showNotification(res.message || 'Upload Debtor diterapkan.', 'success');
                    zdState = { file: '', parsed: null, uploadId: null, kosong: [], preview: null, filter: 'semua', depot: '', cari: '', depotDitanya: false };
                    zdRenderParse(); zdRenderPratinjau();
                } catch (e) {
                    showNotification((e && e.message) ? e.message : 'Gagal menerapkan.', 'error');
                } finally {
                    hideLoadingOverlay();
                    zdMuatRiwayat();
                }
            }

            async function zdLanjutkan(uploadId) {
                const ok = await showConfirmModal({ title: 'Lanjutkan Penerapan', message: 'Depot yang belum selesai diterapkan akan dikerjakan; yang sudah selesai tidak diulang. Lanjutkan?', confirmText: 'Lanjutkan', danger: false });
                if (ok) await zdJalankanTerapkan(uploadId, []);
            }

            async function zdBatal() {
                if (zdState.uploadId) { try { await fetchApp({ action: 'zdageDiscard', uploadId: zdState.uploadId }); } catch (e) { /* pratinjau tetap dibuang di layar */ } }
                zdState = { file: '', parsed: null, uploadId: null, kosong: [], preview: null, filter: 'semua', depot: '', cari: '', depotDitanya: false };
                zdRenderParse(); zdRenderPratinjau();
            }

            async function zdMuatRiwayat() {
                const box = document.getElementById('zdRiwayat');
                if (!box) return;
                try {
                    const res = await fetchApp({ action: 'zdageRiwayat' });
                    if (res.status !== 'success') throw new Error(res.message || '');
                    document.getElementById('zdAturan').innerText = 'Toleransi ' + rcNominalPenuh(res.toleransi) + ', mode ' + (res.mode === 'jumlah' ? 'dijumlah' : 'per kolom') + '.';
                    box.innerHTML = (res.belumSelesai || []).map(b => '<div class="mb-4 p-3 bg-amber-50 border border-amber-300 rounded-xl text-sm text-amber-900 flex flex-wrap items-center gap-3">'
                            + '<span class="flex-1 min-w-[240px]"><b>Penerapan belum selesai:</b> ' + rcEsc(b.file) + ', ' + Number(b.selesai).toLocaleString('id-ID') + ' dari ' + Number(b.total).toLocaleString('id-ID') + ' depot.</span>'
                            + '<button type="button" onclick="zdLanjutkan(\'' + rcEsc(b.id) + '\')" class="px-4 py-2 bg-amber-600 hover:bg-amber-700 text-white rounded-lg font-bold text-xs">Lanjutkan</button></div>').join('')
                        + '<div class="grid md:grid-cols-2 gap-4"><div><h4 class="font-black text-gray-700 text-sm mb-2">Data debtor yang berlaku per depot</h4>'
                        + '<div class="overflow-auto border border-gray-200 rounded-lg max-h-[260px]"><table class="w-full text-xs"><thead class="bg-gray-50"><tr><th class="p-2 text-left">Depot</th><th class="p-2 text-left">Tarikan</th><th class="p-2 text-left">Bulan</th></tr></thead><tbody>'
                        + ((res.depot || []).map(d => '<tr class="border-t border-gray-100"><td class="p-2"><b>' + rcEsc(d.kode) + '</b> ' + rcEsc(d.nama || '') + '</td><td class="p-2">' + rcEsc(d.tarikan)
                            + '</td><td class="p-2">' + (d.kosong ? 'Tidak ada tagihan' : rcEsc(d.asOf)) + '</td></tr>').join('') || '<tr><td colspan="3" class="p-3 text-center text-gray-400">Belum ada data.</td></tr>')
                        + '</tbody></table></div></div><div><h4 class="font-black text-gray-700 text-sm mb-2">Upload yang sudah diterapkan</h4>'
                        + '<div class="overflow-auto border border-gray-200 rounded-lg max-h-[260px]"><table class="w-full text-xs"><thead class="bg-gray-50"><tr><th class="p-2 text-left">Berkas</th><th class="p-2 text-left">Diterapkan</th><th class="p-2 text-right">Tawaran baru</th></tr></thead><tbody>'
                        + ((res.upload || []).map(u => '<tr class="border-t border-gray-100"><td class="p-2 break-all">' + rcEsc(u.file) + '<span class="block text-gray-500">tarikan ' + rcEsc(u.tarikan) + ' &middot; ' + rcEsc(u.oleh) + '</span></td>'
                            + '<td class="p-2 whitespace-nowrap">' + rcEsc(u.diterapkan) + '</td><td class="p-2 text-right">' + Number(u.tawaranBaru || 0).toLocaleString('id-ID') + '</td></tr>').join('') || '<tr><td colspan="3" class="p-3 text-center text-gray-400">Belum ada.</td></tr>')
                        + '</tbody></table></div></div></div>';
                } catch (e) { box.innerHTML = '<p class="text-sm text-red-600">Riwayat tidak dapat dimuat.</p>'; }
            }

            let zdKembaliRows = [];
            async function zdMuatDikembalikan() {
                const body = document.getElementById('zdKembaliBody');
                if (!body) return;
                try {
                    const res = await fetchApp({ action: 'clearingDikembalikan' });
                    if (res.status !== 'success') throw new Error(res.message || '');
                    zdKembaliRows = res.rows || [];
                    body.innerHTML = zdKembaliRows.map(r => '<tr class="border-b border-gray-100"><td class="p-2 text-center"><input type="checkbox" class="cb-zd-kembali w-4 h-4" value="' + rcEsc(r.noDoc) + '" onchange="zdHitungKembali()"></td>'
                        + '<td class="p-2 font-black text-blue-700 whitespace-nowrap">' + rcEsc(r.noDoc) + '</td><td class="p-2">' + rcEsc(r.kodeDepot) + '</td>'
                        + '<td class="p-2"><b>' + rcEsc(r.namaToko) + '</b><br><span class="text-gray-500">' + rcEsc(r.kodeToko) + '</span></td>'
                        + '<td class="p-2">' + rcEsc(r.kodeCampaign) + '</td><td class="p-2 text-right whitespace-nowrap">' + rcNominalPenuh(r.netCb) + '</td>'
                        + '<td class="p-2 text-xs">' + rcEsc(r.alasan) + '</td><td class="p-2 text-xs whitespace-nowrap">' + rcEsc(r.oleh) + '<br>' + rcEsc(r.waktu) + '</td></tr>').join('')
                        || '<tr><td colspan="8" class="p-4 text-center text-gray-400">Tidak ada tawaran yang dikembalikan depot.</td></tr>';
                    zdHitungKembali();
                } catch (e) { body.innerHTML = '<tr><td colspan="8" class="p-4 text-center text-red-600">Daftar tidak dapat dimuat.</td></tr>'; }
            }
            function zdHitungKembali() {
                const n = document.querySelectorAll('.cb-zd-kembali:checked').length;
                document.getElementById('zdKembaliTerpilih').innerText = n;
                setDisabledSafely('btnZdTawarUlang', n === 0);
            }
            async function zdTawarkanUlang() {
                const docs = Array.from(document.querySelectorAll('.cb-zd-kembali:checked')).map(c => c.value);
                if (!docs.length) return;
                const ok = await showConfirmModal({ title: 'Tawarkan Ulang', message: docs.length + ' dokumen ditawarkan ulang ke depot dengan batas proses 7 hari. Lanjutkan?', confirmText: 'Tawarkan Ulang', danger: false });
                if (!ok) return;
                try {
                    const res = await fetchApp({ action: 'clearingReoffer', docs: docs });
                    if (res.status !== 'success') throw new Error(res.message || 'Gagal.');
                    showNotification(res.message, 'success');
                    zdMuatDikembalikan();
                } catch (e) { showNotification((e && e.message) ? e.message : 'Gagal menawarkan ulang.', 'error'); }
            }
