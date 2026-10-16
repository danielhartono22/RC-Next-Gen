            // ============================================================================
            // ACCESS MANAGEMENT - tab tambahan
            // ============================================================================
            // Empat tab di bawah ini dipindahkan ke Access Management atas permintaan pemilik.
            // Benang merahnya satu: semuanya keputusan administratif yang mengubah apa yang
            // dilihat orang lain, bukan bagian dari laporan atau pekerjaan harian.
            //
            //   Email Otomatis      - siapa menerima apa, dan kapan
            //   Exclude Campaign    - campaign mana yang tidak dihitung di Report dan Timetable
            //   Persetujuan Depot   - perubahan profil depot yang diajukan pengguna depot
            //   Grade Depot         - hanya System Manager
            //
            // Panel Email memakai kembali fungsi yang sudah ada di modul Report (loadEmailPanel,
            // simpanJadwalEmail, pratinjauEmail, ujiKoneksiEmail). Yang berpindah hanya markup
            // dan letaknya; logikanya tidak digandakan, supaya tidak ada dua kebenaran.

            let kaExcludeRows = [];
            let kaGradeRows = [];

            // ---------- Kirim email uji ----------
            // Alamatnya diperiksa di sini sekadar supaya salah ketik tertangkap segera; server
            // memeriksanya lagi dan menolak apa pun yang bukan alamat email.
            async function kirimEmailUji() {
                const alamat = (document.getElementById('rtEmailUjiAlamat') || {}).value || '';
                const jenis = (document.getElementById('rtEmailUjiJenis') || {}).value || 'daily';
                const bersih = alamat.trim();
                if (!/^[^\s@,;]+@[^\s@,;]+\.[^\s@,;]+$/.test(bersih)) {
                    showNotification('Isi satu alamat email yang sah lebih dulu.', 'warning'); return;
                }
                const setuju = await showConfirmModal({
                    title: 'Test Email',
                    message: 'Email ' + jenis + ' akan LANGSUNG dikirim hanya ke ' + bersih
                        + '. Penerima depot tidak dilibatkan.',
                    confirmText: 'Ya, Kirim'
                });
                if (!setuju) return;
                setDisabledSafely('btnKirimEmailUji', true);
                showLoadingOverlay('Mengirim test email...');
                try {
                    // emailSendNow, bukan emailCompose: yang kedua hanya mengantre, dan
                    // antreannya baru berjalan pada tick pg_cron berikutnya - sampai sejam
                    // kemudian. Tombol uji harus memberi jawabannya seketika.
                    const res = await fetchApp({
                        action: 'emailSendNow', jenis: jenis, testEmail: bersih
                    });
                    if (res.status === 'error') { showNotification(res.message || 'Gagal mengirim.', 'error'); return; }
                    // status 'warning' berarti tersusun tetapi belum terkirim - setelan Gmail
                    // belum lengkap, misalnya. Pesannya datang dari server dan sudah menyebut
                    // sebabnya, jadi diteruskan apa adanya.
                    showNotification(res.message, res.status === 'success' ? 'success' : 'warning');
                    logActivity('Kirim email uji ' + jenis + ' ke ' + bersih);
                    loadEmailPanel();
                } catch (e) { showNotification('Gagal mengirim email uji.', 'error'); }
                finally { setDisabledSafely('btnKirimEmailUji', false); hideLoadingOverlay(); }
            }

            // ---------- Exclude Campaign ----------
            // Daftarnya diambil dari Campaign Master, bukan dari campaign yang kebetulan punya
            // klaim: campaign yang belum berjalan pun boleh dikecualikan lebih dulu.
            async function muatExcludeCampaign() {
                showLoadingOverlay('Memuat daftar campaign...');
                try {
                    const res = await fetchApp({ action: 'campaignList', search: '', offset: 0, limit: 200 });
                    if (res.status !== 'success') { showNotification(res.message || 'Gagal memuat.', 'error'); return; }
                    // Campaign yang sedang dikecualikan diketahui dari Timetable, yang memang
                    // membawa daftarnya. Bila modul itu belum pernah dibuka, daftarnya kosong dan
                    // seluruh campaign tampil sebagai "Masuk" sampai dimuat.
                    let dikecualikan = [];
                    try {
                        const t = await fetchApp({ action: 'timetableMatrix', filter: {} });
                        dikecualikan = (t.excluded || t.dikecualikan || []).map(x => String(x.kode || x.codeCampaign || x));
                    } catch (e) { dikecualikan = []; }
                    kaExcludeRows = (res.rows || []).map(r => ({
                        kode: r.codeCampaign, nama: r.campaignName,
                        status: r.status || 'active',
                        dikecualikan: dikecualikan.indexOf(String(r.codeCampaign)) !== -1
                    }));
                    renderExcludeCampaign();
                } catch (e) { showNotification('Gagal memuat daftar campaign.', 'error'); }
                finally { hideLoadingOverlay(); }
            }

            function renderExcludeCampaign() {
                const cari = ((document.getElementById('kaExcludeCari') || {}).value || '').toLowerCase();
                const hanya = (document.getElementById('kaExcludeHanyaDikecualikan') || {}).checked;
                const tampil = kaExcludeRows.filter(function (r) {
                    if (hanya && !r.dikecualikan) return false;
                    if (!cari) return true;
                    return (r.kode + ' ' + r.nama).toLowerCase().indexOf(cari) !== -1;
                });
                document.getElementById('kaExcludeBody').innerHTML = tampil.map(function (r) {
                    return '<tr class="border-b border-gray-100 hover:bg-amber-50/40">'
                        + '<td class="p-3 text-center"><input type="checkbox" class="cb-ka-exclude w-4 h-4 rounded" value="'
                        + rcEsc(r.kode) + '" onchange="kaHitungExclude()"></td>'
                        + '<td class="p-3 font-black text-gray-800">' + rcEsc(r.kode) + '</td>'
                        + '<td class="p-3 text-gray-700">' + rcEsc(r.nama) + '</td>'
                        + '<td class="p-3 text-center text-[10px] font-black uppercase text-gray-500">' + rcEsc(r.status) + '</td>'
                        + '<td class="p-3 text-center">' + (r.dikecualikan
                            ? '<span class="bg-amber-100 text-amber-800 px-2 py-1 rounded text-[10px] font-black uppercase">Dikecualikan</span>'
                            : '<span class="bg-emerald-100 text-emerald-700 px-2 py-1 rounded text-[10px] font-black uppercase">Masuk</span>')
                        + '</td></tr>';
                }).join('') || '<tr><td colspan="5" class="p-8 text-center text-gray-500">Tidak ada campaign yang cocok.</td></tr>';
                const semua = document.getElementById('kaExcludeAll'); if (semua) semua.checked = false;
                kaHitungExclude();
                rcAktifkanUrutSemua('mContentExclude');
            }

            function kaToggleSemuaExclude(src) {
                document.querySelectorAll('.cb-ka-exclude').forEach(c => { c.checked = src.checked; });
                kaHitungExclude();
            }

            function kaHitungExclude() {
                const n = document.querySelectorAll('.cb-ka-exclude:checked').length;
                const el = document.getElementById('kaExcludeCount'); if (el) el.innerText = n;
                setDisabledSafely('btnKaExclude', n === 0);
                setDisabledSafely('btnKaRestore', n === 0);
            }

            async function kaSetExclude(kecualikan) {
                const kode = [];
                document.querySelectorAll('.cb-ka-exclude:checked').forEach(c => kode.push(c.value));
                if (kode.length === 0) return;
                const setuju = await showConfirmModal({
                    title: kecualikan ? 'Exclude Campaign' : 'Restore Campaign',
                    message: kode.length + ' campaign akan '
                        + (kecualikan
                            ? 'dikeluarkan dari Report dan Timetable, termasuk dari email otomatis.'
                            : 'dihitung kembali di Report dan Timetable.')
                        + ' Angka laporan berubah seketika.',
                    confirmText: kecualikan ? 'Ya, Exclude' : 'Ya, Restore',
                    danger: kecualikan
                });
                if (!setuju) return;
                showLoadingOverlay('Menyimpan...');
                try {
                    const res = await fetchApp({
                        action: 'campaignExclude', campaigns: kode, kecualikan: kecualikan,
                        reason: 'Diatur lewat Access Management'
                    });
                    if (res.status !== 'success') { showNotification(res.message || 'Gagal menyimpan.', 'error'); return; }
                    showNotification(res.message || 'Tersimpan.', 'success');
                    logActivity((kecualikan ? 'Exclude' : 'Restore') + ' campaign: ' + kode.join(', '));
                    muatExcludeCampaign();
                } catch (e) { showNotification('Gagal menyimpan.', 'error'); }
                finally { hideLoadingOverlay(); }
            }

            // ---------- Arsip Hapus ----------
            //
            // Akun yang dihapus mendarat di sini, bukan lenyap. Penghapusan di sistem ini selalu
            // dapat dibatalkan: yang benar-benar dilepas hanyalah wewenangnya - izin, depot, dan
            // supervisi - sedangkan barisnya tetap ada supaya jejak pekerjaannya pada dokumen
            // tetap terbaca atas namanya.
            //
            // Izin dan depotnya SENGAJA tidak ikut dipulihkan. Menghidupkan kembali kewenangan
            // lama diam-diam adalah cara paling mudah mengembalikan akses yang justru sedang
            // sengaja dicabut; memberikannya lagi harus menjadi keputusan yang diambil sadar.
            let kaArsipRows = [];

            async function muatArsipAkun() {
                showLoadingOverlay('Memuat Arsip Hapus...');
                try {
                    const res = await fetchApp({ action: 'accountArchive' });
                    if (res.status !== 'success') { showNotification(res.message || 'Gagal memuat.', 'error'); return; }
                    kaArsipRows = res.rows || [];
                    document.getElementById('mArsipBody').innerHTML = kaArsipRows.map(function (r, i) {
                        return '<tr class="border-b border-gray-100 hover:bg-blue-50/40">'
                            + '<td class="p-3 font-black text-gray-800">' + rcEsc(r.userId) + '</td>'
                            + '<td class="p-3 text-gray-700">' + rcEsc(r.namaLengkap || '-') + '</td>'
                            + '<td class="p-3 text-center text-[10px] font-black uppercase text-gray-500">' + rcEsc(r.peran || '-') + '</td>'
                            + '<td class="p-3 text-center text-xs text-gray-500 whitespace-nowrap">' + rcEsc(r.diarsipkanPada || '-')
                            + '<br><span class="text-gray-400">' + rcEsc(r.diarsipkanOleh || '-') + '</span></td>'
                            + '<td class="p-3 text-xs text-gray-600 max-w-[280px] truncate" title="' + rcEsc(r.catatan || '') + '">'
                            + rcEsc(r.catatan || '-') + '</td>'
                            + '<td class="p-3 text-center">' + (r.bentrok
                                ? '<span class="text-[11px] text-red-600 font-bold" title="User ID ini sekarang dipakai akun lain">User ID bentrok</span>'
                                : '<button type="button" onclick="pulihkanAkun(' + i + ')" '
                                  + 'class="px-3 py-1.5 bg-white border border-emerald-300 hover:bg-emerald-50 text-emerald-700 font-bold rounded-lg text-xs">'
                                  + '<i class="fas fa-rotate-left mr-1"></i>Aktifkan Kembali</button>')
                            + '</td></tr>';
                    }).join('') || '<tr><td colspan="6" class="p-8 text-center text-gray-500">Arsip masih kosong.</td></tr>';
                    rcAktifkanUrutSemua('mContentArsip');
                } catch (e) { showNotification('Gagal memuat Arsip Hapus.', 'error'); }
                finally { hideLoadingOverlay(); }
            }

            async function pulihkanAkun(i) {
                const r = kaArsipRows[i]; if (!r) return;
                const setuju = await showConfirmModal({
                    title: 'Aktifkan Kembali ' + r.userId,
                    message: (r.namaLengkap || r.userId) + ' akan dapat masuk lagi memakai PIN lamanya. '
                        + 'Izin dan depotnya TIDAK ikut kembali - berikan lagi lewat tombol Kelola setelah ini.',
                    confirmText: 'Ya, Aktifkan', danger: false
                });
                if (!setuju) return;
                showLoadingOverlay('Mengaktifkan kembali...');
                try {
                    const res = await fetchApp({ action: 'accountRestore', id: r.id, alasan: '' });
                    if (res.status !== 'success') { showNotification(res.message || 'Gagal mengaktifkan.', 'error'); return; }
                    showNotification(res.message, 'success');
                    logActivity('Aktifkan kembali akun ' + r.userId);
                    muatArsipAkun();
                    fetchManageableData();
                } catch (e) { showNotification((e && e.message) || 'Gagal mengaktifkan kembali.', 'error'); }
                finally { hideLoadingOverlay(); }
            }

            // ---------- Permintaan ganti / lupa PIN ----------
            // Antreannya sudah lengkap di server (rc_pin_requests, rc_review_pin) tetapi tidak
            // pernah tampil di layar mana pun, sehingga permintaan menumpuk tanpa ada yang tahu.
            // PIN yang diajukan tidak pernah terlihat di sini; yang disimpan hanya hash-nya, dan
            // berlaku begitu disetujui.
            async function muatPermintaanPin() {
                const wadah = document.getElementById('mReqPin');
                if (!wadah) return;
                try {
                    const res = await fetchApp({ action: 'pinRequests' });
                    if (res.status !== 'success') { wadah.innerHTML = ''; return; }
                    const rows = res.rows || [];
                    wadah.innerHTML = '<h3 class="font-black text-gray-700 mb-3"><i class="fas fa-key mr-2 text-orange-500"></i>Permintaan Ganti PIN'
                        + ' <span class="ml-1 px-2 py-0.5 rounded-full text-[11px] ' + (rows.length ? 'bg-orange-500 text-white' : 'bg-gray-100 text-gray-500') + '">' + rows.length + '</span></h3>'
                        + (rows.length === 0
                            ? '<p class="p-6 text-center text-gray-500 border border-dashed border-gray-200 rounded-xl text-sm">Tidak ada permintaan ganti PIN yang menunggu.</p>'
                            : '<div class="overflow-auto border border-gray-200 rounded-xl"><table class="w-full text-sm"><thead class="bg-gray-50 text-gray-600"><tr>'
                                + '<th class="p-3 text-left font-bold">User ID</th><th class="p-3 text-left font-bold">Nama</th>'
                                + '<th class="p-3 text-left font-bold">Peran / Depot</th><th class="p-3 text-left font-bold">Jenis</th>'
                                + '<th class="p-3 text-left font-bold">Alasan</th><th class="p-3 text-left font-bold">Diajukan</th>'
                                + '<th class="p-3 text-center font-bold" data-rc-no-sort="1">Keputusan</th></tr></thead><tbody>'
                                + rows.map(function (r) {
                                    return '<tr class="border-b border-gray-100">'
                                        + '<td class="p-3 font-black text-blue-700">' + rcEsc(r.userId) + '</td>'
                                        + '<td class="p-3">' + rcEsc(r.namaLengkap || '-') + '</td>'
                                        + '<td class="p-3 text-xs">' + rcEsc(r.peran || '-') + (r.kodeDepot ? ' / ' + rcEsc(r.kodeDepot) : '') + '</td>'
                                        + '<td class="p-3 text-xs font-bold">' + (r.jenis === 'lupa' ? 'Lupa PIN' : 'Ganti PIN') + '</td>'
                                        + '<td class="p-3 text-xs">' + rcEsc(r.alasan || '-') + '</td>'
                                        + '<td class="p-3 text-xs whitespace-nowrap">' + rcEsc(r.diajukan || '-') + '</td>'
                                        + '<td class="p-3 text-center whitespace-nowrap">'
                                        + '<button onclick="tinjauPermintaanPin(\'' + rcEsc(r.id) + '\',true,\'' + rcEsc(r.userId) + '\')" class="px-3 py-1.5 bg-emerald-600 hover:bg-emerald-700 text-white font-bold rounded-lg text-xs mr-1">Setujui</button>'
                                        + '<button onclick="tinjauPermintaanPin(\'' + rcEsc(r.id) + '\',false,\'' + rcEsc(r.userId) + '\')" class="px-3 py-1.5 bg-white border border-red-200 text-red-700 font-bold rounded-lg text-xs">Reject</button>'
                                        + '</td></tr>';
                                }).join('') + '</tbody></table></div>');
                } catch (e) { wadah.innerHTML = ''; }
            }

            async function tinjauPermintaanPin(id, setujui, kode) {
                let catatan = '';
                if (!setujui) {
                    catatan = window.prompt('Alasan penolakan permintaan PIN ' + kode + ':', '') || '';
                    if (!catatan.trim()) { showNotification('Penolakan memerlukan alasan.', 'warning'); return; }
                }
                showLoadingOverlay(setujui ? 'Menyetujui PIN baru...' : 'Menolak permintaan...');
                try {
                    const res = await fetchApp({ action: 'reviewPin', id: id, approve: setujui, note: catatan });
                    if (res.status !== 'success') { showNotification(res.message || 'Gagal memproses.', 'error'); return; }
                    showNotification(res.message, 'success');
                    logActivity((setujui ? 'Setujui' : 'Tolak') + ' permintaan PIN ' + kode);
                    muatPermintaanPin();
                    if (typeof fetchManageableData === 'function') fetchManageableData();
                } catch (e) { showNotification((e && e.message) || 'Gagal memproses permintaan.', 'error'); }
                finally { hideLoadingOverlay(); }
            }

            // ---------- Persetujuan perubahan depot ----------
            // Tiap pengajuan ditampilkan sebagai kartu berisi perbandingan nilai lama dan baru.
            // Menampilkan hanya nilai barunya akan memaksa penyetuju membuka Depot Master di
            // tab lain untuk tahu apa yang sebenarnya berubah.
            async function muatPersetujuanDepot() {
                showLoadingOverlay('Memuat pengajuan depot...');
                try {
                    const res = await fetchApp({ action: 'depotRequests' });
                    if (res.status !== 'success') { showNotification(res.message || 'Gagal memuat.', 'error'); return; }
                    const rows = res.rows || [];
                    document.getElementById('mReqDepot').innerHTML = (rows.length === 0
                        ? '<p class="p-8 text-center text-gray-500">Tidak ada pengajuan yang menunggu.</p>'
                        : rows.map(function (r) {
                            const ubah = r.perubahan || {};
                            const baris = Object.keys(ubah).map(function (k) {
                                const v = ubah[k];
                                const lama = (v && typeof v === 'object' && 'lama' in v) ? v.lama : '';
                                const baru = (v && typeof v === 'object' && 'baru' in v) ? v.baru : v;
                                return '<tr class="border-b border-gray-100">'
                                    + '<td class="p-2 font-bold text-gray-600 text-xs align-top">' + rcEsc(k) + '</td>'
                                    + '<td class="p-2 text-xs text-gray-400 line-through align-top break-all">' + rcEsc(String(lama || '-')) + '</td>'
                                    + '<td class="p-2 text-xs font-bold text-emerald-700 align-top break-all">' + rcEsc(String(baru || '-')) + '</td></tr>';
                            }).join('');
                            return '<div class="border border-gray-200 rounded-xl overflow-hidden">'
                                + '<div class="flex flex-wrap justify-between items-center gap-2 bg-gray-50 p-3 border-b border-gray-200">'
                                + '<div><span class="font-black text-gray-800">' + rcEsc(r.kodeDepot) + ' - ' + rcEsc(r.namaDepot) + '</span>'
                                + '<span class="block text-[11px] text-gray-500">Diajukan ' + rcEsc(r.namaPengaju || r.pengaju || '-')
                                + ' pada ' + rcEsc(r.diajukan || '-') + '</span></div>'
                                + '<div class="flex gap-2">'
                                + '<button onclick="tinjauPengajuanDepot(\'' + rcEsc(r.id) + '\',true)" class="px-4 py-2 bg-emerald-600 hover:bg-emerald-700 text-white font-bold rounded-lg text-xs">Setujui</button>'
                                + '<button onclick="tinjauPengajuanDepot(\'' + rcEsc(r.id) + '\',false)" class="px-4 py-2 bg-white border border-red-200 text-red-700 font-bold rounded-lg text-xs">Reject</button>'
                                + '</div></div>'
                                + '<table class="w-full"><thead class="bg-white"><tr>'
                                + '<th class="p-2 text-left text-[10px] font-black uppercase text-gray-400">Kolom</th>'
                                + '<th class="p-2 text-left text-[10px] font-black uppercase text-gray-400">Sekarang</th>'
                                + '<th class="p-2 text-left text-[10px] font-black uppercase text-gray-400">Diusulkan</th>'
                                + '</tr></thead><tbody>' + baris + '</tbody></table></div>';
                        }).join(''));
                } catch (e) { showNotification('Gagal memuat pengajuan depot.', 'error'); }
                finally { hideLoadingOverlay(); }
            }

            async function tinjauPengajuanDepot(id, setujui) {
                let catatan = '';
                if (!setujui) {
                    catatan = window.prompt('Alasan penolakan (akan terlihat oleh pengaju):', '') || '';
                    if (!catatan.trim()) { showNotification('Penolakan memerlukan alasan.', 'warning'); return; }
                }
                showLoadingOverlay(setujui ? 'Menyetujui...' : 'Menolak...');
                try {
                    const res = await fetchApp({ action: 'depotReview', id: id, setujui: setujui, catatan: catatan });
                    if (res.status !== 'success') { showNotification(res.message || 'Gagal memproses.', 'error'); return; }
                    showNotification(res.message || (setujui ? 'Pengajuan disetujui.' : 'Pengajuan ditolak.'), 'success');
                    logActivity('Tinjau pengajuan depot ' + id + ': ' + (setujui ? 'disetujui' : 'ditolak'));
                    muatPersetujuanDepot();
                } catch (e) { showNotification('Gagal memproses pengajuan.', 'error'); }
                finally { hideLoadingOverlay(); }
            }

            // ---------- Grade depot ----------
            // Nilainya disunting langsung di tabel lalu disimpan sekaligus. Hanya baris yang
            // benar-benar berubah yang dikirim, supaya catatan aktivitas tidak dipenuhi
            // penyimpanan yang tidak mengubah apa pun.
            async function muatGradeDepot() {
                showLoadingOverlay('Memuat grade depot...');
                try {
                    const res = await fetchApp({ action: 'depotGradeList' });
                    if (res.status !== 'success') { showNotification(res.message || 'Gagal memuat.', 'error'); return; }
                    kaGradeRows = res.rows || [];
                    document.getElementById('kaGradeBody').innerHTML = kaGradeRows.map(function (r, i) {
                        return '<tr class="border-b border-gray-100">'
                            + '<td class="p-3 font-black text-gray-800">' + rcEsc(r.kode) + '</td>'
                            + '<td class="p-3 text-gray-700">' + rcEsc(r.nama) + '</td>'
                            + '<td class="p-3 text-center text-gray-500">' + rcEsc(r.region || '-') + '</td>'
                            + '<td class="p-3 text-center"><input id="kaGrade_' + i + '" value="' + rcEsc(r.grade || '')
                            + '" class="w-24 px-2 py-1.5 border border-gray-300 rounded-lg text-sm text-center font-bold uppercase"></td>'
                            + '<td class="p-3 text-center"><input id="kaTipe_' + i + '" value="' + rcEsc(r.tipe || '')
                            + '" class="w-36 px-2 py-1.5 border border-gray-300 rounded-lg text-sm text-center"></td></tr>';
                    }).join('') || '<tr><td colspan="5" class="p-8 text-center text-gray-500">Tidak ada depot.</td></tr>';
                } catch (e) { showNotification('Gagal memuat grade depot.', 'error'); }
                finally { hideLoadingOverlay(); }
            }

            async function simpanGradeDepot() {
                const rows = [];
                kaGradeRows.forEach(function (r, i) {
                    const g = getValueSafely('kaGrade_' + i).trim();
                    const t = getValueSafely('kaTipe_' + i).trim();
                    if (g !== String(r.grade || '') || t !== String(r.tipe || '')) {
                        rows.push({ kode: r.kode, grade: g, tipe: t });
                    }
                });
                if (rows.length === 0) { showNotification('Tidak ada perubahan untuk disimpan.', 'warning'); return; }
                setDisabledSafely('btnSimpanGrade', true);
                showLoadingOverlay('Menyimpan grade...');
                try {
                    const res = await fetchApp({ action: 'depotGradeSet', rows: rows });
                    if (res.status !== 'success') { showNotification(res.message || 'Gagal menyimpan.', 'error'); return; }
                    showNotification(res.message || rows.length + ' depot diperbarui.', 'success');
                    logActivity('Ubah grade depot: ' + rows.map(r => r.kode).join(', '));
                    muatGradeDepot();
                } catch (e) { showNotification('Gagal menyimpan grade depot.', 'error'); }
                finally { setDisabledSafely('btnSimpanGrade', false); hideLoadingOverlay(); }
            }

            // ---------- Approval On/Off (20261162180000) ----------
            // Saklar seluruh sistem. Saat dimatikan, submit langsung ke tahap Release; dokumen yang
            // sudah diajukan sebelumnya tetap diputuskan lewat Management of Approval.
            let kaApprovalAktif = true;

            async function muatSetelanApproval() {
                try {
                    const res = await fetchApp({ action: 'approvalSetelan' });
                    if (res.status !== 'success') { showNotification(res.message || 'Gagal memuat setelan approval.', 'error'); return; }
                    kaApprovalAktif = res.aktif === true;
                    const lencana = document.getElementById('kaApprovalLencana');
                    lencana.innerText = kaApprovalAktif ? 'APPROVAL AKTIF' : 'APPROVAL DIMATIKAN';
                    lencana.className = 'px-3 py-1.5 rounded-lg text-sm font-black '
                        + (kaApprovalAktif ? 'bg-green-100 text-green-800' : 'bg-red-100 text-red-700');
                    document.getElementById('kaApprovalSejak').innerText = res.diubahPada
                        ? 'Diubah ' + res.diubahPada + ' oleh ' + (res.diubahOleh || '-') + (res.catatan ? ' — ' + res.catatan : '')
                        : 'Belum pernah diubah (bawaan: aktif).';
                    const n = Number(res.menunggu || 0);
                    document.getElementById('kaApprovalMenunggu').innerText = n > 0
                        ? n.toLocaleString('id-ID') + ' dokumen dari ' + Number(res.menungguDepot || 0) + ' depot masih menunggu keputusan di Management of Approval.'
                        : 'Tidak ada dokumen yang menunggu approval.';
                    const btn = document.getElementById('btnKaApproval');
                    btn.innerText = kaApprovalAktif ? 'Matikan Approval' : 'Hidupkan Approval';
                    btn.className = 'px-6 py-2.5 font-bold rounded-lg text-sm shadow-md text-white '
                        + (kaApprovalAktif ? 'bg-red-600 hover:bg-red-700' : 'bg-green-600 hover:bg-green-700');
                    document.getElementById('kaApprovalRiwayat').innerHTML = (res.riwayat || []).map(function (r) {
                        return '<div><span class="font-bold">' + rcEsc(r.waktu) + '</span> &middot; ' + rcEsc(r.aksi) + ' oleh '
                            + rcEsc(r.oleh || '-') + (r.catatan ? ' &mdash; ' + rcEsc(r.catatan) : '') + '</div>';
                    }).join('') || '<div class="text-gray-400">Belum ada perubahan.</div>';
                } catch (e) { showNotification('Gagal memuat setelan approval.', 'error'); }
            }

            async function ubahSetelanApproval() {
                const catatan = (document.getElementById('kaApprovalCatatan').value || '').trim();
                if (catatan.length < 3) { showNotification('Isi alasan perubahan lebih dulu.', 'warning'); return; }
                const target = !kaApprovalAktif;
                const setuju = await showConfirmModal({
                    title: target ? 'Hidupkan Approval' : 'Matikan Approval',
                    message: target
                        ? 'Pengajuan baru akan kembali menunggu persetujuan di Management of Approval.'
                        : 'Pengajuan baru langsung ke tahap Release tanpa approval, dan email pengajuannya berjudul "Pengajuan Claim Depot ...". Dokumen yang sudah diajukan tetap harus diputuskan lewat Management of Approval.'
                });
                if (!setuju) return;
                setDisabledSafely('btnKaApproval', true);
                try {
                    const res = await fetchApp({ action: 'approvalSetel', aktif: target, catatan: catatan });
                    if (res.status !== 'success') { showNotification(res.message || 'Gagal mengubah setelan.', 'error'); return; }
                    showNotification(res.message || 'Tersimpan.', 'success');
                    logActivity((target ? 'Hidupkan' : 'Matikan') + ' approval: ' + catatan);
                    document.getElementById('kaApprovalCatatan').value = '';
                    await muatSetelanApproval();
                } catch (e) {
                    showNotification((e && e.message) ? e.message : 'Gagal mengubah setelan.', 'error');
                } finally { setDisabledSafely('btnKaApproval', false); }
            }
