            // ============================================================================
            // CLAIM UPLOAD - TAB RESTRICTED (20261163170000)
            // ============================================================================
            // Sejak 17 Oktober 2026 hanya klaim yang lunas (tawaran Upload Debtor) yang tampil di
            // Open dan dapat diajukan. Klaim Not Yet lainnya tampil di sini beserta alasannya.
            // Tab ini terlihat bawaan (hanya baca). Pemegang tab "Restricted (Editor)" dapat
            // memindahkannya ke Open (berlabel Restricted, boleh diajukan); Tandai / Cabut Bad
            // Debt memerlukan tab "Bad Debt (Tandai)"; Pindah ke Posting Exception boleh bagi
            // siapa saja tetapi hanya Expired - klaim Restricted tidak dapat di-On Hold.

            let rcRestrictedState = { offset: 0, rows: [], total: 0, opsi: {} };
            let rcRestrictedMuatKe = 0;
            const RESTRICTED_PER_HALAMAN = 200;

            function openRcRestrictedTab() {
                if (!rcEnterTab('upload', 'restricted')) return;
                currentUploadMode = 'restricted';
                ['tab_mass', 'tab_single', 'tab_open'].forEach(id => setHiddenSafely(id, true));
                setHiddenSafely('tab_restricted', false);
                const idle = 'px-5 py-2 text-sm font-bold rounded-lg text-gray-500 hover:bg-gray-100 transition';
                ['subnav_mass', 'subnav_single', 'subnav_open'].forEach(id => { const e = document.getElementById(id); if (e) e.className = idle; });
                const sr = document.getElementById('subnav_restricted');
                if (sr) sr.className = 'px-5 py-2 text-sm font-bold rounded-lg bg-slate-200 text-slate-800 transition';
                loadRestrictedClaims(0);
                rcZdSpanduk('rcZdMatiRestricted'); // 20261163620000
            }

            function restrictedCariOtomatis() { debounceSearch(() => loadRestrictedClaims(0), 500); }

            async function loadRestrictedClaims(offset) {
                const ke = ++rcRestrictedMuatKe;
                setHiddenSafely('restrictedMuat', false);
                try {
                    const res = await fetchApp({ action: 'restrictedClaims',
                        search: document.getElementById('restrictedSearch').value.trim(),
                        campaign: document.getElementById('restrictedCampaign').value,
                        cbType: document.getElementById('restrictedCbType').value, offset: offset });
                    if (ke !== rcRestrictedMuatKe) return;
                    if (res.status !== 'success') { showNotification(res.message || 'Gagal memuat.', 'error'); return; }
                    rcRestrictedState = { offset: offset, rows: res.rows || [], total: res.total || 0, opsi: res.opsi || rcRestrictedState.opsi || {} };
                    if (res.opsi) restrictedOpsiFilter(res.opsi);
                    renderRestrictedClaims();
                } catch (e) {
                    if (ke === rcRestrictedMuatKe) showNotification((e && e.message) ? e.message : 'Gagal memuat dokumen Restricted.', 'error');
                } finally { if (ke === rcRestrictedMuatKe) setHiddenSafely('restrictedMuat', true); }
            }

            function restrictedOpsiFilter(opsi) {
                const isi = function (id, semua, daftar) {
                    const sel = document.getElementById(id);
                    if (!sel) return;
                    const kini = sel.value;
                    sel.innerHTML = '<option value="">' + rcEsc(semua) + '</option>'
                        + (kini && !daftar.some(d => d.v === kini) ? '<option value="' + rcEsc(kini) + '">' + rcEsc(kini) + '</option>' : '')
                        + daftar.map(d => '<option value="' + rcEsc(d.v) + '">' + rcEsc(d.t) + '</option>').join('');
                    sel.value = kini;
                };
                isi('restrictedCampaign', '-- Semua Campaign --', (opsi.campaigns || []).map(c => ({ v: c.kode, t: c.kode + ' - ' + (c.nama || '') })));
                isi('restrictedCbType', 'Semua Jenis CB', (opsi.jenisCb || []).map(j => ({ v: j, t: j })));
                // Tombol mengikuti hak yang dihitung server (tab Editor dan Bad Debt).
                setHiddenSafely('btnRestrictedPindah', opsi.bolehPindah !== true);
                setHiddenSafely('btnRestrictedBadDebt', opsi.bolehBadDebt !== true);
                setHiddenSafely('btnRestrictedCabutBadDebt', opsi.bolehBadDebt !== true);
            }

            const RESTRICTED_WARNA = {
                'Bad Debt': 'bg-red-700 text-white',
                'Belum lunas': 'bg-red-100 text-red-700',
                'Periode salah': 'bg-amber-100 text-amber-800',
                'Dikembalikan depot': 'bg-gray-200 text-gray-700',
                'Tanpa Customer Master': 'bg-orange-100 text-orange-800'
            };

            // Rincian alasan, satu butir per baris (nomor aturan = skala prioritas, lihat Upload Debtor).
            function restrictedRincian(r) {
                const a = r.alasanRinci || {};
                if (r.alasan === 'Belum lunas') return (a.rincian || []).map(x => x.aturan + '. ' + (ZD_ATURAN[x.aturan] || '') + ': '
                    + (x.aturan === 1 ? '' : (x.bulan === 'jumlah' ? 'jumlah s/d Bulan Bill ' : zdLabelBulan(x.bulan) + ' ')) + rcNominalPenuh(x.nilai));
                if (r.alasan === 'Bad Debt') return [a.badDebt || ''];
                if (r.alasan === 'Dikembalikan depot') return [a.alasanKembali || ''];
                if (r.alasan === 'Periode salah') return [a.masalah === 'tanggal_salah' ? 'SO start sesudah Billing end di Campaign Master' : 'SO / Billing belum diisi di Campaign Master'];
                return [];
            }

            function renderRestrictedClaims() {
                const rows = rcRestrictedState.rows || [];
                document.getElementById('restrictedTableBody').innerHTML = rows.map(function (r, i) {
                    const warna = RESTRICTED_WARNA[r.alasan] || 'bg-gray-100 text-gray-700';
                    return '<tr class="border-b border-gray-100 hover:bg-slate-50 align-top">'
                        + '<td class="p-3 text-center"><input type="checkbox" class="cb-restricted w-4 h-4 rounded" data-idx="' + i + '" value="' + rcEsc(r.noDoc) + '" onchange="updateRestrictedSelection()"></td>'
                        + '<td class="p-3"><span class="font-black text-blue-700 whitespace-nowrap">' + rcEsc(r.noDoc) + '</span><span class="block text-[10px] text-gray-500">' + rcEsc(r.dcCode || '') + '</span></td>'
                        + '<td class="p-3 min-w-[220px]"><span class="inline-block px-2 py-0.5 rounded text-[10px] font-black whitespace-nowrap ' + warna + '">' + rcEsc(r.alasan || '-') + '</span>'
                          + restrictedRincian(r).filter(Boolean).map(t => '<div class="text-[11px] text-gray-600 leading-snug mt-0.5">' + rcEsc(t) + '</div>').join('')
                          + (r.dinilai ? '<div class="text-[10px] text-gray-400 mt-0.5">dinilai ' + rcEsc(r.dinilai) + '</div>' : '') + '</td>'
                        + '<td class="p-3 text-xs"><b>' + rcEsc(r.namaToko) + '</b>' + openLabelBadDebt(r) + '<br><span class="text-gray-500">' + rcEsc(r.kodeToko) + '</span></td>'
                        + '<td class="p-3 text-xs"><b>' + rcEsc(r.codeCampaign) + '</b><br><span class="text-gray-500">' + rcEsc(r.campaignName) + '</span></td>'
                        + '<td class="p-3 text-center text-xs font-bold">' + rcEsc(r.jenisCb || '-') + '</td>'
                        + '<td class="p-3 text-right font-black text-red-600 whitespace-nowrap" data-sort="' + Number(r.cbNet || 0) + '">' + rcMoney(r.cbNet) + '</td>'
                        + '<td class="p-3 text-center text-xs whitespace-nowrap">' + rcEsc(r.soStart || '-') + '<br>s/d ' + rcEsc(r.billingEnd || '-') + '</td>'
                        + '</tr>';
                }).join('') || '<tr><td colspan="8" class="p-8 text-center text-gray-500">Tidak ada dokumen Restricted.</td></tr>';
                const total = Number(rcRestrictedState.total) || 0;
                const awal = total === 0 ? 0 : rcRestrictedState.offset + 1;
                const akhir = Math.min(rcRestrictedState.offset + rows.length, total);
                document.getElementById('restrictedPager').innerHTML = '<div class="flex flex-wrap justify-between items-center gap-3 text-xs text-gray-600">'
                    + '<span>Menampilkan <b>' + awal.toLocaleString('id-ID') + ' - ' + akhir.toLocaleString('id-ID') + '</b> dari <b>' + total.toLocaleString('id-ID') + '</b> dokumen Restricted</span>'
                    + '<span class="flex gap-2"><button type="button" ' + (rcRestrictedState.offset > 0 ? '' : 'disabled ') + 'onclick="loadRestrictedClaims(' + Math.max(0, rcRestrictedState.offset - RESTRICTED_PER_HALAMAN) + ')" class="px-3 py-1.5 rounded-lg border border-gray-300 bg-white font-bold disabled:opacity-40"><i class="fas fa-chevron-left"></i></button>'
                    + '<button type="button" ' + (rcRestrictedState.offset + RESTRICTED_PER_HALAMAN < total ? '' : 'disabled ') + 'onclick="loadRestrictedClaims(' + (rcRestrictedState.offset + RESTRICTED_PER_HALAMAN) + ')" class="px-3 py-1.5 rounded-lg border border-gray-300 bg-white font-bold disabled:opacity-40"><i class="fas fa-chevron-right"></i></button></span></div>';
                rcPilihanPulihkan('cb-restricted', 'restrictedSelectAll');
                updateRestrictedSelection();
                rcAktifkanUrutSemua('tab_restricted');
            }

            function toggleAllRestricted(src) {
                const induk = src || document.getElementById('restrictedSelectAll');
                document.querySelectorAll('.cb-restricted').forEach(c => { c.checked = induk.checked; });
                updateRestrictedSelection();
            }
            function updateRestrictedSelection() {
                const n = rcPilihanSerap('cb-restricted', c => rcRestrictedState.rows[Number(c.dataset.idx)], 'restrictedSelectAll');
                document.getElementById('restrictedSelectedCount').innerText = n;
                const dipilih = rcSelectedRestrictedRows();
                setDisabledSafely('btnRestrictedPindah', n === 0);
                setDisabledSafely('btnRestrictedExpired', n === 0);
                setDisabledSafely('btnRestrictedUnduh', n === 0);
                setDisabledSafely('btnRestrictedBadDebt', !dipilih.some(r => !r.badDebt));
                setDisabledSafely('btnRestrictedCabutBadDebt', !dipilih.some(r => r.badDebt));
            }
            function rcSelectedRestrictedRows() { return rcPilihanData('cb-restricted').filter(Boolean); }

            async function restrictedPindahKeOpen() {
                const docs = rcSelectedRestrictedRows().map(r => r.noDoc);
                if (!docs.length) return;
                const alasan = await rcMintaAlasan('Pindah ke Open', docs.length + ' dokumen Restricted dipindah ke Open dan boleh diajukan, berlabel Restricted. '
                    + 'Tindakan ini tercatat di riwayat dokumen.', 'Pindah ke Open');
                if (alasan === null) return;
                try {
                    const res = await fetchApp({ action: 'restrictedPindah', docs: docs, alasan: alasan });
                    if (res.status !== 'success') throw new Error(res.message || 'Gagal memindahkan.');
                    showNotification(res.message, 'success');
                    rcPilihanKosongkan('cb-restricted', 'restrictedSelectAll');
                    loadRestrictedClaims(rcRestrictedState.offset || 0);
                } catch (e) { showNotification((e && e.message) ? e.message : 'Gagal memindahkan ke Open.', 'error'); }
            }

            async function restrictedTandaiBadDebt(tandai) {
                const rows = rcSelectedRestrictedRows().filter(r => tandai ? !r.badDebt : r.badDebt);
                if (!rows.length) return;
                const toko = Array.from(new Set(rows.map(r => r.kodeToko)));
                const alasan = await rcMintaAlasan(tandai ? 'Tandai Bad Debt' : 'Cabut Bad Debt',
                    toko.length + ' toko ' + (tandai ? 'ditandai Bad Debt.' : 'dicabut dari Bad Debt.'), tandai ? 'Tandai Bad Debt' : 'Cabut Bad Debt');
                if (alasan === null) return;
                try {
                    const res = await fetchApp({ action: tandai ? 'badDebtSet' : 'badDebtRevoke', docs: rows.map(r => r.noDoc), alasan: alasan });
                    if (res.status !== 'success') throw new Error(res.message || 'Gagal.');
                    showNotification(res.message, 'success');
                    rcPilihanKosongkan('cb-restricted', 'restrictedSelectAll');
                    loadRestrictedClaims(rcRestrictedState.offset || 0);
                } catch (e) { showNotification((e && e.message) ? e.message : 'Gagal menyimpan Bad Debt.', 'error'); }
            }

            // Ke Posting Exception, hanya Expired: grid Mass Upload dibuka dalam mode Posting
            // Exception dengan No Doc terisi; tombol On Hold ditolak untuk batch ini (server juga
            // menolak On Hold klaim Restricted).
            function restrictedKePostingException() {
                const picked = rcSelectedRestrictedRows();
                if (!picked.length) return;
                if (picked.length > 500) { showNotification('Maksimal 500 dokumen sekali pindah.', 'warning'); return; }
                switchSubTab('upload', 'mass');
                setPostingMode('exception');
                window.rcExcHanyaExpired = true;
                currentInputRows = picked.length;
                initInputGrid();
                const trs = document.getElementById('inputGridBody').querySelectorAll('.row-input');
                picked.forEach((r, i) => {
                    const tr = trs[i]; if (!tr) return;
                    const el = tr.querySelector('[name="noDoc"]');
                    if (el) el.value = r.noDoc;
                    if (typeof autoFillGridRowFromDoc === 'function') autoFillGridRowFromDoc(tr);
                });
                showNotification(picked.length + ' dokumen Restricted dipindah ke Posting Exception. Validasi lalu tekan Expired (On Hold tidak tersedia untuk dokumen Restricted).', 'success');
                rcPilihanKosongkan('cb-restricted', 'restrictedSelectAll');
            }

            function restrictedUnduhDipilih() {
                const dipilih = rcSelectedRestrictedRows();
                if (!dipilih.length) { showNotification('Centang dokumen yang akan diunduh lebih dulu.', 'warning'); return; }
                const aoa = [['No Document', 'Kode Depot', 'Alasan', 'Rincian', 'Kode Toko', 'Nama Toko', 'Kode Campaign', 'Nama Campaign', 'Jenis CB', 'Cashback', 'Start SO', 'End Billing']]
                    .concat(dipilih.map(r => [rcSelTeks(r.noDoc), rcSelTeks(r.dcCode), r.alasan || '', restrictedRincian(r).join('; '), rcSelTeks(r.kodeToko), r.namaToko || '',
                        rcSelTeks(r.codeCampaign), r.campaignName || '', r.jenisCb || '', Math.trunc(Number(r.cbNet) || 0), r.soStart || '', r.billingEnd || '']));
                const wb = XLSX.utils.book_new();
                XLSX.utils.book_append_sheet(wb, XLSX.utils.aoa_to_sheet(aoa), 'Restricted');
                XLSX.writeFile(wb, 'Restricted_' + new Date().toISOString().slice(0, 10) + '.xlsx');
                showNotification(dipilih.length.toLocaleString('id-ID') + ' dokumen diunduh.', 'success');
            }
