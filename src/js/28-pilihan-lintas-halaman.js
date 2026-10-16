            // =============================================================================
            // PILIHAN LINTAS HALAMAN
            // =============================================================================
            // Tabel berhalaman (Customer, Campaign dan Depot Master, Document Center, tab Open)
            // menggambar ulang barisnya setiap kali halaman, pencarian atau filter berganti.
            // Dulu centangnya hanya hidup di kotak centang baris yang sedang tampil, sehingga
            // pindah ke halaman 2 menghapus pilihan di halaman 1: memilih baris dari beberapa
            // halaman sekaligus tidak mungkin dilakukan.
            //
            // Sekarang pilihan disimpan per tabel di sini, dengan kunci nilai kotak centangnya
            // (kode customer, kode campaign, kode depot, id dokumen, No Doc). Sesudah tabel
            // digambar, rcPilihanPulihkan mencentang kembali baris yang sudah dipilih; setiap
            // perubahan centang diserap lewat rcPilihanSerap. Tombol aksi memakai SELURUH
            // pilihan, bukan hanya yang tampil. Pilihan bertahan sampai aksinya selesai atau
            // pengguna menekan "Kosongkan pilihan".

            const rcPilihan = {};

            function rcPilihanPeta(kelas) {
                return rcPilihan[kelas] || (rcPilihan[kelas] = new Map());
            }

            // Dipanggil sesudah baris digambar dan SEBELUM penghitungnya diperbarui; urutan ini
            // penting, karena rcPilihanSerap membuang baris tampil yang tidak tercentang.
            function rcPilihanPulihkan(kelas, idKepala) {
                const peta = rcPilihanPeta(kelas);
                document.querySelectorAll('input.' + kelas).forEach(c => {
                    if (!c.disabled && peta.has(c.value)) c.checked = true;
                });
                rcPilihanKepala(kelas, idKepala);
            }

            // Menyamakan baris yang sedang tampil ke pilihan. Baris di halaman lain tidak
            // disentuh. ambilData (opsional) menyimpan data baris, untuk aksi yang memerlukan
            // isi barisnya, bukan hanya kuncinya.
            function rcPilihanSerap(kelas, ambilData, idKepala) {
                const peta = rcPilihanPeta(kelas);
                document.querySelectorAll('input.' + kelas).forEach(c => {
                    if (c.checked && !c.disabled) peta.set(c.value, ambilData ? ambilData(c) : true);
                    else peta.delete(c.value);
                });
                rcPilihanKepala(kelas, idKepala);
                rcPilihanTombolKosong(kelas);
                return peta.size;
            }

            // Kotak centang judul mengikuti halaman yang tampil: tercentang bila seluruh baris
            // halaman ini terpilih, setengah bila baru sebagian.
            function rcPilihanKepala(kelas, idKepala) {
                const kepala = idKepala ? document.getElementById(idKepala) : null;
                if (!kepala) return;
                const kotak = [...document.querySelectorAll('input.' + kelas)].filter(c => !c.disabled);
                const n = kotak.filter(c => c.checked).length;
                kepala.checked = kotak.length > 0 && n === kotak.length;
                kepala.indeterminate = n > 0 && n < kotak.length;
            }

            function rcPilihanKunci(kelas) { return [...rcPilihanPeta(kelas).keys()]; }
            function rcPilihanData(kelas) { return [...rcPilihanPeta(kelas).values()]; }

            function rcPilihanKosongkan(kelas, idKepala) {
                rcPilihanPeta(kelas).clear();
                document.querySelectorAll('input.' + kelas).forEach(c => { c.checked = false; });
                rcPilihanKepala(kelas, idKepala);
                rcPilihanTombolKosong(kelas);
            }

            // Tombol "Kosongkan pilihan" tabel ini (data-rc-pilihan="kelas") hanya tampil bila
            // ada yang dipilih.
            function rcPilihanTombolKosong(kelas) {
                const kosong = rcPilihanPeta(kelas).size === 0;
                document.querySelectorAll('[data-rc-pilihan="' + kelas + '"]').forEach(b => {
                    b.classList.toggle('hidden', kosong);
                });
            }
