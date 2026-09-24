            // ============================================================================
            // MODUL MANAGEMENT OF APPROVAL
            // ============================================================================
            // Tahap persetujuan sebelum Release. Pengajuan berstatus Submitted menunggu di sini;
            // hanya yang sudah Approved yang muncul di antrean Release.
            //
            // Dua antrean dipisahkan menurut TOP yang DIKETIK DEPOT saat mengunggah, dihitung
            // sejak tanggal posting. Pemisahan itu dikerjakan di server - satu fungsi,
            // rc_private.approval_overdue - supaya daftar batch, rincian dan penyaringnya tidak
            // mungkin memakai perhitungan yang berbeda.
            //
            // Menyetujui dan menolak melewati jalur perpindahan status yang sama dengan seluruh
            // modul lain, sehingga versi dokumen, riwayat status dan Log Aktivitas terisi
            // dengan cara yang sama persis. Tab History karena itu tidak menyimpan catatan
            // sendiri - ia membaca riwayat yang sudah ada.

            let apTab = 'wpt';
            let apState = { batches: [], docs: [], batch: null, depots: null,
                            histori: [], hTotal: 0, hOffset: 0, hLimit: 50, timer: null,
                            hold: [], holdBoleh: false };

            // Kolom jejak per tahap, dapat ditampilkan atau tidak seperti tab Open pada Claim
            // Upload. "baku" menandai kolom yang tampil tanpa dipilih; sisanya ada tetapi
            // dimatikan, supaya tabel tidak langsung penuh bagi yang tidak membutuhkannya.
            const AP_KOLOM = [
                { k: 'submitted', judul: 'Submitted By', baku: false },
                { k: 'posting',   judul: 'Posting Date', baku: true },
                { k: 'approved',  judul: 'Approved By',  baku: false },
                { k: 'approvedAt',judul: 'Approval Date',baku: false },
                { k: 'topSetting',judul: 'TOP Setting',  baku: true },
                { k: 'topAktual', judul: 'TOP Actual',   baku: true },
                { k: 'topSelisih',judul: 'Selisih TOP',  baku: true }
            ];
            let apKolomAktif = null;

            function apKolomMuat() {
                if (apKolomAktif) return apKolomAktif;
                let simpan = null;
                try { simpan = JSON.parse(window.localStorage.getItem('rcApprovalKolom') || 'null'); }
                catch (e) { simpan = null; }
                apKolomAktif = {};
                AP_KOLOM.forEach(function (c) {
                    apKolomAktif[c.k] = (simpan && typeof simpan[c.k] === 'boolean') ? simpan[c.k] : c.baku;
                });
                return apKolomAktif;
            }

            function apKolomSimpan() {
                try { window.localStorage.setItem('rcApprovalKolom', JSON.stringify(apKolomAktif)); }
                catch (e) { /* penyimpanan ditolak; pilihan tetap berlaku untuk sesi ini */ }
            }

            function toggleApprovalKolomPanel() {
                const panel = document.getElementById('apKolomPanel');
                const buka = panel.classList.contains('hidden');
                setHiddenSafely('apKolomPanel', !buka);
                if (buka) apKolomRender();
            }

            function apKolomRender() {
                const aktif = apKolomMuat();
                document.getElementById('apKolomDaftar').innerHTML = AP_KOLOM.map(function (c) {
                    return '<label class="flex items-center gap-2 text-sm text-gray-700">'
                        + '<input type="checkbox" class="rounded text-pink-600" '
                        + 'onchange="apKolomUbah(\'' + c.k + '\', this.checked)"'
                        + (aktif[c.k] ? ' checked' : '') + '>' + rcEsc(c.judul) + '</label>';
                }).join('');
            }

            function apKolomUbah(k, on) {
                apKolomMuat();
                apKolomAktif[k] = !!on;
                apKolomSimpan();
                if (apState.batch) renderApprovalDocs();
            }

            // ---- Navigasi tab ------------------------------------------------------------
            function switchApprovalTab(tab) {
                if(!rcEnterTab('approval',tab))return;
                apTab = tab;
                ['wpt', 'ovd', 'hold', 'history'].forEach(function (t) {
                    const btn = document.getElementById('apTab' + t.charAt(0).toUpperCase() + t.slice(1));
                    if (!btn) return;
                    btn.classList.toggle('border-pink-600', t === tab);
                    btn.classList.toggle('text-pink-700', t === tab);
                    btn.classList.toggle('border-transparent', t !== tab);
                    btn.classList.toggle('text-gray-500', t !== tab);
                });
                setHiddenSafely('apPaneHistory', tab !== 'history');
                setHiddenSafely('apPaneHold', tab !== 'hold');
                // Bilah atas tetap dipakai tab On Hold - penyaring depot, pencarian, unduh dan
                // Muat Ulang berlaku sama di sana.
                setHiddenSafely('apBar', tab === 'history');
                apState.batch = null;
                setHiddenSafely('apPaneRincian', true);
                setHiddenSafely('apPaneDaftar', tab !== 'wpt' && tab !== 'ovd');
                loadApproval();
            }

            // Overdue hanya untuk peran yang berhak. Tabnya disembunyikan di sini, dan server
            // menolak permintaannya juga - menyembunyikan tab saja bukan penjagaan.
            function apTerapkanPeran() {
                const peran = String((currentUserData && currentUserData.role) || '').toLowerCase();
                const hanyaWpt = peran === 'depot head';
                setHiddenSafely('apTabOvd', hanyaWpt);
                const catatan = document.getElementById('apPeranCatatan');
                if (catatan) {
                    catatan.innerText = hanyaWpt
                        ? 'Depot Head menyetujui dokumen Within Payment Term.' : '';
                    setHiddenSafely('apPeranCatatan', !hanyaWpt);
                }
                if (hanyaWpt && apTab === 'ovd') apTab = 'wpt';
            }

            // Penyaring depot diisi dari depot yang benar-benar terjangkau akun ini. Bila hanya
            // ada satu, ia dikunci pada depot itu: tidak ada yang dapat dipilih, jadi menyodorkan
            // daftar berisi satu isian hanya menyesatkan. Keputusannya diambil dari DATA, bukan
            // dari peran - seorang OSC dapat memegang satu depot atau lima.
            async function apIsiFilterDepot() {
                const el = document.getElementById('apFilterDepot');
                if (!el) return;
                if (!apState.depots) {
                    try {
                        const res = await fetchApp({ action: 'approvalDepots' });
                        apState.depots = res.status === 'success' ? (res.rows || []) : [];
                    } catch (e) { apState.depots = []; }
                }
                const d = apState.depots;
                if (d.length === 1) {
                    el.innerHTML = '<option value="' + rcEsc(d[0].kode) + '">'
                        + rcEsc(d[0].kode + ' - ' + d[0].nama) + '</option>';
                    el.value = d[0].kode;
                    el.disabled = true;
                    el.classList.add('bg-gray-100', 'cursor-not-allowed');
                } else {
                    const terpilih = el.value;
                    el.innerHTML = '<option value="">Semua Depot (' + d.length + ')</option>'
                        + d.map(function (x) {
                            return '<option value="' + rcEsc(x.kode) + '">'
                                + rcEsc(x.kode + ' - ' + x.nama) + '</option>';
                        }).join('');
                    el.value = d.some(function (x) { return x.kode === terpilih; }) ? terpilih : '';
                    el.disabled = false;
                    el.classList.remove('bg-gray-100', 'cursor-not-allowed');
                }
            }

            function apDepotTerpilih() {
                const el = document.getElementById('apFilterDepot');
                return el ? el.value : '';
            }

            // Pencarian pada daftar batch dan rincian dikerjakan di layar: barisnya sudah ada,
            // jadi hasilnya terasa seketika. Riwayat berbeda - jumlahnya tumbuh tanpa batas,
            // sehingga pencariannya dikirim ke server bersama nomor halamannya; menyaring di
            // layar hanya akan menyaring halaman yang kebetulan sedang terbuka.
            function apCariBerubah() {
                if (apTab === 'hold') {
                    clearTimeout(apState.timer);
                    apState.timer = setTimeout(loadApproval, 300);
                } else if (apTab === 'history') {
                    apState.hOffset = 0;
                    clearTimeout(apState.timer);
                    apState.timer = setTimeout(loadApproval, 300);
                } else if (apState.batch) renderApprovalDocs();
                else renderApprovalBatches();
            }

            function apSaring(rows, ambil) {
                const el = document.getElementById('apCari');
                const kata = String((el && el.value) || '').toLowerCase().split(/\s+/).filter(Boolean);
                if (!kata.length) return rows;
                return rows.filter(function (r) {
                    const teks = ambil(r).toLowerCase();
                    return kata.every(function (k) { return teks.indexOf(k) >= 0; });
                });
            }

            async function openApprovalModule() {
                apTerapkanPeran();
                await apIsiFilterDepot();
                switchApprovalTab(rcFirstTab('approval',apTab));
            }

            // ---- Memuat ------------------------------------------------------------------
            async function loadApproval() {
                showLoadingOverlay('Memuat antrean approval...');
                try {
                    if (apTab === 'hold') {
                        const res = await fetchApp({
                            action: 'approvalHold',
                            depot: apDepotTerpilih(), search: document.getElementById('apCari').value
                        });
                        if (res.status !== 'success') throw new Error(res.message || 'Gagal memuat antrean.');
                        apState.hold = res.rows || [];
                        apState.holdBoleh = res.bolehPutus === true;
                        renderApprovalHold();
                    } else if (apTab === 'history') {
                        const res = await fetchApp({
                            action: 'approvalHistory', limit: apState.hLimit, offset: apState.hOffset,
                            search: document.getElementById('apCari').value, depot: apDepotTerpilih()
                        });
                        if (res.status !== 'success') throw new Error(res.message || 'Gagal memuat riwayat.');
                        apState.histori = res.rows || [];
                        apState.hTotal = Number(res.total) || 0;
                        renderApprovalHistory(apState.histori);
                    } else if (apState.batch) {
                        await muatRincianApproval(apState.batch);
                    } else {
                        const res = await fetchApp({ action: 'approvalBatches', kind: apTab, depot: apDepotTerpilih() });
                        if (res.status !== 'success') throw new Error(res.message || 'Gagal memuat antrean.');
                        apState.batches = res.rows || [];
                        renderApprovalBatches();
                    }
                } catch (e) {
                    showNotification((e && e.message) ? e.message : 'Gagal memuat approval.', 'error');
                } finally {
                    hideLoadingOverlay();
                }
            }

            function renderApprovalBatches() {
                const rows = apSaring(apState.batches, function (b) {
                    return [b.noBatch, b.kodeDepot, b.namaDepot, b.submittedBy, b.postingDate].join(' ');
                });
                document.getElementById('apBatchBody').innerHTML = rows.map(function (b) {
                    const kode = rcEsc(b.noBatch);
                    return '<tr class="border-b border-gray-100 hover:bg-pink-50/50">'
                        + '<td class="p-3 text-center"><input type="checkbox" class="cb-approval w-4 h-4 rounded" value="'
                          + kode + '" onchange="updateApprovalCount()"></td>'
                        + '<td class="p-3"><button onclick="bukaRincianApproval(&#39;' + kode + '&#39;)" '
                          + 'class="font-black text-blue-700 hover:underline">' + kode + '</button></td>'
                        + '<td class="p-3 text-right">' + Number(b.qtyDoc || 0).toLocaleString('id-ID') + '</td>'
                        + '<td class="p-3 text-right">' + Number(b.qtyCust || 0).toLocaleString('id-ID') + '</td>'
                        + '<td class="p-3 text-right">' + Number(b.qtyCampaign || 0).toLocaleString('id-ID') + '</td>'
                        + '<td class="p-3 text-right font-black text-red-600 whitespace-nowrap" data-sort="'
                          + Number(b.totalNetCb || 0) + '">' + rcEsc(rcNominalPenuh(b.totalNetCb)) + '</td>'
                        + '<td class="p-3 text-gray-600 whitespace-nowrap">' + rcEsc(b.kodeDepot || '-') + '</td>'
                        + '<td class="p-3 text-gray-700">' + rcEsc(b.submittedBy || '-') + '</td>'
                        + '<td class="p-3 text-center whitespace-nowrap">' + rcEsc(b.postingDate || '-') + '</td>'
                        + '<td class="p-3 text-center whitespace-nowrap">'
                          + '<button onclick="approvalSatuBatch(&#39;' + kode + '&#39;,&#39;approve&#39;)" class="px-3 py-1.5 bg-pink-600 hover:bg-pink-700 text-white font-bold rounded-lg text-xs mr-1">Approve</button>'
                          + '<button onclick="approvalSatuBatch(&#39;' + kode + '&#39;,&#39;reject&#39;)" class="px-3 py-1.5 bg-white border border-red-300 hover:bg-red-50 text-red-700 font-bold rounded-lg text-xs">Reject</button>'
                        + '</td></tr>';
                }).join('') || '<tr><td colspan="10" class="p-6 text-center text-gray-400">Tidak ada dokumen menunggu persetujuan.</td></tr>';

                const totalDoc = rows.reduce(function (a, b) { return a + Number(b.qtyDoc || 0); }, 0);
                const totalCb = rows.reduce(function (a, b) { return a + Number(b.totalNetCb || 0); }, 0);
                document.getElementById('apRingkas').innerText =
                    rows.length + (rows.length === apState.batches.length ? '' : ' dari ' + apState.batches.length) + ' batch · ' + totalDoc + ' dokumen · ' + rcNominalPenuh(totalCb);
                const semua = document.getElementById('apPilihSemua');
                if (semua) semua.checked = false;
                updateApprovalCount();
                rcAktifkanUrutSemua('apPaneDaftar');
            }

            function toggleSemuaApproval(src) {
                const on = src ? src.checked : document.getElementById('apPilihSemua').checked;
                document.querySelectorAll('.cb-approval').forEach(function (c) { c.checked = on; });
                updateApprovalCount();
            }

            function apBatchTerpilih() {
                return Array.from(document.querySelectorAll('.cb-approval:checked')).map(function (c) { return c.value; });
            }

            function updateApprovalCount() {
                const n = apBatchTerpilih().length;
                document.getElementById('apTerpilih').innerText = n;
                setHiddenSafely('apAksiMassal', n === 0);
            }

            // ---- Rincian sebuah batch ----------------------------------------------------
            async function bukaRincianApproval(batch) {
                apState.batch = batch;
                setHiddenSafely('apPaneDaftar', true);
                setHiddenSafely('apPaneRincian', false);
                document.getElementById('apRincianJudul').innerText = 'Batch ' + batch;
                await muatRincianApproval(batch);
            }

            async function muatRincianApproval(batch) {
                showLoadingOverlay('Memuat rincian batch...');
                try {
                    const res = await fetchApp({ action: 'approvalDetail', batch: batch, kind: apTab });
                    if (res.status !== 'success') throw new Error(res.message || 'Gagal memuat rincian.');
                    apState.docs = res.rows || [];
                    renderApprovalDocs();
                } catch (e) {
                    showNotification((e && e.message) ? e.message : 'Gagal memuat rincian.', 'error');
                } finally {
                    hideLoadingOverlay();
                }
            }

            function kembaliKeDaftarApproval() {
                apState.batch = null;
                setHiddenSafely('apPaneRincian', true);
                setHiddenSafely('apPaneDaftar', false);
                loadApproval();
            }

            function renderApprovalDocs() {
                const aktif = apKolomMuat();
                const judul = ['No Doc', 'Kode Cust', 'Nama Cust', 'Kode Campaign', 'Nama Campaign',
                               'Net CB', 'Jenis CB', 'Status Pajak']
                    .concat(AP_KOLOM.filter(function (c) { return aktif[c.k]; })
                                    .map(function (c) { return c.judul; }));

                document.getElementById('apDocHead').innerHTML =
                    '<th class="p-3 text-center w-12" data-rc-no-sort="1"><input type="checkbox" id="apDocSemua" onchange="toggleSemuaApprovalDoc(this)" class="w-4 h-4 rounded"></th>'
                    + judul.map(function (t) {
                        const rata = (t === 'Net CB') ? ' class="p-3 text-right text-[10px] font-black uppercase"'
                            : ' class="p-3 text-left text-[10px] font-black uppercase"';
                        return '<th' + rata + '>' + rcEsc(t) + '</th>';
                    }).join('')
                    + '<th class="p-3 text-center text-[10px] font-black uppercase" data-rc-no-sort="1">Tindakan</th>';

                const docs = apSaring(apState.docs, function (r) {
                    return [r.noDoc, r.kodeCust, r.namaCust, r.kodeCampaign, r.namaCampaign,
                            r.jenisCb, r.statusPajak, r.topSetting, r.topAktual].join(' ');
                });
                document.getElementById('apDocBody').innerHTML = docs.map(function (r) {
                    const nd = rcEsc(r.noDoc);
                    let ekor = '';
                    AP_KOLOM.forEach(function (c) {
                        if (!aktif[c.k]) return;
                        // TOP Setting adalah kesepakatan pada Customer Master, TOP Actual yang
                        // diminta depot pada dokumen ini. Selisihnya diberi warna karena justru
                        // itulah yang dibaca penyetuju: angka positif berarti meminta kelonggaran.
                        if (c.k === 'topSelisih') {
                            const d = r.topSelisih;
                            const teks = (d === null || d === undefined) ? '-'
                                : (Number(d) > 0 ? '+' + Number(d) : String(Number(d)));
                            const warna = (d === null || d === undefined) ? 'text-gray-400'
                                : Number(d) > 0 ? 'text-red-600 font-black' : 'text-gray-600';
                            ekor += '<td class="p-3 text-center whitespace-nowrap ' + warna + '">'
                                  + rcEsc(teks) + '</td>';
                            return;
                        }
                        const v = c.k === 'submitted' ? (r.submittedBy || '-')
                            : c.k === 'posting' ? (r.postingDate || '-')
                            : c.k === 'approved' ? (r.approvedBy || '-')
                            : c.k === 'approvedAt' ? (r.approvedAt || '-')
                            : c.k === 'topSetting' ? (r.topSetting || '-')
                            : c.k === 'topAktual' ? (r.topAktual || '-')
                            : '-';
                        ekor += '<td class="p-3 text-center text-gray-700 whitespace-nowrap">' + rcEsc(v) + '</td>';
                    });
                    return '<tr class="border-b border-gray-100 hover:bg-pink-50/50' + (r.overdue ? ' bg-red-50/40' : '') + '">'
                        + '<td class="p-3 text-center"><input type="checkbox" class="cb-approval-doc w-4 h-4 rounded" value="'
                          + nd + '" onchange="updateApprovalDocCount()"></td>'
                        + '<td class="p-3 font-black text-blue-700">' + nd + '</td>'
                        + '<td class="p-3 text-gray-600">' + rcEsc(r.kodeCust || '-') + '</td>'
                        + '<td class="p-3 font-bold text-gray-800">' + rcEsc(r.namaCust || '-') + '</td>'
                        + '<td class="p-3 text-gray-600">' + rcEsc(r.kodeCampaign || '-') + '</td>'
                        + '<td class="p-3 max-w-[200px] truncate" title="' + rcEsc(r.namaCampaign) + '">' + rcEsc(r.namaCampaign || '-') + '</td>'
                        // Nilai penuh, bukan singkatan: di layar rincian inilah angka persisnya
                        // dibaca sebelum disetujui, dan "Rp 24,93 Jt" tidak cukup untuk itu.
                        + '<td class="p-3 text-right font-black text-red-600 whitespace-nowrap" data-sort="'
                          + Number(r.netCb || 0) + '">' + rcEsc(rcNominalPenuh(r.netCb)) + '</td>'
                        + '<td class="p-3 text-center font-bold text-gray-700">' + rcEsc(r.jenisCb || '-') + '</td>'
                        + '<td class="p-3 text-center font-bold text-gray-700">' + rcEsc(r.statusPajak || '-') + '</td>'
                        + ekor
                        + '<td class="p-3 text-center whitespace-nowrap">'
                          + '<button onclick="approvalSatuDoc(&#39;' + nd + '&#39;,&#39;approve&#39;)" class="px-3 py-1.5 bg-pink-600 hover:bg-pink-700 text-white font-bold rounded-lg text-xs mr-1">Approve</button>'
                          + '<button onclick="approvalSatuDoc(&#39;' + nd + '&#39;,&#39;reject&#39;)" class="px-3 py-1.5 bg-white border border-red-300 hover:bg-red-50 text-red-700 font-bold rounded-lg text-xs">Reject</button>'
                        + '</td></tr>';
                }).join('') || '<tr><td colspan="12" class="p-6 text-center text-gray-400">Batch ini tidak memuat dokumen pada antrean tersebut.</td></tr>';

                updateApprovalDocCount();
                rcAktifkanUrutSemua('apPaneRincian');
            }

            function toggleSemuaApprovalDoc(src) {
                const on = src ? src.checked : document.getElementById('apDocSemua').checked;
                document.querySelectorAll('.cb-approval-doc').forEach(function (c) { c.checked = on; });
                updateApprovalDocCount();
            }

            function apDocTerpilih() {
                return Array.from(document.querySelectorAll('.cb-approval-doc:checked')).map(function (c) { return c.value; });
            }

            function updateApprovalDocCount() {
                const n = apDocTerpilih().length;
                document.getElementById('apDocTerpilih').innerText = n;
                setHiddenSafely('apAksiRincian', n === 0);
            }

            // ---- Menyetujui dan menolak --------------------------------------------------
            // Satu jalan untuk seluruh bentuk: dari daftar maupun dari rincian, satu per satu
            // maupun massal. Dokumennya selalu berupa daftar No Doc, karena itulah yang
            // dimengerti jalur perpindahan status.
            // Alasan tidak diminta, atas instruksi pemilik: "tidak perlu ada alasan jadi reject
            // atau approve aja". Tindakannya sendiri sudah merupakan keterangan yang lengkap, dan
            // riwayat tetap mencatat siapa, kapan, dari status apa ke status apa.
            async function kirimApproval(docs, mode, batch) {
                if (!docs.length) { showNotification('Tidak ada dokumen yang dipilih.', 'warning'); return; }
                const setuju = await showConfirmModal({
                    title: mode === 'approve' ? 'Approve Dokumen' : 'Reject Dokumen',
                    message: docs.length + ' dokumen akan di-'
                        + (mode === 'approve' ? 'approve dan masuk antrean Release.'
                                              : 'reject dan dikembalikan ke depot sebagai Not Yet.')
                });
                if (!setuju) return;

                showLoadingOverlay('Memproses ' + docs.length + ' dokumen...');
                try {
                    const res = await fetchApp({
                        action: mode === 'approve' ? 'approveDocs' : 'rejectDocs',
                        docsToProcess: docs, reason: ''
                    });
                    if (res.status !== 'success') throw new Error(res.message || 'Gagal memproses.');
                    showNotification(docs.length + ' dokumen berhasil di-' + mode + '.', 'success');
                    logActivity(apKeteranganLog(mode === 'approve' ? 'Approve' : 'Reject',
                        docs, 'dokumen', batch));
                    apState.batch = null;
                    setHiddenSafely('apPaneRincian', true);
                    setHiddenSafely('apPaneDaftar', false);
                    await loadApproval();
                } catch (e) {
                    showNotification((e && e.message) ? e.message : 'Gagal memproses dokumen.', 'error');
                } finally {
                    hideLoadingOverlay();
                }
            }

            // Menyetujui sebuah batch berarti menyetujui seluruh dokumennya. Daftarnya diambil
            // dari server lebih dulu, bukan disusun di browser, supaya yang diproses persis apa
            // yang memang berada di antrean itu saat ini.
            async function dokumenBatch(batch) {
                const res = await fetchApp({ action: 'approvalDetail', batch: batch, kind: apTab });
                if (res.status !== 'success') throw new Error(res.message || 'Gagal membaca batch.');
                return (res.rows || []).map(function (r) { return r.noDoc; });
            }

            async function approvalSatuBatch(batch, mode) {
                showLoadingOverlay('Membaca batch...');
                try {
                    const docs = await dokumenBatch(batch);
                    hideLoadingOverlay();
                    await kirimApproval(docs, mode, batch);
                } catch (e) {
                    hideLoadingOverlay();
                    showNotification((e && e.message) ? e.message : 'Gagal membaca batch.', 'error');
                }
            }

            async function postingApproval(mode) {
                const batches = apBatchTerpilih();
                if (!batches.length) { showNotification('Pilih minimal satu batch.', 'warning'); return; }
                showLoadingOverlay('Membaca ' + batches.length + ' batch...');
                try {
                    let docs = [];
                    for (const b of batches) docs = docs.concat(await dokumenBatch(b));
                    hideLoadingOverlay();
                    await kirimApproval(docs, mode, batches.join(', '));
                } catch (e) {
                    hideLoadingOverlay();
                    showNotification((e && e.message) ? e.message : 'Gagal membaca batch.', 'error');
                }
            }

            function approvalSatuDoc(noDoc, mode) { kirimApproval([noDoc], mode); }

            function postingApprovalDoc(mode) { kirimApproval(apDocTerpilih(), mode); }

            // ---- History -----------------------------------------------------------------
            function renderApprovalHistory(rows) {
                document.getElementById('apHistoryBody').innerHTML = rows.map(function (h) {
                    const warna = h.tindakan === 'Approve' ? 'bg-green-100 text-green-700' : 'bg-red-100 text-red-700';
                    return '<tr class="border-b border-gray-100 hover:bg-blue-50">'
                        + '<td class="p-3 whitespace-nowrap text-gray-600">' + rcEsc(h.waktu || '-') + '</td>'
                        + '<td class="p-3 font-black text-blue-700">' + rcEsc(h.noDoc || '-') + '</td>'
                        + '<td class="p-3 text-gray-600">' + rcEsc(h.noBatch || '-') + '</td>'
                        + '<td class="p-3 text-gray-600 whitespace-nowrap">' + rcEsc(h.kodeDepot || '-') + '</td>'
                        + '<td class="p-3 text-center"><span class="px-2 py-0.5 rounded font-black text-[11px] ' + warna + '">'
                          + rcEsc(h.tindakan) + '</span></td>'
                        + '<td class="p-3 text-center text-gray-600">' + rcEsc(h.dari || '-') + '</td>'
                        + '<td class="p-3 text-center text-gray-600">' + rcEsc(h.ke || '-') + '</td>'
                        + '<td class="p-3 text-gray-700">' + rcEsc(h.oleh || '-') + '</td>'
                        + '<td class="p-3 text-gray-500 max-w-[260px] truncate" title="' + rcEsc(h.alasan) + '">'
                          + rcEsc(h.alasan || '-') + '</td></tr>';
                }).join('') || '<tr><td colspan="9" class="p-6 text-center text-gray-400">Belum ada riwayat approval.</td></tr>';
                rcAktifkanUrutSemua('apPaneHistory');
                apGambarHalaman();
            }

            // ---- Halaman riwayat ---------------------------------------------------------
            // Riwayat approval hanya bertambah, tidak pernah menyusut. Memuat seluruhnya sekali
            // jalan akan bekerja hari ini dan berhenti bekerja diam-diam beberapa bulan lagi -
            // karena itu ia berhalaman sejak awal, bukan setelah menjadi masalah.
            function apGambarHalaman() {
                const info = document.getElementById('apHalamanInfo');
                if (!info) return;
                const dari = apState.hTotal === 0 ? 0 : apState.hOffset + 1;
                const sampai = Math.min(apState.hOffset + apState.hLimit, apState.hTotal);
                info.innerText = 'Menampilkan ' + dari + '-' + sampai + ' dari '
                    + apState.hTotal.toLocaleString('id-ID') + ' baris';
                setDisabledSafely('apPrev', apState.hOffset <= 0);
                setDisabledSafely('apNext', sampai >= apState.hTotal);
            }

            function apHalaman(arah) {
                const baru = apState.hOffset + arah * apState.hLimit;
                if (baru < 0 || baru >= apState.hTotal) return;
                apState.hOffset = baru;
                loadApproval();
            }

            // ---- Unduh -------------------------------------------------------------------
            // Yang diunduh adalah apa yang SEDANG DILIHAT - tab yang aktif, penyaring yang
            // sedang berlaku, pencarian yang sedang diketik. Mengunduh seluruh data sementara
            // layar menampilkan sebagian hanya menghasilkan berkas yang tidak dikenali
            // pembacanya sendiri.
            function downloadApprovalExcel() {
                if (typeof XLSX === 'undefined') {
                    showNotification('Pustaka Excel belum termuat. Muat ulang halaman.', 'error'); return;
                }
                let nama, rows;
                if (apTab === 'history') {
                    nama = 'Riwayat Approval';
                    rows = apState.histori;
                } else if (apState.batch) {
                    nama = 'Batch ' + apState.batch;
                    rows = apSaring(apState.docs, function (r) {
                        return [r.noDoc, r.kodeCust, r.namaCust, r.kodeCampaign, r.namaCampaign,
                                r.jenisCb, r.statusPajak, r.topSetting, r.topAktual].join(' ');
                    });
                } else {
                    nama = apTab === 'ovd' ? 'Approval Overdue' : 'Approval WPT';
                    rows = apSaring(apState.batches, function (b) {
                        return [b.noBatch, b.kodeDepot, b.namaDepot, b.submittedBy, b.postingDate].join(' ');
                    });
                }
                if (!rows || !rows.length) { showNotification('Tidak ada baris untuk diunduh.', 'warning'); return; }

                const kolom = Object.keys(rows[0]);
                const aoa = [kolom].concat(rows.map(function (r) {
                    return kolom.map(function (k) { return rcExportAmount(k,r[k],r); });
                }));
                const wb = XLSX.utils.book_new();
                XLSX.utils.book_append_sheet(wb, XLSX.utils.aoa_to_sheet(aoa),
                    nama.replace(/[:\\/?*[\]]/g, '-').slice(0, 31));
                XLSX.writeFile(wb, 'RC_' + nama.replace(/ /g, '_') + '_'
                    + new Date().toISOString().slice(0, 10) + '.xlsx');
                showNotification(rows.length + ' baris diunduh.', 'success');
            }

            // ---- On Hold & Expired --------------------------------------------------------
            // Management mengesahkan atau membatalkan keputusan menahan dan menghanguskan.
            // Approve berarti keputusannya sah - dokumen tetap di tempatnya dan berhenti
            // menunggu. Reject membatalkannya: dokumen kembali ke status sebelum ditahan atau
            // dihanguskan, lalu melanjutkan alurnya.
            //
            // Peran lain tetap MELIHAT antreannya dalam jangkauan depotnya - mengetahui dokumen
            // mana yang tertahan adalah bagian dari pekerjaan mereka - tetapi tombolnya beku.
            function renderApprovalHold() {
                const rows = apState.hold;
                const boleh = apState.holdBoleh;

                const catatan = document.getElementById('apHoldCatatan');
                if (catatan) {
                    catatan.innerText = boleh ? ''
                        : 'Keputusan On Hold dan Expired ditetapkan Management. Anda dapat melihat '
                          + 'antreannya, tetapi tombolnya tidak aktif.';
                    setHiddenSafely('apHoldCatatan', boleh);
                }

                apAlasanSimpan = {};
                document.getElementById('apHoldBody').innerHTML = rows.map(function (r, i) {
                    const nd = rcEsc(r.noDoc);
                    const warna = r.statusPengajuan === 'Expired'
                        ? 'bg-slate-200 text-slate-700' : 'bg-orange-100 text-orange-700';
                    const mati = boleh ? '' : ' disabled';
                    const gaya = boleh ? '' : ' opacity-50 cursor-not-allowed';
                    return '<tr class="border-b border-gray-100 hover:bg-amber-50/40">'
                        + '<td class="p-3 text-center"><input type="checkbox" class="cb-hold w-4 h-4 rounded" value="'
                          + nd + '" onchange="updateHoldCount()"' + mati + '></td>'
                        + '<td class="p-3 text-center"><span class="px-2 py-0.5 rounded font-black text-[11px] '
                          + warna + '">' + rcEsc(r.statusPengajuan || r.statusKini) + '</span></td>'
                        + '<td class="p-3 text-center text-gray-600">' + rcEsc(r.asal || '-') + '</td>'
                        + '<td class="p-3 font-black text-blue-700">' + nd + '</td>'
                        + '<td class="p-3 text-gray-600 whitespace-nowrap">' + rcEsc(r.kodeDepot || '-') + '</td>'
                        + '<td class="p-3"><span class="font-bold text-gray-800">' + rcEsc(r.namaCust || '-') + '</span>'
                          + '<span class="block text-xs text-gray-500">' + rcEsc(r.kodeCust || '') + '</span></td>'
                        + '<td class="p-3"><span class="font-bold text-gray-700">' + rcEsc(r.kodeCampaign || '-') + '</span>'
                          + '<span class="block text-xs text-gray-500 max-w-[220px] truncate" title="' + rcEsc(r.namaCampaign)
                          + '">' + rcEsc(r.namaCampaign || '') + '</span></td>'
                        + '<td class="p-3 text-right font-black text-red-600 whitespace-nowrap" data-sort="'
                          + Number(r.netCb || 0) + '">' + rcEsc(rcNominalPenuh(r.netCb)) + '</td>'
                        + apSelAlasan(r, i)
                        + '<td class="p-3 text-gray-700">' + rcEsc(r.olehTerakhir || '-') + '</td>'
                        + '<td class="p-3 text-center whitespace-nowrap">'
                          + '<button onclick="holdSatuDoc(&#39;' + nd + '&#39;,&#39;approve&#39;)"' + mati
                            + ' class="px-3 py-1.5 bg-pink-600 hover:bg-pink-700 text-white font-bold rounded-lg text-xs mr-1'
                            + gaya + '">Approve</button>'
                          + '<button onclick="holdSatuDoc(&#39;' + nd + '&#39;,&#39;reject&#39;)"' + mati
                            + ' class="px-3 py-1.5 bg-white border border-red-300 hover:bg-red-50 text-red-700 font-bold rounded-lg text-xs'
                            + gaya + '">Reject</button>'
                        + '</td></tr>';
                }).join('') || '<tr><td colspan="11" class="p-6 text-center text-gray-400">Tidak ada dokumen On Hold atau Expired yang menunggu keputusan.</td></tr>';

                const total = rows.reduce(function (a, r) { return a + (Number(r.netCb) || 0); }, 0);
                document.getElementById('apRingkas').innerText =
                    rows.length + ' dokumen \u00b7 ' + rcNominalPenuh(total);

                const semua = document.getElementById('apHoldSemua');
                if (semua) { semua.checked = false; semua.disabled = !boleh; }
                updateHoldCount();
                rcAktifkanUrutSemua('apPaneHold');
            }

            function toggleSemuaHold(src) {
                const on = src ? src.checked : document.getElementById('apHoldSemua').checked;
                document.querySelectorAll('.cb-hold').forEach(function (c) { c.checked = on; });
                updateHoldCount();
            }

            function apHoldTerpilihDaftar() {
                return Array.from(document.querySelectorAll('.cb-hold:checked')).map(function (c) { return c.value; });
            }

            function updateHoldCount() {
                const n = apHoldTerpilihDaftar().length;
                document.getElementById('apHoldTerpilih').innerText = n;
                setHiddenSafely('apAksiHold', n === 0);
            }

            // Alasan TIDAK diminta lagi saat memutuskan. Keterangannya sudah lahir pada saat
            // dokumen ditahan atau dihanguskan - itulah yang tampil di kolom Alasan Terakhir -
            // dan menuntut keterangan kedua hanya menghasilkan dua catatan untuk satu peristiwa.

            // Alasan yang panjang tidak dipotong begitu saja. Yang panjang diringkas di dalam sel
            // dan diberi satu tombol kecil; rinciannya dibuka di dialog, tempat ia dapat dibaca
            // utuh dan disalin. Ambangnya sengaja rendah - pada lebar kolom ini, di atas itu pun
            // sudah terpotong.
            const AP_ALASAN_PANJANG = 60;
            let apAlasanSimpan = {};

            function apLihatAlasan(kunci) {
                const d = apAlasanSimpan[kunci];
                if (!d) return;
                rcDialog('Alasan - ' + d.noDoc,
                    '<div class="space-y-3 text-sm">'
                    + '<div class="flex flex-wrap gap-4 text-xs text-gray-500">'
                      + '<span><b class="text-gray-700">Status</b> ' + rcEsc(d.status) + '</span>'
                      + '<span><b class="text-gray-700">Oleh</b> ' + rcEsc(d.oleh || '-') + '</span>'
                      + '<span><b class="text-gray-700">Waktu</b> ' + rcEsc(d.waktu || '-') + '</span>'
                    + '</div>'
                    + '<div class="p-4 bg-gray-50 border border-gray-200 rounded-xl whitespace-pre-wrap '
                      + 'leading-relaxed text-gray-800">' + rcEsc(d.alasan) + '</div></div>');
            }

            // Sel alasan: pendek ditampilkan apa adanya, panjang diringkas plus tombol rincian.
            function apSelAlasan(r, i) {
                const teks = String(r.alasanTerakhir || '');
                const waktu = '<span class="block text-[10px] text-gray-400">'
                    + rcEsc(r.waktuTerakhir || '') + '</span>';
                if (!teks) return '<td class="p-3 text-gray-400">-' + waktu + '</td>';
                if (teks.length <= AP_ALASAN_PANJANG) {
                    return '<td class="p-3 text-gray-600 max-w-[240px]">' + rcEsc(teks) + waktu + '</td>';
                }
                const kunci = 'a' + i;
                apAlasanSimpan[kunci] = {
                    noDoc: r.noDoc, alasan: teks, oleh: r.olehTerakhir,
                    waktu: r.waktuTerakhir, status: r.statusPengajuan || r.statusKini
                };
                return '<td class="p-3 text-gray-600 max-w-[240px]">'
                    + '<span class="align-middle">' + rcEsc(teks.slice(0, AP_ALASAN_PANJANG)) + '…</span>'
                    + '<button type="button" onclick="apLihatAlasan(&#39;' + kunci + '&#39;)" '
                      + 'title="Lihat alasan selengkapnya" '
                      + 'class="ml-1.5 align-middle px-1.5 py-0.5 bg-white border border-gray-300 '
                      + 'hover:bg-blue-50 hover:border-blue-300 text-blue-600 rounded text-[10px] font-black">'
                      + '<i class="fas fa-up-right-and-down-left-from-center"></i></button>'
                    + waktu + '</td>';
            }

            // Keterangan untuk Log Aktivitas. Pemilik meminta nomor batch dan jumlahnya ikut
            // tercatat, dan bila hanya satu dokumen, nomor dokumennya saja - karena "1 dokumen"
            // tidak memberi tahu dokumen yang mana.
            function apKeteranganLog(tindakan, docs, konteks, batch) {
                if (docs.length === 1) return tindakan + ' ' + konteks + ': ' + docs[0];
                return tindakan + ' ' + konteks + (batch ? ' batch ' + batch : '')
                    + ' \u00b7 ' + docs.length + ' dokumen';
            }

            async function kirimHold(docs, mode) {
                if (!apState.holdBoleh) {
                    showNotification('Keputusan ini ditetapkan Management.', 'warning'); return;
                }
                if (!docs.length) { showNotification('Tidak ada dokumen yang dipilih.', 'warning'); return; }

                const setuju = await showConfirmModal({
                    title: mode === 'approve' ? 'Sahkan Keputusan' : 'Batalkan Keputusan',
                    message: mode === 'approve'
                        ? docs.length + ' dokumen akan berubah menjadi On Hold / Expired sesuai pengajuan.'
                        : docs.length + ' pengajuan dibatalkan. Status dokumen tidak berubah.'
                });
                if (!setuju) return;

                showLoadingOverlay('Memproses ' + docs.length + ' dokumen...');
                try {
                    const res = await fetchApp({
                        action: mode === 'approve' ? 'approveHoldDocs' : 'rejectHoldDocs',
                        docsToProcess: docs, reason: ''
                    });
                    if (res.status !== 'success') throw new Error(res.message || 'Gagal memproses.');
                    showNotification(docs.length + ' dokumen diproses.', 'success');
                    logActivity(apKeteranganLog(mode === 'approve' ? 'Sahkan' : 'Batalkan',
                        docs, 'keputusan On Hold/Expired'));
                    await loadApproval();
                } catch (e) {
                    showNotification((e && e.message) ? e.message : 'Gagal memproses dokumen.', 'error');
                } finally {
                    hideLoadingOverlay();
                }
            }

            function holdSatuDoc(noDoc, mode) { kirimHold([noDoc], mode); }
            function postingHold(mode) { kirimHold(apHoldTerpilihDaftar(), mode); }
