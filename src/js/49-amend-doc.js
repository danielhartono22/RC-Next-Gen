            // ============================================================================
            // DOCUMENT CENTER - TAB AMEND DOC (20261163140000, 20261163150000)
            // ============================================================================
            // Pemilik, 16 Oktober 2026: No Doc dan Net CB terbaru, dari status apa pun, dengan
            // alasan. Tab hanya tampil bila dicentang di Access Management. Server memeriksa
            // seluruh baris dulu (satu salah = tidak ada yang diubah), menghitung ulang gross up,
            // mempertahankan status, mengirim email peringatan per depot, dan menandai dokumen
            // "Doc Amendment - <tahap>" di Remark.

            const AMEND_MAKS = 200;
            let amendInfo = {};   // No Doc (huruf besar) -> hasil amendCek, atau { galat }

            // "1.234.567", "1234567", "1,234,567", "1234567,89" -> 1234567 (desimal dipotong,
            // aturan Document Center). null bila bukan angka.
            function amendUraiAngka(teks) {
                let t = String(teks || '').replace(/\s/g, '').replace(/^Rp\.?/i, '');
                if (!t) return null;
                if (/^\d{1,3}(\.\d{3})+(,\d+)?$/.test(t)) t = t.replace(/\./g, '').replace(',', '.');
                else if (/^\d{1,3}(,\d{3})+(\.\d+)?$/.test(t)) t = t.replace(/,/g, '');
                else if (/^\d+,\d+$/.test(t)) t = t.replace(',', '.');
                if (!/^\d+(\.\d+)?$/.test(t)) return null;
                return Math.trunc(Number(t));
            }

            function amendBarisHtml() {
                return '<tr class="amend-baris border-t border-amber-200">'
                    + '<td class="p-1.5"><input class="amend-doc w-full px-3 py-2 border border-amber-300 rounded-lg text-xs font-mono bg-white" placeholder="No Doc" autocomplete="off"'
                    + ' onchange="amendCekBaris(this.closest(\'tr\'))" onpaste="amendTempel(event, this)"></td>'
                    + '<td class="p-1.5"><input class="amend-cb w-full px-3 py-2 border border-amber-300 rounded-lg text-xs text-right bg-white" inputmode="numeric" placeholder="Rp" autocomplete="off" onpaste="amendTempel(event, this)"></td>'
                    + '<td class="p-1.5"><input class="amend-alasan w-full px-3 py-2 border border-amber-300 rounded-lg text-xs bg-white" placeholder="Alasan baris ini" autocomplete="off" onpaste="amendTempel(event, this)"></td>'
                    + '<td class="p-1.5 text-[11px] leading-snug amend-info text-gray-400">-</td>'
                    + '<td class="p-1.5 text-center"><button type="button" title="Hapus baris" onclick="amendHapusBaris(this)" class="text-gray-400 hover:text-red-600"><i class="fas fa-xmark"></i></button></td></tr>';
            }

            function amendTambahBaris(n) {
                const tb = document.getElementById('amendBaris');
                if (!tb) return null;
                let akhir = null;
                for (let i = 0; i < (n || 1); i++) {
                    if (tb.querySelectorAll('.amend-baris').length >= AMEND_MAKS) { showNotification('Maksimal ' + AMEND_MAKS + ' dokumen sekali Amend.', 'warning'); break; }
                    tb.insertAdjacentHTML('beforeend', amendBarisHtml());
                    akhir = tb.lastElementChild;
                }
                return akhir;
            }

            function amendHapusBaris(btn) {
                const tb = document.getElementById('amendBaris');
                btn.closest('tr').remove();
                if (tb && tb.querySelectorAll('.amend-baris').length === 0) amendTambahBaris();
            }

            const AMEND_KOLOM = ['.amend-doc', '.amend-cb', '.amend-alasan'];

            // Copas dari Excel: baris dipisah enter, kolom dipisah tab. Ditempel mulai dari kolom dan
            // baris tempat kursor berada - jadi satu kolom (mis. hanya Net CB Baru) juga bisa.
            function amendTempel(ev, input) {
                const teks = (ev.clipboardData || window.clipboardData || { getData: () => '' }).getData('text');
                if (!/[\r\n\t]/.test(teks)) return;
                ev.preventDefault();
                const baris = teks.replace(/\r?\n$/, '').split(/\r?\n/).map(l => l.split('\t'));
                const kolomAwal = AMEND_KOLOM.findIndex(k => input.matches(k));
                let tr = input.closest('tr');
                baris.forEach(function (k, i) {
                    if (i > 0) { tr = tr.nextElementSibling || amendTambahBaris(); }
                    if (!tr) return;
                    k.forEach(function (nilai, j) {
                        const sel = AMEND_KOLOM[kolomAwal + j];
                        if (sel) tr.querySelector(sel).value = String(nilai || '').trim();
                    });
                });
                if (kolomAwal === 0) { amendInfo = {}; amendCekSemua(); }
            }

            // Template Excel: No Doc, Net CB Baru, Alasan. No Doc berformat teks supaya Excel tidak
            // mengubahnya; contoh pengisian ada di lembar Petunjuk, bukan di lembar data.
            function amendUnduhTemplate() {
                const wb = XLSX.utils.book_new();
                const ws = XLSX.utils.aoa_to_sheet([['No Doc', 'Net CB Baru', 'Alasan']]);
                ws['!cols'] = [{ wch: 30 }, { wch: 16 }, { wch: 45 }];
                for (let r = 2; r <= 201; r++) { const ref = 'A' + r; ws[ref] = { t: 's', v: '', z: '@' }; }
                ws['!ref'] = 'A1:C201';
                XLSX.utils.book_append_sheet(wb, ws, 'Amend Doc');
                const p = XLSX.utils.aoa_to_sheet([
                    ['Petunjuk Amend Doc'], [''],
                    ['Kolom', 'Wajib', 'Keterangan'],
                    ['No Doc', 'Ya', 'Nomor dokumen, dari status apa pun.'],
                    ['Net CB Baru', 'Ya', 'Angka rupiah tanpa desimal, mis. 3613544 atau 3.613.544.'],
                    ['Alasan', 'Ya*', '*Boleh kosong bila Alasan umum diisi di layar.'], [''],
                    ['Contoh', '', ''], ['NPC/CMP/MDN/CM10/30113', '1622296', 'Salah input nominal (kelebihan x1000)'],
                    [''], ['Maksimal 200 dokumen sekali Amend. Seluruh baris diperiksa dulu; satu baris salah, tidak ada yang diubah.']]);
                p['!cols'] = [{ wch: 30 }, { wch: 10 }, { wch: 70 }];
                XLSX.utils.book_append_sheet(wb, p, 'Petunjuk');
                XLSX.writeFile(wb, 'Template_Amend_Doc.xlsx');
            }

            function amendUnggahTemplate(input) {
                const file = input.files && input.files[0];
                if (!file) return;
                const reader = new FileReader();
                reader.onload = async function (e) {
                    try {
                        const wb = XLSX.read(new Uint8Array(e.target.result), { type: 'array' });
                        const nama = wb.SheetNames.find(n => /amend/i.test(n)) || wb.SheetNames[0];
                        const rows = XLSX.utils.sheet_to_json(wb.Sheets[nama], { header: 1, defval: '', raw: true });
                        const hIdx = rows.findIndex(r => (r || []).some(c => /^no\.?\s*doc/i.test(String(c || '').trim())));
                        if (hIdx < 0) { showNotification('Kolom "No Doc" tidak ditemukan. Gunakan Unduh Template.', 'error'); return; }
                        const h = rows[hIdx].map(c => String(c || '').trim().toLowerCase());
                        const iDoc = h.findIndex(c => /^no\.?\s*doc/.test(c));
                        const iCb = h.findIndex(c => /net\s*cb|cb\s*net|cashback/.test(c));
                        const iAl = h.findIndex(c => /alasan|reason/.test(c));
                        if (iCb < 0) { showNotification('Kolom "Net CB Baru" tidak ditemukan. Gunakan Unduh Template.', 'error'); return; }
                        const data = rows.slice(hIdx + 1).filter(r => String(rcCellText((r || [])[iDoc]) || '').trim() !== '');
                        if (data.length === 0) { showNotification('Tidak ada baris data pada berkas.', 'warning'); return; }
                        if (data.length > AMEND_MAKS) { showNotification('Maksimal ' + AMEND_MAKS + ' dokumen sekali Amend; berkas berisi ' + data.length + ' baris.', 'error'); return; }
                        const tb = document.getElementById('amendBaris');
                        tb.innerHTML = ''; amendInfo = {};
                        amendTambahBaris(data.length);
                        [...tb.querySelectorAll('.amend-baris')].forEach(function (tr, i) {
                            const r = data[i];
                            tr.querySelector('.amend-doc').value = String(rcCellText(r[iDoc]) || '').trim();
                            tr.querySelector('.amend-cb').value = String(rcCellText(r[iCb]) || '').trim();
                            tr.querySelector('.amend-alasan').value = iAl < 0 ? '' : String(rcCellText(r[iAl]) || '').trim();
                        });
                        showNotification(data.length + ' baris dimuat dari template. Periksa info dokumen, lalu Proses Amend.', 'success');
                        await amendCekSemua();
                    } catch (err) { showNotification('Berkas tidak dapat dibaca.', 'error'); }
                    finally { input.value = ''; }
                };
                reader.readAsArrayBuffer(file);
            }

            function amendTulisInfo(tr, info) {
                const el = tr.querySelector('.amend-info');
                if (!info) { el.className = 'p-1.5 text-[11px] leading-snug amend-info text-gray-400'; el.innerHTML = '-'; return; }
                if (info.galat) { el.className = 'p-1.5 text-[11px] leading-snug amend-info text-red-600 font-bold'; el.textContent = info.galat; return; }
                el.className = 'p-1.5 text-[11px] leading-snug amend-info text-gray-700';
                el.innerHTML = '<span class="' + rcStatusClass(info.statusDok) + ' px-1.5 py-0.5 rounded text-[9px] uppercase font-bold">' + rcEsc(info.statusDok) + '</span> '
                    + rcEsc(info.kodeDepot) + ' &middot; Net CB sekarang <b class="text-red-600">' + rcMoney(info.cbNet) + '</b><br>'
                    + rcEsc(info.kodeToko + ' - ' + info.namaToko)
                    + (info.bisa ? '' : '<br><b class="text-red-600">Tidak dapat di-Amend: ' + rcEsc(info.sebab) + '</b>');
            }

            async function amendCekBaris(tr) {
                const noDoc = (tr.querySelector('.amend-doc').value || '').trim();
                if (!noDoc) { amendTulisInfo(tr, null); return null; }
                const kunci = noDoc.toUpperCase();
                if (!amendInfo[kunci]) {
                    try {
                        const res = await fetchApp({ action: 'amendCek', noDoc: noDoc });
                        amendInfo[kunci] = res.status === 'success' ? res : { galat: res.message || 'Dokumen tidak ditemukan.' };
                    } catch (e) { amendInfo[kunci] = { galat: 'Gagal terhubung ke server.' }; }
                }
                amendTulisInfo(tr, amendInfo[kunci]);
                return amendInfo[kunci];
            }

            async function amendCekSemua() {
                const baris = [...document.querySelectorAll('#amendBaris .amend-baris')];
                showLoadingOverlay('Memeriksa dokumen...');
                try { for (const tr of baris) await amendCekBaris(tr); }
                finally { hideLoadingOverlay(); }
            }

            async function prosesAmendDoc() {
                amendInfo = {};
                const baris = [...document.querySelectorAll('#amendBaris .amend-baris')]
                    .filter(tr => (tr.querySelector('.amend-doc').value || '').trim() !== '');
                if (baris.length === 0) { showNotification('Isi minimal satu No Doc.', 'warning'); return; }
                await amendCekSemua();
                const umum = (document.getElementById('amendAlasanUmum').value || '').trim();
                const masalah = [], items = [], ringkas = [], lihat = {};
                baris.forEach(function (tr) {
                    const noDoc = tr.querySelector('.amend-doc').value.trim();
                    const info = amendInfo[noDoc.toUpperCase()];
                    const baru = amendUraiAngka(tr.querySelector('.amend-cb').value);
                    const alasan = (tr.querySelector('.amend-alasan').value || '').trim();
                    if (lihat[noDoc.toUpperCase()]) { masalah.push(noDoc + ': No Doc ganda di daftar'); return; }
                    lihat[noDoc.toUpperCase()] = true;
                    if (!info || info.galat) { masalah.push(noDoc + ': ' + ((info && info.galat) || 'tidak ditemukan')); return; }
                    if (!info.bisa) { masalah.push(noDoc + ': ' + info.sebab); return; }
                    if (baru === null) { masalah.push(noDoc + ': Net CB baru wajib diisi dengan angka'); return; }
                    if (baru === Math.trunc(Number(info.cbNet))) { masalah.push(noDoc + ': Net CB baru sama dengan sekarang'); return; }
                    if (!alasan && !umum) { masalah.push(noDoc + ': alasan wajib diisi (per baris atau alasan umum)'); return; }
                    items.push({ noDoc: info.noDoc, cbNet: String(baru), versionNo: info.versionNo, alasan: alasan });
                    ringkas.push(info.noDoc + ' (' + info.statusDok + '): ' + rcMoney(info.cbNet) + ' -> ' + rcMoney(baru));
                });
                if (masalah.length) {
                    rcDialog('Amend belum bisa diproses', '<p class="text-sm mb-2">Perbaiki baris berikut; tidak ada yang diubah.</p><ul class="list-disc pl-5 text-sm text-red-700">'
                        + masalah.map(m => '<li>' + rcEsc(m) + '</li>').join('') + '</ul>');
                    return;
                }
                const setuju = await showConfirmModal({ title: 'Konfirmasi Amend Doc (' + items.length + ' dokumen)',
                    message: ringkas.slice(0, 15).join('\n') + (ringkas.length > 15 ? '\n... dan ' + (ringkas.length - 15) + ' lainnya' : '')
                        + '\n\nGross up dihitung ulang, status dokumen tidak berubah, dan email peringatan dikirim ke depot terkait.',
                    confirmText: 'Ya, Amend', danger: true });
                if (!setuju) return;
                setDisabledSafely('btnAmendProses', true);
                showLoadingOverlay('Memproses Amend...');
                try {
                    const res = await fetchApp({ action: 'amendDoc', items: items, alasan: umum });
                    if (res.status !== 'success') {
                        const daftar = String(res.message || 'Amend gagal.').split('; ');
                        if (daftar.length > 1) rcDialog('Amend dibatalkan', '<ul class="list-disc pl-5 text-sm text-red-700">' + daftar.map(m => '<li>' + rcEsc(m) + '</li>').join('') + '</ul>');
                        else showNotification(daftar[0], 'error');
                        amendInfo = {};
                        return;
                    }
                    // Log Activity: satu baris per proses ditulis server (amend_doc) - layar tidak menulis lagi.
                    showNotification(res.message, 'success');
                    amendKosongkan(); loadAmendRiwayat();
                } catch (e) { showNotification('Gagal terhubung ke server.', 'error'); }
                finally { setDisabledSafely('btnAmendProses', false); hideLoadingOverlay(); }
            }

            function amendKosongkan() {
                amendInfo = {};
                const tb = document.getElementById('amendBaris');
                if (tb) { tb.innerHTML = ''; amendTambahBaris(3); }
                const u = document.getElementById('amendAlasanUmum'); if (u) u.value = '';
            }

            async function loadAmendRiwayat() {
                const tb = document.getElementById('amendRiwayatBody');
                if (!tb) return;
                try {
                    const res = await fetchApp({ action: 'amendRiwayat', limit: 50 });
                    if (res.status !== 'success') throw new Error(res.message || 'Riwayat Amend gagal dimuat.');
                    tb.innerHTML = (res.rows || []).map(r => '<tr class="border-b border-gray-100">'
                        + '<td class="p-3 text-xs whitespace-nowrap">' + rcEsc(r.waktu) + '</td>'
                        + '<td class="p-3 font-mono text-xs font-black text-blue-700">' + rcEsc(r.noDoc) + '</td>'
                        + '<td class="p-3 text-xs">' + rcEsc(r.kodeDepot || '-') + '</td>'
                        + '<td class="p-3"><span class="' + rcStatusClass(r.statusDok) + ' px-2 py-0.5 rounded text-[10px] uppercase font-bold">' + rcEsc(r.statusDok) + '</span></td>'
                        + '<td class="p-3 text-right whitespace-nowrap">' + rcMoney(r.cbNetLama) + '</td>'
                        + '<td class="p-3 text-right whitespace-nowrap font-black text-red-600">' + rcMoney(r.cbNetBaru) + '</td>'
                        + '<td class="p-3 text-xs">' + rcEsc(r.alasan || '-') + '</td>'
                        + '<td class="p-3 text-xs">' + rcEsc(r.oleh || '-') + '</td></tr>').join('')
                        || '<tr><td colspan="8" class="p-6 text-center text-gray-400">Belum ada dokumen yang di-Amend.</td></tr>';
                } catch (e) { tb.innerHTML = '<tr><td colspan="8" class="p-6 text-center text-red-600">' + rcEsc(e.message) + '</td></tr>'; }
            }

            function bukaAmendDoc() {
                const tb = document.getElementById('amendBaris');
                if (tb && tb.querySelectorAll('.amend-baris').length === 0) amendKosongkan();
                loadAmendRiwayat();
            }
