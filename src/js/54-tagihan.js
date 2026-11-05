            // =====================================================================================
            // Tagihan per dokumen dari Upload Debtor (ZDAGE) - 20261163270000
            // =====================================================================================
            // Pemilik, 21 Oktober 2026: tagihan dan Final Billing Month tampil di tab Open, Document
            // Center, dan Details pada Analytics. Satu sumber untuk ketiganya: rc_tagihan_dokumen
            // (data debtor yang berlaku untuk depot dokumen). Diambil untuk No Doc yang sedang tampil
            // saja, maksimal 2000 per permintaan, lalu disimpan sementara per No Doc.
            //
            // status: 'ada' (toko ada di file), 'kosong' (depot ditandai Tidak ada tagihan),
            // 'tidak_di_file' (toko tidak ada di file = lunas), 'tanpa_data' (depot belum punya data
            // debtor - tidak diketahui, ditampilkan "-").
            // 20261163680000: saklar ZDAGE Integration dari bootstrap login. Mati = tampilan seperti
            // prod sebelum ZDAGE: kolom Tagihan / Final Billing Month / Deadline dan kartu Tagihan
            // disembunyikan, tab ZDAGE sudah ditutup lewat hak tab di server.
            function rcZdageAktif() { return !!(typeof currentUserData !== 'undefined' && currentUserData && currentUserData.zdageAktif === true); }
            const rcTagihanCache = new Map();
            const rcTagihanKunci = (noDoc) => String(noDoc == null ? '' : noDoc).trim().toUpperCase();

            // Dipanggil saat daftar dimuat ulang, supaya angka mengikuti unggahan debtor terbaru.
            function rcTagihanKosongkan() { rcTagihanCache.clear(); }

            // Mengambil tagihan No Doc yang belum ada di cache. false = gagal dimuat (baris tetap
            // tampil dengan "-"; tidak dicatat di cache, sehingga dicoba lagi pada pemuatan berikut).
            async function rcTagihanMuat(noDocs) {
                if (!rcZdageAktif()) return true; // 20261163680000
                const perlu = [...new Set((noDocs || []).map(rcTagihanKunci))].filter(n => n && !rcTagihanCache.has(n));
                for (let i = 0; i < perlu.length; i += 2000) {
                    const potong = perlu.slice(i, i + 2000);
                    let res = null;
                    try { res = await fetchApp({ action: 'tagihanDokumen', noDocs: potong }); }
                    catch (e) { res = null; }
                    if (!res || res.status !== 'success') {
                        if (window.console) console.warn('Tagihan gagal dimuat', res && res.message);
                        return false;
                    }
                    const data = res.data || {};
                    potong.forEach(n => rcTagihanCache.set(n, data[n] || { status: 'tanpa_data' }));
                }
                return true;
            }

            function rcTagihanInfo(noDoc) { return rcTagihanCache.get(rcTagihanKunci(noDoc)) || null; }
            function rcTagihanDiketahui(i) { return !!(i && i.status && i.status !== 'tanpa_data'); }

            // Layar: nominal tagihan (0 = lunas), "-" bila belum ada data debtor untuk depotnya.
            function rcTagihanSel(noDoc) {
                const i = rcTagihanInfo(noDoc);
                if (!rcTagihanDiketahui(i)) return '<span class="text-gray-400" title="Belum ada data Upload Debtor untuk depot ini">-</span>';
                const n = Number(i.tagihan) || 0;
                return '<span class="' + (n > 0 ? 'text-red-700 font-bold' : 'text-green-700') + '" title="Upload Debtor per '
                    + rcEsc(i.asOf || '-') + (i.status === 'kosong' ? ' (depot: tidak ada tagihan)' : i.status === 'tidak_di_file' ? ' (toko tidak ada di file)' : '')
                    + '">' + rcMoney(n) + '</span>';
            }
            function rcTagihanBulan(noDoc) {
                const i = rcTagihanInfo(noDoc);
                return rcTagihanDiketahui(i) && i.bulan ? i.bulan : '-';
            }
            // Excel: nominal dipotong bulat (seperti layar), kosong bila tidak diketahui.
            function rcTagihanUnduh(noDoc) {
                const i = rcTagihanInfo(noDoc);
                return rcTagihanDiketahui(i) ? Math.trunc(Number(i.tagihan) || 0) : '';
            }
            function rcTagihanBulanUnduh(noDoc) {
                const i = rcTagihanInfo(noDoc);
                return rcTagihanDiketahui(i) ? (i.bulan || '') : '';
            }
            // Teks untuk kartu Details (Analytics).
            function rcTagihanDetail(noDoc) {
                const i = rcTagihanInfo(noDoc);
                if (!i) return 'Memuat...';
                if (!rcTagihanDiketahui(i)) return 'Belum ada data Upload Debtor untuk depot ini';
                return rcMoney(Number(i.tagihan) || 0) + (Number(i.overdue) ? '\nOver Due: ' + rcMoney(Number(i.overdue) || 0) : '')
                    + '\nUpload Debtor per ' + (i.asOf || '-');
            }
