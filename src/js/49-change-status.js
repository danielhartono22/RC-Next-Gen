            // ============================================================================
            // DOCUMENT CENTER - AMEND DOC > CHANGE STATUS (20261163880000)
            // ============================================================================
            // Pemilik, 10 November 2026: "untuk ubah status dari expired ke not yet di amend doc buat
            // sama seperti change value dengan nama Change Status, ini hanya bisa dari expired ke not
            // yet jika dimasukan no doc nya akan berubah jadi not yet."
            // Baris, template, dan tempel Excel mengikuti Change Value (49-amend-doc.js). Server
            // (rc_change_status) memeriksa seluruh baris dulu: satu salah = tidak ada yang diubah.
            // Expired milik campaign Closed sudah final dan ditolak.

            const CST_MAKS = 200;
            const CST_KOLOM = ['.cst-doc', '.cst-alasan'];

            function cstBarisHtml() {
                const masukan = 'w-full px-3 py-2 border border-rose-300 rounded-lg text-xs bg-white';
                return '<tr class="cst-baris border-t border-rose-200">'
                    + '<td class="p-1.5"><input class="cst-doc ' + masukan + ' font-mono" placeholder="No Doc" autocomplete="off" onchange="cstCekBaris(this.closest(\'tr\'))" onpaste="cstTempel(event, this)"></td>'
                    + '<td class="p-1.5"><input class="cst-alasan ' + masukan + '" maxlength="300" placeholder="Alasan baris ini" autocomplete="off" onpaste="cstTempel(event, this)"></td>'
                    + '<td class="p-1.5 text-[11px] leading-snug cst-info text-gray-400">-</td>'
                    + '<td class="p-1.5 text-center"><button type="button" title="Hapus baris" onclick="cstHapusBaris(this)" class="text-gray-400 hover:text-red-600"><i class="fas fa-xmark"></i></button></td></tr>';
            }

            function cstTambahBaris(n) {
                const tb = document.getElementById('cstBaris');
                if (!tb) return null;
                let akhir = null;
                for (let i = 0; i < (n || 1); i++) {
                    if (tb.querySelectorAll('.cst-baris').length >= CST_MAKS) { showNotification('Maksimal ' + CST_MAKS + ' dokumen sekali proses.', 'warning'); break; }
                    tb.insertAdjacentHTML('beforeend', cstBarisHtml());
                    akhir = tb.lastElementChild;
                }
                return akhir;
            }

            function cstHapusBaris(btn) {
                const tb = document.getElementById('cstBaris');
                btn.closest('tr').remove();
                if (tb && tb.querySelectorAll('.cst-baris').length === 0) cstTambahBaris();
            }

            // Copas dari Excel: baris dipisah enter, kolom dipisah tab, mulai dari kolom dan baris kursor.
            function cstTempel(ev, input) {
                const teks = (ev.clipboardData || window.clipboardData || { getData: () => '' }).getData('text');
                if (!/[\r\n\t]/.test(teks)) return;
                ev.preventDefault();
                const baris = teks.replace(/\r?\n$/, '').split(/\r?\n/).map(l => l.split('\t'));
                const kolomAwal = CST_KOLOM.findIndex(k => input.matches(k));
                let tr = input.closest('tr');
                baris.forEach(function (k, i) {
                    if (i > 0) { tr = tr && (tr.nextElementSibling || cstTambahBaris()); }
                    if (!tr) return;
                    k.forEach(function (nilai, j) {
                        const sel = CST_KOLOM[kolomAwal + j];
                        if (sel) tr.querySelector(sel).value = String(nilai || '').trim();
                    });
                });
                if (kolomAwal === 0) cstCekSemua();
            }

            // Template Excel: No Doc (teks) dan Alasan; contoh di lembar Petunjuk.
            function cstUnduhTemplate() {
                const wb = XLSX.utils.book_new();
                const ws = XLSX.utils.aoa_to_sheet([['No Doc', 'Alasan']]);
                ws['!cols'] = [{ wch: 30 }, { wch: 50 }];
                for (let r = 2; r <= CST_MAKS + 1; r++) ws['A' + r] = { t: 's', v: '', z: '@' };
                ws['!ref'] = 'A1:B' + (CST_MAKS + 1);
                XLSX.utils.book_append_sheet(wb, ws, 'Change Status');
                const p = XLSX.utils.aoa_to_sheet([
                    ['Petunjuk Change Status'], [''],
                    ['Kolom', 'Wajib', 'Keterangan'],
                    ['No Doc', 'Ya', 'Nomor dokumen berstatus Expired.'],
                    ['Alasan', 'Ya*', '*Boleh kosong bila Alasan umum diisi di layar.'], [''],
                    ['Contoh', '', ''], ['NPC/CMP/MDN/CA10/30113', 'Expired keliru, toko masih berhak', ''], [''],
                    ['Hanya Expired yang dapat dikembalikan ke Not Yet. Expired milik campaign Closed sudah final.'],
                    ['Maksimal ' + CST_MAKS + ' dokumen sekali proses. Seluruh baris diperiksa dulu; satu baris salah, tidak ada yang diubah.']]);
                p['!cols'] = [{ wch: 30 }, { wch: 10 }, { wch: 70 }];
                XLSX.utils.book_append_sheet(wb, p, 'Petunjuk');
                XLSX.writeFile(wb, 'Template_Change_Status.xlsx');
            }

            function cstUnggahTemplate(input) {
                const file = input.files && input.files[0];
                if (!file) return;
                const reader = new FileReader();
                reader.onload = async function (e) {
                    try {
                        const wb = XLSX.read(new Uint8Array(e.target.result), { type: 'array' });
                        const nama = wb.SheetNames.find(n => /change\s*status/i.test(n)) || wb.SheetNames[0];
                        const rows = XLSX.utils.sheet_to_json(wb.Sheets[nama], { header: 1, defval: '', raw: true });
                        const hIdx = rows.findIndex(r => (r || []).some(c => /^no\.?\s*doc/i.test(String(c || '').trim())));
                        if (hIdx < 0) { showNotification('Kolom "No Doc" tidak ditemukan. Gunakan Unduh Template.', 'error'); return; }
                        const h = rows[hIdx].map(c => String(c || '').trim().toLowerCase());
                        const iDoc = h.findIndex(c => /^no\.?\s*doc/.test(c));
                        const iAl = h.findIndex(c => /alasan|reason/.test(c));
                        const sel = (r, i) => i < 0 ? '' : String(rcCellText((r || [])[i]) || '').trim();
                        const data = rows.slice(hIdx + 1).filter(r => sel(r, iDoc) !== '');
                        if (data.length === 0) { showNotification('Tidak ada baris data pada berkas.', 'warning'); return; }
                        if (data.length > CST_MAKS) { showNotification('Maksimal ' + CST_MAKS + ' dokumen sekali proses; berkas berisi ' + data.length + ' baris.', 'error'); return; }
                        const tb = document.getElementById('cstBaris');
                        tb.innerHTML = '';
                        cstTambahBaris(data.length);
                        [...tb.querySelectorAll('.cst-baris')].forEach(function (tr, i) {
                            tr.querySelector('.cst-doc').value = sel(data[i], iDoc);
                            tr.querySelector('.cst-alasan').value = sel(data[i], iAl);
                        });
                        showNotification(data.length + ' baris dimuat dari template. Periksa info dokumen, lalu Proses Change Status.', 'success');
                        await cstCekSemua();
                    } catch (err) { showNotification('Berkas tidak dapat dibaca.', 'error'); }
                    finally { input.value = ''; }
                };
                reader.readAsArrayBuffer(file);
            }

            function cstTulisInfo(tr, info) {
                const el = tr.querySelector('.cst-info');
                if (!info) { el.className = 'p-1.5 text-[11px] leading-snug cst-info text-gray-400'; el.innerHTML = '-'; return; }
                if (info.galat) { el.className = 'p-1.5 text-[11px] leading-snug cst-info text-red-600 font-bold'; el.textContent = info.galat; return; }
                el.className = 'p-1.5 text-[11px] leading-snug cst-info text-gray-700';
                el.innerHTML = '<span class="' + rcStatusClass('Expired') + ' px-1.5 py-0.5 rounded text-[9px] uppercase font-bold">Expired</span> &rarr; '
                    + '<span class="' + rcStatusClass('Not Yet') + ' px-1.5 py-0.5 rounded text-[9px] uppercase font-bold">Not Yet</span> '
                    + rcEsc(info.kodeDepot) + ' &middot; Net CB <b>' + rcMoney(info.cbNet) + '</b><br>'
                    + rcEsc(info.kodeToko + ' - ' + info.namaToko) + ' &middot; ' + rcEsc(info.kodeCampaign);
            }

            const cstIsi = (tr, sel) => (tr.querySelector(sel).value || '').trim();
            const cstTerisi = () => [...document.querySelectorAll('#cstBaris .cst-baris')].filter(tr => cstIsi(tr, '.cst-doc') !== '');

            // Satu panggilan server untuk seluruh baris yang diminta.
            async function cstPeriksa(baris) {
                const res = await fetchApp({ action: 'changeStatusCek', items: baris.map(tr => ({ noDoc: cstIsi(tr, '.cst-doc') })) });
                if (res.status !== 'success') throw new Error(res.message || 'Pemeriksaan gagal.');
                return res.rows || [];
            }

            async function cstCekBaris(tr) {
                if (cstIsi(tr, '.cst-doc') === '') { cstTulisInfo(tr, null); return; }
                try { cstTulisInfo(tr, (await cstPeriksa([tr]))[0]); }
                catch (e) { cstTulisInfo(tr, { galat: (e && e.message) || 'Gagal terhubung ke server.' }); }
            }

            // Mengembalikan [{ tr, info }] untuk baris yang terisi, atau null bila pemeriksaan gagal.
            async function cstCekSemua() {
                const baris = cstTerisi();
                [...document.querySelectorAll('#cstBaris .cst-baris')].forEach(tr => { if (!baris.includes(tr)) cstTulisInfo(tr, null); });
                if (baris.length === 0) return [];
                showLoadingOverlay('Memeriksa dokumen...');
                try {
                    const rows = await cstPeriksa(baris);
                    baris.forEach((tr, i) => cstTulisInfo(tr, rows[i]));
                    return baris.map((tr, i) => ({ tr: tr, info: rows[i] }));
                } catch (e) { showNotification((e && e.message) || 'Pemeriksaan gagal.', 'error'); return null; }
                finally { hideLoadingOverlay(); }
            }

            function cstTampilGalat(pesan) {
                const daftar = String(pesan || 'Change Status gagal.').split('; ');
                if (daftar.length > 1) rcDialog('Change Status dibatalkan', '<ul class="list-disc pl-5 text-sm text-red-700">' + daftar.map(m => '<li>' + rcEsc(m) + '</li>').join('') + '</ul>');
                else showNotification(daftar[0], 'error');
            }

            async function cstProses() {
                if (cstTerisi().length === 0) { showNotification('Isi minimal satu No Doc.', 'warning'); return; }
                const hasil = await cstCekSemua();
                if (!hasil) return;
                const umum = (document.getElementById('cstAlasanUmum').value || '').trim();
                const masalah = [], items = [], ringkas = [], lihat = new Set();
                hasil.forEach(function (x) {
                    const doc = cstIsi(x.tr, '.cst-doc'), alasan = cstIsi(x.tr, '.cst-alasan'), kunci = doc.toUpperCase();
                    if (lihat.has(kunci)) { masalah.push(doc + ': No Doc ganda di daftar'); return; }
                    lihat.add(kunci);
                    if (x.info.galat) { masalah.push(doc + ': ' + x.info.galat); return; }
                    if ((alasan || umum).length < 3) { masalah.push(doc + ': alasan wajib diisi (per baris atau alasan umum, minimal 3 karakter)'); return; }
                    items.push({ noDoc: x.info.noDoc, alasan: alasan });
                    ringkas.push(x.info.noDoc + ' (' + x.info.kodeDepot + '): Expired -> Not Yet, ' + rcMoney(x.info.cbNet));
                });
                if (masalah.length) {
                    rcDialog('Change Status belum bisa diproses', '<p class="text-sm mb-2">Perbaiki baris berikut; tidak ada yang diubah.</p><ul class="list-disc pl-5 text-sm text-red-700">'
                        + masalah.map(m => '<li>' + rcEsc(m) + '</li>').join('') + '</ul>');
                    return;
                }
                const setuju = await showConfirmModal({ title: 'Konfirmasi Change Status (' + items.length + ' dokumen)',
                    message: ringkas.slice(0, 15).join('\n') + (ringkas.length > 15 ? '\n... dan ' + (ringkas.length - 15) + ' lainnya' : '')
                        + '\n\nDokumen kembali menjadi Not Yet dan dapat diproses lagi. Email dikirim ke depot terkait.',
                    confirmText: 'Ya, Ubah Status', danger: true });
                if (!setuju) return;
                setDisabledSafely('btnCstProses', true);
                showLoadingOverlay('Mengubah status...');
                try {
                    const res = await fetchApp({ action: 'changeStatus', items: items, alasan: umum });
                    if (res.status !== 'success') { cstTampilGalat(res.message); return; }
                    showNotification(res.message, 'success');
                    cstKosongkan();
                    bukaChangeStatus();
                } catch (e) { cstTampilGalat(e && e.message); }
                finally { setDisabledSafely('btnCstProses', false); hideLoadingOverlay(); }
            }

            function cstKosongkan() {
                const tb = document.getElementById('cstBaris');
                if (tb) { tb.innerHTML = ''; cstTambahBaris(3); }
                const u = document.getElementById('cstAlasanUmum'); if (u) u.value = '';
            }

            async function bukaChangeStatus() {
                const baris = document.getElementById('cstBaris');
                if (baris && baris.querySelectorAll('.cst-baris').length === 0) cstKosongkan();
                const tb = document.getElementById('cstRiwayatBody');
                try {
                    const res = await fetchApp({ action: 'changeStatusRiwayat' });
                    if (res.status !== 'success') throw new Error(res.message || 'Riwayat Change Status gagal dimuat.');
                    tb.innerHTML = (res.rows || []).map(r => '<tr class="border-b border-gray-100">'
                        + '<td class="p-3 text-xs whitespace-nowrap">' + rcEsc(r.waktu) + '</td>'
                        + '<td class="p-3 font-mono text-xs font-black text-blue-700">' + rcEsc(r.noDoc) + '</td>'
                        + '<td class="p-3 text-xs">' + rcEsc(r.kodeDepot || '-') + '</td>'
                        + '<td class="p-3 text-xs"><b class="font-mono">' + rcEsc(r.kodeToko || '') + '</b><br><span class="text-gray-500">' + rcEsc(r.namaToko || '') + '</span></td>'
                        + '<td class="p-3 text-xs">' + rcEsc(r.kodeCampaign || '-') + '</td>'
                        + '<td class="p-3 text-right whitespace-nowrap">' + rcMoney(r.cbNet) + '</td>'
                        + '<td class="p-3 text-xs">' + rcEsc(r.alasan || '-') + '</td>'
                        + '<td class="p-3 text-xs">' + rcEsc(r.oleh || '-') + '</td></tr>').join('')
                        || '<tr><td colspan="8" class="p-6 text-center text-gray-400">Belum ada dokumen yang diubah statusnya.</td></tr>';
                } catch (e) { tb.innerHTML = '<tr><td colspan="8" class="p-6 text-center text-red-600">' + rcEsc(e.message) + '</td></tr>'; }
            }
