            // ==========================================================================================
            // Ad-Hoc Process (20261163440000): klaim berjenis Others sesudah approval. Per dokumen
            // (atau massal untuk yang dicentang) pengguna menentukan Jenis CB, Net CB, Tax Count, dan
            // tahap lanjutannya. Data antreannya ikut fetchWorkflowData (adhocData).
            // ==========================================================================================
            let globalAdhocData = [];
            // Isian yang sudah diketik, per No Doc. Bertahan saat tabel digambar ulang dan saat
            // Segarkan Data; dibuang setelah dokumennya diproses.
            const rcAhIsian = {};
            const RC_AH_JENIS = ['Transfer', 'CN', 'Voucher', 'Rebate', 'Rebate Manual'];

            // Angka tempelan Excel: "1.234.567", "1.234.567,89", "1,234,567.89", "Rp 1234567".
            // null bila bukan angka.
            function rcAhAngka(v) {
                let s = String(v === null || v === undefined ? '' : v).replace(/rp/i, '').replace(/\s/g, '');
                if (!s) return null;
                const titik = s.lastIndexOf('.'), koma = s.lastIndexOf(',');
                if (titik >= 0 && koma >= 0) {
                    s = titik > koma ? s.replace(/,/g, '') : s.replace(/\./g, '').replace(',', '.');
                } else if (/^-?\d{1,3}(\.\d{3})+$/.test(s)) {
                    s = s.replace(/\./g, '');
                } else if (/^-?\d{1,3}(,\d{3})+$/.test(s)) {
                    s = s.replace(/,/g, '');
                } else {
                    s = s.replace(',', '.');
                }
                if (!/^-?\d+(\.\d+)?$/.test(s)) return null;
                return Number(s);
            }

            // Label Jenis CB yang sah untuk Ad-Hoc (Others tidak boleh dipilih lagi); '' bila tidak sah.
            function rcAhJenisSah(v) {
                const label = rcCbLabel(String(v || '').trim());
                return RC_AH_JENIS.includes(label) ? label : '';
            }

            // Net CB ditampilkan seragam dengan pemisah ribuan; isian yang bukan angka dibiarkan apa
            // adanya supaya kolomnya tetap ditandai merah.
            function rcAhTeksCb(v) {
                const n = rcAhAngka(v);
                return n === null ? String(v === null || v === undefined ? '' : v).trim() : Math.trunc(n).toLocaleString('id-ID');
            }

            function rcAhIsianDari(r) {
                if (!rcAhIsian[r.noDoc]) {
                    // Dokumen yang kembali dari Claim to Finance membawa pilihan Ad-Hoc sebelumnya.
                    rcAhIsian[r.noDoc] = {
                        jenisCb: rcAhJenisSah(r.jenisCb),
                        cbNet: rcAhTeksCb(Number(r.cbNet) || 0),
                        pajak: r.adhocPajak === true,
                        claim: r.adhocLanjut === 'claim',
                        clearing: r.adhocLanjut === 'clearing'
                    };
                }
                return rcAhIsian[r.noDoc];
            }

            // Perkiraan Gross Up di layar, sama dengan rc_private.gross_up_adhoc. Angka yang disimpan
            // dan diunduh tetap hasil server.
            function rcAhGross(cb, subyek, jenis, pajak) {
                cb = Math.trunc(Number(cb) || 0);
                if (cb <= 0) return 0;
                if (!pajak) return cb;
                const j = rcCbLabel(jenis);
                if (j === 'Rebate' || j === 'Rebate Manual') return Math.floor(cb * 111 / 100);
                if (String(subyek || '').trim().toLowerCase() === 'badan') return Math.floor(cb * 100 / 85);
                if (cb <= 57000000) return Math.floor(cb * 100 / 95);
                if (cb <= 218500000) return Math.floor(60000000 + (cb - 57000000) * 100 / 85);
                if (cb <= 406000000) return Math.floor(250000000 + (cb - 218500000) * 100 / 75);
                if (cb <= 3556000000) return Math.floor(500000000 + (cb - 406000000) * 100 / 70);
                return Math.floor(5000000000 + (cb - 3556000000) * 100 / 65);
            }

            function rcAhHasil(isi) {
                if (isi.claim) return { kode: 'claim', html: '<span class="bg-indigo-100 text-indigo-700 px-2 py-0.5 rounded text-[10px] font-bold uppercase">Claim to Finance</span>' };
                if (isi.clearing) return { kode: 'clearing', html: '<span class="bg-emerald-100 text-emerald-700 px-2 py-0.5 rounded text-[10px] font-bold uppercase">Clearing</span>' };
                return { kode: 'done', html: '<span class="bg-gray-800 text-white px-2 py-0.5 rounded text-[10px] font-bold uppercase">Done &middot; Special Claims</span>' };
            }

            function rcAhSubyek(r) { return r.statusPajakCust || rcIdentitasDokumen(r).subyek || ''; }

            function popAdhocFilters() {
                const dA = new Set(), cA = new Set();
                globalAdhocData.forEach(r => { dA.add(r.depot); cA.add(r.codeCampaign + " - " + r.campaignName); });
                if (document.getElementById('ahDepotDropdown')) document.getElementById('ahDepotDropdown').innerHTML = buildMultiselectHTML(Array.from(dA).map(x => ({ label: x, value: x })), true, 'ahDepotDropdown', "renderAdhocTable()");
                if (document.getElementById('ahCampDropdown')) document.getElementById('ahCampDropdown').innerHTML = buildMultiselectHTML(Array.from(cA).map(x => ({ label: x, value: x })), true, 'ahCampDropdown', "renderAdhocTable()");
                setHiddenSafely('ahFilterDepotContainer', dA.size < 2);
            }

            function rcAhTersaring() {
                const sv = (document.getElementById('ahSearch')?.value || "").toLowerCase();
                const sd = checkMultiSelect('ahDepotDropdown') ? checkMultiSelect('ahDepotDropdown').split(', ') : [];
                const sc = checkMultiSelect('ahCampDropdown') ? checkMultiSelect('ahCampDropdown').split(', ') : [];
                return globalAdhocData.filter(r => {
                    const cocok = !sv || Object.values(r).some(v => v !== null && typeof v !== 'object' && String(v).toLowerCase().includes(sv));
                    return cocok && (sd.length === 0 || sd.includes(r.depot)) && (sc.length === 0 || sc.includes(r.codeCampaign + " - " + r.campaignName));
                });
            }

            function rcAhBaris(noDoc) {
                return Array.from(document.querySelectorAll('#adhocTableBody tr[data-doc]')).find(tr => tr.dataset.doc === noDoc) || null;
            }

            function rcAhIsiKartu() {
                const rows = rcAhTersaring();
                let cb = 0, gu = 0;
                rows.forEach(r => {
                    const isi = rcAhIsianDari(r);
                    const n = rcAhAngka(isi.cbNet);
                    cb += Math.trunc(n || 0);
                    gu += rcAhGross(n, rcAhSubyek(r), isi.jenisCb, isi.pajak);
                });
                rcIsiKartuAngka('ahTotToko', new Set(rows.map(r => r.kodeToko).filter(Boolean)).size.toLocaleString('id-ID'));
                rcIsiKartuAngka('ahTotCB', rcNominalRingkas(cb), rcNominalPenuh(cb));
                rcIsiKartuAngka('ahTotGrossUp', rcNominalRingkas(gu), rcNominalPenuh(gu));
            }

            // Gross Up dan Hasil satu baris digambar ulang tanpa menggambar seluruh tabel, supaya
            // kursor di kolom yang sedang diketik tidak hilang.
            function rcAhSegarkanBaris(r) {
                const tr = rcAhBaris(r.noDoc);
                if (!tr) return;
                const isi = rcAhIsianDari(r);
                const n = rcAhAngka(isi.cbNet);
                tr.querySelector('.ah-gross').innerText = n === null || n < 0 ? '-' : rcMoney(rcAhGross(n, rcAhSubyek(r), isi.jenisCb, isi.pajak));
                tr.querySelector('.ah-hasil').innerHTML = rcAhHasil(isi).html;
                const inCb = tr.querySelector('[data-kolom="cb"]'), inJenis = tr.querySelector('[data-kolom="jenis"]');
                inCb.classList.toggle('border-red-500', n === null || n < 0);
                inJenis.classList.toggle('border-red-500', !rcAhJenisSah(isi.jenisCb));
                tr.querySelector('[data-kolom="pajak"]').checked = !!isi.pajak;
                tr.querySelector('[data-kolom="claim"]').checked = !!isi.claim;
                tr.querySelector('[data-kolom="clearing"]').checked = !!isi.clearing;
            }

            function renderAdhocTable() {
                const tb = document.getElementById('adhocTableBody');
                if (!tb) return;
                const rows = rcAhTersaring();
                let html = '';
                rows.forEach(r => {
                    const isi = rcAhIsianDari(r);
                    const idn = rcIdentitasDokumen(r);
                    const n = rcAhAngka(isi.cbNet);
                    const doc = rcEsc(r.noDoc);
                    const kunci = r.masterKosong ? ' disabled title="Customer Master belum ada. Lengkapi di Key Master &gt; Customer Master lebih dulu."' : '';
                    const detId = 'det-adhoc-' + r.noDoc;
                    html += `<tr class="hover:bg-teal-50/40 border-b transition-colors" data-doc="${doc}">`
                        + `<td class="p-3.5 text-center"><input type="checkbox" value="${doc}" class="cb-adhoc w-4 h-4 rounded text-teal-600 focus:ring-teal-500" onchange="updateWorkflowCount('cb-adhoc', 'btnSubmitAdhoc', 'adhocSelectedCount')"${kunci}></td>`
                        + `<td class="p-3.5 text-[10px] font-black text-gray-600 bg-gray-50/50 uppercase">${rcEsc(r.batchUpload || '-')}</td>`
                        + `<td class="p-3.5 text-xs text-gray-500 font-medium">${rcEsc(r.tglApprove || '-')}</td>`
                        + `<td class="p-3.5 font-black text-blue-700">${doc}</td>`
                        + `<td class="p-3.5">${rcSelToko(r)}</td>`
                        + `<td class="p-3.5"><span class="text-[10px] text-gray-500 block uppercase font-bold">${rcEsc(r.codeCampaign)}</span><span class="text-sm font-medium whitespace-normal" title="${rcEsc(r.campaignName)}">${rcEsc(r.campaignName)}</span></td>`
                        + `<td class="p-3.5 text-right"><input type="text" inputmode="numeric" data-kolom="cb" data-doc="${doc}" value="${rcEsc(isi.cbNet)}" onchange="adhocUbah(this)" class="w-36 px-2 py-1.5 border ${n === null || n < 0 ? 'border-red-500' : 'border-gray-300'} rounded-lg text-right font-bold text-red-600 text-sm" title="Net CB semula ${rcEsc(rcMoney(r.cbNet))}"></td>`
                        + `<td class="p-3.5"><input type="text" list="ahJenisOptions" data-kolom="jenis" data-doc="${doc}" value="${rcEsc(isi.jenisCb)}" onchange="adhocUbah(this)" placeholder="Pilih / tempel" class="w-32 px-2 py-1.5 border ${rcAhJenisSah(isi.jenisCb) ? 'border-gray-300' : 'border-red-500'} rounded-lg text-sm"></td>`
                        + `<td class="p-3.5 text-center"><input type="checkbox" data-kolom="pajak" data-doc="${doc}" onchange="adhocUbah(this)" class="w-4 h-4 rounded text-teal-600"${isi.pajak ? ' checked' : ''}></td>`
                        + `<td class="p-3.5 text-center"><input type="checkbox" data-kolom="claim" data-doc="${doc}" onchange="adhocUbah(this)" class="w-4 h-4 rounded text-indigo-600"${isi.claim ? ' checked' : ''}></td>`
                        + `<td class="p-3.5 text-center"><input type="checkbox" data-kolom="clearing" data-doc="${doc}" onchange="adhocUbah(this)" class="w-4 h-4 rounded text-emerald-600"${isi.clearing ? ' checked' : ''}></td>`
                        + `<td class="p-3.5 text-right text-orange-700 font-bold ah-gross">${n === null || n < 0 ? '-' : rcMoney(rcAhGross(n, rcAhSubyek(r), isi.jenisCb, isi.pajak))}</td>`
                        + `<td class="p-3.5 ah-hasil">${rcAhHasil(isi).html}</td>`
                        + `<td class="p-3.5 text-center"><button onclick="toggleWorkflowDetails('${rcEsc(detId)}')" class="bg-blue-50 hover:bg-blue-100 text-blue-600 font-bold px-3 py-1.5 rounded-lg text-[10px] uppercase shadow-sm transition"><i class="fas fa-eye mr-1"></i> Details</button></td></tr>`
                        + `<tr id="${rcEsc(detId)}" class="hidden expanded-details"><td colspan="14" class="p-4 bg-gray-50"><div class="grid grid-cols-2 md:grid-cols-4 gap-4 text-xs">`
                        + `<div class="bg-white p-3 rounded-lg shadow-sm border border-gray-200"><span class="font-bold text-gray-500 block mb-1 uppercase text-[9px]"><i class="fas fa-id-card mr-1"></i> Identitas & Pajak</span><span class="font-bold text-gray-800 block text-xs truncate">KTP: ${rcEsc(idn.ktp || '-')} | NPWP: ${rcEsc(idn.npwp || '-')}</span><span class="font-bold text-gray-800 block text-xs truncate">Sbyk: ${rcEsc(rcAhSubyek(r) || '-')} | Stat: ${rcEsc(rcLabelPajak(r.statusPajakCamp))}</span></div>`
                        + `<div class="bg-white p-3 rounded-lg shadow-sm border border-gray-200"><span class="font-bold text-gray-500 block mb-1 uppercase text-[9px]"><i class="fas fa-money-check-alt mr-1"></i> Rekening</span><span class="font-bold text-gray-800 block text-xs truncate">${rcEsc(idn.noRek || '-')}</span><span class="font-bold text-gray-800 block text-xs truncate">${rcEsc(idn.namaRek || '-')} (${rcEsc(idn.bank || '-')})</span></div>`
                        + `<div class="bg-white p-3 rounded-lg shadow-sm border border-gray-200"><span class="font-bold text-gray-500 block mb-1 uppercase text-[9px]"><i class="fas fa-user-check mr-1"></i> Process by</span>${kartuPelaku(r)}</div>`
                        + `${rcDetailCardHtml('Remark', rcRemarkHtml(r.remark))}</div></td></tr>`;
                });
                tb.innerHTML = html || '<tr><td colspan="14" class="p-8 text-center text-gray-400 text-sm">Tidak ada dokumen Others yang menunggu Ad-Hoc Process.</td></tr>';
                rcAhIsiKartu();
                updateWorkflowCount('cb-adhoc', 'btnSubmitAdhoc', 'adhocSelectedCount');
            }

            function rcAhCentang(noDoc) {
                const tr = rcAhBaris(noDoc);
                const cb = tr && tr.querySelector('.cb-adhoc');
                if (cb && !cb.disabled && !cb.checked) { cb.checked = true; updateWorkflowCount('cb-adhoc', 'btnSubmitAdhoc', 'adhocSelectedCount'); }
            }

            function rcAhSetel(r, kolom, nilai) {
                const isi = rcAhIsianDari(r);
                if (kolom === 'cb') isi.cbNet = rcAhTeksCb(nilai);
                else if (kolom === 'jenis') isi.jenisCb = rcAhJenisSah(nilai) || String(nilai || '').trim();
                else isi[kolom] = !!nilai;
            }

            // Mengubah satu isian: barisnya ikut tercentang supaya pasti ikut diproses.
            function adhocUbah(el) {
                const r = globalAdhocData.find(x => x.noDoc === el.dataset.doc);
                if (!r) return;
                const kolom = el.dataset.kolom;
                rcAhSetel(r, kolom, el.type === 'checkbox' ? el.checked : el.value);
                if (kolom === 'jenis') el.value = rcAhIsianDari(r).jenisCb;
                if (kolom === 'cb') el.value = rcAhIsianDari(r).cbNet;
                rcAhSegarkanBaris(r);
                rcAhIsiKartu();
                rcAhCentang(r.noDoc);
            }

            // Tempel satu kolom dari Excel ke Net CB / Jenis CB: baris ini dan baris di bawahnya.
            document.addEventListener('paste', function (ev) {
                const el = ev.target;
                if (!el || !el.dataset || !['cb', 'jenis'].includes(el.dataset.kolom) || !el.closest('#adhocTableBody')) return;
                const teks = (ev.clipboardData || window.clipboardData).getData('text') || '';
                const nilai = teks.replace(/\r/g, '').split('\n');
                while (nilai.length && nilai[nilai.length - 1].trim() === '') nilai.pop();
                if (nilai.length <= 1) return;
                ev.preventDefault();
                const kolom = el.dataset.kolom;
                const semua = Array.from(document.querySelectorAll('#adhocTableBody [data-kolom="' + kolom + '"]'));
                const mulai = semua.indexOf(el);
                nilai.forEach(function (v, i) {
                    const target = semua[mulai + i];
                    if (!target) return;
                    const r = globalAdhocData.find(x => x.noDoc === target.dataset.doc);
                    if (!r) return;
                    // Sel Excel bisa berisi beberapa kolom (dipisah tab): yang dipakai kolom pertama.
                    rcAhSetel(r, kolom, v.split('\t')[0]);
                    target.value = kolom === 'jenis' ? rcAhIsianDari(r).jenisCb : rcAhIsianDari(r).cbNet;
                    rcAhSegarkanBaris(r);
                    rcAhCentang(r.noDoc);
                });
                rcAhIsiKartu();
                if (nilai.length > semua.length - mulai) {
                    showNotification((nilai.length - (semua.length - mulai)) + ' nilai tempelan melebihi jumlah baris di layar dan diabaikan.', 'warning');
                }
            });

            function adhocTerapkanMassal() {
                const docs = Array.from(document.querySelectorAll('.cb-adhoc:checked')).map(c => c.value);
                if (!docs.length) { showNotification('Centang dulu dokumen yang akan diisi.', 'warning'); return; }
                const jenis = document.getElementById('ahMassJenis').value;
                const cbTeks = document.getElementById('ahMassCb').value.trim();
                const pajak = document.getElementById('ahMassPajak').value;
                const claim = document.getElementById('ahMassClaim').value;
                const clearing = document.getElementById('ahMassClearing').value;
                let cb = null;
                if (cbTeks) {
                    cb = rcAhAngka(cbTeks);
                    if (cb === null || cb < 0) { showNotification('Net CB massal bukan angka yang valid.', 'warning'); return; }
                }
                if (!jenis && cb === null && !pajak && !claim && !clearing) { showNotification('Pilih dulu isian yang akan diterapkan.', 'warning'); return; }
                docs.forEach(function (d) {
                    const r = globalAdhocData.find(x => x.noDoc === d);
                    if (!r) return;
                    const isi = rcAhIsianDari(r);
                    if (jenis) isi.jenisCb = jenis;
                    if (cb !== null) isi.cbNet = rcAhTeksCb(cb);
                    if (pajak) isi.pajak = pajak === '1';
                    if (claim) isi.claim = claim === '1';
                    if (clearing) isi.clearing = clearing === '1';
                    const tr = rcAhBaris(d);
                    if (tr) {
                        tr.querySelector('[data-kolom="cb"]').value = isi.cbNet;
                        tr.querySelector('[data-kolom="jenis"]').value = isi.jenisCb;
                    }
                    rcAhSegarkanBaris(r);
                });
                rcAhIsiKartu();
                showNotification('Isian diterapkan ke ' + docs.length + ' dokumen.', 'success');
            }

            async function adhocProses() {
                const docs = Array.from(document.querySelectorAll('.cb-adhoc:checked')).map(c => c.value);
                if (!docs.length) return;
                const salah = [], items = [];
                let nClaim = 0, nClr = 0, nDone = 0;
                docs.forEach(function (d) {
                    const r = globalAdhocData.find(x => x.noDoc === d);
                    if (!r) return;
                    const isi = rcAhIsianDari(r);
                    const jenis = rcAhJenisSah(isi.jenisCb), cb = rcAhAngka(isi.cbNet);
                    if (!jenis) { salah.push(d + ': Jenis CB belum diisi atau tidak dikenali'); return; }
                    if (cb === null || cb < 0) { salah.push(d + ': Net CB bukan angka yang valid'); return; }
                    const hasil = rcAhHasil(isi).kode;
                    if (hasil === 'claim') nClaim++; else if (hasil === 'clearing') nClr++; else nDone++;
                    items.push({ noDoc: d, jenisCb: jenis, cbNet: String(Math.trunc(cb)), pajak: !!isi.pajak, lanjutClaim: !!isi.claim, lanjutClearing: !!isi.clearing });
                });
                if (salah.length) {
                    showNotification('Lengkapi dulu: ' + salah.slice(0, 3).join('; ') + (salah.length > 3 ? ' (dan ' + (salah.length - 3) + ' lainnya)' : ''), 'warning');
                    return;
                }
                const lanjut = await showConfirmModal({
                    title: 'Proses Ad-Hoc',
                    message: `${items.length} dokumen diproses: ${nClaim} ke Claim to Finance, ${nClr} ke Clearing, ${nDone} langsung Done (Special Claims).`
                        + (nDone ? ' Berkas Claim to Finance untuk dokumen yang langsung Done akan terunduh.' : ''),
                    confirmText: 'Ya, Proses', danger: false
                });
                if (!lanjut) return;
                setDisabledSafely('btnSubmitAdhoc', true); showLoadingOverlay('Memproses Ad-Hoc...');
                try {
                    const res = await fetchApp({ action: 'adhocProses', items: items });
                    if (res.status === 'success') {
                        const hasil = {};
                        (res.processed || []).forEach(p => { hasil[String(p.no_doc).trim().toUpperCase()] = p; });
                        // Nilai yang ditampilkan dan diunduh adalah hasil server, bukan perkiraan layar.
                        const baris = globalAdhocData.filter(r => hasil[String(r.noDoc).trim().toUpperCase()]).map(function (r) {
                            const p = hasil[String(r.noDoc).trim().toUpperCase()];
                            return Object.assign({}, r, { jenisCb: p.jenis_cb, cbNet: p.cb_net, grossUpCb: p.gross_up, statusAdhoc: p.status });
                        });
                        const sukses = baris.map(d => ({ noDoc: d.noDoc, kodeCamp: d.codeCampaign, namaCamp: d.campaignName, kodeToko: d.kodeToko, namaToko: d.namaToko, reward: d.cbNet, grossUp: d.grossUpCb || 0, prevBatch: d.batchUpload || '-' }));
                        showActionResult('Laporan Ad-Hoc Process', sukses, [], 'approve', res.batch || null);
                        const done = baris.filter(d => d.statusAdhoc === 'done');
                        if (done.length) downloadClaimToFinanceExcel(done, 'Ad_Hoc_Special_Claims');
                        baris.forEach(d => { delete rcAhIsian[d.noDoc]; });
                        fetchWorkflowData();
                    } else { showNotification(res.message || 'Gagal memproses Ad-Hoc.', 'error'); }
                } catch (e) { showNotification((e && e.message) ? 'Gagal: ' + e.message : 'Terjadi kesalahan saat memproses Ad-Hoc.', 'error'); fetchWorkflowData(); } finally { hideLoadingOverlay(); }
            }

            async function adhocTolak() {
                const docs = Array.from(document.querySelectorAll('.cb-adhoc:checked')).map(c => c.value);
                if (!docs.length) { showNotification('Centang dulu dokumen yang akan di-Reject.', 'warning'); return; }
                const lanjut = await showConfirmModal({ title: 'Reject (Kembali)', message: `${docs.length} dokumen dikembalikan ke depot sebagai Not Yet berjenis Others. Lanjutkan?`, confirmText: 'Ya, Reject', danger: true });
                if (!lanjut) return;
                showLoadingOverlay('Membatalkan / Reject Data...');
                try {
                    const res = await fetchApp({ action: 'adhocTolak', docs: docs, reason: 'Reject pada tahap Ad-Hoc Process' });
                    if (res.status === 'success') {
                        const sukses = globalAdhocData.filter(r => docs.includes(r.noDoc)).map(d => ({ noDoc: d.noDoc, kodeCamp: d.codeCampaign, namaCamp: d.campaignName, kodeToko: d.kodeToko, namaToko: d.namaToko, reward: d.cbNet, grossUp: d.grossUpCb || 0, prevBatch: d.batchUpload || '-' }));
                        showActionResult('Laporan Ad-Hoc Process', sukses, [], 'reject');
                        docs.forEach(d => { delete rcAhIsian[d]; });
                        fetchWorkflowData();
                    } else { showNotification(res.message || 'Gagal me-Reject dokumen.', 'error'); }
                } catch (e) { showNotification((e && e.message) ? 'Gagal: ' + e.message : 'Terjadi kesalahan saat Reject.', 'error'); fetchWorkflowData(); } finally { hideLoadingOverlay(); }
            }
