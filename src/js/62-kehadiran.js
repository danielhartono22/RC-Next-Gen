            // ---- 20261164000000: indikator online ---------------------------------------------------
            // Selama tab ini terlihat, satu sinyal kecil dikirim tiap 2 menit. Server hanya mencatat
            // waktu terakhirnya (satu baris per akun). Daftar akun di Access Management menampilkan
            // lampu hijau bila sinyal terakhir kurang dari 5 menit lalu. Kegagalan sinyal diabaikan:
            // ia tidak boleh mengganggu pekerjaan pengguna.
            const RC_HADIR_SELANG = 120000;
            let rcHadirTimer = null, rcHadirTerakhir = 0;

            function rcHadirKirim(paksa) {
                if (!currentUserData || document.visibilityState !== 'visible') return;
                if (!paksa && Date.now() - rcHadirTerakhir < RC_HADIR_SELANG - 5000) return;
                rcHadirTerakhir = Date.now();
                try { fetchApp({ action: 'hadir' }).catch(function () { /* sinyal saja */ }); } catch (e) { /* sinyal saja */ }
            }

            // Lampu di samping User ID pada daftar akun.
            function rcHadirLampu(u) {
                const online = !!(u && u.online === true);
                const judul = online ? 'Online (aktif ' + (u.terakhirAktif || '') + ')'
                    : (u && u.terakhirAktif ? 'Offline - terakhir aktif ' + u.terakhirAktif : 'Offline - belum pernah tercatat');
                return '<span class="inline-block w-2.5 h-2.5 rounded-full mr-2 align-middle ' + (online ? 'bg-green-500' : 'bg-gray-300')
                    + '" data-online="' + (online ? '1' : '0') + '" title="' + rcEsc(judul) + '"></span>';
            }

            (function () {
                const asliSesi = applySession;
                applySession = function (res) {
                    asliSesi(res);
                    rcHadirKirim(true);
                    if (!rcHadirTimer) rcHadirTimer = setInterval(function () { rcHadirKirim(false); }, RC_HADIR_SELANG);
                };
                // Kembali ke tab ini sesudah lama ditinggal: langsung tercatat lagi.
                document.addEventListener('visibilitychange', function () { if (document.visibilityState === 'visible') rcHadirKirim(false); });
                // Logout: akun langsung tampil offline, tanpa menunggu 5 menit.
                const asliKeluar = reqLogout;
                reqLogout = function () {
                    if (!currentUserData) return asliKeluar();
                    let p; try { p = fetchApp({ action: 'hadir', keluar: true }); } catch (e) { p = Promise.resolve(); }
                    Promise.resolve(p).catch(function () {}).then(function () { asliKeluar(); });
                };
            })();
