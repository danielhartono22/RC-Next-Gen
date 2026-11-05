            // ============================================================================
            // DETAILS CAMPAIGN - tampilan BERSAMA portal (Timetable) dan halaman publik
            // /details-campaign (20261163470000)
            // ============================================================================
            // Pemilik, 27 Oktober 2026: "buat general link tanpa login untuk details campaign".
            // Seluruh tampilan tab Details Campaign tinggal di sini, dipakai portal (disisipkan
            // index.html) dan halaman publik (aset rc-report-view.js), sehingga keduanya tidak
            // mungkin menyimpang. Yang berbeda hanya dari mana datanya datang: portal memanggil
            // rc_timetable_campaigns, halaman publik rc_publik_timetable_campaigns - keduanya
            // dibungkus dari badan kueri yang sama (rc_private.timetable_campaigns_isi).

            let rcTtcState = { rows: [], tampil: [], depots: [], regions: [], depotSaya: '', depotRp: [], dimuat: false, depotDipilih: false };

            // Kode depot akun yang login (portal); halaman publik tidak punya akun.
            function ttcKodeDepotAkun() {
                return (typeof currentUserData !== 'undefined' && currentUserData) ? String(currentUserData.kodeDepot || '') : '';
            }
            function ttcTeks(id, teks) { const el = document.getElementById(id); if (el) el.textContent = teks; }

            // Data dari server -> state dan pilihan filter (Tahun SO, Berlaku di Depot).
            function ttcIsiData(r) {
                    Object.assign(rcTtcState, { rows: r.rows || [], depots: r.depots || [], regions: r.regions || [], depotSaya: r.depotSaya || '', depotRp: r.depotRp || [], dimuat: true });

                    const elT = document.getElementById('ttcTahun'), lamaT = elT ? elT.value : '';
                    const tahun = Array.from(new Set(rcTtcState.rows.map(x => (x.soStartIso || '').slice(0, 4)).filter(Boolean))).sort().reverse();
                    if (elT) {
                        elT.innerHTML = '<option value="">Semua Tahun</option>' + tahun.map(t => '<option value="' + t + '">' + t + '</option>').join('')
                            + (rcTtcState.rows.some(x => !x.soStartIso) ? '<option value="-">Tanpa Periode SO</option>' : '');
                        if (lamaT && Array.from(elT.options).some(o => o.value === lamaT)) elT.value = lamaT;
                    }
                    // Depot acuan penanda merah: pilihan pengguna bila sudah memilih, lalu depot akun ini,
                    // lalu satu-satunya depot jangkauan.
                    const elD = document.getElementById('ttcDepot'), lamaD = elD ? elD.value : '';
                    if (elD) {
                        const kode = rcTtcState.depots.map(d => d.kode);
                        elD.innerHTML = '<option value="">Semua depot (tanpa penanda)</option>'
                            + rcTtcState.depots.map(d => '<option value="' + rcEsc(d.kode) + '">' + rcEsc(d.kode + ' - ' + d.nama) + (d.region ? ' (' + rcEsc(d.region) + ')' : '') + '</option>').join('');
                        const akun = ttcKodeDepotAkun();
                        const rumah = kode.includes(rcTtcState.depotSaya) ? rcTtcState.depotSaya : kode.includes(akun) ? akun : (kode.length === 1 ? kode[0] : '');
                        elD.value = rcTtcState.depotDipilih && (lamaD === '' || kode.includes(lamaD)) ? lamaD : rumah;
                    }
            }

            function ttcDepotTerpilih() { return String((document.getElementById('ttcDepot') || {}).value || ''); }
            function ttcTidakBerlaku(r, depot) { return !!depot && (r.tidakBerlakuDepot || []).includes(depot); }

            function ttcSaring() {
                if (document.activeElement && document.activeElement.id === 'ttcDepot') rcTtcState.depotDipilih = true;
                const v = id => String((document.getElementById(id) || {}).value || '');
                const cari = v('ttcCari').trim().toLowerCase(), tahun = v('ttcTahun'), status = v('ttcStatus'), memo = v('ttcMemo');
                rcTtcState.tampil = rcTtcState.rows.filter(r =>
                    (!tahun || (tahun === '-' ? !r.soStartIso : (r.soStartIso || '').slice(0, 4) === tahun))
                    && (!status || r.status === status)
                    && (!memo || (memo === 'ada' ? !!(r.memoPath || r.adaMemo) : !(r.memoPath || r.adaMemo)))
                    && (!cari || [r.kode, r.nama].concat((r.variant || []).flatMap(x => [x.nama, x.deskripsi])).some(x => String(x || '').toLowerCase().includes(cari))));
                renderTimetableCampaigns();
            }

            function ttcLencanaStatus(st) {
                st = String(st || 'active').toLowerCase();
                const kelas = st === 'active' ? 'bg-emerald-100 text-emerald-700' : st === 'inactive' ? 'bg-red-100 text-red-700' : 'bg-slate-200 text-slate-700';
                return '<span class="px-2 py-1 rounded text-[10px] font-black uppercase ' + kelas + '">' + rcEsc(st) + '</span>';
            }

            // Warna Jenis CB sama dengan Campaign Master.
            function ttcLencanaJenis(j) {
                const k = String(j || '').toLowerCase();
                const kelas = k === 'transfer' ? 'bg-green-100 text-green-800' : k === 'cn' ? 'bg-yellow-100 text-yellow-800'
                    : k === 'rebate' || k === 'rebate manual' ? 'bg-pink-100 text-pink-800' : k === 'voucher' ? 'bg-indigo-100 text-indigo-800' : 'bg-red-100 text-red-700';
                return '<span class="px-2 py-1 rounded text-[10px] font-black uppercase whitespace-nowrap ' + kelas + '">' + rcEsc(j || 'Belum diisi') + '</span>';
            }

            function ttcTombolMemo(r) {
                return r.memoPath
                    ? '<button type="button" onclick="event.stopPropagation(); bukaMemoTimetable(' + rcEsc(JSON.stringify(r.kode)) + ')" class="px-2.5 py-1 bg-white border border-red-200 hover:bg-red-50 text-red-700 font-bold rounded-lg text-[11px] whitespace-nowrap" title="Buka memo: ' + rcEsc(r.memoName || 'memo.pdf') + '"><i class="fas fa-file-pdf mr-1"></i>PDF</button>'
                    // Halaman publik tidak membuka memo; cukup tanda bahwa memonya ada.
                    : r.adaMemo ? '<span class="text-[11px] text-gray-500 whitespace-nowrap" title="Masuk ke portal untuk membuka memo"><i class="fas fa-file-pdf mr-1"></i>Ada</span>'
                    : '<span class="text-[11px] text-gray-400 whitespace-nowrap">Belum ada</span>';
            }

            function renderTimetableCampaigns() {
                const rows = rcTtcState.tampil, body = document.getElementById('ttcBody'), depot = ttcDepotTerpilih();
                const kosong = '<span class="text-gray-300">-</span>';
                body.innerHTML = rows.length ? rows.map(r => {
                    const tidak = ttcTidakBerlaku(r, depot);
                    return '<tr onclick="ttcDetail(' + rcEsc(JSON.stringify(r.kode)) + ')" class="border-t cursor-pointer '
                        + (tidak ? 'bg-red-50 border-red-100 hover:bg-red-100' : 'border-gray-100 hover:bg-amber-50/50') + '"'
                        + (tidak ? ' title="Tidak berlaku di depot ' + rcEsc(depot) + ' (Not Participating)"' : '') + '>'
                        + '<td class="p-3 font-black whitespace-nowrap ' + (tidak ? 'text-red-700' : 'text-gray-800') + '">' + rcEsc(r.kode) + '</td>'
                        + '<td class="p-3 ' + (tidak ? 'text-red-700' : 'text-gray-700') + '">' + rcEsc(r.nama)
                            + (tidak ? ' <span class="ml-1 px-1.5 py-0.5 rounded bg-red-600 text-white text-[10px] font-bold whitespace-nowrap">Tidak berlaku di ' + rcEsc(depot) + '</span>' : '') + '</td>'
                        + '<td class="p-3 text-center">' + ttcLencanaStatus(r.status) + '</td>'
                        + '<td class="p-3 text-center">' + ttcLencanaJenis(r.jenisCb) + '</td>'
                        + '<td class="p-3 text-center text-xs whitespace-nowrap">' + rcLabelPajak(r.statusPajak) + '</td>'
                        + '<td class="p-3 text-center whitespace-nowrap ' + (tidak ? 'text-red-700' : 'text-gray-600') + '" data-sort="' + rcEsc(r.soStartIso) + '">' + (r.soStart ? rcEsc(r.soStart) : kosong) + '</td>'
                        + '<td class="p-3 text-center whitespace-nowrap ' + (tidak ? 'text-red-700' : 'text-gray-600') + '" data-sort="' + rcEsc(r.soEndIso) + '">' + (r.soEnd ? rcEsc(r.soEnd) : kosong) + '</td>'
                        + '<td class="p-3 text-center">' + ttcTombolMemo(r) + '</td></tr>';
                }).join('') : '<tr><td colspan="8" class="p-8 text-center text-gray-500">'
                    + (rcTtcState.rows.length ? 'Tidak ada campaign yang cocok dengan filter.' : 'Belum ada campaign di Campaign Master.') + '</td></tr>';
                const total = rcTtcState.rows.length, tidakN = depot ? rows.filter(r => ttcTidakBerlaku(r, depot)).length : 0;
                ttcTeks('ttRingkas', 'Details Campaign · ' + rows.length.toLocaleString('id-ID') + ' dari ' + total.toLocaleString('id-ID') + ' campaign'
                    + (depot ? ' · ' + tidakN.toLocaleString('id-ID') + ' tidak berlaku di depot ' + depot : ''));
            }

            // Detail satu campaign: periode lengkap, variant, keberlakuan region / depot, memo.
            function ttcDetail(kode) {
                const r = rcTtcState.rows.find(x => x.kode === kode); if (!r) return;
                const depot = ttcDepotTerpilih(), kosong = '<span class="text-gray-300">-</span>';
                const sel = (judul, isi) => '<div class="bg-gray-50 border border-gray-200 rounded-lg p-3"><p class="text-[10px] font-black uppercase text-gray-500">' + judul + '</p><p class="text-sm font-bold text-gray-800 mt-1">' + isi + '</p></div>';
                const npRegion = r.npRegion || [], npDepot = r.npDepot || [];
                const berlakuRegion = rcTtcState.regions.filter(x => !npRegion.includes(x));
                const chip = (t, merah) => '<span class="inline-block px-2 py-0.5 rounded-md text-xs font-bold mr-1 mb-1 ' + (merah ? 'bg-red-100 text-red-700 border border-red-200' : 'bg-emerald-50 text-emerald-700 border border-emerald-200') + '">' + rcEsc(t) + '</span>';
                const tanpaExclude = !npRegion.length && !npDepot.length && !Number(r.npDepotLain || 0);
                // Catatan untuk akun yang login (pemilik, 19 Oktober 2026): "campaign ini berlaku di depot
                // ..." untuk depot asalnya, begitu juga untuk depot Resource Partner-nya bila ada.
                const namaDepot = k => { const d = rcTtcState.depots.find(x => x.kode === k) || {}; return k + (d.nama ? ' - ' + d.nama : ''); };
                const sebab = k => {
                    const d = rcTtcState.depots.find(x => x.kode === k) || {};
                    return npDepot.includes(k) ? 'depot ini Not Participating' : d.region && npRegion.includes(d.region) ? 'Region ' + d.region + ' Not Participating' : 'Not Participating';
                };
                const kalimat = (awalan, daftar, tidak) => '<div class="rounded-lg p-3 text-sm font-bold ' + (tidak ? 'bg-red-50 border border-red-200 text-red-700' : 'bg-emerald-50 border border-emerald-200 text-emerald-700') + '">'
                    + '<i class="fas ' + (tidak ? 'fa-ban' : 'fa-check-circle') + ' mr-1.5"></i>' + awalan + 'Campaign ini ' + (tidak ? 'tidak berlaku' : 'berlaku') + ' di depot '
                    + daftar.map(k => rcEsc(namaDepot(k)) + (tidak ? ' <span class="font-normal">(' + rcEsc(sebab(k)) + ')</span>' : '')).join(', ') + '.</div>';
                // Depot asal: profil (home_depot_id), atau Kode Depot akun seperti yang tampil di kepala halaman.
                const akun = ttcKodeDepotAkun(), kodeJangkauan = rcTtcState.depots.map(d => d.kode);
                const asal = rcTtcState.depotSaya || (kodeJangkauan.includes(akun) ? akun : ''), rp = (rcTtcState.depotRp || []).filter(k => k && k !== asal);
                let catatan = '';
                if (asal) catatan += kalimat('', [asal], ttcTidakBerlaku(r, asal));
                if (rp.length) {
                    const rpYa = rp.filter(k => !ttcTidakBerlaku(r, k)), rpTidak = rp.filter(k => ttcTidakBerlaku(r, k));
                    if (rpYa.length) catatan += kalimat('Resource Partner: ', rpYa, false);
                    if (rpTidak.length) catatan += kalimat('Resource Partner: ', rpTidak, true);
                }
                // Depot lain yang sedang dipilih di "Berlaku di Depot" (mis. System Manager / Supervisor).
                if (depot && depot !== asal && !rp.includes(depot)) catatan += kalimat('Depot terpilih: ', [depot], ttcTidakBerlaku(r, depot));
                if (!catatan) catatan = '<p class="text-xs text-gray-500">Pilih depot pada "Berlaku di Depot" untuk melihat apakah campaign ini berlaku di depot itu.</p>';
                let keberlakuan = '<div class="space-y-2 mb-3">' + catatan + '</div>';
                keberlakuan += '<p class="text-[10px] font-black uppercase text-gray-500 mb-2">Rincian Not Participating (Campaign Master)</p>'
                    + '<div class="grid grid-cols-1 md:grid-cols-2 gap-3">'
                    + '<div class="border border-gray-200 rounded-lg p-3"><p class="text-[10px] font-black uppercase text-gray-500 mb-2">Berlaku di region</p>'
                        + (tanpaExclude ? '<p class="text-xs font-bold text-emerald-700 mb-1.5">Semua region dan depot</p>' : '')
                        + (berlakuRegion.length ? berlakuRegion.map(x => chip('Region ' + x, false)).join('') : '<span class="text-xs text-gray-500">Tidak ada region yang berlaku.</span>')
                        + (npDepot.length && !tanpaExclude ? '<p class="text-[11px] text-gray-500 mt-1">kecuali depot yang di-exclude.</p>' : '') + '</div>'
                    + '<div class="border border-gray-200 rounded-lg p-3"><p class="text-[10px] font-black uppercase text-gray-500 mb-2">Exclude (Not Participating)</p>'
                        + (npRegion.length ? npRegion.map(x => chip('Region ' + x, true)).join('') : '')
                        + (npDepot.length ? npDepot.map(x => chip('Depot ' + x, true)).join('') : '')
                        + (Number(r.npDepotLain || 0) ? '<p class="text-xs text-gray-500 mt-1">+ ' + Number(r.npDepotLain) + ' depot di luar jangkauan Anda</p>' : '')
                        + (tanpaExclude ? '<span class="text-xs text-gray-500">Tidak ada region / depot yang di-exclude.</span>' : '') + '</div>'
                    + '</div>'
                    + (r.dikecualikan ? '<p class="mt-3 text-xs bg-amber-50 border border-amber-200 text-amber-800 rounded-lg p-2.5"><i class="fas fa-triangle-exclamation mr-1"></i>Campaign ini dikecualikan dari seluruh laporan (Access Management &rarr; Exclude Campaign)' + (r.alasanDikecualikan ? ': ' + rcEsc(r.alasanDikecualikan) : '') + '.</p>' : '');
                // Variant (20261163470000): server hanya mengirim T-code yang terisi, dan satu T-code boleh
                // punya beberapa variant (ditulis dipisah titik koma / baris baru di Campaign Master). Tanpa
                // variant sama sekali, bagian ini tidak ditampilkan.
                const daftarVariant = (r.variant || []).filter(x => String(x.nama || '').trim());
                const jumlahPerKode = daftarVariant.reduce((m, x) => (m[x.laporan] = (m[x.laporan] || 0) + 1, m), {});
                const varian = daftarVariant.length ? '<table class="w-full text-sm border border-gray-200"><thead class="bg-gray-50 text-gray-600"><tr>'
                    + '<th class="p-2.5 text-left text-[10px] font-black uppercase w-24">T-Code</th><th class="p-2.5 text-left text-[10px] font-black uppercase">Variant Name</th><th class="p-2.5 text-left text-[10px] font-black uppercase">Description</th></tr></thead><tbody>'
                    + daftarVariant.map((x, k) => '<tr class="border-t border-gray-100">'
                        + (k === 0 || daftarVariant[k - 1].laporan !== x.laporan ? '<td class="p-2.5 font-black text-gray-700 align-top" rowspan="' + jumlahPerKode[x.laporan] + '">' + rcEsc(x.laporan) + '</td>' : '')
                        + '<td class="p-2.5 font-mono text-xs text-gray-800 break-all">' + rcEsc(x.nama) + '</td>'
                        + '<td class="p-2.5 text-gray-700">' + (x.deskripsi ? rcEsc(x.deskripsi) : kosong) + '</td></tr>').join('')
                    + '</tbody></table>' : '';
                rcDialog(r.kode + ' - ' + r.nama, '<div data-rc-dialog-wide class="space-y-5 text-sm">'
                    + '<div class="flex flex-wrap items-center gap-2">' + ttcLencanaStatus(r.status) + ttcLencanaJenis(r.jenisCb) + '<span class="text-xs">Status Pajak: ' + rcLabelPajak(r.statusPajak) + '</span>'
                        + '<span class="ml-auto">' + ttcTombolMemo(r) + '</span></div>'
                    + '<div><p class="text-xs font-black text-gray-700 mb-2">Periode</p><div class="grid grid-cols-2 md:grid-cols-4 gap-3">'
                        + sel('SO Start', r.soStart ? rcEsc(r.soStart) : kosong) + sel('SO End', r.soEnd ? rcEsc(r.soEnd) : kosong)
                        + sel('Billing Start', r.billingStart ? rcEsc(r.billingStart) : kosong) + sel('Billing End', r.billingEnd ? rcEsc(r.billingEnd) : kosong) + '</div></div>'
                    + (varian ? '<div><p class="text-xs font-black text-gray-700 mb-2">Variant</p>' + varian + '</div>' : '')
                    + '<div><p class="text-xs font-black text-gray-700 mb-2">Catatan</p>' + keberlakuan + '</div>'
                    + '</div>');
            }

            // Unduhan sama dengan layar: baris yang tersaring, kolom tampilan pertama, tanggal
            // dd-Mmm-yyyy, dan keberlakuan di depot terpilih (penanda merah di layar).
            function unduhTimetableCampaignExcel() {
                if (!rcTtcState.dimuat) { showNotification('Belum ada data untuk diekspor.', 'warning'); return; }
                const depot = ttcDepotTerpilih();
                const judul = ['Code Campaign', 'Nama Campaign', 'Status', 'Jenis CB', 'Status Pajak', 'Periode Start', 'Periode End', 'Memo'];
                if (depot) judul.push('Berlaku di Depot ' + depot);
                const aoa = [judul];
                rcTtcState.tampil.forEach(r => {
                    const baris = [rcSelTeks(r.kode), r.nama, r.status, r.jenisCb || '', rcTeksPajak(r.statusPajak), r.soStart, r.soEnd, r.memoName || ((r.memoPath || r.adaMemo) ? 'memo.pdf' : '')];
                    if (depot) baris.push(ttcTidakBerlaku(r, depot) ? 'Tidak berlaku' : 'Berlaku');
                    aoa.push(baris);
                });
                const wb = XLSX.utils.book_new(), ws = XLSX.utils.aoa_to_sheet(aoa);
                ws['!cols'] = [16, 52, 10, 14, 22, 13, 13, 30, 20].map(w => ({ wch: w }));
                XLSX.utils.book_append_sheet(wb, ws, 'Details Campaign');
                XLSX.writeFile(wb, 'RC_Timetable_Details_Campaign' + (depot ? '_' + depot : '') + '.xlsx');
            }

            // Dialog umum untuk menampilkan HTML apa pun.
            //
            // showActionResult() TIDAK dapat dipakai untuk ini: tanda tangannya
            // (title, successList, failList, actionType, batchNum) menuntut daftar hasil
            // eksekusi, dan ia memanggil .map() atas argumen kedua. Memberinya string HTML
            // membuatnya melempar TypeError sebelum sempat menampilkan apa pun, sehingga
            // layar hanya diam tanpa dialog dan tanpa pesan galat yang terlihat.
            function rcDialog(judul, html) {
                document.getElementById('rcDialogTitle').innerText = judul || '';
                const body = document.getElementById('rcDialogBody');
                const modal = document.getElementById('rcDialogModal');
                body.innerHTML = html || '';
                // Detail berupa tabel/grafik memerlukan panel lebar; pesan dan formulir pendek
                // tetap memakai ukuran ringkas. Keduanya selalu dibatasi viewport oleh CSS.
                modal.classList.toggle('rc-dialog-wide', !!body.querySelector('table, canvas, [data-rc-dialog-wide]'));
                setHiddenSafely('rcDialogModal', false);
                rcUkurUlangGrafik(body);
            }

            function rcTutupDialog() { setHiddenSafely('rcDialogModal', true); }

            document.addEventListener('keydown', function (e) {
                if (e.key === 'Escape') rcTutupDialog();
            });

            // ------------------------------------------------------------------------------
            // Status Pajak: satu penafsiran untuk seluruh layar
            // ------------------------------------------------------------------------------
            // Kolom tax_status pada master campaign berisi kalimat bebas warisan spreadsheet
            // lama, dan isinya beragam:
            //
            //   "PT Nipsea Paint and Chemicals" (35 campaign)   "Rebate Non Tax" (28)
            //   "PT Nipsea Paint And Chemicals" (11, beda huruf) "Customer"       (22)
            //   "0" (3)                                          kosong           (1)
            //
            // Sementara itu filter di layar hanya menawarkan "Ditanggung Perusahaan" dan
            // "Ditanggung Customer". Tidak satu pun nilai di atas memuat kata "ditanggung",
            // sehingga KEDUA pilihan filter itu selalu menghasilkan tabel kosong - inilah
            // yang terlihat sebagai status pajak "tidak sinkron".
            //
            // Penafsirannya disatukan di sini supaya filter, tampilan kolom, dan perhitungan
            // gross up membaca nilai yang sama. Teks aslinya tidak diubah di database; yang
            // disepakati hanyalah cara membacanya.
            const RC_PAJAK = {
                perusahaan: { label: 'Ditanggung Perusahaan', kelas: 'text-emerald-700' },
                customer:   { label: 'Ditanggung Customer',   kelas: 'text-orange-700' },
                nonTax:     { label: 'Rebate Non Tax',        kelas: 'text-sky-700' },
                takJelas:   { label: 'Belum Ditentukan',      kelas: 'text-gray-400' }
            };

            function rcKunciPajak(mentah) {
                const t = String(mentah == null ? '' : mentah).trim().toLowerCase();
                if (!t || t === '0' || t === '-') return 'takJelas';
                if (t.indexOf('non tax') > -1 || t.indexOf('nontax') > -1) return 'nonTax';
                if (t.indexOf('nipsea') > -1 || t.indexOf('ditanggung perusahaan') > -1
                    || t.indexOf('ditanggung pt') > -1 || t.indexOf('perusahaan') > -1) return 'perusahaan';
                if (t.indexOf('customer') > -1 || t.indexOf('toko') > -1) return 'customer';
                return 'takJelas';
            }

            // Label seragam sebagai teks biasa. Dipakai berkas Excel, yang tidak dapat memuat
            // markup, dan menjadi dasar bentuk berwarna di bawahnya.
            function rcTeksPajak(mentah) { return RC_PAJAK[rcKunciPajak(mentah)].label; }

            // Label seragam untuk ditampilkan. Teks aslinya tetap dibawa sebagai title, supaya
            // perbedaan penulisan di master masih dapat ditelusuri dari layar.
            function rcLabelPajak(mentah) {
                const k = rcKunciPajak(mentah);
                const asli = String(mentah == null ? '' : mentah).trim();
                return '<span class="' + RC_PAJAK[k].kelas + ' font-bold" title="'
                    + rcEsc(asli || '(kosong di master campaign)') + '">' + RC_PAJAK[k].label + '</span>';
            }

