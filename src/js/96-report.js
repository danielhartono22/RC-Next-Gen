            // ============================================================================
            // MODUL REPORT - Dashboard, Cost Center 1, Cost Center 2, dan Email Otomatis
            // ============================================================================
            // Susunannya mengikuti Dashboard.html pada RC_Reporting_AppsScript. Seluruh angka
            // datang dari RPC yang membaca public.claims langsung, sehingga tidak ada
            // perhitungan kedua di browser yang bisa menyimpang dari email otomatis maupun
            // modul lain.






            // Dipanggil ekspor Excel untuk bagian yang belum pernah dibuka tabnya. Filternya
            // sama dengan yang sedang aktif di layar, supaya berkas yang keluar menggambarkan
            // apa yang sedang dilihat - bukan seluruh data yang kebetulan ada di server.
            async function rtMuatBagian(nama) {
                const f = filterReport();
                if (nama === 'dashboard') {
                    const res = await fetchApp({ action: 'reportDashboard', filter: f });
                    if (res.status === 'success') rtData.dashboard = res;
                } else if (nama === 'cc1') {
                    const res = await fetchApp({ action: 'costCenter', filter: f });
                    if (res.status === 'success') rtData.cc1 = res;
                } else if (nama === 'cc2') {
                    const res = await fetchApp({ action: 'costCenter2', filter: f });
                    if (res.status === 'success') rtData.cc2 = res;
                }
            }

            async function loadReport() {
                showLoadingOverlay();
                try {
                    const f = filterReport();
                    if (rtTabAktif === 'dashboard') {
                        const res = await fetchApp({ action: 'reportDashboard', filter: f });
                        if (res.status !== 'success') throw new Error(res.message || 'Gagal memuat Dashboard.');
                        rtData.dashboard = res;
                        // Filter diisi dari hasil terbaru, sebelum digambar.
                        rtIsiFilterDariData(res);
                        renderReportDashboard(res);
                    } else if (rtTabAktif === 'cc1') {
                        const res = await fetchApp({ action: 'costCenter', filter: f });
                        if (res.status !== 'success') throw new Error(res.message || 'Gagal memuat Cost Center 1.');
                        rtData.cc1 = res;
                        renderCostCenter1(res.rows || []);
                        renderCc1Charts(res.rows || []);
                        rcAktifkanUrutSemua('rtPaneCc1');
                    } else if (rtTabAktif === 'cc2') {
                        const res = await fetchApp({ action: 'costCenter2', filter: f });
                        if (res.status !== 'success') throw new Error(res.message || 'Gagal memuat Cost Center 2.');
                        rtData.cc2 = res;
                        rtIsiFilterBulan(res.rows || []);
                        renderCc2Terfilter();
                    }
                } catch (e) {
                    showNotification((e && e.message) ? e.message : 'Gagal memuat laporan.', 'error');
                } finally {
                    hideLoadingOverlay();
                }
            }


            // ---- Email otomatis ------------------------------------------------------------
            const RT_HARI = ['Minggu', 'Senin', 'Selasa', 'Rabu', 'Kamis', 'Jumat', 'Sabtu'];

            async function loadEmailPanel() {
                showLoadingOverlay();
                try {
                    const res = await fetchApp({ action: 'emailStatus' });
                    if (res.status !== 'success') throw new Error(res.message || 'Gagal memuat status email.');

                    document.getElementById('rtEmailJadwal').innerHTML = (res.pengaturan || []).map(function (p) {
                        // hariList null berarti TIAP HARI. Daftar berisi angka berarti hanya hari
                        // itu - sehingga hari yang tidak dikehendaki cukup tidak dicentang.
                        const dipilih = Array.isArray(p.hariList) ? p.hariList.map(Number) : [];
                        const tiapHari = dipilih.length === 0;
                        return '<div class="p-3 border border-gray-200 rounded-xl space-y-2" data-jenis="' + rcEsc(p.jenis) + '">'
                            + '<div class="flex flex-wrap items-center gap-3">'
                            + '<label class="flex items-center gap-2 w-40"><input type="checkbox" class="rt-email-aktif rounded text-blue-600"' + (p.aktif ? ' checked' : '') + '>'
                            + '<span class="font-black text-gray-800 capitalize">' + rcEsc(p.jenis) + '</span></label>'
                            + '<div class="flex items-center gap-2"><span class="text-xs text-gray-500">Jam</span>'
                            + '<input type="number" min="0" max="23" value="' + Number(p.jam || 0) + '" class="rt-email-jam w-16 px-2 py-1.5 border border-gray-300 rounded-lg text-sm text-center">'
                            + '<span class="text-[10px] text-gray-400">WIB</span></div>'
                            + '<input type="text" value="' + rcEsc(p.subjek || '') + '" class="rt-email-subjek flex-1 min-w-[220px] px-3 py-1.5 border border-gray-300 rounded-lg text-sm">'
                            + '<button type="button" onclick="kirimEmailManual(&#39;' + rcEsc(p.jenis) + '&#39;)" '
                            + 'class="px-4 py-1.5 bg-amber-600 hover:bg-amber-700 text-white font-bold rounded-lg text-xs whitespace-nowrap">'
                            + '<i class="fas fa-paper-plane mr-1"></i>Kirim Manual</button>'
                            + '</div>'
                            + '<div class="flex flex-wrap items-center gap-2 pl-1">'
                            + '<span class="text-xs text-gray-500 w-14">Hari</span>'
                            + RT_HARI.map(function (h, i) {
                                return '<label class="flex items-center gap-1.5 px-2 py-1 border border-gray-200 rounded-lg cursor-pointer hover:bg-gray-50">'
                                    + '<input type="checkbox" class="rt-email-hari rounded text-blue-600" value="' + i + '"'
                                    + (dipilih.indexOf(i) > -1 ? ' checked' : '') + ' onchange="rtPerbaruiCatatanHari(this)">'
                                    + '<span class="text-xs font-bold text-gray-700">' + h + '</span></label>';
                              }).join('')
                            + '<span class="rt-email-hari-catatan text-[11px] ' + (tiapHari ? 'text-blue-600' : 'text-gray-400') + '">'
                            + (tiapHari ? 'Tidak ada yang dicentang: dikirim TIAP HARI' : dipilih.length + ' hari dipilih')
                            + '</span></div></div>';
                    }).join('');

                    const r = res.ringkas || {};
                    document.getElementById('rtEmailRingkas').innerText =
                        (res.depotBerEmail || 0) + ' dari ' + (res.depotTotal || 0) + ' depot punya alamat email. '
                        + Object.keys(r).map(k => k + ': ' + r[k]).join(', ');

                    document.getElementById('rtEmailBody').innerHTML = (res.antrean || []).map(function (a) {
                        return '<tr class="border-b border-gray-100">'
                            + '<td class="p-3 whitespace-nowrap text-gray-600">' + rcEsc(a.dibuat || '-') + '</td>'
                            + '<td class="p-3 font-bold capitalize">' + rcEsc(a.jenis) + '</td>'
                            + '<td class="p-3 max-w-[280px] truncate" title="' + rcEsc(a.subjek) + '">' + rcEsc(a.subjek) + '</td>'
                            + '<td class="p-3 text-center">' + Number(a.tujuan || 0) + (a.cc ? ' +' + a.cc + ' cc' : '') + '</td>'
                            + '<td class="p-3 text-center"><span class="px-2 py-0.5 rounded text-[10px] font-black uppercase ' + rtWarnaEmail(a.status) + '">' + rcEsc(a.status) + '</span></td>'
                            + '<td class="p-3 text-xs text-gray-500 max-w-[260px] truncate" title="' + rcEsc(a.galat || '') + '">' + rcEsc(a.galat || '-') + '</td>'
                            // Email yang masih mengantre atau sudah gagal dapat dibatalkan dari sini.
                            // Tanpa jalan ini, satu pengiriman yang terlanjur diantrekan hanya dapat
                            // dihentikan lewat SQL langsung ke tabel.
                            + '<td class="p-3 text-center">' + (['pending', 'failed'].indexOf(String(a.status)) > -1
                                ? '<button type="button" onclick="batalkanEmailAntrean(&#39;' + rcEsc(a.id) + '&#39;)" '
                                  + 'class="px-3 py-1.5 bg-white border border-red-200 hover:bg-red-50 text-red-700 font-bold rounded-lg text-xs">Batalkan</button>'
                                : '<span class="text-gray-300 text-xs">-</span>') + '</td></tr>';
                    }).join('') || '<tr><td colspan="7" class="p-6 text-center text-gray-400">Antrean masih kosong.</td></tr>';

                    rcAktifkanUrutSemua('mContentEmail');
                } catch (e) {
                    showNotification((e && e.message) ? e.message : 'Gagal memuat panel email.', 'error');
                } finally { hideLoadingOverlay(); }
            }

            async function batalkanEmailAntrean(id) {
                const setuju = await showConfirmModal({
                    title: 'Batalkan Email',
                    message: 'Email ini tidak akan dikirim ke siapa pun. Statusnya menjadi skipped '
                        + 'dan tetap tercatat di antrean sebagai riwayat.',
                    confirmText: 'Ya, Batalkan', danger: true
                });
                if (!setuju) return;
                showLoadingOverlay('Membatalkan email...');
                try {
                    const res = await fetchApp({ action: 'emailCancel', id: id });
                    if (res.status !== 'success') { showNotification(res.message || 'Gagal membatalkan.', 'error'); return; }
                    showNotification(res.message, 'success');
                    logActivity('Batalkan email antrean ' + id);
                    loadEmailPanel();
                } catch (e) { showNotification('Gagal membatalkan email.', 'error'); }
                finally { hideLoadingOverlay(); }
            }

            function rtWarnaEmail(s) {
                return { pending: 'bg-yellow-100 text-yellow-800', sent: 'bg-green-100 text-green-800',
                         failed: 'bg-red-100 text-red-800', skipped: 'bg-gray-200 text-gray-700' }[s]
                    || 'bg-gray-100 text-gray-700';
            }

            async function simpanJadwalEmail() {
                const rows = [...document.querySelectorAll('#rtEmailJadwal [data-jenis]')].map(function (el) {
                    // Daftar kosong dikirim apa adanya dan diartikan server sebagai TIAP HARI.
                    // Itu sebabnya hariList selalu ikut dikirim: tidak mengirimnya berarti
                    // "biarkan seperti semula", dan pengguna yang baru saja mengosongkan seluruh
                    // centang tidak akan melihat perubahannya tersimpan.
                    const hari = [...el.querySelectorAll('.rt-email-hari:checked')].map(c => Number(c.value));
                    return {
                        jenis: el.dataset.jenis,
                        aktif: el.querySelector('.rt-email-aktif').checked,
                        jam: Number(el.querySelector('.rt-email-jam').value),
                        subjek: el.querySelector('.rt-email-subjek').value.trim(),
                        hariList: hari
                    };
                });
                try {
                    const res = await fetchApp({ action: 'emailSettingsSave', rows: rows });
                    if (res.status === 'success') {
                        showNotification(res.message || 'Jadwal email disimpan.', 'success');
                        loadEmailPanel();
                    } else showNotification(res.message || 'Gagal menyimpan jadwal.', 'error');
                } catch (e) { showNotification((e && e.message) || 'Gagal menyimpan jadwal.', 'error'); }
            }

            // Keterangan di sebelah deretan centang hari, disegarkan tanpa menggambar ulang
            // seluruh panel supaya centang lain tidak ikut hilang saat diklik.
            function rtPerbaruiCatatanHari(el) {
                const baris = el.closest('[data-jenis]');
                if (!baris) return;
                const n = baris.querySelectorAll('.rt-email-hari:checked').length;
                const catatan = baris.querySelector('.rt-email-hari-catatan');
                if (!catatan) return;
                catatan.innerText = n === 0 ? 'Tidak ada yang dicentang: dikirim TIAP HARI' : n + ' hari dipilih';
                catatan.className = 'rt-email-hari-catatan text-[11px] ' + (n === 0 ? 'text-blue-600' : 'text-gray-400');
            }

            // Kirim manual: ke penerima depot yang sesungguhnya, seketika. Dikonfirmasi lebih
            // dulu karena inilah satu-satunya tombol di layar ini yang benar-benar mengirim
            // kepada orang banyak tanpa menunggu jadwal.
            async function kirimEmailManual(jenis) {
                const setuju = await showConfirmModal({
                    title: 'Kirim Manual - ' + jenis,
                    message: 'Email ' + jenis + ' akan disusun dan LANGSUNG dikirim ke seluruh penerima '
                        + 'depot yang terdaftar, tanpa menunggu jadwal. Lanjutkan?',
                    confirmText: 'Ya, Kirim Sekarang', danger: true
                });
                if (!setuju) return;
                showLoadingOverlay('Mengirim ' + jenis + '...');
                try {
                    const res = await fetchApp({ action: 'emailSendNow', jenis: jenis });
                    showNotification(res.message || 'Selesai.',
                        res.status === 'success' ? 'success' : 'warning');
                    logActivity('Kirim manual email ' + jenis);
                    loadEmailPanel();
                } catch (e) {
                    showNotification((e && e.message) ? e.message : 'Gagal mengirim.', 'error');
                } finally { hideLoadingOverlay(); }
            }

            async function pratinjauEmail(jenis) {
                showLoadingOverlay();
                try {
                    const res = await fetchApp({ action: 'emailCompose', jenis: jenis, kirim: false });
                    if (res.status !== 'success') throw new Error(res.message || 'Gagal menyusun pratinjau.');
                    rcDialog('Pratinjau ' + jenis,
                        '<p class="text-xs text-gray-500 mb-2">' + rcEsc(res.message || '') + '</p>'
                        + '<p class="text-xs mb-3"><b>Subjek:</b> ' + rcEsc(res.subjek || '-') + '</p>'
                        + '<div class="border border-gray-200 rounded-lg p-3 bg-white max-h-[50vh] overflow-auto">'
                        + (res.isiHtml || '<i>kosong</i>') + '</div>');
                    loadEmailPanel();
                } catch (e) {
                    showNotification((e && e.message) ? e.message : 'Gagal menyusun pratinjau.', 'error');
                } finally { hideLoadingOverlay(); }
            }

            async function ujiKoneksiEmail() {
                const kotak = document.getElementById('rtEmailKoneksi');
                try {
                    const res = await fetchApp({ action: 'emailTestConnection' });
                    const siap = res.gmailSiap || res.resendSiap;
                    kotak.className = 'mb-4 p-3 rounded-lg text-sm ' + (siap
                        ? 'bg-green-50 text-green-800 border border-green-200'
                        : 'bg-orange-50 text-orange-800 border border-orange-200');
                    kotak.innerHTML = '<b>' + rcEsc(res.pesan || '') + '</b><br>'
                        + '<span class="text-xs">Pengirim: ' + rcEsc(res.pengirim || '-') + '</span>';
                    setHiddenSafely('rtEmailKoneksi', false);
                } catch (e) {
                    kotak.className = 'mb-4 p-3 rounded-lg text-sm bg-red-50 text-red-800 border border-red-200';
                    kotak.innerText = (e && e.message) ? e.message : 'Gagal menguji koneksi.';
                    setHiddenSafely('rtEmailKoneksi', false);
                }
            }
