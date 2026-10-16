            // =============================================================================
            // MUAT BERTAHAP
            // =============================================================================
            // Antrean Workflow dan daftar Analytics dapat berisi puluhan ribu baris. Satu
            // permintaan untuk seluruhnya melewati batas waktu server (8 detik) dan layarnya
            // kosong. Keduanya kini diambil per halaman memakai kursor dari server: halaman
            // pertama langsung digambar, sisanya menyusul di latar belakang, dan tabel
            // diperbarui berkala tanpa menghapus pilihan filter maupun centangan baris.
            //
            // Pemuatan baru untuk layar yang sama - misalnya setelah Release - menghentikan
            // pemuatan yang lama, sehingga dua pemuatan tidak pernah saling menimpa.

            const rcMuatAktif = {};

            // opsi.kunci   nama layar; pemuatan baru dengan kunci yang sama menghentikan yang lama
            // opsi.label   teks indikator kemajuan
            // opsi.ambil   (setelah, pertama) => Promise respons satu halaman
            // opsi.terima  (res, pertama) => menyimpan baris halaman itu (boleh async)
            // opsi.gambar  (pertama, selesai) => menggambar tabel dari seluruh baris sejauh ini
            // Mengembalikan true bila selesai, false bila dihentikan pemuatan yang lebih baru.
            async function rcMuatBertahap(opsi) {
                const kunci = opsi.kunci;
                const ke = (rcMuatAktif[kunci] || 0) + 1;
                rcMuatAktif[kunci] = ke;
                const masihBerlaku = () => rcMuatAktif[kunci] === ke;

                // Galat jaringan diubah menjadi respons galat biasa, supaya keduanya ditangani
                // di satu tempat - dan permintaan yang tidak lagi ditunggu (karena pemuatan
                // dihentikan) tidak pernah muncul sebagai penolakan tak tertangani di konsol.
                const ambil = (setelahNya, pertama) => Promise.resolve()
                    .then(() => opsi.ambil(setelahNya, pertama))
                    .catch((e) => ({ status: 'error', message: e && e.message }));

                let setelah = null, halaman = 0, dimuat = 0, total = null, perkiraan = false;
                let terakhirGambar = 0, lamaGambar = 0, belumDigambar = false;
                let setelahTertunda = null;
                let tertunda = ambil(null, true);
                try {
                    do {
                        let res = await tertunda;
                        // Satu halaman yang gagal - biasanya batas waktu server saat sedang sibuk -
                        // dicoba ulang dua kali dengan jeda, bukan langsung menghentikan seluruh
                        // pemuatan. Halaman yang dicoba ulang adalah halaman yang sama (kursornya
                        // sama), jadi tidak ada baris yang terlewat atau terulang.
                        for (let coba = 1; (!res || res.status !== 'success') && coba <= 2; coba++) {
                            if (!masihBerlaku()) return false;
                            await new Promise(r => setTimeout(r, 1500 * coba));
                            if (!masihBerlaku()) return false;
                            res = await ambil(setelahTertunda, halaman === 0);
                        }
                        if (!masihBerlaku()) return false;
                        if (!res || res.status !== 'success') {
                            throw new Error((res && res.message) || 'Gagal memuat data.');
                        }
                        if (halaman === 0) {
                            if (res.total != null) total = Number(res.total);
                            else if (res.perkiraanTotal != null) { total = Number(res.perkiraanTotal); perkiraan = true; }
                        }
                        dimuat += Number(res.dimuat) || 0;
                        setelah = res.berikutnya || null;
                        // Halaman berikutnya diminta SEKARANG, sementara halaman ini masih diolah
                        // dan digambar - keduanya berjalan bersamaan, bukan bergantian.
                        if (setelah) {
                            setelahTertunda = setelah;
                            tertunda = ambil(setelah, false);
                        }
                        await opsi.terima(res, halaman === 0);
                        if (!masihBerlaku()) return false;
                        halaman++;
                        belumDigambar = true;

                        // Halaman pertama dan terakhir selalu digambar. Di antaranya jedanya
                        // paling sedikit 5 detik, atau dua puluh kali lama gambar terakhir bila
                        // itu lebih besar. Tabel yang digambar utuh makin mahal seiring barisnya
                        // bertambah (Workflow menggambar SEMUA baris, tanpa halaman); tanpa jeda
                        // ini penggambaran sendiri yang memperlambat pemuatan. Di awal tabel tetap
                        // tampak bertambah, di akhir praktis hanya digambar sekali.
                        const jeda = Math.max(5000, lamaGambar * 20);
                        if (halaman === 1 || !setelah || Date.now() - terakhirGambar > jeda) {
                            const mulai = Date.now();
                            opsi.gambar(halaman === 1, !setelah);
                            lamaGambar = Date.now() - mulai;
                            terakhirGambar = Date.now();
                            belumDigambar = false;
                        }
                        rcIndikatorMuat(kunci, opsi.label, dimuat, total, perkiraan, !setelah);
                    } while (setelah);
                    return true;
                } catch (e) {
                    // Baris yang sudah sampai tetap ditampilkan; yang gagal hanya sisanya.
                    if (masihBerlaku()) {
                        if (belumDigambar) opsi.gambar(halaman <= 1, true);
                        rcIndikatorMuat(kunci, opsi.label, dimuat, total, perkiraan, true);
                    }
                    throw e;
                }
            }

            // Indikator kecil di pojok kanan bawah selama sisa halaman dimuat.
            function rcIndikatorMuat(kunci, label, dimuat, total, perkiraan, selesai) {
                let wadah = document.getElementById('rcIndikatorMuat');
                if (!wadah) {
                    document.body.insertAdjacentHTML('beforeend',
                        '<div id="rcIndikatorMuat" class="fixed bottom-4 right-4 z-50 flex flex-col gap-2 items-end pointer-events-none"></div>');
                    wadah = document.getElementById('rcIndikatorMuat');
                }
                let el = document.getElementById('rcIndikatorMuat-' + kunci);
                if (selesai) { if (el) el.remove(); return; }
                // Kerangkanya dibuat SEKALI, dan teksnya diperbarui lewat atribut data-teks yang
                // ditampilkan CSS (.rc-teks-atribut::after). Tailwind versi CDN memindai SEMUA
                // elemen berkelas di dokumen setiap kali isi elemen mana pun berubah - termasuk
                // sekadar teks. Saat tabel berisi puluhan ribu baris, satu pemindaian memakan
                // beberapa detik, dan bila indikator mengubah isinya di setiap halaman, browser
                // membeku di setiap halaman. Perubahan atribut selain class tidak memicunya.
                if (!el) {
                    wadah.insertAdjacentHTML('beforeend',
                        '<div id="rcIndikatorMuat-' + rcEsc(kunci) + '" class="bg-white border border-blue-200 shadow-lg rounded-xl px-4 py-2 text-xs font-bold text-blue-700">'
                        + '<i class="fas fa-spinner fa-spin mr-2"></i><span class="rc-teks-atribut"></span></div>');
                    el = document.getElementById('rcIndikatorMuat-' + kunci);
                }
                const angka = n => Number(n).toLocaleString('id-ID');
                el.querySelector('.rc-teks-atribut').dataset.teks = label + ': '
                    + angka(dimuat) + (total ? ' / ' + (perkiraan ? '± ' : '') + angka(total) : '')
                    + ' baris dimuat';
            }

            // Pilihan dropdown multi-select yang sedang aktif, supaya dapat dipasang kembali
            // setelah daftar opsinya dibangun ulang dengan data yang lebih lengkap. "Pilih
            // Semua" yang tercentang ikut mencentang opsi yang baru muncul.
            function rcSimpanPilihanMulti(ids) {
                const simpan = {};
                ids.forEach(function (id) {
                    const c = document.getElementById(id);
                    if (!c) return;
                    simpan[id] = Array.from(c.querySelectorAll('input[type="checkbox"]:checked')).map(b => b.value);
                });
                return simpan;
            }

            function rcPulihkanPilihanMulti(simpan) {
                Object.keys(simpan).forEach(function (id) {
                    const c = document.getElementById(id);
                    if (!c || !simpan[id].length) return;
                    const pilih = new Set(simpan[id]);
                    const semua = pilih.has('ALL');
                    c.querySelectorAll('input[type="checkbox"]').forEach(function (b) {
                        b.checked = semua || pilih.has(b.value);
                    });
                    const s = c.closest('.relative') && c.closest('.relative').querySelector('button span');
                    if (s) s.innerText = getMultiSelectLabel(id);
                });
            }

            // Centangan baris tabel, disimpan per kelas kotak centang berdasarkan nilainya.
            function rcSimpanCentang(kelas) {
                const simpan = {};
                kelas.forEach(function (k) {
                    simpan[k] = new Set(Array.from(document.querySelectorAll('.' + k + ':checked')).map(b => b.value));
                });
                return simpan;
            }

            function rcPulihkanCentang(simpan) {
                Object.keys(simpan).forEach(function (k) {
                    if (!simpan[k].size) return;
                    document.querySelectorAll('.' + k).forEach(function (b) {
                        if (simpan[k].has(b.value) && !b.disabled) b.checked = true;
                    });
                });
            }
