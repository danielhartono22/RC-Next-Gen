            // =============================================================================
            // MASTER DIAMBIL SAAT PERLU
            // =============================================================================
            // Dulu login mengunduh seluruh daftar pelanggan dan dokumen supaya layar bisa
            // mencari satu baris dengan globalCustomers.find(...). Pada 100 ribu baris itu
            // berarti 2,8 MB per login dan akhirnya gagal sama sekali - melewati batas waktu
            // 8 detik yang berlaku untuk pengguna yang sudah masuk.
            //
            // Keduanya tidak pernah ditampilkan; hanya dicari berdasarkan kode. Jadi yang
            // diambil sekarang hanya kode yang benar-benar dipakai - biasanya belasan.
            //
            // globalCustomers dan globalDocuments TETAP menjadi tempat penyimpanannya, dengan
            // bentuk baris yang sama persis seperti dulu. Dengan begitu seluruh kode yang
            // memakai .find() tidak perlu diubah sama sekali; yang berubah hanya kapan isinya
            // sampai ke sana.

            // Kode yang sudah pernah dicari, termasuk yang TIDAK ditemukan. Tanpa mencatat
            // yang tidak ditemukan, satu kode salah ketik akan ditanyakan ulang ke server
            // pada setiap penekanan tombol.
            const rcMasterDiminta = { cust: new Set(), doc: new Set() };

            function rcNormKode(v) {
                return String(v == null ? '' : v).trim().toUpperCase();
            }

            // -----------------------------------------------------------------------------
            // Indeks pencarian
            // -----------------------------------------------------------------------------
            // .find() dan .some() memeriksa larik dari depan untuk SETIAP pencarian. Pada
            // antrean 30 ribu baris dengan cache puluhan ribu pelanggan itu berarti ratusan
            // juta perbandingan setiap tabel digambar - browser membeku. Indeks ini memberi
            // jawaban yang sama (baris PERTAMA yang cocok, persis seperti .find) dalam satu
            // langkah.
            //
            // Larik master hanya pernah diganti utuh atau ditambah di ujung (push). Karena
            // itu indeks dibangun ulang bila lariknya berganti, dan bila hanya bertambah,
            // yang diindeks cukup baris barunya.
            const rcIndeksCache = new Map();

            function rcIndeks(nama, arr, kunciFn) {
                let e = rcIndeksCache.get(nama);
                if (!e || e.arr !== arr || e.n > arr.length) {
                    e = { arr: arr, n: 0, map: new Map() };
                    rcIndeksCache.set(nama, e);
                }
                for (let i = e.n; i < arr.length; i++) {
                    const k = kunciFn(arr[i]);
                    if (!e.map.has(k)) e.map.set(k, arr[i]);
                }
                e.n = arr.length;
                return e.map;
            }

            // Padanan globalCustomers.find(c => c.custCode === kode).
            function rcCariCustomer(kode) {
                return rcIndeks('customerPersis', globalCustomers, c => c.custCode).get(kode);
            }
            // Padanan globalDocuments.find(d => String(d.noDoc).toUpperCase() === String(no).toUpperCase()).
            function rcCariDokumen(no) {
                return rcIndeks('dokumenBesar', globalDocuments, d => String(d.noDoc).toUpperCase())
                    .get(String(no).toUpperCase());
            }
            // Padanan globalCampaigns.find(c => c.codeCampaign === kode).
            function rcCariCampaign(kode) {
                return rcIndeks('campaignPersis', globalCampaigns, c => c.codeCampaign).get(kode);
            }
            // Padanan globalCampaigns.find(c => String(c.codeCampaign || '').trim().toUpperCase() === target).
            function rcCariCampaignNorm(target) {
                return rcIndeks('campaignNorm', globalCampaigns,
                    c => String(c.codeCampaign || '').trim().toUpperCase()).get(target);
            }

            // Mengambil pelanggan dan dokumen yang BELUM ada di cache, lalu menaruhnya di
            // globalCustomers / globalDocuments. Aman dipanggil berulang: yang sudah ada
            // tidak diminta lagi.
            async function pastikanMaster(custCodes, docNos) {
                const perluCust = [];
                const perluDoc = [];
                const custAda = rcIndeks('customerNorm', globalCustomers, c => rcNormKode(c.custCode));
                const docAda = rcIndeks('dokumenNorm', globalDocuments, d => rcNormKode(d.noDoc));
                const sudahCust = new Set();
                const sudahDoc = new Set();

                (custCodes || []).forEach(function (k) {
                    const kode = rcNormKode(k);
                    if (!kode || rcMasterDiminta.cust.has(kode) || sudahCust.has(kode)) return;
                    sudahCust.add(kode);
                    if (custAda.has(kode)) {
                        rcMasterDiminta.cust.add(kode); return;
                    }
                    perluCust.push(kode);
                });
                (docNos || []).forEach(function (n) {
                    const no = rcNormKode(n);
                    if (!no || rcMasterDiminta.doc.has(no) || sudahDoc.has(no)) return;
                    sudahDoc.add(no);
                    if (docAda.has(no)) {
                        rcMasterDiminta.doc.add(no); return;
                    }
                    perluDoc.push(no);
                });

                if (!perluCust.length && !perluDoc.length) return;

                // Server membatasi 2000 kode per permintaan; dipecah di sini supaya unggahan
                // besar tidak ditolak seluruhnya hanya karena melewati batas satu permintaan.
                const POTONG = 1000;
                for (let i = 0; i < Math.max(perluCust.length, perluDoc.length); i += POTONG) {
                    const c = perluCust.slice(i, i + POTONG);
                    const d = perluDoc.slice(i, i + POTONG);
                    if (!c.length && !d.length) continue;
                    try {
                        const res = await fetchApp({ action: 'lookupMaster', custCodes: c, docNos: d });
                        if (res && res.status === 'success') {
                            (res.customers || []).forEach(function (row) {
                                const ada = rcIndeks('customerNorm', globalCustomers, x => rcNormKode(x.custCode));
                                if (!ada.has(rcNormKode(row.custCode))) {
                                    globalCustomers.push(row);
                                }
                            });
                            (res.documents || []).forEach(function (row) {
                                row.status = normalizeClaimStatus(row.status);
                                const ada = rcIndeks('dokumenNorm', globalDocuments, x => rcNormKode(x.noDoc));
                                if (!ada.has(rcNormKode(row.noDoc))) {
                                    globalDocuments.push(row);
                                }
                            });
                        }
                    } catch (e) {
                        // Kegagalan pengambilan TIDAK dicatat sebagai "sudah diminta": kalau
                        // dicatat, satu gangguan jaringan akan membuat barisnya dianggap tidak
                        // ada selamanya sampai halaman dimuat ulang.
                        if (window.console) console.warn('pastikanMaster gagal', e);
                        return;
                    }
                    c.forEach(k => rcMasterDiminta.cust.add(k));
                    d.forEach(k => rcMasterDiminta.doc.add(k));
                }
            }

            // Bentuk yang lebih mudah dipakai: menerima larik baris apa pun, lalu memungut
            // kode pelanggan dan nomor dokumen dari nama kolom yang biasa dipakai di layar.
            function pastikanMasterDariBaris(rows) {
                const cust = [];
                const doc = [];
                (rows || []).forEach(function (r) {
                    if (!r) return;
                    const k = r.custCode || r.kodeToko || r.customerCode;
                    const n = r.noDoc || r.no_doc;
                    if (k) cust.push(k);
                    if (n) doc.push(n);
                });
                return pastikanMaster(cust, doc);
            }
