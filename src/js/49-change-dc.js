            // ============================================================================
            // DOCUMENT CENTER - AMEND DOC > CHANGE DC (20261163810000, 20261163850000)
            // ============================================================================
            // Pemilik, 9 November 2026: memindahkan toko berdasarkan Kode Toko ke Depot Baru dengan
            // Reason. Master toko dan dokumen yang belum selesai pindah, No Doc mengikuti abbr depot
            // baru; Done dan Expired tetap di depot lama dengan Remark "DC changed". Log Activity,
            // riwayat dokumen, dan email dikerjakan server (rc_change_dc). Tanpa yurisdiksi.
            // 20261163850000: baris, template, dan tempel Excel sama seperti Change Value
            // (49-amend-doc.js). Server memeriksa seluruh baris dulu: satu salah = tidak ada yang dipindah.

            const CDC_MAKS = 200;
            const CDC_KOLOM = ['.cdc-kode', '.cdc-depot', '.cdc-reason'];
            let rcAmdSub = 'value', rcCdcDepot = [];

            // 20261163880000: sub bab ketiga Change Status (Expired -> Not Yet).
            const RC_AMD_SUB = {
                value:  { tab: 'amend',        panel: 'amdPanelValue',  tombol: 'amdSubValue',  buka: () => bukaAmendDoc() },
                dc:     { tab: 'changedc',     panel: 'amdPanelDc',     tombol: 'amdSubDc',     buka: () => bukaChangeDc() },
                status: { tab: 'changestatus', panel: 'amdPanelStatus', tombol: 'amdSubStatus', buka: () => bukaChangeStatus() }
            };
            function amdBuka() {
                const boleh = Object.keys(RC_AMD_SUB).filter(s => rcCanTab('compilation.' + RC_AMD_SUB[s].tab));
                amdSub(boleh.includes(rcAmdSub) ? rcAmdSub : (boleh[0] || 'value'));
            }
            function amdSub(sub) {
                if (!RC_AMD_SUB[sub] || !rcEnterTab('compilation', RC_AMD_SUB[sub].tab)) return;
                rcAmdSub = sub;
                Object.keys(RC_AMD_SUB).forEach(function (s) {
                    setHiddenSafely(RC_AMD_SUB[s].panel, s !== sub);
                    const el = document.getElementById(RC_AMD_SUB[s].tombol);
                    if (el) el.className = 'px-4 py-1.5 text-sm font-bold rounded-lg transition ' + (s === sub ? 'bg-amber-100 text-amber-800' : 'text-gray-500 hover:bg-gray-100');
                });
                RC_AMD_SUB[sub].buka();
            }

            function cdcBarisHtml() {
                const masukan = 'w-full px-3 py-2 border border-cyan-300 rounded-lg text-xs bg-white';
                return '<tr class="cdc-baris border-t border-cyan-200">'
                    + '<td class="p-1.5"><input class="cdc-kode ' + masukan + ' font-mono" placeholder="Kode Toko" autocomplete="off" onchange="cdcCekBaris(this.closest(\'tr\'))" onpaste="cdcTempel(event, this)"></td>'
                    + '<td class="p-1.5"><input class="cdc-depot ' + masukan + '" list="cdcDepotPilihan" placeholder="Kode Depot" autocomplete="off" onchange="cdcCekBaris(this.closest(\'tr\'))" onpaste="cdcTempel(event, this)"></td>'
                    + '<td class="p-1.5"><input class="cdc-reason ' + masukan + '" maxlength="500" placeholder="Reason baris ini" autocomplete="off" onpaste="cdcTempel(event, this)"></td>'
                    + '<td class="p-1.5 text-[11px] leading-snug cdc-info text-gray-400">-</td>'
                    + '<td class="p-1.5 text-center"><button type="button" title="Hapus baris" onclick="cdcHapusBaris(this)" class="text-gray-400 hover:text-red-600"><i class="fas fa-xmark"></i></button></td></tr>';
            }

            function cdcTambahBaris(n) {
                const tb = document.getElementById('cdcBaris');
                if (!tb) return null;
                let akhir = null;
                for (let i = 0; i < (n || 1); i++) {
                    if (tb.querySelectorAll('.cdc-baris').length >= CDC_MAKS) { showNotification('Maksimal ' + CDC_MAKS + ' toko sekali proses.', 'warning'); break; }
                    tb.insertAdjacentHTML('beforeend', cdcBarisHtml());
                    akhir = tb.lastElementChild;
                }
                return akhir;
            }

            function cdcHapusBaris(btn) {
                const tb = document.getElementById('cdcBaris');
                btn.closest('tr').remove();
                if (tb && tb.querySelectorAll('.cdc-baris').length === 0) cdcTambahBaris();
            }

            // Copas dari Excel: baris dipisah enter, kolom dipisah tab. Ditempel mulai dari kolom dan
            // baris tempat kursor berada, jadi satu kolom saja (mis. hanya Depot Baru) juga bisa.
            function cdcTempel(ev, input) {
                const teks = (ev.clipboardData || window.clipboardData || { getData: () => '' }).getData('text');
                if (!/[\r\n\t]/.test(teks)) return;
                ev.preventDefault();
                const baris = teks.replace(/\r?\n$/, '').split(/\r?\n/).map(l => l.split('\t'));
                const kolomAwal = CDC_KOLOM.findIndex(k => input.matches(k));
                let tr = input.closest('tr');
                baris.forEach(function (k, i) {
                    if (i > 0) { tr = tr && (tr.nextElementSibling || cdcTambahBaris()); }
                    if (!tr) return;
                    k.forEach(function (nilai, j) {
                        const sel = CDC_KOLOM[kolomAwal + j];
                        if (sel) tr.querySelector(sel).value = String(nilai || '').trim();
                    });
                });
                if (kolomAwal < 2) cdcCekSemua();
            }

            // Template Excel: Kode Toko, Depot Baru, Reason. Kode berformat teks supaya Excel tidak
            // mengubahnya; contoh ada di lembar Petunjuk dan kode depot di lembar Daftar Depot.
            function cdcUnduhTemplate() {
                const wb = XLSX.utils.book_new();
                const ws = XLSX.utils.aoa_to_sheet([['Kode Toko', 'Depot Baru', 'Reason']]);
                ws['!cols'] = [{ wch: 18 }, { wch: 16 }, { wch: 50 }];
                for (let r = 2; r <= CDC_MAKS + 1; r++) { ['A', 'B'].forEach(k => { ws[k + r] = { t: 's', v: '', z: '@' }; }); }
                ws['!ref'] = 'A1:C' + (CDC_MAKS + 1);
                XLSX.utils.book_append_sheet(wb, ws, 'Change DC');
                const p = XLSX.utils.aoa_to_sheet([
                    ['Petunjuk Change DC'], [''],
                    ['Kolom', 'Wajib', 'Keterangan'],
                    ['Kode Toko', 'Ya', 'Kode toko di Customer Master.'],
                    ['Depot Baru', 'Ya', 'Kode depot tujuan, lihat lembar Daftar Depot.'],
                    ['Reason', 'Ya*', '*Boleh kosong bila Reason umum diisi di layar.'], [''],
                    ['Contoh', '', ''], ['628401', '1A', 'Toko pindah area layanan'], [''],
                    ['Master toko dan dokumen yang belum selesai pindah, No Doc mengikuti abbr depot baru. Done dan Expired tetap di depot lama dengan Remark DC changed.'],
                    ['Maksimal ' + CDC_MAKS + ' toko sekali proses. Seluruh baris diperiksa dulu; satu baris salah, tidak ada yang dipindah.']]);
                p['!cols'] = [{ wch: 18 }, { wch: 10 }, { wch: 70 }];
                XLSX.utils.book_append_sheet(wb, p, 'Petunjuk');
                const d = XLSX.utils.aoa_to_sheet([['Kode Depot', 'Nama Depot']].concat(rcCdcDepot.map(x => [x.kode, x.nama])));
                d['!cols'] = [{ wch: 12 }, { wch: 36 }];
                XLSX.utils.book_append_sheet(wb, d, 'Daftar Depot');
                XLSX.writeFile(wb, 'Template_Change_DC.xlsx');
            }

            function cdcUnggahTemplate(input) {
                const file = input.files && input.files[0];
                if (!file) return;
                const reader = new FileReader();
                reader.onload = async function (e) {
                    try {
                        const wb = XLSX.read(new Uint8Array(e.target.result), { type: 'array' });
                        const nama = wb.SheetNames.find(n => /change\s*dc/i.test(n)) || wb.SheetNames[0];
                        const rows = XLSX.utils.sheet_to_json(wb.Sheets[nama], { header: 1, defval: '', raw: true });
                        const polaToko = /^(kode|code)\s*(toko|cust)|^cust(omer)?\s*code/;
                        const hIdx = rows.findIndex(r => (r || []).some(c => polaToko.test(String(c || '').trim().toLowerCase())));
                        if (hIdx < 0) { showNotification('Kolom "Kode Toko" tidak ditemukan. Gunakan Unduh Template.', 'error'); return; }
                        const h = rows[hIdx].map(c => String(c || '').trim().toLowerCase());
                        const iToko = h.findIndex(c => polaToko.test(c));
                        const iDepot = h.findIndex(c => /depot|new\s*dc|dc\s*baru/.test(c));
                        const iReason = h.findIndex(c => /reason|alasan/.test(c));
                        if (iDepot < 0) { showNotification('Kolom "Depot Baru" tidak ditemukan. Gunakan Unduh Template.', 'error'); return; }
                        const sel = (r, i) => String(rcCellText((r || [])[i]) || '').trim();
                        const data = rows.slice(hIdx + 1).filter(r => sel(r, iToko) !== '' || sel(r, iDepot) !== '');
                        if (data.length === 0) { showNotification('Tidak ada baris data pada berkas.', 'warning'); return; }
                        if (data.length > CDC_MAKS) { showNotification('Maksimal ' + CDC_MAKS + ' toko sekali proses; berkas berisi ' + data.length + ' baris.', 'error'); return; }
                        const tb = document.getElementById('cdcBaris');
                        tb.innerHTML = '';
                        cdcTambahBaris(data.length);
                        [...tb.querySelectorAll('.cdc-baris')].forEach(function (tr, i) {
                            tr.querySelector('.cdc-kode').value = sel(data[i], iToko);
                            tr.querySelector('.cdc-depot').value = sel(data[i], iDepot);
                            tr.querySelector('.cdc-reason').value = iReason < 0 ? '' : sel(data[i], iReason);
                        });
                        showNotification(data.length + ' baris dimuat dari template. Periksa info toko, lalu Proses Change DC.', 'success');
                        await cdcCekSemua();
                    } catch (err) { showNotification('Berkas tidak dapat dibaca.', 'error'); }
                    finally { input.value = ''; }
                };
                reader.readAsArrayBuffer(file);
            }

            function cdcTulisInfo(tr, info) {
                const el = tr.querySelector('.cdc-info');
                if (!info) { el.className = 'p-1.5 text-[11px] leading-snug cdc-info text-gray-400'; el.innerHTML = '-'; return; }
                if (info.galat) { el.className = 'p-1.5 text-[11px] leading-snug cdc-info text-red-600 font-bold'; el.textContent = (info.namaToko ? info.namaToko + ': ' : '') + info.galat; return; }
                el.className = 'p-1.5 text-[11px] leading-snug cdc-info text-gray-700';
                el.innerHTML = '<b>' + rcEsc(info.namaToko || '') + '</b> &rarr; ' + rcEsc(info.depotBaru) + ' (No Doc ' + rcEsc(info.abbrBaru) + ')'
                    + (info.asal || []).map(a => '<br>' + rcEsc(a.kode + ' - ' + a.nama) + ': ' + Number(a.aktif).toLocaleString('id-ID') + ' dokumen pindah, CB <b>' + rcEsc(rcNominalPenuh(a.cb)) + '</b>, '
                        + Number(a.selesai).toLocaleString('id-ID') + ' Done / Expired tetap').join('');
            }

            const cdcIsi = (tr, sel) => (tr.querySelector(sel).value || '').trim();
            const cdcTerisi = () => [...document.querySelectorAll('#cdcBaris .cdc-baris')].filter(tr => cdcIsi(tr, '.cdc-kode') !== '' || cdcIsi(tr, '.cdc-depot') !== '');

            // Satu panggilan server untuk seluruh baris yang diminta, bukan satu per baris.
            async function cdcPeriksa(baris) {
                const res = await fetchApp({ action: 'changeDcCek', items: baris.map(tr => ({ kodeToko: cdcIsi(tr, '.cdc-kode'), depotBaru: cdcIsi(tr, '.cdc-depot') })) });
                if (res.status !== 'success') throw new Error(res.message || 'Pemeriksaan gagal.');
                return res.rows || [];
            }

            // Baris yang baru terisi separuh belum diperiksa, supaya tidak langsung merah saat mengetik.
            async function cdcCekBaris(tr) {
                if (cdcIsi(tr, '.cdc-kode') === '' || cdcIsi(tr, '.cdc-depot') === '') { cdcTulisInfo(tr, null); return; }
                try { cdcTulisInfo(tr, (await cdcPeriksa([tr]))[0]); }
                catch (e) { cdcTulisInfo(tr, { galat: (e && e.message) || 'Gagal terhubung ke server.' }); }
            }

            // Mengembalikan [{ tr, info }] untuk baris yang terisi, atau null bila pemeriksaan gagal.
            async function cdcCekSemua() {
                const baris = cdcTerisi();
                [...document.querySelectorAll('#cdcBaris .cdc-baris')].forEach(tr => { if (!baris.includes(tr)) cdcTulisInfo(tr, null); });
                if (baris.length === 0) return [];
                showLoadingOverlay('Memeriksa toko...');
                try {
                    const rows = await cdcPeriksa(baris);
                    baris.forEach((tr, i) => cdcTulisInfo(tr, rows[i]));
                    return baris.map((tr, i) => ({ tr: tr, info: rows[i] }));
                } catch (e) { showNotification((e && e.message) || 'Pemeriksaan gagal.', 'error'); return null; }
                finally { hideLoadingOverlay(); }
            }

            // Galat banyak baris dari server dipisah "; ".
            function cdcTampilGalat(pesan) {
                const daftar = String(pesan || 'Change DC gagal.').split('; ');
                if (daftar.length > 1) rcDialog('Change DC dibatalkan', '<ul class="list-disc pl-5 text-sm text-red-700">' + daftar.map(m => '<li>' + rcEsc(m) + '</li>').join('') + '</ul>');
                else showNotification(daftar[0], 'error');
            }

            async function cdcProses() {
                if (cdcTerisi().length === 0) { showNotification('Isi minimal satu Kode Toko dan Depot Baru.', 'warning'); return; }
                const hasil = await cdcCekSemua();
                if (!hasil) return;
                const umum = (document.getElementById('cdcReasonUmum').value || '').trim();
                const masalah = [], items = [], ringkas = [], lihat = new Set();
                hasil.forEach(function (x) {
                    const kode = cdcIsi(x.tr, '.cdc-kode'), reason = cdcIsi(x.tr, '.cdc-reason');
                    const label = kode || '(Kode Toko kosong)', kunci = kode.toUpperCase();
                    if (kunci && lihat.has(kunci)) { masalah.push(label + ': Kode Toko ganda di daftar'); return; }
                    lihat.add(kunci);
                    if (x.info.galat) { masalah.push(label + ': ' + x.info.galat); return; }
                    const dipakai = reason || umum;
                    if (dipakai.length < 3) { masalah.push(label + ': Reason wajib diisi (per baris atau Reason umum, minimal 3 karakter)'); return; }
                    if (dipakai.length > 500) { masalah.push(label + ': Reason terlalu panjang (maksimal 500 karakter)'); return; }
                    items.push({ kodeToko: x.info.kodeToko, depotBaru: x.info.depotKode, reason: reason });
                    ringkas.push(x.info.kodeToko + ' - ' + (x.info.namaToko || '') + ': ' + x.info.asal.map(a => a.kode).join(', ') + ' -> ' + x.info.depotKode);
                });
                if (masalah.length) {
                    rcDialog('Change DC belum bisa diproses', '<p class="text-sm mb-2">Perbaiki baris berikut; tidak ada toko yang dipindah.</p><ul class="list-disc pl-5 text-sm text-red-700">'
                        + masalah.map(m => '<li>' + rcEsc(m) + '</li>').join('') + '</ul>');
                    return;
                }
                const setuju = await showConfirmModal({ title: 'Konfirmasi Change DC (' + items.length + ' toko)',
                    message: ringkas.slice(0, 15).join('\n') + (ringkas.length > 15 ? '\n... dan ' + (ringkas.length - 15) + ' lainnya' : '')
                        + '\n\nDepot asal tidak lagi memiliki akses terhadap dokumen yang belum selesai. Email dikirim ke depot asal dan depot tujuan.',
                    confirmText: 'Ya, Pindahkan', danger: true });
                if (!setuju) return;
                setDisabledSafely('btnCdcProses', true);
                showLoadingOverlay('Memindahkan toko...');
                try {
                    const res = await fetchApp({ action: 'changeDc', items: items, reason: umum });
                    if (res.status !== 'success') { cdcTampilGalat(res.message); return; }
                    showNotification(res.message, 'success');
                    cdcKosongkan();
                    bukaChangeDc();
                } catch (e) { cdcTampilGalat(e && e.message); }
                finally { setDisabledSafely('btnCdcProses', false); hideLoadingOverlay(); }
            }

            function cdcKosongkan() {
                const tb = document.getElementById('cdcBaris');
                if (tb) { tb.innerHTML = ''; cdcTambahBaris(3); }
                const u = document.getElementById('cdcReasonUmum'); if (u) u.value = '';
            }

            async function bukaChangeDc() {
                const baris = document.getElementById('cdcBaris');
                if (baris && baris.querySelectorAll('.cdc-baris').length === 0) cdcKosongkan();
                const tb = document.getElementById('cdcRiwayatBody');
                try {
                    const res = await fetchApp({ action: 'changeDcRiwayat' });
                    if (res.status !== 'success') throw new Error(res.message || 'Riwayat Change DC gagal dimuat.');
                    rcCdcDepot = res.depot || [];
                    const pilihan = document.getElementById('cdcDepotPilihan');
                    if (pilihan) pilihan.innerHTML = rcCdcDepot.map(d => '<option value="' + rcEsc(d.kode) + '">' + rcEsc(d.kode + ' - ' + d.nama) + '</option>').join('');
                    tb.innerHTML = (res.rows || []).map(r => '<tr class="border-b border-gray-100">'
                        + '<td class="p-3 text-xs whitespace-nowrap">' + rcEsc(r.waktu) + '</td>'
                        + '<td class="p-3 text-xs"><b class="font-mono">' + rcEsc(r.kodeToko) + '</b><br><span class="text-gray-500">' + rcEsc(r.namaToko) + '</span></td>'
                        + '<td class="p-3 text-xs">' + rcEsc(r.dari || '-') + '</td><td class="p-3 text-xs font-bold">' + rcEsc(r.ke || '-') + '</td>'
                        + '<td class="p-3 text-xs text-gray-600">' + rcEsc(r.detail || '') + '</td><td class="p-3 text-xs">' + rcEsc(r.reason || '-') + '</td>'
                        + '<td class="p-3 text-xs">' + rcEsc(r.oleh || '-') + '</td></tr>').join('')
                        || '<tr><td colspan="7" class="p-6 text-center text-gray-400">Belum ada toko yang dipindahkan.</td></tr>';
                } catch (e) { tb.innerHTML = '<tr><td colspan="7" class="p-6 text-center text-red-600">' + rcEsc(e.message) + '</td></tr>'; }
            }
