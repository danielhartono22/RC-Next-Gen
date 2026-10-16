            // =============================================================================
            // EMAIL PENGAJUAN
            // =============================================================================
            // Berbeda dari Email Otomatis yang terjadwal, surat di sini berangkat saat kejadian:
            // Submitted, On Hold, Expired, Approval dan Clearing. Layar ini hanya mengatur tiga
            // hal - sakelar, daftar CC tambahan, dan kirim uji.
            //
            // Seluruh keputusan siapa menerima apa ada di server. Layar tidak pernah menyusun
            // daftar penerima sendiri; ia hanya menampilkan apa yang server katakan, supaya tidak
            // ada dua versi kebenaran yang bisa berbeda diam-diam.

            let epData = null;

            async function loadEmailPanelPengajuan() {
                const kotak = document.getElementById('epPenerima');
                if (kotak) kotak.textContent = 'Memuat...';
                try {
                    const res = await fetchApp({ action: 'emailPengajuanBaca' });
                    if (!res || res.status !== 'success') throw new Error((res && res.message) || 'Gagal memuat.');
                    epData = res;
                    epGambar();
                } catch (e) {
                    if (kotak) kotak.innerHTML = '<span class="text-red-600">' + rcEsc(e.message || 'Gagal memuat.') + '</span>';
                }
            }

            function epGambar() {
                const d = epData || {};
                const aktif = d.aktif === true;

                const lbl = document.getElementById('epStatusLabel');
                if (lbl) {
                    lbl.textContent = aktif ? 'AKTIF' : 'NONAKTIF';
                    lbl.className = 'text-xs font-black px-3 py-1.5 rounded-full '
                        + (aktif ? 'bg-green-100 text-green-700' : 'bg-gray-100 text-gray-500');
                }
                const btn = document.getElementById('epToggle');
                if (btn) {
                    btn.textContent = aktif ? 'Nonaktifkan' : 'Aktifkan';
                    btn.className = 'text-xs font-bold py-2 px-4 rounded-lg transition '
                        + (aktif ? 'bg-red-100 hover:bg-red-200 text-red-700'
                                 : 'bg-gray-200 hover:bg-gray-300 text-gray-700');
                }

                const ta = document.getElementById('epCcTambahan');
                if (ta) ta.value = (d.ccTambahan || []).join('\n');
                // 20261163150000: CC wajib per jenis email.
                document.querySelectorAll('.ep-cc-jenis').forEach(function (el) {
                    el.value = ((d.ccPerJenis || {})[el.dataset.jenis] || []).join('\n');
                });

                setHiddenSafely('epHanyaUji', d.hanyaUji !== true);

                const cbUji = document.getElementById('epModeUji');
                if (cbUji) cbUji.checked = d.modeUji === true;
                const elUji = document.getElementById('epEmailUji');
                if (elUji && !elUji.value) elUji.value = d.emailUji || '';
                epGambarModeUji();

                // Depot tanpa alamat tidak akan pernah menerima surat. Diam-diam dilewati server,
                // jadi satu-satunya tempat hal itu bisa diketahui adalah di sini.
                const per = document.getElementById('epPeringatan');
                if (per) {
                    const n = Number(d.depotTanpaEmail || 0);
                    if (n > 0) {
                        per.innerHTML = '<i class="fas fa-triangle-exclamation mr-1.5"></i><strong>'
                            + n + ' depot</strong> belum punya alamat email di Depot Master. '
                            + 'Depot tersebut tidak akan menerima surat apa pun sampai alamatnya diisi.';
                        setHiddenSafely('epPeringatan', false);
                    } else {
                        setHiddenSafely('epPeringatan', true);
                    }
                }

                const jejak = document.getElementById('epJejak');
                if (jejak) {
                    jejak.textContent = d.diubahPada
                        ? 'Terakhir diubah ' + d.diubahPada + (d.diubahOleh ? ' oleh ' + d.diubahOleh : '')
                        : 'Belum pernah diubah.';
                }

                epGambarPenerima();

                // Pengguna yang hanya boleh melihat tetap melihat isinya, tetapi kendalinya mati.
                // Penguncian sesungguhnya ada di server; ini semata supaya tidak ada orang yang
                // mengetik panjang-panjang lalu ditolak.
                if (d.bolehUbah === false) {
                    ['epToggle', 'epBtnSimpan', 'epBtnUji', 'epCcTambahan', 'epEmailUji']
                        .forEach(function (id) {
                            const el = document.getElementById(id);
                            if (el) { el.disabled = true; el.classList.add('opacity-50', 'cursor-not-allowed'); }
                        });
                    document.querySelectorAll('.ep-cc-jenis').forEach(function (el) {
                        el.disabled = true; el.classList.add('opacity-50', 'cursor-not-allowed');
                    });
                }
            }

            // Mode Uji dan sakelar AKTIF adalah dua hal berbeda, dan gabungannya menentukan
            // siapa yang benar-benar menerima surat. Karena salah membacanya berarti surat
            // sampai ke orang sungguhan, keadaannya dikatakan dengan kalimat penuh, bukan
            // hanya lewat centang.
            function epGambarModeUji() {
                const cb = document.getElementById('epModeUji');
                const el = document.getElementById('epStatusUji');
                if (!cb || !el) return;
                const alamat = (document.getElementById('epEmailUji') || {}).value || '';
                const aktif = epData && epData.aktif === true;

                if (cb.checked && !alamat.trim()) {
                    el.className = 'text-[11px] mt-2 rounded px-2 py-1.5 leading-relaxed bg-red-50 border border-red-200 text-red-700';
                    el.textContent = 'Mode Uji perlu alamat uji. Tanpa itu, penyimpanan akan ditolak.';
                } else if (cb.checked) {
                    el.className = 'text-[11px] mt-2 rounded px-2 py-1.5 leading-relaxed bg-gray-800 text-gray-100';
                    el.textContent = aktif
                        ? 'Seluruh email dari action akan masuk ke ' + alamat.trim() + '. Depot tidak menerima apa pun.'
                        : 'Sakelar masih nonaktif, jadi belum ada email sama sekali. Nyalakan sakelar agar Mode Uji berjalan.';
                } else if (aktif) {
                    el.className = 'text-[11px] mt-2 rounded px-2 py-1.5 leading-relaxed bg-amber-50 border border-amber-200 text-amber-800';
                    el.textContent = 'Mode Uji mati dan sakelar aktif: email akan dikirim ke alamat depot yang sebenarnya.';
                } else {
                    el.className = 'text-[11px] mt-2 rounded px-2 py-1.5 leading-relaxed bg-gray-100 text-gray-500';
                    el.textContent = 'Pengiriman nonaktif. Tidak ada email yang berangkat.';
                }
            }

            function epGambarPenerima() {
                const kotak = document.getElementById('epPenerima');
                if (!kotak) return;
                const d = epData || {};
                const to = d.contohTo || [];
                const cc = d.contohCc || [];

                if (!to.length && !cc.length) {
                    kotak.innerHTML = '<span class="text-amber-700">Belum ada depot dengan alamat email pada Depot Master.</span>';
                    return;
                }

                function daftar(judul, arr, warna) {
                    return '<div class="mb-3">'
                        + '<div class="text-[11px] font-black ' + warna + ' mb-1.5">' + judul
                        + ' <span class="font-bold text-gray-400">(' + arr.length + ')</span></div>'
                        + (arr.length
                            ? '<div class="flex flex-wrap gap-1.5">' + arr.map(function (a) {
                                return '<span class="inline-block bg-gray-100 text-gray-700 rounded px-2 py-1 text-[11px] break-all">'
                                    + rcEsc(a) + '</span>';
                              }).join('') + '</div>'
                            : '<span class="text-[11px] text-gray-400">tidak ada</span>')
                        + '</div>';
                }

                kotak.innerHTML =
                    '<div class="text-[11px] text-gray-600 mb-3">Depot contoh: <strong>'
                    + rcEsc(d.depotContoh || '-') + '</strong></div>'
                    + daftar('TO &mdash; alamat depot', to, 'text-green-700')
                    + daftar('CC &mdash; OSC &amp; Supervisor sesuai yurisdiksi, dan email tambahan di tab ini', cc, 'text-blue-700')
                    // Depot tanpa OSC/Supervisor dan tanpa email tambahan akan berangkat tanpa
                    // tembusan sama sekali. Dikatakan terus terang di sini, karena CC kosong
                    // mudah disangka kerusakan padahal itu memang keadaan datanya.
                    + (cc.length ? ''
                        : '<div class="text-[11px] text-amber-700 bg-amber-50 border border-amber-200 rounded px-2 py-1.5 leading-relaxed">'
                          + 'Depot ini belum punya OSC atau Supervisor yang ditugaskan, dan daftar email '
                          + 'tambahan masih kosong &mdash; suratnya akan berangkat tanpa CC.</div>');
            }

            // Alamat boleh diketik satu per baris atau dipisah koma; keduanya wajar dilakukan
            // orang, jadi keduanya diterima.
            function epBacaCc() {
                const ta = document.getElementById('epCcTambahan');
                if (!ta) return [];
                return String(ta.value || '')
                    .split(/[\n,;]+/)
                    .map(function (s) { return s.trim().toLowerCase(); })
                    .filter(function (s) { return s !== ''; })
                    .filter(function (s, i, a) { return a.indexOf(s) === i; });
            }

            // CC wajib per jenis (20261163150000): { pengajuan: [...], approval: [...], ... }.
            function epBacaCcJenis() {
                const hasil = {};
                document.querySelectorAll('.ep-cc-jenis').forEach(function (el) {
                    hasil[el.dataset.jenis] = String(el.value || '').split(/[\n,;]+/)
                        .map(function (s) { return s.trim().toLowerCase(); })
                        .filter(function (s, i, a) { return s !== '' && a.indexOf(s) === i; });
                });
                return hasil;
            }

            function epToggleAktif() {
                if (!epData) return;
                // Tombol ini menggambar ulang panel dari epData. Isian CC yang sudah diketik tetapi
                // belum disimpan ikut dibawa; dulu isian itu hilang begitu tombol ditekan.
                epData.ccTambahan = epBacaCc();
                epData.ccPerJenis = epBacaCcJenis();
                epData.aktif = !epData.aktif;
                epGambar();
                showNotification(epData.aktif
                    ? 'Pengiriman akan AKTIF setelah Simpan ditekan.'
                    : 'Pengiriman akan NONAKTIF setelah Simpan ditekan.', 'info');
            }

            async function epSimpan() {
                if (!epData) return;
                const cc = epBacaCc();

                // Seluruh nilai dibaca lebih dulu, sebelum ada cabang yang memakainya. Versi
                // sebelumnya membaca modeUji di bawah tetapi memakainya di atas - JavaScript
                // melempar ReferenceError di situ, dan lemparannya terjadi di luar try sehingga
                // tidak tertangkap: penyimpanan mati tanpa pesan apa pun.
                const modeUji = !!(document.getElementById('epModeUji') || {}).checked;
                const emailUji = String((document.getElementById('epEmailUji') || {}).value || '').trim();
                if (modeUji && !emailUji) {
                    showNotification('Mode Uji memerlukan alamat email uji.', 'warning');
                    return;
                }

                // Menyalakan pengiriman berarti surat mulai berangkat ke alamat orang sungguhan.
                // Konfirmasi hanya diminta ketika itu benar-benar terjadi. Dalam Mode Uji tidak
                // ada yang perlu dikhawatirkan, dan bertanya pada saat yang tidak berbahaya
                // justru membuat pertanyaannya diabaikan ketika keadaannya memang berbahaya.
                if (epData.aktif && !modeUji) {
                    const ok = await showConfirmModal({
                        title: 'Aktifkan Email Pengajuan?',
                        message: 'Mulai sekarang setiap Submitted, On Hold, Expired, Approval, Amend Doc, Reprocessing Doc dan '
                            + 'Clearing akan mengirim email ke alamat depot pada Depot Master beserta '
                            + 'CC-nya. Alamat tersebut milik orang sungguhan.\n\n'
                            + 'Untuk mencobanya lebih dulu tanpa menyentuh depot, centang Mode Uji.',
                        confirmText: 'Ya, Aktifkan'
                    });
                    if (!ok) return;
                }

                const btn = document.getElementById('epBtnSimpan');
                if (btn) btn.disabled = true;
                try {
                    const res = await fetchApp({ action: 'emailPengajuanSimpan',
                        aktif: epData.aktif === true, cc: cc, ccJenis: epBacaCcJenis(),
                        modeUji: modeUji, emailUji: emailUji });
                    if (!res || res.status !== 'success') {
                        throw new Error((res && res.message) || 'Gagal menyimpan.');
                    }
                    showNotification(res.message || 'Tersimpan.', 'success');
                    await loadEmailPanelPengajuan();
                } catch (e) {
                    showNotification(e.message || 'Gagal menyimpan.', 'error');
                } finally {
                    if (btn) btn.disabled = false;
                }
            }

            async function epKirimUji() {
                const el = document.getElementById('epEmailUji');
                const alamat = el ? String(el.value || '').trim() : '';
                if (!alamat) { showNotification('Isi alamat email uji terlebih dahulu.', 'warning'); return; }

                const btn = document.getElementById('epBtnUji');
                const semula = btn ? btn.innerHTML : '';
                if (btn) { btn.disabled = true; btn.innerHTML = '<i class="fas fa-spinner fa-spin mr-1.5"></i> Mengirim...'; }
                try {
                    const res = await fetchApp({ action: 'emailPengajuanUji', email: alamat });
                    showNotification((res && res.message) || 'Terkirim.',
                        (res && res.status === 'success') ? 'success' : 'warning');
                } catch (e) {
                    showNotification(e.message || 'Gagal mengirim email uji.', 'error');
                } finally {
                    if (btn) { btn.disabled = false; btn.innerHTML = semula; }
                }
            }
