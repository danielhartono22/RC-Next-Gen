            // ============================================================================
            // PERILAKU MODAL: layar utama mati selama modal terbuka
            // ============================================================================
            // Pemilik meminta: begitu sebuah modal terbuka, gulir dan layar utama tidak lagi
            // aktif; yang aktif hanya modalnya, sampai ditutup.
            //
            // MENGAPA SATU MEKANISME UNTUK SEMUA, BUKAN DITAMBAHKAN DI TIAP FUNGSI BUKA/TUTUP
            // Halaman ini punya sepuluh modal, dan masing-masing dibuka lewat jalan yang berbeda:
            // ada yang lewat setHiddenSafely(), ada yang classList.remove('hidden') langsung, ada
            // yang dibuka dari dalam modal lain. Menambahkan penguncian di tiap tempat berarti
            // satu perilaku dipelihara di sepuluh tempat, dan modal kesebelas yang ditambahkan
            // nanti pasti melewatkannya.
            //
            // Yang dipakai di sini adalah MutationObserver atas atribut class tiap modal. Apa pun
            // cara membukanya, kelas 'hidden'-nya pasti berubah, dan perubahan itulah yang
            // ditangkap. Tidak ada fungsi lama yang perlu disentuh.
            //
            // MENGAPA inert, BUKAN SEKADAR pointer-events
            // pointer-events:none hanya menahan tetikus. Tombol di belakang modal masih dapat
            // dicapai dengan Tab dan ditekan dengan Enter - persis cara orang bekerja cepat.
            // Atribut inert menahan tetikus, papan ketik, fokus, dan pembaca layar sekaligus.

            let rcModalDiamati = false;

            function rcSemuaModal() {
                // Seluruh modal adalah anak langsung <body> dengan id berakhiran "Modal".
                return Array.from(document.querySelectorAll('body > [id$="Modal"]'));
            }

            function rcModalTerbuka() {
                // Yang dipakai adalah tampilan sesungguhnya, bukan sekadar ada-tidaknya kelas
                // 'hidden'. Keduanya sejalan hari ini, tetapi membaca display membuat modal yang
                // suatu saat disembunyikan dengan cara lain tetap terhitung dengan benar.
                return rcSemuaModal().filter(function (el) {
                    if (el.classList.contains('hidden')) return false;
                    try { return window.getComputedStyle(el).display !== 'none'; }
                    catch (e) { return true; }
                });
            }

            // Lapisan mana yang benar-benar berada PALING ATAS.
            //
            // Sebelumnya yang dianggap teratas adalah yang terakhir pada urutan DOM. Itu keliru:
            // yang menentukan tumpukan di layar adalah z-index, dan di halaman ini urutannya tidak
            // sejalan - actionResultModal (z-120) berada paling awal di DOM, ttMatrixModal (z-70)
            // paling akhir. Akibatnya modal yang benar-benar terlihat di depan bisa mendapat
            // inert, dan tombolnya tidak dapat ditekan sama sekali.
            //
            // z-index dibaca dari gaya terhitung, bukan dari kelasnya, supaya tetap benar bila
            // suatu saat nilainya diatur lewat CSS biasa.
            function rcModalPalingAtas(terbuka) {
                let atas = null;
                let tertinggi = -Infinity;
                terbuka.forEach(function (el, i) {
                    let z = 0;
                    try { z = parseInt(window.getComputedStyle(el).zIndex, 10); } catch (e) { z = 0; }
                    if (!isFinite(z)) z = 0;
                    // Urutan DOM hanya dipakai sebagai pemutus ketika z-index-nya sama persis.
                    const nilai = z * 1000 + i;
                    if (nilai >= tertinggi) { tertinggi = nilai; atas = el; }
                });
                return atas;
            }

            function rcPerbaruiKuncianModal() {
                const terbuka = rcModalTerbuka();
                const ada = terbuka.length > 0;

                // Dikunci di dua tempat: elemen penggulir halaman berbeda-beda menurut peramban,
                // dan mengunci salah satunya saja menyisakan kemungkinan halaman tetap bergerak.
                document.documentElement.classList.toggle('rc-modal-terbuka', ada);
                document.body.classList.toggle('rc-modal-terbuka', ada);

                Array.from(document.body.children).forEach(function (el) {
                    if (el.tagName === 'SCRIPT' || el.tagName === 'DATALIST') return;
                    if (el.hasAttribute('id') && /Modal$/.test(el.id)) return; // diatur di bawah
                    if (ada) el.setAttribute('inert', ''); else el.removeAttribute('inert');
                });

                // Hanya modal PALING ATAS yang aktif. Modal dapat bertumpuk - konfirmasi yang
                // dibuka dari dalam dialog rincian, misalnya - dan bila lapisan di bawahnya ikut
                // menerima Tab dan klik, tombol yang tertutup masih dapat ditekan tanpa terlihat.
                const atas = ada ? rcModalPalingAtas(terbuka) : null;
                rcSemuaModal().forEach(function (el) {
                    if (el === atas) el.removeAttribute('inert');
                    else el.setAttribute('inert', '');
                });

                if (atas) {
                    if (!atas.hasAttribute('tabindex')) atas.setAttribute('tabindex', '-1');
                    // Fokus dipindahkan ke dalam modal supaya gulir papan ketik dan Tab
                    // langsung berlaku di sana, bukan di halaman yang sudah tidak aktif.
                    const isian = atas.querySelector('input:not([type=hidden]):not([disabled]), select, textarea, button');
                    try { (isian || atas).focus({ preventScroll: true }); } catch (e) { /* fokus bukan keharusan */ }
                }
            }

            function rcPasangPengamatModal() {
                if (rcModalDiamati) return;
                const daftar = rcSemuaModal();
                if (daftar.length === 0) return;
                // 'style' ikut diamati, bukan hanya 'class': seluruh modal hari ini dibuka dengan
                // menanggalkan kelas 'hidden', tetapi satu baris display:flex yang ditulis
                // langsung suatu saat akan membuka modal tanpa sepengetahuan pengamat ini, dan
                // kegagalannya senyap - layar belakang tetap hidup tanpa satu pun pesan.
                const pengamat = new MutationObserver(rcPerbaruiKuncianModal);
                daftar.forEach(function (el) {
                    pengamat.observe(el, { attributes: true, attributeFilter: ['class', 'style'] });
                });
                rcModalDiamati = true;
                rcPerbaruiKuncianModal();
            }

            document.addEventListener('DOMContentLoaded', rcPasangPengamatModal);
            // Bila skrip ini berjalan setelah DOM siap, DOMContentLoaded tidak akan datang lagi.
            if (document.readyState !== 'loading') rcPasangPengamatModal();

            // Escape menutup modal paling atas, apa pun modalnya. Sebelumnya hanya rcDialogModal
            // yang menanggapinya, sehingga sebagian modal hanya bisa ditutup dengan tetikus.
            document.addEventListener('keydown', function (e) {
                if (e.key !== 'Escape') return;
                const terbuka = rcModalTerbuka();
                if (terbuka.length === 0) return;
                const atas = terbuka[terbuka.length - 1];
                // Kartu yang sedang diperbesar dikembalikan lewat fungsinya sendiri, karena isinya
                // harus dipindahkan pulang ke kartu asalnya - sekadar menyembunyikan lapisannya
                // akan meninggalkan grafiknya di tempat yang salah.
                if (atas.id === 'cardExpandModal' && typeof rcTutupCardExpand === 'function') {
                    rcTutupCardExpand();
                } else {
                    atas.classList.add('hidden');
                }
            });
