            // ====================================================================================
            // RUTE - setiap modul punya alamatnya sendiri
            // ====================================================================================
            // Permintaan pemilik: "saya mau ada route / path sehingga jelas adress nya". Sebelum
            // ini seluruh aplikasi hidup di satu alamat, sehingga bilah URL menampilkan hal yang
            // sama entah orang sedang berada di Claim Upload atau di Timetable, dan tautan ke
            // sebuah modul tidak mungkin dikirim kepada siapa pun.
            //
            // Cara kerjanya sengaja menempel di luar, bukan dijahit ke dalam. Fungsi navigasi yang
            // sudah ada - goToHome, openModule, openRcModule, applySession - tidak diubah satu
            // baris pun; keempatnya dibungkus, dan bungkusnya menambahkan satu hal saja: alamat di
            // bilah URL ikut berpindah. Seluruh onclick pada HTML tetap memanggil nama yang sama,
            // jadi tidak ada satu atribut pun yang perlu disunting, dan bila rute ini suatu saat
            // dicabut, aplikasinya tetap utuh.
            //
            // Alamat tidak pernah menjadi sumber kewenangan. Rute hanya menekan kartu menu yang
            // memang sudah terlihat bagi akun ini - bila applyRoleBasedUI menyembunyikannya,
            // alamatnya pun tidak membuka apa-apa dan berakhir di beranda. Mengetik /access di
            // bilah URL karena itu tidak memberi hak yang tidak dimiliki.

            // jenis menentukan fungsi mana yang membuka modul; menu adalah id kartu di beranda,
            // yang sudah disembunyikan applyRoleBasedUI sesuai hak akun.
            const RC_RUTE = [
                { path: '/',             jenis: 'home' },
                { path: '/upload',       jenis: 'modul',   modul: 'upload',      menu: 'menuUpload' },
                { path: '/release',      jenis: 'modul',   modul: 'release',     menu: 'menuRelease' },
                { path: '/process',      jenis: 'modul',   modul: 'process',     menu: 'menuProcess' },
                { path: '/analytics',    jenis: 'modul',   modul: 'analytics',   menu: 'menuAnalytics' },
                { path: '/access',       jenis: 'modul',   modul: 'manage',      menu: 'menuKelolaAkses' },
                { path: '/log-activity', jenis: 'modul',   modul: 'logActivity', menu: 'menuLogActivity' },
                { path: '/bulk-process', jenis: 'modul',   modul: 'bulkProcess', menu: 'menuBulkProcess' },
                { path: '/key-master',   jenis: 'rcModul', modul: 'keyMaster',   menu: 'menuKeyMaster' },
                // Modulnya dinamai Document Center; kata compilation bertahan sebagai
                // pengenal internal, jadi alamatnya mengikuti nama yang dilihat orang.
                { path: '/document-center', jenis: 'rcModul', modul: 'compilation', menu: 'menuCompilation' },
                { path: '/approval',     jenis: 'rcModul', modul: 'approval',    menu: 'menuApproval' },
                { path: '/report',       jenis: 'rcModul', modul: 'report',      menu: 'menuReport' },
                { path: '/timetable',    jenis: 'rcModul', modul: 'timetable',   menu: 'menuTimetable' },
                // Profil tidak punya kartu menu: setiap akun berhak melihat profil depotnya
                // sendiri, jadi tidak ada yang perlu dijaga di sini.
                { path: '/people-performance', jenis: 'rcModul', modul: 'people', menu: 'menuPeople' },
                { path: '/profile',      jenis: 'profil' }
            ];

            // Alamat yang diminta saat halaman dimuat. Ia ditahan sampai sesi siap, karena modul
            // baru boleh dibuka setelah data dan hak akses akun diterima. Tanpa penahanan ini,
            // membuka /report dari sebuah tautan akan selalu mendarat di beranda.
            let rcRuteTertunda = null;

            // Benar selama rute sedang menerapkan alamat. Bungkus navigasi membaca penanda ini dan
            // menahan diri, supaya membuka modul karena alamatnya tidak mendorong alamat lagi.
            let rcRuteDiam = false;

            function rcRutePath() {
                return (location.pathname || '/').replace(/\/+$/, '') || '/';
            }

            function rcRuteCari(path) {
                const p = String(path || '/').replace(/\/+$/, '').toLowerCase() || '/';
                return RC_RUTE.find(r => r.path === p) || null;
            }

            function rcRuteUntukModul(jenis, modul) {
                return RC_RUTE.find(r => r.jenis === jenis && r.modul === modul) || null;
            }

            function rcRuteBolehBuka(r) {
                if (!r || !r.menu) return true;
                const el = document.getElementById(r.menu);
                return !!el && !el.classList.contains('hidden');
            }

            // Mendorong alamat baru tanpa memuat ulang halaman.
            function rcRuteDorong(path) {
                if (rcRuteDiam) return;
                try {
                    if (rcRutePath() !== path) window.history.pushState({ rc: path }, '', path);
                } catch (e) { /* riwayat ditolak; aplikasi tetap berjalan tanpa alamat */ }
            }

            // Menerapkan sebuah alamat: membuka modulnya bila akun ini berhak, dan jatuh ke beranda
            // bila tidak. Tidak pernah mendorong alamat baru - alamatnya memang sudah benar.
            function rcRuteTerapkan(path) {
                const r = rcRuteCari(path);
                rcRuteDiam = true;
                try {
                    if (r && r.jenis === 'modul' && rcRuteBolehBuka(r)) rcRuteAsliModule(r.modul);
                    else if (r && r.jenis === 'rcModul' && rcRuteBolehBuka(r)) rcRuteAsliRcModule(r.modul);
                    else if (r && r.jenis === 'profil') rcRuteAsliProfil();
                    else rcRuteAsliHome();
                } finally { rcRuteDiam = false; }
            }

            // Dipanggil sekali begitu sesi siap, sesudah applyRoleBasedUI menentukan menu mana yang
            // terlihat. Beranda tidak perlu diterapkan: applySession sudah mendarat di sana dan
            // alamatnya pun sudah "/".
            function rcRuteMulai() {
                const path = rcRuteTertunda || rcRutePath();
                rcRuteTertunda = null;
                if (path !== '/') rcRuteTerapkan(path);
            }

            // ---- Pembungkusan ------------------------------------------------------------------
            const rcRuteAsliHome = goToHome;
            const rcRuteAsliModule = openModule;
            const rcRuteAsliRcModule = openRcModule;
            const rcRuteAsliApplySession = applySession;
            const rcRuteAsliProfil = openProfileView;

            goToHome = function () {
                rcRuteAsliHome();
                if (currentUserData) rcRuteDorong('/');
            };

            openModule = function (mod) {
                rcRuteAsliModule(mod);
                const r = rcRuteUntukModul('modul', mod);
                if (r) rcRuteDorong(r.path);
            };

            openRcModule = function (mod) {
                rcRuteAsliRcModule(mod);
                const r = rcRuteUntukModul('rcModul', mod);
                if (r) rcRuteDorong(r.path);
            };

            // applySession berakhir dengan goToHome(). Bila dorongan tidak ditahan di sini, alamat
            // yang diminta pengguna - misalnya /report - akan tertimpa "/" tepat sebelum rute
            // sempat menerapkannya, sehingga isinya benar tetapi alamatnya salah.
            applySession = function (res) {
                rcRuteDiam = true;
                try { rcRuteAsliApplySession(res); } finally { rcRuteDiam = false; }
                rcRuteMulai();
            };

            openProfileView = function () {
                rcRuteAsliProfil();
                rcRuteDorong('/profile');
            };

            // Tombol maju/mundur peramban berpindah modul, bukan meninggalkan aplikasi.
            window.addEventListener('popstate', function () {
                if (!currentUserData) return;
                rcRuteTerapkan(rcRutePath());
            });

            // Alamat saat halaman dimuat dicatat sebelum apa pun sempat menggantinya.
            rcRuteTertunda = rcRutePath();
