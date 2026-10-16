            // ============================================================================
            // MODUL TIMETABLE - matrix depot x campaign, Not Achieved, exclude campaign
            // ============================================================================
            // Status setiap sel diputuskan di server, termasuk dua hal yang mudah salah bila
            // dihitung ulang di browser: Expired adalah tahap akhir dan dihitung SELESAI bersama
            // Done (20261163040000; dulu diabaikan), dan data aktual selalu mengungguli tanda
            // Not Achieved. Layar ini hanya menggambar.

            let ttData = null;

            const TT_WARNA = {
                'Not Yet':      'bg-red-500 text-white',
                'Compiled':     'bg-orange-400 text-white',
                'Completed':    'bg-green-500 text-white',
                'Not Achieved': 'bg-white text-gray-400 border border-gray-300',
                // Not Participating diatur di Campaign Master (20261162170000); dihitung seperti NA.
                'Not Participating': 'bg-gray-200 text-gray-500 border border-gray-300'
            };

            // Sama seperti Report: pilihan filter diturunkan dari data yang ada pada matrix,
            // bukan dari master depot. Pilihan yang sedang aktif dipertahankan.
            function ttIsiFilterDariData(res) {
                const isi = (id, daftar, labelSemua) => {
                    const el = document.getElementById(id);
                    const terpilih = el.value;
                    const opsi = daftar.slice().sort((a, b) => String(a.v).localeCompare(String(b.v)));
                    if (terpilih && !opsi.some(o => o.v === terpilih)) {
                        opsi.unshift({ v: terpilih, t: terpilih + ' (tidak ada di data)' });
                    }
                    el.innerHTML = '<option value="">' + labelSemua + '</option>'
                        + opsi.map(o => '<option value="' + rcEsc(o.v) + '">' + rcEsc(o.t) + '</option>').join('');
                    el.value = terpilih;
                };
                isi('ttRegion', [...new Set((res.depots || [])
                        .map(d => d.region).filter(r => r && r !== '(belum diisi)'))]
                        .map(r => ({ v: r, t: r })), 'Semua Region');
                isi('ttDepot', (res.depots || [])
                        .map(d => ({ v: d.kodeDepot, t: d.kodeDepot + ' - ' + d.namaDepot })), 'Semua Depot');

                // Tahun selalu dikirim server dari seluruh Campaign Master, tidak mengikuti
                // Region/Depot. Acuannya sama dengan Report: tahun Periode Start; Periode End
                // hanya menjadi fallback untuk data lama yang belum mempunyai Periode Start.
                const tahun = document.getElementById('ttTahunCampaign');
                const daftarTahun = (res.tahunTersedia || []).map(String);
                const tahunTerpilih = String(res.tahunCampaign || daftarTahun[0] || '');
                tahun.innerHTML = '<option value="ALL">Semua Tahun</option>'
                    + daftarTahun.map(y => '<option value="' + rcEsc(y) + '">' + rcEsc(y) + '</option>').join('');
                tahun.value = tahunTerpilih;
            }

            async function loadTimetable() {
                showLoadingOverlay();
                try {
                    const pilihanTahun = document.getElementById('ttTahunCampaign').value;
                    const res = await fetchApp({
                        action: 'timetableMatrix',
                        filter: {
                            region: document.getElementById('ttRegion').value,
                            depot: document.getElementById('ttDepot').value,
                            // Saat select belum diisi pada pemuatan pertama, properti ini
                            // dihilangkan agar server memakai tahun default. Sesudahnya ALL
                            // dikirim eksplisit ketika pengguna memilih Semua Tahun.
                            tahunCampaign: pilihanTahun || undefined
                        }
                    });
                    if (res.status !== 'success') throw new Error(res.message || 'Gagal memuat Timetable.');
                    ttData = res;

                    // Campaign berubah mengikuti Tahun Campaign, jadi daftar penandaannya
                    // diisi ulang setiap kali - bukan sekali di awal.

                    const catatan = [];
                    const labelTahun = String(res.tahunCampaign || '') === 'ALL'
                        ? 'semua tahun' : 'tahun ' + rcEsc(String(res.tahunCampaign || '-'));
                    catatan.push(`${res.campaignJumlah ?? res.campaignAktif ?? 0} campaign ${labelTahun}`);
                    catatan.push(`${(res.depots || []).length} depot`);
                    if (res.campaignTanpaPeriode) {
                        // Ini perlu terlihat: campaign tanpa periode tidak pernah masuk penyebut,
                        // sehingga Compile % akan terlihat lebih tinggi daripada kenyataannya.
                        catatan.push(`${res.campaignTanpaPeriode} campaign tanpa tahun (tidak dihitung)`);
                    }
                    if (res.campaignDikecualikan) catatan.push(`${res.campaignDikecualikan} dikecualikan`);
                    document.getElementById('ttRingkas').innerText = catatan.join(' · ');

                    ttIsiFilterDariData(res);
                    renderTimetableKpi(res.kpi || {});
                    renderTimetableCharts(res);
                    // Pengguna satu depot tidak melihat susunan per depot maupun matrix.
                    const perDepot = ttBolehLihatPerDepot();
                    setHiddenSafely('ttCardDepot', !perDepot);
                    // Tombol pembuka matrix ikut disembunyikan bagi pengguna satu depot:
                    // matrixnya memuat seluruh depot, yang bukan urusannya.
                    setHiddenSafely('ttLegenda', !perDepot);
                    renderTimetable();
                    renderTimetableCampaignTabel();
                    muatDetailNotAchieved();
                    // Pastikan Chart.js membaca batas card yang sudah final. Ini diperlukan saat
                    // modul baru saja berubah dari hidden menjadi terlihat.
                    rcUkurUlangGrafik(document.getElementById('modTimetable'));
                } catch (e) {
                    showNotification((e && e.message) ? e.message : 'Gagal memuat Timetable.', 'error');
                } finally { hideLoadingOverlay(); }
            }

            // ATURAN PEMILIK, ditulis di satu tempat supaya tidak ditafsirkan berbeda-beda:
            //
            //   System Manager dan Supervisor  - melihat seluruh depot.
            //   Selain keduanya                - HANYA progres per campaign. Progres per depot
            //                                    muncul hanya bila akunnya ditag ke lebih dari
            //                                    satu depot, dan terbatas pada taggingan itu.
            //
            // Batas taggingan itu sendiri dipasang di server, bukan di sini: rc_timetable_matrix
            // hanya mengembalikan depot yang lolos rc_private.can_access(). Jadi yang diputuskan
            // fungsi ini semata APAKAH susunan per depot ditampilkan - bukan depot mana saja yang
            // boleh terlihat. Menaruh keduanya di layar berarti seseorang yang membuka konsol
            // browser dapat melewatinya.
            //
            // Satu depot tidak dihitung sebagai taggingan: susunan per depot untuk satu depot
            // hanyalah pengulangan angka campaign yang sudah ada di atasnya.
            function ttBolehLihatPerDepot() {
                const peran = String((currentUserData && (currentUserData.sysRole || currentUserData.role)) || '')
                    .trim().toLowerCase();
                if (peran === 'system manager' || peran === 'supervisor') return true;
                const depot = (currentUserData && currentUserData.managedDepots) || [];
                return depot.length > 1;
            }

            // Sejak aturan pemilik 20 September 2026, seorang supervisor punya DUA jangkauan
            // yang berbeda: ia MELIHAT seluruh depot di Report dan Timetable, tetapi hanya
            // BERTINDAK pada depot milik OSC binaannya. Depot yang hanya boleh dilihat tetap
            // tampil lengkap dengan angkanya - yang dibekukan hanya tombol aksinya.
            //
            // currentUserData.managedDepots berisi jangkauan BERTINDAK: ia dibangun dari
            // user_depot_access, yang bagi supervisor hanya memuat depot OSC binaannya. Jangan
            // memakainya untuk memutuskan apa yang boleh dilihat.
            //
            // Pembekuan di sini semata penunjuk arah bagi penggunanya. Penjagaan yang sebenarnya
            // ada di server: rc_timetable_mark menyaring setiap depot dengan
            // rc_private.can_access(), sehingga menekan tombol lewat konsol pun tetap ditolak.
            function ttBolehAksiDepot(kodeDepot) {
                const peran = String((currentUserData && (currentUserData.sysRole || currentUserData.role)) || '')
                    .trim().toLowerCase();
                if (peran === 'system manager') return true;
                const milik = (currentUserData && currentUserData.managedDepots) || [];
                return milik.map(x => String(x).toUpperCase()).includes(String(kodeDepot).toUpperCase());
            }

            // Penanda seragam untuk depot yang hanya boleh dilihat.
            function ttLencanaHanyaLihat(kelasUkuran) {
                return '<span class="' + (kelasUkuran || 'text-[11px]') + ' text-gray-300" '
                    + 'title="Depot ini di luar OSC binaan Anda: boleh dilihat, tidak boleh diubah">'
                    + '<i class="fas fa-lock mr-1"></i>hanya lihat</span>';
            }

            function bolehKelolaTimetable() {
                const a = (currentUserData && currentUserData.auth) || {};
                const peran = String((currentUserData && (currentUserData.sysRole || currentUserData.role)) || '').toLowerCase();
                return peran === 'system manager' || String(a.timetable || '').toLowerCase() === 'yes';
            }

            let ttChart = {};

            // Proporsi persentase pada seluruh diagram Timetable.
            //
            // Ditulis sebagai plugin Chart.js sendiri, bukan memuat chartjs-plugin-datalabels
            // dari CDN. Halaman ini hanya memuat empat berkas luar, dan menambah yang kelima
            // demi satu label berarti satu titik gagal baru: bila CDN itu lambat atau diblokir
            // jaringan kantor, seluruh diagram ikut tidak tergambar.
            //
            // Penyebutnya berbeda menurut bentuk diagramnya, dan itu yang menentukan apakah
            // angkanya berarti:
            //   doughnut   -> terhadap total seluruh irisan
            //   bar tumpuk -> terhadap total satu tumpukan (satu depot / region / campaign)
            //   bar biasa  -> terhadap total seluruh batang
            // Memakai satu penyebut untuk semuanya akan menghasilkan persentase yang jumlahnya
            // bukan 100% pada diagram tumpuk, dan angka seperti itu lebih buruk daripada tidak
            // ada angka sama sekali.
            const rcPluginPersen = {
                id: 'rcPersen',
                afterDatasetsDraw: function (chart) {
                    const ctx = chart.ctx;
                    const jenis = chart.config.type;
                    const tumpuk = !!(chart.options.scales && chart.options.scales.x
                        && chart.options.scales.x.stacked);

                    chart.data.datasets.forEach(function (ds, di) {
                        const meta = chart.getDatasetMeta(di);
                        if (meta.hidden) return;

                        meta.data.forEach(function (el, i) {
                            const nilai = Number(ds.data[i]) || 0;
                            if (nilai <= 0) return;

                            let penyebut;
                            if (jenis === 'doughnut' || jenis === 'pie') {
                                penyebut = ds.data.reduce(function (a, b) { return a + (Number(b) || 0); }, 0);
                            } else if (tumpuk) {
                                penyebut = chart.data.datasets.reduce(function (a, d, dj) {
                                    return chart.getDatasetMeta(dj).hidden ? a : a + (Number(d.data[i]) || 0);
                                }, 0);
                            } else {
                                penyebut = ds.data.reduce(function (a, b) { return a + (Number(b) || 0); }, 0);
                            }
                            if (!penyebut) return;

                            const persen = (nilai / penyebut) * 100;
                            // Irisan yang terlalu kecil dilewati: labelnya akan bertumpuk dengan
                            // tetangganya dan keduanya menjadi tidak terbaca.
                            if (persen < 4) return;

                            const teks = (Math.round(persen * 10) / 10) + '%';
                            const p = el.tooltipPosition ? el.tooltipPosition() : { x: el.x, y: el.y };

                            ctx.save();
                            ctx.font = 'bold 10px system-ui, -apple-system, Segoe UI, sans-serif';
                            ctx.textAlign = 'center';
                            ctx.textBaseline = 'middle';
                            // Garis luar putih supaya tetap terbaca di atas warna gelap maupun terang.
                            ctx.lineWidth = 3;
                            ctx.strokeStyle = 'rgba(255,255,255,0.9)';
                            ctx.strokeText(teks, p.x, p.y);
                            ctx.fillStyle = '#1f2937';
                            ctx.fillText(teks, p.x, p.y);
                            ctx.restore();
                        });
                    });
                }
            };

            // Tooltip pun menyebut persentasenya, karena irisan kecil sengaja tidak diberi label
            // di atas gambar dan hanya lewat tooltip-lah angkanya dapat dibaca.
            function rcTooltipPersen(tumpuk) {
                return {
                    label: function (item) {
                        const ds = item.chart.data.datasets;
                        const nilai = Number(item.parsed.y !== undefined && item.parsed.y !== null
                            ? item.parsed.y : item.parsed) || 0;
                        let penyebut;
                        if (tumpuk === 'stack') {
                            penyebut = ds.reduce(function (a, d) { return a + (Number(d.data[item.dataIndex]) || 0); }, 0);
                        } else {
                            penyebut = (item.dataset.data || []).reduce(function (a, b) { return a + (Number(b) || 0); }, 0);
                        }
                        const persen = penyebut ? (nilai / penyebut) * 100 : 0;
                        const nama = item.dataset.label ? item.dataset.label + ': ' : '';
                        return nama + nilai.toLocaleString('id-ID')
                            + ' (' + (Math.round(persen * 10) / 10) + '%)';
                    }
                };
            }

            function ttGambarChart(id, konfig) {
                if (ttChart[id]) { ttChart[id].destroy(); delete ttChart[id]; }
                const el = document.getElementById(id);
                if (!el || typeof Chart === 'undefined') return;
                // Plugin persentase dipasang per diagram, bukan didaftarkan global, supaya
                // diagram di modul lain tidak ikut berubah tanpa diminta.
                konfig.plugins = (konfig.plugins || []).concat([rcPluginPersen]);
                ttChart[id] = new Chart(el.getContext('2d'), konfig);
            }

            function ttPersen(n) { return Number(n || 0).toFixed(1) + '%'; }

            function renderTimetableKpi(k) {
                // Tujuh kartu, sama dengan TimetableDashboard.html. Cleared sengaja ditampilkan
                // terpisah dari Completed karena keduanya berbeda arti: Cleared memasukkan
                // Not Achieved, yaitu depot yang memang tidak mengikuti campaign itu.
                const kartu = [
                    ['Campaign ' + (ttData && ttData.tahunCampaign === 'ALL' ? 'Semua Tahun' : (ttData && ttData.tahunCampaign ? ttData.tahunCampaign : 'Terpilih')), Number(k.campaign || 0).toLocaleString('id-ID'), (k.depot || 0) + ' depot dipantau', 'text-blue-700'],
                    ['Completed', Number(k.completed || 0).toLocaleString('id-ID'), 'semua klaim Done / Expired', 'text-green-700'],
                    ['Not Achieved', Number(k.notAchieved || 0).toLocaleString('id-ID'), 'tidak ikut campaign (termasuk NP)', 'text-gray-600'],
                    ['Cleared', Number(k.cleared || 0).toLocaleString('id-ID'), ttPersen(Number(k.clearedPct || 0) * 100) + ' dari total', 'text-emerald-700'],
                    ['Compiled', Number(k.compiled || 0).toLocaleString('id-ID'), ttPersen(Number(k.compiledPct || 0) * 100) + ' dari total', 'text-orange-700'],
                    ['Not Yet', Number(k.notYet || 0).toLocaleString('id-ID'), ttPersen(Number(k.notYetPct || 0) * 100) + ' dari total', 'text-red-600'],
                    ['Total Kombinasi', Number(k.total || 0).toLocaleString('id-ID'), 'Depot x Campaign', 'text-gray-800']
                ];
                document.getElementById('ttKpi').innerHTML = kartu.map(function (c) {
                    return '<div class="bg-white border border-gray-200 rounded-2xl p-4 shadow-sm overflow-hidden">'
                        + '<p class="text-[10px] font-black text-gray-500 uppercase tracking-wider truncate">' + rcEsc(c[0]) + '</p>'
                        + '<p class="rc-kpi-value font-black ' + c[3] + ' mt-1">' + rcEsc(c[1]) + '</p>'
                        + '<p class="rc-kpi-sub">' + rcEsc(c[2]) + '</p></div>';
                }).join('');
            }

            function renderTimetableCharts(res) {
                const k = res.kpi || {};

                ttGambarChart('ttChartSplit', {
                    type: 'doughnut',
                    data: {
                        labels: ['Cleared', 'Compiled', 'Not Yet'],
                        datasets: [{
                            data: [Number(k.cleared || 0), Number(k.compiled || 0), Number(k.notYet || 0)],
                            backgroundColor: ['#22c55e', '#f97316', '#ef4444']
                        }]
                    },
                    options: { responsive: true, maintainAspectRatio: false,
                        plugins: { legend: { position: 'right' },
                                   tooltip: { callbacks: rcTooltipPersen('total') } } }
                });

                const top = res.topNotYet || [];
                ttGambarChart('ttChartNotYet', {
                    type: 'bar',
                    data: { labels: top.map(d => d.kodeDepot + ' - ' + d.namaDepot),
                            datasets: [{ label: 'Not Yet', data: top.map(d => Number(d.notYet)),
                                         backgroundColor: '#ef4444', borderRadius: 4 }] },
                    options: { indexAxis: 'y', responsive: true, maintainAspectRatio: false,
                        scales: { x: { beginAtZero: true } },
                        plugins: { legend: { display: false },
                                   tooltip: { callbacks: rcTooltipPersen('total') } } }
                });

                const rg = res.perRegion || [];
                ttGambarChart('ttChartRegion', {
                    type: 'bar',
                    data: {
                        labels: rg.map(r => r.region),
                        datasets: [
                            { label: 'Cleared', data: rg.map(r => Number(r.cleared)), backgroundColor: '#22c55e', stack: 's' },
                            { label: 'Compiled', data: rg.map(r => Number(r.compiled)), backgroundColor: '#f97316', stack: 's' },
                            { label: 'Not Yet', data: rg.map(r => Number(r.notYet)), backgroundColor: '#ef4444', stack: 's' }
                        ]
                    },
                    options: { responsive: true, maintainAspectRatio: false,
                        scales: { x: { stacked: true }, y: { stacked: true, beginAtZero: true } },
                        plugins: { tooltip: { callbacks: rcTooltipPersen('stack') } } }
                });

                const cp = res.perCampaign || [];
                ttGambarChart('ttChartCampaign', {
                    type: 'bar',
                    data: {
                        labels: cp.map(c => c.kode),
                        datasets: [
                            { label: 'Cleared', data: cp.map(c => Number(c.cleared)), backgroundColor: '#22c55e', stack: 's' },
                            { label: 'Compiled', data: cp.map(c => Number(c.compiled)), backgroundColor: '#f97316', stack: 's' },
                            { label: 'Not Yet', data: cp.map(c => Number(c.notYet)), backgroundColor: '#ef4444', stack: 's' }
                        ]
                    },
                    options: { responsive: true, maintainAspectRatio: false,
                        scales: { x: { stacked: true }, y: { stacked: true, beginAtZero: true } },
                        plugins: { tooltip: { callbacks: {
                            title: function (items) {
                                const row = cp[items[0].dataIndex] || {};
                                return row.kode + ' - ' + (row.nama || '');
                            },
                            label: rcTooltipPersen('stack').label
                        } } } }
                });
            }

            function renderTimetable() {
                if (!ttData) return;
                const campaigns = ttData.campaigns || [];
                let depots = ttData.depots || [];

                if (document.getElementById('ttHanyaBelum').checked) {
                    depots = depots.filter(d => Number(d.completedPersen || 0) < 100);
                }

                // ---- Progres per depot -------------------------------------------------
                document.getElementById('ttDepotBody').innerHTML = depots.map(function (d) {
                    const selesai = Number(d.completedPersen || 0) >= 100;
                    return '<tr class="border-b border-gray-100 hover:bg-amber-50">'
                        + '<td class="p-3">' + rcTautTeks('ttBukaDetailDepot(&#39;' + rcEsc(d.kodeDepot) + '&#39;)',
                            '<span class="font-black text-blue-700">' + rcEsc(d.kodeDepot) + '</span>'
                            + '<span class="text-gray-500 text-xs block">' + rcEsc(d.namaDepot) + '</span>', 'block text-left hover:underline') + '</td>'
                        + '<td class="p-3 text-gray-600">' + rcEsc(d.region) + '</td>'
                        + '<td class="p-3 text-right text-green-700 font-bold">' + Number(d.completed || 0) + '</td>'
                        + '<td class="p-3 text-right text-gray-600">' + Number(d.notAchieved || 0) + '</td>'
                        + '<td class="p-3 text-right text-orange-700">' + Number(d.compiled || 0) + '</td>'
                        + '<td class="p-3 text-right text-red-600 font-bold">' + Number(d.notYet || 0) + '</td>'
                        + '<td class="p-3 text-right" data-sort="' + Number(d.compilePersen || 0) + '">' + (d.compilePersen === null ? '-' : d.compilePersen + '%') + '</td>'
                        + '<td class="p-3 text-right font-black ' + (selesai ? 'text-green-700' : 'text-gray-700') + '" data-sort="' + Number(d.completedPersen || 0) + '">'
                        + (d.completedPersen === null ? '-' : d.completedPersen + '%') + '</td></tr>';
                }).join('') || '<tr><td colspan="8" class="p-6 text-center text-gray-400">Tidak ada depot yang cocok dengan filter.</td></tr>';

                rcAktifkanUrutSemua('ttCardDepot');
            }

            // Progres per Campaign - satu-satunya susunan yang dilihat SEMUA peran.
            //
            // Angkanya dijumlahkan dari ttData.depots[].sel, bukan dari ttData.perCampaign,
            // karena dua alasan. Pertama, perCampaign menggabungkan Completed dan Not Achieved
            // menjadi satu angka 'cleared', sedangkan tabel ini memisahkan keduanya. Kedua,
            // depots[] adalah sumber yang sama persis dengan tabel per depot di atasnya - jadi
            // kedua tabel tidak mungkin menampilkan jumlah yang berbeda untuk campaign yang
            // sama. Server sudah membatasi depots[] pada yurisdiksi pemanggil, sehingga admin
            // yang ditag ke empat depot melihat angka empat depot itu saja.
            function renderTimetableCampaignTabel() {
                if (!ttData) return;
                const campaigns = ttData.campaigns || [];
                const depots = ttData.depots || [];

                const rekap = new Map();
                campaigns.forEach(function (c) {
                    rekap.set(String(c.kode), {
                        kode: c.kode, nama: c.nama,
                        completed: 0, compiled: 0, notYet: 0, notAchieved: 0, total: 0
                    });
                });
                depots.forEach(function (d) {
                    const sel = d.sel || {};
                    Object.keys(sel).forEach(function (kode) {
                        const r = rekap.get(String(kode));
                        if (!r) return;
                        const status = String(sel[kode] || '');
                        if (status === 'Completed') r.completed += 1;
                        else if (status === 'Compiled') r.compiled += 1;
                        else if (status === 'Not Yet') r.notYet += 1;
                        else if (status === 'Not Achieved' || status === 'Not Participating') r.notAchieved += 1;
                        r.total += 1;
                    });
                });

                let baris = [...rekap.values()].map(function (r) {
                    r.persen = r.total === 0 ? null
                        : Math.round(((r.completed + r.notAchieved) / r.total) * 1000) / 10;
                    return r;
                });

                // Saringan yang sama dengan tabel per depot: bila pengguna hanya ingin melihat
                // yang belum selesai, campaign yang sudah 100% ikut disembunyikan di sini juga.
                if (document.getElementById('ttHanyaBelum').checked) {
                    baris = baris.filter(function (r) { return Number(r.persen || 0) < 100; });
                }

                document.getElementById('ttCampaignBody').innerHTML = baris.map(function (r) {
                    const selesai = Number(r.persen || 0) >= 100;
                    return '<tr class="border-b border-gray-100 hover:bg-amber-50">'
                        + '<td class="p-3">' + rcTautTeks('ttBukaDetailCampaign(&#39;' + rcEsc(r.kode) + '&#39;)',
                            '<span class="font-black text-blue-700">' + rcEsc(r.kode) + '</span>'
                            + '<span class="text-gray-500 text-xs block">' + rcEsc(r.nama) + '</span>', 'block text-left hover:underline') + '</td>'
                        + '<td class="p-3 text-right text-green-700 font-bold">' + r.completed + '</td>'
                        + '<td class="p-3 text-right text-orange-700">' + r.compiled + '</td>'
                        + '<td class="p-3 text-right text-red-600 font-bold">' + r.notYet + '</td>'
                        + '<td class="p-3 text-right text-gray-600">' + r.notAchieved + '</td>'
                        + '<td class="p-3 text-right font-black ' + (selesai ? 'text-green-700' : 'text-gray-700') + '" data-sort="' + Number(r.persen || 0) + '">'
                        + (r.persen === null ? '-' : r.persen + '%') + '</td>'
                        + '<td class="p-3 text-center"><button type="button" onclick="ttBukaDetailCampaign(&#39;' + rcEsc(r.kode) + '&#39;)" class="bg-white hover:bg-gray-50 text-gray-700 border border-gray-300 text-[11px] font-bold py-1.5 px-3 rounded-lg shadow-sm">'
                        + '<i class="fas fa-list mr-1 text-blue-600"></i>Detail Depot</button></td></tr>';
                }).join('') || '<tr><td colspan="7" class="p-6 text-center text-gray-400">Tidak ada campaign yang cocok dengan filter.</td></tr>';

                setTextSafely('ttCampaignTabelCatatan',
                    (ttData.tahunCampaign === 'ALL' ? 'Semua Tahun Campaign' : 'Tahun Campaign ' + rcEsc(String(ttData.tahunCampaign || '-'))) + '. '
                    + baris.length + ' campaign x '
                    + depots.length + ' depot dalam yurisdiksi Anda.');

                rcAktifkanUrutSemua('ttCardCampaignTabel');
            }

            // Matrix dipisahkan dari renderTimetable() karena kini tinggal di dalam modal:
            // ia hanya digambar ketika modalnya dibuka, bukan pada setiap pemuatan halaman.
            // Matrix 52 depot x puluhan campaign adalah ribuan sel; menggambarnya setiap kali
            // Timetable dimuat membuat layar tersendat tanpa ada yang melihatnya.
            function renderTimetableMatrix() {
                if (!ttData) return;
                const campaigns = ttData.campaigns || [];
                let depots = ttData.depots || [];
                if (document.getElementById('ttHanyaBelum').checked) {
                    depots = depots.filter(d => Number(d.completedPersen || 0) < 100);
                }

                // Proporsi sel diseragamkan.
                //
                // Sebelumnya lebar tiap kolom campaign ditentukan panjang kodenya, sehingga satu
                // baris memuat sel lebar dan sel sempit berselang-seling dan matrixnya sukar
                // dibaca menyamping. Dengan table-layout:fixed dan lebar yang ditetapkan di sini,
                // seluruh kolom campaign berukuran sama persis. Judulnya dibiarkan wrap - itulah
                // sebabnya kolomnya diperlebar - supaya kode panjang tidak terpotong.
                const LEBAR_CAMPAIGN = 92;
                document.getElementById('ttHead').innerHTML =
                    '<tr class="bg-gray-50">'
                    + '<th class="p-2 text-left sticky left-0 bg-gray-50 z-10 border-b border-r border-gray-200" style="width:200px" data-rc-no-sort="1">Depot</th>'
                    + '<th class="p-2 text-center border-b border-gray-200" style="width:70px" data-rc-no-sort="1">Compile %</th>'
                    + '<th class="p-2 text-center border-b border-r border-gray-200" style="width:80px" data-rc-no-sort="1">Completed %</th>'
                    + campaigns.map(c => '<th class="p-2 text-center border-b border-gray-200 align-bottom leading-tight" '
                        + 'style="width:' + LEBAR_CAMPAIGN + 'px;white-space:normal;overflow-wrap:anywhere" '
                        + 'data-rc-no-sort="1" title="' + rcEsc(c.kode + ' - ' + (c.nama || '')) + '">' + rcEsc(c.kode) + '</th>').join('')
                    + '</tr>';

                document.getElementById('ttBody').innerHTML = depots.map(function (d) {
                    const sel = d.sel || {};
                    return '<tr class="hover:bg-amber-50">'
                        + '<td class="p-2 sticky left-0 bg-white z-10 border-b border-r border-gray-200" style="width:200px">'
                        + rcTautTeks('ttBukaDetailDepot(&#39;' + rcEsc(d.kodeDepot) + '&#39;)',
                            '<span class="font-black text-blue-700">' + rcEsc(d.kodeDepot) + '</span>'
                            + '<span class="text-gray-500 block text-[10px]">' + rcEsc(d.namaDepot) + ' &middot; ' + rcEsc(d.region) + '</span>', 'block text-left hover:underline') + '</td>'
                        + '<td class="p-2 text-center border-b border-gray-200 font-bold">' + (d.compilePersen === null ? '-' : d.compilePersen + '%') + '</td>'
                        + '<td class="p-2 text-center border-b border-r border-gray-200 font-bold ' + (Number(d.completedPersen) >= 100 ? 'text-green-700' : 'text-gray-700') + '">'
                        + (d.completedPersen === null ? '-' : d.completedPersen + '%') + '</td>'
                        + campaigns.map(function (c) {
                            const s = sel[c.kode] || 'Not Yet';
                            return '<td class="p-0 border-b border-gray-200" style="width:' + LEBAR_CAMPAIGN + 'px"><div class="m-1 h-6 rounded flex items-center justify-center text-[9px] font-black '
                                + (TT_WARNA[s] || 'bg-gray-100') + '" title="' + rcEsc(d.kodeDepot) + ' x ' + rcEsc(c.kode) + ': ' + rcEsc(s) + '">'
                                + (s === 'Not Achieved' ? 'NA' : (s === 'Not Participating' ? 'NP' : '')) + '</div></td>';
                        }).join('')
                        + '</tr>';
                }).join('') || '<tr><td colspan="' + (campaigns.length + 3) + '" class="p-6 text-center text-gray-400">Tidak ada depot yang cocok dengan filter.</td></tr>';

            }

            // ---------- Detail Not Achieved ----------
            // Daftar seluruh pasangan yang sedang ditandai, beserta pelaku dan alasannya.
            // Pembatalan hanya untuk OSC ke atas; bagi yang lain kartu ini tetap terlihat sebagai
            // keterangan, karena tandanyalah yang menghalangi compile dan upload mereka.
            let ttNaBolehBatalkan = false;

            async function muatDetailNotAchieved() {
                try {
                    const res = await fetchApp({ action: 'timetableNotAchieved' });
                    if (res.status !== 'success') { showNotification(res.message || 'Gagal memuat.', 'error'); return; }
                    ttNaBolehBatalkan = !!res.bolehBatalkan;
                    const rows = res.rows || [];
                    document.getElementById('ttNaBody').innerHTML = rows.map(function (r) {
                        return '<tr class="border-b border-gray-100 hover:bg-amber-50">'
                            + '<td class="p-3"><span class="font-black text-blue-700">' + rcEsc(r.kodeDepot) + '</span>'
                            + '<span class="text-gray-500 text-xs block">' + rcEsc(r.namaDepot) + '</span></td>'
                            + '<td class="p-3"><span class="font-bold text-gray-700">' + rcEsc(r.kodeCampaign) + '</span>'
                            + '<span class="text-gray-500 text-xs block max-w-[280px] truncate" title="' + rcEsc(r.namaCampaign) + '">'
                            + rcEsc(r.namaCampaign) + '</span></td>'
                            + '<td class="p-3 text-gray-700">' + rcEsc(r.ditandaiOleh || '-') + '</td>'
                            + '<td class="p-3 text-center text-xs text-gray-500 whitespace-nowrap">' + rcEsc(r.ditandaiPada || '-') + '</td>'
                            + '<td class="p-3 text-xs text-gray-600">' + rcEsc(r.catatan || '-')
                            + (r.adaKlaim
                                ? '<span class="block text-[10px] text-orange-600 font-bold mt-1">Sudah ada data klaim; tanda ini sementara tidak berefek.</span>'
                                : '')
                            + '</td>'
                            + '<td class="p-3 text-center">' + (!ttBolehAksiDepot(r.kodeDepot)
                                ? ttLencanaHanyaLihat('text-xs')
                                : ttNaBolehBatalkan
                                ? '<button type="button" onclick="ttTandaiPasangan(&#39;' + rcEsc(r.kodeDepot) + '&#39;,&#39;'
                                  + rcEsc(r.kodeCampaign) + '&#39;,false)" '
                                  + 'class="px-3 py-1.5 bg-white border border-gray-300 hover:bg-gray-50 text-gray-700 font-bold rounded-lg text-xs">Batalkan</button>'
                                : '<span class="text-gray-300 text-xs" title="Membatalkan butuh akses Timetable">-</span>')
                            + '</td></tr>';
                    }).join('') || '<tr><td colspan="6" class="p-6 text-center text-gray-400">Belum ada pasangan yang ditandai Not Achieved.</td></tr>';

                    const catatan = document.getElementById('ttNaCatatan');
                    if (catatan) {
                        catatan.innerText = rows.length + ' pasangan ditandai. '
                            + 'Pasangan yang ditandai tidak dapat di-compile maupun di-upload sampai tandanya dibatalkan'
                            + (ttNaBolehBatalkan ? '.' : ' oleh pemegang akses Timetable.');
                    }
                    rcAktifkanUrutSemua('ttCardNotAchieved');
                } catch (e) { showNotification('Gagal memuat Detail Not Achieved.', 'error'); }
            }

            // ---------- Remarking Not Achieved lewat modal ----------
            //
            // Pemilik menetapkan satu jalan saja: klik campaign, lalu depotnya muncul di modal
            // dan penandaan dilakukan dari situ. Kebalikannya berlaku sama - klik depot, lalu
            // campaign-nya muncul dan penandaan dilakukan dari situ.
            //
            // Panel "Tandai Not Achieved" yang lama dilepas. Panel itu meminta pengguna memilih
            // depot dan campaign dari dua kotak daftar terpisah, tanpa memperlihatkan status
            // pasangan yang sedang dipilih. Akibatnya orang menandai pasangan yang sebenarnya
            // sudah Completed tanpa menyadarinya. Di modal, statusnya ada di baris yang sama
            // dengan tombolnya.

            function ttBolehTandai() { return bolehKelolaTimetable(); }
            function ttBolehBatalkan() { return ttNaBolehBatalkan; }

            // Satu tombol untuk satu pasangan, bentuknya mengikuti status pasangan itu.
            function ttTombolTandai(kodeDepot, kodeCampaign, status) {
                // Not Participating ditetapkan di Campaign Master, bukan ditandai dari sini.
                if (status === 'Not Participating') {
                    return '<span class="text-gray-400 text-[11px]" title="Diatur di Key Master > Campaign Master">NP (Campaign Master)</span>';
                }
                const na = status === 'Not Achieved';
                // Diperiksa lebih dulu daripada apa pun: depot di luar jangkauan bertindak tidak
                // ditawari tombol sama sekali, apa pun statusnya dan apa pun perannya.
                if (!ttBolehAksiDepot(kodeDepot)) return ttLencanaHanyaLihat();
                if (na) {
                    return ttBolehBatalkan()
                        ? '<button type="button" onclick="ttTandaiPasangan(&#39;' + rcEsc(kodeDepot) + '&#39;,&#39;'
                          + rcEsc(kodeCampaign) + '&#39;,false)" class="px-3 py-1 bg-white border border-gray-300 '
                          + 'hover:bg-gray-50 text-gray-700 font-bold rounded-lg text-[11px]">Batalkan</button>'
                        : '<span class="text-gray-300 text-[11px]" title="Membatalkan butuh akses Timetable">terkunci</span>';
                }
                // Pasangan yang sudah punya data klaim tidak ditawari penandaan: tandanya tidak
                // akan berefek, dan menawarkan tombol yang pasti sia-sia hanya membingungkan.
                if (status === 'Completed' || status === 'Compiled') {
                    return '<span class="text-gray-300 text-[11px]" title="Sudah ada data klaim; penandaan tidak berefek">-</span>';
                }
                return ttBolehTandai()
                    ? '<button type="button" onclick="ttTandaiPasangan(&#39;' + rcEsc(kodeDepot) + '&#39;,&#39;'
                      + rcEsc(kodeCampaign) + '&#39;,true)" class="px-3 py-1 bg-white border border-amber-300 '
                      + 'hover:bg-amber-50 text-amber-700 font-bold rounded-lg text-[11px]">Tandai NA</button>'
                    : '<span class="text-gray-300 text-[11px]">-</span>';
            }

            async function ttTandaiPasangan(kodeDepot, kodeCampaign, tandai) {
                const setuju = await showConfirmModal({
                    title: tandai ? 'Tandai Not Achieved' : 'Batalkan Tanda Not Achieved',
                    message: kodeDepot + ' x ' + kodeCampaign + (tandai
                        ? ' akan ditandai Not Achieved. Klaim untuk pasangan ini tidak dapat di-compile '
                          + 'maupun di-upload sampai tandanya dibatalkan oleh OSC.'
                        : ' akan dibuka kembali; klaimnya dapat di-compile dan di-upload lagi.'),
                    confirmText: tandai ? 'Ya, Tandai' : 'Ya, Batalkan',
                    danger: !!tandai
                });
                if (!setuju) return;
                showLoadingOverlay(tandai ? 'Menandai...' : 'Membatalkan tanda...');
                try {
                    const r = await fetchApp({
                        action: 'timetableMark', depots: [kodeDepot], campaigns: [kodeCampaign],
                        tandai: !!tandai, note: tandai ? 'Ditandai dari modal Timetable' : ''
                    });
                    if (r.status !== 'success') { showNotification(r.message || 'Gagal.', 'error'); return; }
                    showNotification(r.message, 'success');
                    logActivity((tandai ? 'Tandai' : 'Batalkan') + ' Not Achieved: ' + kodeDepot + ' x ' + kodeCampaign);
                    rcTutupDialog();
                    loadTimetable();
                } catch (e) { showNotification((e && e.message) || 'Gagal memperbarui tanda.', 'error'); }
                finally { hideLoadingOverlay(); }
            }

            // Klik sebuah campaign: seluruh depot untuk campaign itu, beserta tombol penandaan.
            function ttBukaDetailCampaign(kodeCampaign) {
                if (!ttData) return;
                const c = (ttData.campaigns || []).find(x => String(x.kode) === String(kodeCampaign));
                if (!c) return;
                let depots = ttData.depots || [];
                if (document.getElementById('ttHanyaBelum').checked) {
                    depots = depots.filter(d => Number(d.completedPersen || 0) < 100);
                }

                const urutan = { 'Not Yet': 0, 'Compiled': 1, 'Completed': 2, 'Not Achieved': 3, 'Not Participating': 3 };
                let completed = 0, compiled = 0, notYet = 0, na = 0;
                depots.forEach(function (d) {
                    const s = (d.sel || {})[c.kode] || 'Not Yet';
                    if (s === 'Completed') completed += 1;
                    else if (s === 'Compiled') compiled += 1;
                    else if (s === 'Not Achieved' || s === 'Not Participating') na += 1;
                    else notYet += 1;
                });

                const baris = depots.slice().sort(function (a, b) {
                    const sa = (a.sel || {})[c.kode] || 'Not Yet', sb = (b.sel || {})[c.kode] || 'Not Yet';
                    return (urutan[sa] - urutan[sb]) || String(a.kodeDepot).localeCompare(String(b.kodeDepot));
                }).map(function (d) {
                    const s = (d.sel || {})[c.kode] || 'Not Yet';
                    return '<tr class="border-b border-gray-100">'
                        + '<td class="p-2 font-bold text-gray-800 whitespace-nowrap">' + rcEsc(d.kodeDepot) + '</td>'
                        + '<td class="p-2 text-gray-600 max-w-[240px] truncate" title="' + rcEsc(d.namaDepot) + '">' + rcEsc(d.namaDepot) + '</td>'
                        + '<td class="p-2 text-gray-500 text-xs">' + rcEsc(d.region || '-') + '</td>'
                        + '<td class="p-2 text-center"><span class="px-2 py-0.5 rounded text-[10px] font-black '
                        + (TT_WARNA[s] || 'bg-gray-100') + '">' + rcEsc(s) + '</span></td>'
                        + '<td class="p-2 text-center">' + ttTombolTandai(d.kodeDepot, c.kode, s) + '</td></tr>';
                }).join('') || '<tr><td colspan="5" class="p-6 text-center text-gray-400">Tidak ada depot yang cocok dengan filter.</td></tr>';

                const penyebut = completed + compiled + notYet;
                const persen = penyebut === 0 ? null : Math.round((completed / penyebut) * 1000) / 10;

                rcDialog(c.kode + ' - ' + (c.nama || ''),
                    '<p class="text-xs text-gray-500 mb-3">Periode ' + rcEsc((c.mulai || '-') + ' s/d ' + (c.selesai || '-'))
                    + ' &middot; Completed ' + (persen === null ? '-' : persen + '%')
                    + ' &middot; Not Achieved tidak ikut dihitung sebagai tertinggal.</p>'
                    + '<div class="grid grid-cols-2 md:grid-cols-4 gap-3 mb-4">'
                    + ttKartuKecil('Completed', completed, 'text-green-700')
                    + ttKartuKecil('Not Achieved', na, 'text-gray-600')
                    + ttKartuKecil('Compiled', compiled, 'text-orange-700')
                    + ttKartuKecil('Not Yet', notYet, 'text-red-600')
                    + '</div>'
                    + '<div class="overflow-auto max-h-[52vh] border border-gray-200 rounded-lg">'
                    + '<table class="w-full text-sm"><thead class="bg-gray-50 text-gray-600 sticky top-0"><tr>'
                    + '<th class="p-2 text-left text-[10px] font-black uppercase">Depot</th>'
                    + '<th class="p-2 text-left text-[10px] font-black uppercase">Nama</th>'
                    + '<th class="p-2 text-left text-[10px] font-black uppercase">Region</th>'
                    + '<th class="p-2 text-center text-[10px] font-black uppercase">Status</th>'
                    + '<th class="p-2 text-center text-[10px] font-black uppercase">Not Achieved</th>'
                    + '</tr></thead><tbody>' + baris + '</tbody></table></div>');
            }

            // Matrix depot x campaign dipindahkan ke modal atas permintaan pemilik. Di layar
            // utama ia memakan tinggi yang besar dan jarang dipakai; di modal ia mendapat
            // seluruh lebar layar, yang justru dibutuhkan tabel selebar ini.
            function ttBukaMatrix() {
                if (!ttData) { showNotification('Belum ada data Timetable.', 'warning'); return; }
                renderTimetableMatrix();
                setHiddenSafely('ttMatrixModal', false);
            }
            function ttTutupMatrix() { setHiddenSafely('ttMatrixModal', true); }

            // Klik nama depot membuka rincian campaign beserta statusnya, seperti pada
            // TimetableDashboard.html. Datanya sudah ada di ttData, jadi tidak ada permintaan
            // baru ke server: yang dibuka hanyalah bagian yang memang sudah dimuat.
            function ttBukaDetailDepot(kodeDepot) {
                if (!ttData) return;
                const d = (ttData.depots || []).find(x => String(x.kodeDepot) === String(kodeDepot));
                if (!d) return;
                const campaigns = ttData.campaigns || [];
                const sel = d.sel || {};

                const urutan = { "Not Yet": 0, "Compiled": 1, "Completed": 2, "Not Achieved": 3, "Not Participating": 3 };
                const baris = campaigns.slice().sort(function (a, b) {
                    // Yang belum selesai ditaruh di atas: itu yang perlu ditindaklanjuti.
                    const sa = sel[a.kode] || "Not Yet", sb = sel[b.kode] || "Not Yet";
                    return (urutan[sa] - urutan[sb]) || String(a.kode).localeCompare(String(b.kode));
                }).map(function (c) {
                    const s = sel[c.kode] || "Not Yet";
                    const periode = (c.mulai || "-") + " s/d " + (c.selesai || "-");
                    return [
                        '<tr class="border-b border-gray-100">',
                        '<td class="p-2 font-bold text-gray-800">' + rcEsc(c.kode) + '</td>',
                        '<td class="p-2 text-gray-600 max-w-[320px] truncate" title="' + rcEsc(c.nama || "") + '">' + rcEsc(c.nama || "-") + '</td>',
                        '<td class="p-2 text-gray-500 whitespace-nowrap text-xs">' + rcEsc(periode) + '</td>',
                        '<td class="p-2 text-center"><span class="px-2 py-0.5 rounded text-[10px] font-black ' + (TT_WARNA[s] || "bg-gray-100") + '">' + rcEsc(s) + '</span></td>',
                        // Penandaan juga dapat dilakukan dari sisi depot, dengan aturan yang
                        // sama persis seperti dari sisi campaign - satu fungsi dipakai berdua.
                        '<td class="p-2 text-center">' + ttTombolTandai(d.kodeDepot, c.kode, s) + '</td>',
                        '</tr>'
                    ].join('');
                }).join('');

                const ringkas = [
                    '<div class="grid grid-cols-2 md:grid-cols-4 gap-3 mb-4">',
                    ttKartuKecil("Completed", d.completed, "text-green-700"),
                    ttKartuKecil("Not Achieved", d.notAchieved, "text-gray-600"),
                    ttKartuKecil("Compiled", d.compiled, "text-orange-700"),
                    ttKartuKecil("Not Yet", d.notYet, "text-red-600"),
                    '</div>'
                ].join('');

                rcDialog(d.kodeDepot + " - " + d.namaDepot,
                    '<p class="text-xs text-gray-500 mb-3">Region ' + rcEsc(d.region)
                    + ' &middot; Compile ' + (d.compilePersen === null ? "-" : d.compilePersen + "%")
                    + ' &middot; Completed ' + (d.completedPersen === null ? "-" : d.completedPersen + "%") + '</p>'
                    + ringkas
                    + '<div class="overflow-auto max-h-[52vh] border border-gray-200 rounded-lg">'
                    + '<table class="w-full text-sm"><thead class="bg-gray-50 text-gray-600 sticky top-0"><tr>'
                    + '<th class="p-2 text-left text-[10px] font-black uppercase">Kode</th>'
                    + '<th class="p-2 text-left text-[10px] font-black uppercase">Campaign</th>'
                    + '<th class="p-2 text-left text-[10px] font-black uppercase">Periode</th>'
                    + '<th class="p-2 text-center text-[10px] font-black uppercase">Status</th>'
                    + '<th class="p-2 text-center text-[10px] font-black uppercase">Not Achieved</th>'
                    + '</tr></thead><tbody>' + (baris || '<tr><td colspan="5" class="p-4 text-center text-gray-400">Tidak ada campaign pada tahun terpilih.</td></tr>')
                    + '</tbody></table></div>');
            }

            function ttKartuKecil(judul, nilai, warna) {
                return '<div class="border border-gray-200 rounded-xl p-3 text-center">'
                    + '<p class="text-[10px] font-black text-gray-500 uppercase">' + judul + '</p>'
                    + '<p class="text-lg font-black ' + warna + '">' + Number(nilai || 0) + '</p></div>';
            }
            // ttTerpilih() dan tandaiNotAchieved() dihapus bersama panel tandai massal.
            // Keduanya membaca dua kotak daftar <select multiple> yang sudah tidak ada di markup;
            // membiarkannya berarti menyimpan fungsi yang pasti melempar galat begitu dipanggil.
            // Penggantinya ttTandaiPasangan(), yang menandai satu pasangan dari dalam modal.

            function downloadTimetableExcel() {
                if (!ttData) { showNotification('Belum ada data untuk diekspor.', 'warning'); return; }
                const campaigns = ttData.campaigns || [];
                // Sama dengan matrix di layar: penyaring "hanya yang belum selesai" ikut berlaku,
                // dan persen ditulis seperti tampilannya ("-" bila belum ada, selain itu n%).
                let depots = ttData.depots || [];
                if (document.getElementById('ttHanyaBelum').checked) {
                    depots = depots.filter(d => Number(d.completedPersen || 0) < 100);
                }
                const persen = v => (v === null || v === undefined) ? '-'
                    : { t: 'n', v: Number(v) / 100, z: Number.isInteger(Number(v)) ? '0%' : '0.0#%' };
                const aoa = [['Kode Depot', 'Nama Depot', 'Region', 'Compile %', 'Completed %']
                    .concat(campaigns.map(c => c.kode))];
                depots.forEach(d => {
                    aoa.push([rcSelTeks(d.kodeDepot), d.namaDepot, rcSelTeks(d.region), persen(d.compilePersen), persen(d.completedPersen)]
                        .concat(campaigns.map(c => (d.sel || {})[c.kode] || 'Not Yet')));
                });
                const wb = XLSX.utils.book_new();
                XLSX.utils.book_append_sheet(wb, XLSX.utils.aoa_to_sheet(aoa), 'Timetable');
                XLSX.writeFile(wb, 'RC_Timetable_' + (ttData.tahunCampaign === 'ALL' ? 'Semua_Tahun' : String(ttData.tahunCampaign || 'Campaign')) + '.xlsx');
            }
