            // ============================================================================
            // TAMPILAN REPORT - dipakai aplikasi DAN dashboard publik
            // ============================================================================
            // Susunannya mengikuti Dashboard.html pada RC_Reporting_AppsScript: kartu KPI,
            // Tren Volume & Nilai, Distribusi Status, Aging, Clearing Rate per Region, Top 10
            // Depot Outstanding %, tabel Performa per Campaign, lalu Cost Center 1 dan 2
            // beserta diagram masing-masing.
            //
            // Seluruhnya menggambar ke id yang sama - rtKpi, rtChartVolume, rtCc1Body dan
            // seterusnya - yang disediakan view/parts/report-panes.html. Markup panelnya pun
            // berkas bersama, sehingga menambah sebuah diagram cukup dilakukan sekali dan
            // muncul di kedua halaman.
            //
            // Tidak ada satu pun fungsi di sini yang memanggil backend atau membaca sesi.
            // Datanya diserahkan pemanggilnya: loadReport() di dalam aplikasi, dan muat() pada
            // halaman publik.

            let rtData = { dashboard: null, cc1: null, cc2: null };
            // Grafik disimpan supaya dapat dihancurkan sebelum digambar ulang. Chart.js menolak
            // dua grafik pada kanvas yang sama dan akan diam-diam berhenti memperbarui.
            let rtChart = {};
            const RT_WARNA = ['#2563eb', '#f97316', '#eab308', '#22c55e', '#a855f7', '#64748b', '#ef4444'];

            // Judul tooltip untuk diagram berlabel kode campaign: kode diikuti namanya.
            // "Lainnya" adalah kelompok gabungan, bukan sebuah campaign, jadi dibiarkan apa adanya.
            function rtJudulCampaign(kode, peta) {
                if (!kode || kode === 'Lainnya') return kode || '';
                const nama = (peta || {})[kode];
                return nama ? kode + ' - ' + nama : kode;
            }

            function rtRp(n) { return rcNominalPenuh(n); }
            function rtPersen(n) { return (Number(n || 0) * 100).toFixed(1) + '%'; }

            // Sel nominal: ditampilkan ringkas supaya tidak melebar, diurutkan memakai nilai
            // penuh lewat data-sort, dan angka persisnya muncul saat disorot.
            function rtSelUang(n, kelas) {
                return '<td class="p-3 text-right ' + (kelas || '') + '" data-sort="' + Number(n || 0)
                    + '" title="' + rcEsc(rcNominalPenuh(n)) + '">' + rcEsc(rcNominal(n)) + '</td>';
            }
            function rtSelPersen(n, kelas) {
                return '<td class="p-3 text-right ' + (kelas || '') + '" data-sort="' + Number(n || 0)
                    + '">' + rtPersen(n) + '</td>';
            }
            function rtGambarChart(id, konfig) {
                if (rtChart[id]) { rtChart[id].destroy(); delete rtChart[id]; }
                const el = document.getElementById(id);
                if (!el || typeof Chart === 'undefined') return;
                rtChart[id] = new Chart(el.getContext('2d'), konfig);
            }

            function renderReportDashboard(res) {
                const k = res.kpi || {};
                document.getElementById('rtDibuatPada').innerText = 'Data per ' + (res.dibuatPada || '-');

                // Setiap kartu memuat nilai sekaligus jumlahnya, sesuai permintaan pemilik.
                // Nominalnya diringkas ke juta supaya tidak melewati lebar kartu; angka
                // persisnya tetap tersedia lewat atribut title saat disorot.
                const kartu = [
                    ['Total Klaim', Number(k.claimQty || 0).toLocaleString('id-ID') + ' dok',
                     (k.jumlahDepot || 0) + ' depot &middot; ' + (k.jumlahCampaign || 0) + ' campaign',
                     'text-gray-800', ''],
                    ['Total Net CB', rcNominalRingkas(k.netCb),
                     Number(k.claimQty || 0).toLocaleString('id-ID') + ' dokumen',
                     'text-blue-700', rcNominalPenuh(k.netCb)],
                    ['Net Claimed (Done)', rcNominalRingkas(k.netClaimed),
                     Number(k.qtyDone || 0).toLocaleString('id-ID') + ' dokumen',
                     'text-green-700', rcNominalPenuh(k.netClaimed)],
                    ['Expired', rcNominalRingkas(k.cbExpired),
                     Number(k.qtyExpired || 0).toLocaleString('id-ID') + ' dokumen',
                     'text-gray-600', rcNominalPenuh(k.cbExpired)],
                    ['Outstanding', rcNominalRingkas(k.outstandingValue),
                     Number(k.outstandingQty || 0).toLocaleString('id-ID') + ' dokumen',
                     'text-orange-700', rcNominalPenuh(k.outstandingValue)],
                    ['Clearing Rate', rtPersen(k.clearingRate),
                     'Done + Expired dari Net CB', 'text-indigo-700', '']
                ];
                document.getElementById('rtKpi').innerHTML = kartu.map(function (c) {
                    const judulPenuh = c[4] ? ' title="' + rcEsc(c[4]) + '"' : '';
                    return '<div class="bg-white border border-gray-200 rounded-2xl p-4 shadow-sm overflow-hidden">'
                        + '<p class="text-[10px] font-black text-gray-500 uppercase tracking-wider truncate">' + rcEsc(c[0]) + '</p>'
                        + '<p class="rc-kpi-value font-black ' + c[3] + (c[4] ? ' rc-kpi-money' : '') + ' mt-1"' + judulPenuh + '>' + rcEsc(c[1]) + '</p>'
                        + '<p class="rc-kpi-sub">' + c[2] + '</p></div>';
                }).join('');

                // ---- Tren volume dan nilai per bulan --------------------------------------
                const tren = res.trenBulanan || [];
                rtGambarChart('rtChartVolume', {
                    type: 'bar',
                    data: {
                        labels: tren.map(t => t.label),
                        datasets: [
                            { label: 'Jumlah Klaim', data: tren.map(t => Number(t.qty)), yAxisID: 'y',
                              backgroundColor: '#93c5fd', borderRadius: 4, order: 2 },
                            { label: 'Nilai', data: tren.map(t => Number(t.nilai)), yAxisID: 'y1',
                              type: 'line', borderColor: '#2563eb', backgroundColor: '#2563eb',
                              tension: 0.3, borderWidth: 2, pointRadius: 3, order: 1 }
                        ]
                    },
                    options: {
                        responsive: true, maintainAspectRatio: false,
                        interaction: { mode: 'index', intersect: false },
                        scales: {
                            y: { position: 'left', title: { display: true, text: 'Dokumen' } },
                            y1: { position: 'right', grid: { drawOnChartArea: false },
                                  ticks: { callback: v => rcNominal(v) } }
                        },
                        plugins: { tooltip: { callbacks: { label: function (c) {
                            return c.datasetIndex === 1
                                ? 'Nilai: ' + rcNominalPenuh(c.raw)
                                : 'Klaim: ' + Number(c.raw).toLocaleString('id-ID');
                        } } } }
                    }
                });

                // ---- Distribusi status -----------------------------------------------------
                rtStatusMentah = res.status_distribusi || [];
                gambarDistribusiStatus();

                // ---- Aging -----------------------------------------------------------------
                const ag = res.aging || [];
                rtGambarChart('rtChartAging', {
                    type: 'bar',
                    data: { labels: ag.map(a => a.kelompok),
                            datasets: [{ label: 'Dokumen', data: ag.map(a => Number(a.qty)),
                                         backgroundColor: ['#22c55e', '#eab308', '#f97316', '#ef4444'],
                                         borderRadius: 4 }] },
                    options: { responsive: true, maintainAspectRatio: false,
                        plugins: { legend: { display: false },
                            tooltip: { callbacks: { label: function (c) {
                                const row = ag[c.dataIndex] || {};
                                return Number(row.qty).toLocaleString('id-ID') + ' dok - ' + rcNominalPenuh(row.nilai);
                            } } } } }
                });

                // ---- Clearing rate per region ----------------------------------------------
                const rg = res.region || [];
                rtGambarChart('rtChartRegion', {
                    type: 'bar',
                    data: { labels: rg.map(r => r.region),
                            datasets: [{ label: 'Clearing Rate', data: rg.map(r => Number(r.clearingRate) * 100),
                                         backgroundColor: '#2563eb', borderRadius: 4 }] },
                    options: { responsive: true, maintainAspectRatio: false,
                        scales: { y: { beginAtZero: true, max: 100, ticks: { callback: v => v + '%' } } },
                        plugins: { legend: { display: false },
                            tooltip: { callbacks: { label: c => Number(c.raw).toFixed(1) + '%' } } } }
                });

                // ---- Top 10 depot outstanding % --------------------------------------------
                // Proporsional, bukan nominal: depot kecil yang seluruh klaimnya tertahan tetap
                // muncul, dan itu justru yang perlu ditindaklanjuti.
                const top = (res.depot || []).slice()
                    .sort((a, b) => Number(b.outstandingRate) - Number(a.outstandingRate)).slice(0, 10);
                rtGambarChart('rtChartDepot', {
                    type: 'bar',
                    data: { labels: top.map(d => d.kodeDepot + ' - ' + d.namaDepot),
                            datasets: [{ label: 'Outstanding %',
                                         data: top.map(d => Number(d.outstandingRate) * 100),
                                         backgroundColor: '#f97316', borderRadius: 4 }] },
                    options: { indexAxis: 'y', responsive: true, maintainAspectRatio: false,
                        scales: { x: { beginAtZero: true, max: 100, ticks: { callback: v => v + '%' } } },
                        plugins: { legend: { display: false },
                            tooltip: { callbacks: { label: function (c) {
                                const row = top[c.dataIndex] || {};
                                return Number(c.raw).toFixed(1) + '% - ' + rcNominalPenuh(row.outstandingValue)
                                    + ' dari ' + rcNominalPenuh(row.netCb);
                            } } } } }
                });

                // ---- Performa per campaign --------------------------------------------------
                document.getElementById('rtPerformaBody').innerHTML = (res.campaign || []).map(function (c) {
                    const kelasRate = Number(c.clearingRate) < 0.5 ? 'bg-red-100 text-red-700'
                        : Number(c.clearingRate) < 0.8 ? 'bg-yellow-100 text-yellow-800'
                        : 'bg-green-100 text-green-700';
                    return '<tr class="border-b border-gray-100 hover:bg-blue-50">'
                        + '<td class="p-3"><span class="font-black text-gray-800">' + rcEsc(c.kodeCampaign) + '</span>'
                        + '<span class="text-gray-500 text-xs block max-w-[260px] truncate" title="' + rcEsc(c.namaCampaign) + '">' + rcEsc(c.namaCampaign) + '</span></td>'
                        + '<td class="p-3 text-right">' + Number(c.qty || 0).toLocaleString('id-ID') + '</td>'
                        + '<td class="p-3 text-right" data-sort="' + Number(c.netCb || 0) + '" title="' + rcEsc(rcNominalPenuh(c.netCb)) + '">' + rcEsc(rcNominal(c.netCb)) + '</td>'
                        + '<td class="p-3 text-right text-green-700 font-bold" data-sort="' + Number(c.netClaimed || 0) + '" title="' + rcEsc(rcNominalPenuh(c.netClaimed)) + '">' + rcEsc(rcNominal(c.netClaimed)) + '</td>'
                        + '<td class="p-3 text-right">' + Number(c.outstandingQty || 0).toLocaleString('id-ID') + '</td>'
                        + '<td class="p-3 text-right text-orange-700 font-bold" data-sort="' + Number(c.outstandingValue || 0) + '" title="' + rcEsc(rcNominalPenuh(c.outstandingValue)) + '">' + rcEsc(rcNominal(c.outstandingValue)) + '</td>'
                        + '<td class="p-3 text-right" data-sort="' + Number(c.outstandingRate || 0) + '">' + rtPersen(c.outstandingRate) + '</td>'
                        + '<td class="p-3 text-right" data-sort="' + Number(c.clearingRate || 0) + '">'
                        + '<span class="px-2 py-0.5 rounded font-black text-[11px] ' + kelasRate + '">' + rtPersen(c.clearingRate) + '</span></td></tr>';
                }).join('') || '<tr><td colspan="8" class="p-6 text-center text-gray-400">Tidak ada data.</td></tr>';

                // ---- Performa per region ---------------------------------------------------
                document.getElementById('rtRegionBody').innerHTML = (res.region || []).map(function (r) {
                    return [
                        '<tr class="border-b border-gray-100 hover:bg-blue-50">',
                        '<td class="p-3 font-black text-gray-800">' + rcEsc(r.region) + '</td>',
                        '<td class="p-3 text-right">' + Number(r.qty || 0).toLocaleString('id-ID') + '</td>',
                        rtSelUang(r.netCb, ''),
                        rtSelUang(r.netClaimed, 'text-green-700 font-bold'),
                        rtSelUang(r.outstandingValue, 'text-orange-700 font-bold'),
                        rtSelPersen(r.clearingRate, 'font-black'),
                        '</tr>'
                    ].join('');
                }).join('') || '<tr><td colspan="6" class="p-6 text-center text-gray-400">Belum ada region terisi. Isi lewat Key Master &rarr; Depot Master.</td></tr>';

                // ---- Performa per depot ----------------------------------------------------
                document.getElementById('rtDepotTblBody').innerHTML = (res.depot || []).map(function (d) {
                    return [
                        '<tr class="border-b border-gray-100 hover:bg-blue-50">',
                        '<td class="p-3"><span class="font-black text-gray-800">' + rcEsc(d.kodeDepot) + '</span>',
                        '<span class="text-gray-500 text-xs block">' + rcEsc(d.namaDepot) + ' &middot; ' + rcEsc(d.region || '-') + '</span></td>',
                        '<td class="p-3 text-right">' + Number(d.qty || 0).toLocaleString('id-ID') + '</td>',
                        rtSelUang(d.netCb, ''),
                        rtSelUang(d.netClaimed, 'text-green-700 font-bold'),
                        rtSelUang(d.outstandingValue, 'text-orange-700 font-bold'),
                        rtSelPersen(d.outstandingRate, ''),
                        rtSelPersen(d.clearingRate, Number(d.clearingRate) < 0.5 ? 'font-black text-red-600' : 'font-black text-gray-800'),
                        '</tr>'
                    ].join('');
                }).join('') || '<tr><td colspan="7" class="p-6 text-center text-gray-400">Tidak ada data.</td></tr>';

                rcAktifkanUrutSemua('rtPaneDashboard');
            }

            // Distribusi Status Claim dapat dibaca dengan dua cara.
            //
            // BY STAGE adalah status mentah apa adanya: Not Yet, Submitted, Released, Claimed,
            // Done, On Hold, Expired. Berguna ketika yang dicari adalah letak persis sebuah
            // dokumen di dalam alur.
            //
            // BY PENDING GROUP menjawab pertanyaan yang lebih sering diajukan: siapa yang
            // sedang ditunggu. Pemetaannya ditetapkan pemilik:
            //
            //   Pending Depot   <- Not Yet, kosong, On Hold
            //   Pending OSC     <- Submitted, Released, dan status lain yang tidak terpetakan
            //   Pending Finance <- Claimed
            //   Done            <- Done, Expired
            //
            // On Hold masuk Pending Depot karena yang harus bertindak memang depot - nominalnya
            // perlu direvisi di sisi compilation. Expired dihitung Done karena dokumennya sudah
            // selesai berurusan dengan siapa pun, meski selesainya bukan berupa pencairan.
            //
            // Cara 2 menjadi bawaan atas permintaan pemilik; pilihannya ada di dalam modal.
            let rtStatusMentah = [];
            let rtStatusCara = 'grup';

            const RT_GRUP_STATUS = [
                { label: 'Pending Depot',   warna: '#ef4444', cocok: ['not yet', 'not_yet', '', 'submitted', 'on hold'] },
                { label: 'Pending OSC',     warna: '#f97316', cocok: ['approved', 'released', 'bulk process', 'bulk_processed'] },
                { label: 'Pending Finance', warna: '#2563eb', cocok: ['claimed'] },
                { label: 'Done',            warna: '#22c55e', cocok: ['done', 'expired'] }
            ];

            function rtKelompokStatus(rows) {
                const hasil = RT_GRUP_STATUS.map(g => ({ status: g.label, warna: g.warna, qty: 0, nilai: 0 }));
                // Status yang tidak terpetakan jatuh ke Pending OSC, sesuai ketetapan pemilik.
                const iLainnya = 1;
                (rows || []).forEach(function (r) {
                    const nama = String(r.status || '').trim().toLowerCase();
                    let i = RT_GRUP_STATUS.findIndex(g => g.cocok.indexOf(nama) !== -1);
                    if (i === -1) i = iLainnya;
                    hasil[i].qty += Number(r.qty || 0);
                    hasil[i].nilai += Number(r.nilai || 0);
                });
                return hasil;
            }

            function rtBarisStatus() {
                if (rtStatusCara === 'stage') {
                    return (rtStatusMentah || []).map(function (r, i) {
                        return { status: r.status, qty: Number(r.qty || 0), nilai: Number(r.nilai || 0),
                                 warna: RT_WARNA[i % RT_WARNA.length] };
                    });
                }
                return rtKelompokStatus(rtStatusMentah);
            }

            function gambarDistribusiStatus() {
                const baris = rtBarisStatus();
                const total = baris.reduce((a, b) => a + b.qty, 0);
                const ket = document.getElementById('rtStatusKeterangan');
                if (ket) {
                    ket.innerText = rtStatusCara === 'grup'
                        ? 'Not Yet / Submitted: Pending Depot; Approved / Released: Pending OSC; Claimed: Pending Finance. On Hold masuk Pending Depot; Expired dihitung Done.'
                        : 'Status mentah apa adanya, satu irisan per tahap alur.';
                }
                rtGambarChart('rtChartStatus', {
                    type: 'doughnut',
                    data: { labels: baris.map(b => b.status),
                            datasets: [{ data: baris.map(b => b.qty),
                                         backgroundColor: baris.map(b => b.warna) }] },
                    options: { responsive: true, maintainAspectRatio: false,
                        plugins: { legend: { position: 'right' },
                            tooltip: { callbacks: { label: function (c) {
                                const row = baris[c.dataIndex] || {};
                                const persen = total ? (row.qty / total) * 100 : 0;
                                return c.label + ': ' + Number(row.qty).toLocaleString('id-ID')
                                    + ' dok (' + (Math.round(persen * 10) / 10) + '%) &middot; '
                                    + rcNominalPenuh(row.nilai);
                            } } } } }
                });
            }

            function rtUbahCaraStatus(cara) {
                rtStatusCara = cara === 'stage' ? 'stage' : 'grup';
                ['grup', 'stage'].forEach(function (k) {
                    const b = document.getElementById('rtStatusCara' + (k === 'grup' ? 'Grup' : 'Stage'));
                    if (!b) return;
                    b.className = 'px-3 py-1.5 text-[11px] font-black rounded-lg border transition '
                        + (rtStatusCara === k
                            ? 'bg-blue-600 text-white border-blue-600'
                            : 'bg-white text-gray-600 border-gray-300 hover:bg-gray-50');
                });
                gambarDistribusiStatus();
            }

            function renderCostCenter1(rows) {
                document.getElementById('rtCc1Body').innerHTML = rows.map(function (r) {
                    return '<tr class="border-b border-gray-100 hover:bg-blue-50">'
                        + '<td class="p-3"><span class="font-bold text-gray-800">' + rcEsc(r.kodeDepot) + '</span>'
                        + '<span class="text-gray-500 text-xs block">' + rcEsc(r.namaDepot) + '</span></td>'
                        + '<td class="p-3"><span class="font-bold text-gray-700">' + rcEsc(r.kodeCampaign) + '</span>'
                        + '<span class="text-gray-500 text-xs block max-w-[220px] truncate" title="' + rcEsc(r.namaCampaign) + '">' + rcEsc(r.namaCampaign) + '</span></td>'
                        + '<td class="p-3 text-right">' + Number(r.qty || 0).toLocaleString('id-ID') + '</td>'
                        + '<td class="p-3 text-right" data-sort="' + Number(r.netCb || 0) + '" title="' + rcEsc(rcNominalPenuh(r.netCb)) + '">' + rcEsc(rcNominal(r.netCb)) + '</td>'
                        + '<td class="p-3 text-right text-green-700 font-bold" data-sort="' + Number(r.netClaimed || 0) + '" title="' + rcEsc(rcNominalPenuh(r.netClaimed)) + '">' + rcEsc(rcNominal(r.netClaimed)) + '</td>'
                        + '<td class="p-3 text-right text-emerald-700" data-sort="' + Number(r.grossClaimed || 0) + '" title="' + rcEsc(rcNominalPenuh(r.grossClaimed)) + '">' + rcEsc(rcNominal(r.grossClaimed)) + '</td>'
                        + '<td class="p-3 text-right text-gray-600" data-sort="' + Number(r.cbExpired || 0) + '" title="' + rcEsc(rcNominalPenuh(r.cbExpired)) + '">' + rcEsc(rcNominal(r.cbExpired)) + '</td>'
                        + '<td class="p-3 text-right font-black" data-sort="' + Number(r.clearingRate || 0) + '">' + rtPersen(r.clearingRate) + '</td></tr>';
                }).join('') || '<tr><td colspan="8" class="p-6 text-center text-gray-400">Tidak ada data.</td></tr>';
            }

            function renderCostCenter2(rows, catatan) {
                document.getElementById('rtCc2Catatan').innerText = catatan || '';
                document.getElementById('rtCc2Body').innerHTML = rows.map(function (r) {
                    return '<tr class="border-b border-gray-100 hover:bg-blue-50">'
                        + '<td class="p-3 font-bold text-gray-800 whitespace-nowrap" data-sort="' + rcEsc(r.bulan) + '">' + rcEsc(r.namaBulan) + '</td>'
                        + '<td class="p-3"><span class="font-bold text-gray-700">' + rcEsc(r.kodeCampaign) + '</span>'
                        + '<span class="text-gray-500 text-xs block max-w-[260px] truncate" title="' + rcEsc(r.namaCampaign) + '">' + rcEsc(r.namaCampaign) + '</span></td>'
                        + '<td class="p-3 text-right">' + Number(r.qty || 0).toLocaleString('id-ID') + '</td>'
                        + '<td class="p-3 text-right text-green-700 font-bold" data-sort="' + Number(r.netClaimed || 0) + '" title="' + rcEsc(rcNominalPenuh(r.netClaimed)) + '">' + rcEsc(rcNominal(r.netClaimed)) + '</td>'
                        + '<td class="p-3 text-right text-emerald-700 font-bold" data-sort="' + Number(r.grossClaimed || 0) + '" title="' + rcEsc(rcNominalPenuh(r.grossClaimed)) + '">' + rcEsc(rcNominal(r.grossClaimed)) + '</td></tr>';
                }).join('') || '<tr><td colspan="5" class="p-6 text-center text-gray-400">Belum ada baris Done dengan tanggal clearing.</td></tr>';
            }

            // ---- Grafik Cost Center 1 -------------------------------------------------------
            // Empat sudut pandang yang saling melengkapi: siapa yang paling besar nilainya,
            // ke mana nilainya tersebar, seberapa sehat penyelesaiannya, dan berapa yang hangus.
            function renderCc1Charts(rows) {
                // Agregasi per depot, lalu sepuluh terbesar. Menggambar seluruh 82 baris hanya
                // menghasilkan grafik yang tidak terbaca.
                const perDepot = {};
                rows.forEach(function (r) {
                    const k = r.kodeDepot + ' - ' + r.namaDepot;
                    if (!perDepot[k]) perDepot[k] = { netCb: 0, netClaimed: 0 };
                    perDepot[k].netCb += Number(r.netCb || 0);
                    perDepot[k].netClaimed += Number(r.netClaimed || 0);
                });
                const depotTop = Object.keys(perDepot)
                    .map(k => ({ k: k, v: perDepot[k] }))
                    .sort((a, b) => b.v.netCb - a.v.netCb).slice(0, 10);
                rtGambarChart('rtChartCc1Depot', {
                    type: 'bar',
                    data: { labels: depotTop.map(x => x.k), datasets: [
                        { label: 'Net CB', data: depotTop.map(x => x.v.netCb), backgroundColor: '#93c5fd', borderRadius: 4 },
                        { label: 'Net Claimed', data: depotTop.map(x => x.v.netClaimed), backgroundColor: '#22c55e', borderRadius: 4 }
                    ] },
                    options: { indexAxis: 'y', responsive: true, maintainAspectRatio: false,
                        scales: { x: { ticks: { callback: v => rcNominal(v) } } },
                        plugins: { tooltip: { callbacks: { label: c => c.dataset.label + ': ' + rcNominalPenuh(c.raw) } } } }
                });

                // Nama campaign disimpan per kode supaya tooltip dapat menyebutnya. Diagram
                // memakai kode sebagai label - nama lengkapnya terlalu panjang untuk sumbu -
                // tetapi kode saja tidak memberitahu apa-apa kepada pembacanya.
                const namaCamp = {};
                rows.forEach(r => { if (r.kodeCampaign) namaCamp[r.kodeCampaign] = r.namaCampaign || r.campaignName || ''; });
                const perCamp = {};
                rows.forEach(function (r) {
                    const k = r.kodeCampaign;
                    perCamp[k] = (perCamp[k] || 0) + Number(r.netCb || 0);
                });
                const campUrut = Object.keys(perCamp).map(k => ({ k: k, v: perCamp[k] }))
                    .sort((a, b) => b.v - a.v);
                const camp10 = campUrut.slice(0, 10);
                const sisa = campUrut.slice(10).reduce((s, x) => s + x.v, 0);
                const labelCamp = camp10.map(x => x.k).concat(sisa > 0 ? ['Lainnya'] : []);
                const nilaiCamp = camp10.map(x => x.v).concat(sisa > 0 ? [sisa] : []);
                rtGambarChart('rtChartCc1Camp', {
                    type: 'doughnut',
                    data: { labels: labelCamp, datasets: [{ data: nilaiCamp,
                        backgroundColor: labelCamp.map((x, i) => RT_WARNA[i % RT_WARNA.length]) }] },
                    options: { responsive: true, maintainAspectRatio: false,
                        plugins: { legend: { position: 'right' },
                            tooltip: { callbacks: {
                                title: c => rtJudulCampaign(c[0].label, namaCamp),
                                label: c => rcNominalPenuh(c.raw) } } } }
                });

                // Sebaran clearing rate. Menunjukkan apakah masalahnya merata atau terpusat.
                const rentang = [0, 0, 0, 0, 0];
                const labelRentang = ['0-25%', '26-50%', '51-75%', '76-99%', '100%'];
                // Isi tiap rentang disimpan, bukan hanya jumlahnya. Pemilik meminta diagram ini
                // diperjelas: "jika campaign kasih tanda campaign apa ketika kursor didekatkan".
                // Sebuah batang setinggi 30 tidak memberi tahu apa pun tentang campaign MANA yang
                // tertahan di 0-25%, dan justru itulah yang dicari pembacanya.
                const isiRentang = [[], [], [], [], []];
                rows.forEach(function (r) {
                    const p = Number(r.clearingRate || 0) * 100;
                    const i = p >= 100 ? 4 : p > 75 ? 3 : p > 50 ? 2 : p > 25 ? 1 : 0;
                    rentang[i] += 1;
                    isiRentang[i].push({
                        camp: r.kodeCampaign || '-',
                        nama: r.namaCampaign || '',
                        depot: r.kodeDepot || '-',
                        cr: Number(r.clearingRate || 0)
                    });
                });
                // Per campaign, supaya daftarnya terbaca. Satu campaign dapat muncul di beberapa
                // depot; yang ditampilkan berapa pasangan depotnya di rentang itu.
                const ringkasRentang = isiRentang.map(function (daftar) {
                    const per = {};
                    daftar.forEach(function (x) {
                        if (!per[x.camp]) per[x.camp] = { nama: x.nama, n: 0 };
                        per[x.camp].n += 1;
                    });
                    return Object.keys(per)
                        .map(function (k) { return { kode: k, nama: per[k].nama, n: per[k].n }; })
                        .sort(function (a, b) { return b.n - a.n; });
                });
                rtGambarChart('rtChartCc1Clearing', {
                    type: 'bar',
                    data: { labels: labelRentang, datasets: [{ label: 'Pasangan depot x campaign',
                        data: rentang, backgroundColor: ['#ef4444', '#f97316', '#eab308', '#84cc16', '#22c55e'], borderRadius: 4 }] },
                    options: { responsive: true, maintainAspectRatio: false,
                        scales: { y: { beginAtZero: true } },
                        plugins: { legend: { display: false },
                            tooltip: { callbacks: {
                                title: function (c) {
                                    return 'Clearing Rate ' + c[0].label + ' - '
                                        + rentang[c[0].dataIndex] + ' pasangan depot x campaign';
                                },
                                label: function () { return ''; },
                                afterBody: function (c) {
                                    const daftar = ringkasRentang[c[0].dataIndex] || [];
                                    if (!daftar.length) return ['Tidak ada.'];
                                    // Sepuluh teratas; sisanya diringkas supaya tooltip tidak
                                    // tumbuh melebihi layar dan justru menutupi diagramnya.
                                    const baris = daftar.slice(0, 10).map(function (x) {
                                        return '• ' + x.kode + (x.nama ? ' - ' + x.nama : '')
                                            + ' (' + x.n + ' depot)';
                                    });
                                    if (daftar.length > 10) {
                                        baris.push('… dan ' + (daftar.length - 10) + ' campaign lain');
                                    }
                                    return baris;
                                }
                            } } } }
                });

                const expired = rows.filter(r => Number(r.cbExpired || 0) > 0)
                    .sort((a, b) => Number(b.cbExpired) - Number(a.cbExpired)).slice(0, 10);
                rtGambarChart('rtChartCc1Expired', {
                    type: 'bar',
                    data: { labels: expired.map(r => r.kodeDepot + ' / ' + r.kodeCampaign),
                        datasets: [{ label: 'CB Expired', data: expired.map(r => Number(r.cbExpired)),
                            backgroundColor: '#64748b', borderRadius: 4 }] },
                    options: { indexAxis: 'y', responsive: true, maintainAspectRatio: false,
                        scales: { x: { ticks: { callback: v => rcNominal(v) } } },
                        plugins: { legend: { display: false },
                            tooltip: { callbacks: {
                                title: function (c) {
                                    const r = expired[c[0].dataIndex] || {};
                                    return r.kodeDepot + ' / ' + r.kodeCampaign
                                        + (r.namaCampaign ? ' - ' + r.namaCampaign : '');
                                },
                                label: c => rcNominalPenuh(c.raw) } } } }
                });
            }

            // ---- Cost Center 2: filter bulan dan dua grafik ---------------------------------
            function rtIsiFilterBulan(rows) {
                const el = document.getElementById('rtCc2Bulan');
                const terpilih = el.value;
                // Bulan diurutkan menurun supaya yang terbaru berada di atas.
                const bulan = [...new Set(rows.map(r => r.bulan))].sort().reverse();
                const peta = {};
                rows.forEach(r => { peta[r.bulan] = r.namaBulan; });
                el.innerHTML = '<option value="">Semua Bulan</option>'
                    + bulan.map(b => '<option value="' + rcEsc(b) + '">' + rcEsc(peta[b] || b) + '</option>').join('');
                el.value = bulan.indexOf(terpilih) >= 0 ? terpilih : '';
            }

            // Dipanggil ketika filter bulan berubah. Tidak meminta ulang ke server: seluruh
            // barisnya sudah ada, yang berubah hanya yang ditampilkan.
            function renderCc2Terfilter() {
                const semua = (rtData.cc2 && rtData.cc2.rows) || [];
                const bulan = document.getElementById('rtCc2Bulan').value;
                const terpilih = bulan ? semua.filter(r => r.bulan === bulan) : semua;

                renderCostCenter2(terpilih, (rtData.cc2 && rtData.cc2.catatan) || '');
                rcAktifkanUrutSemua('rtPaneCc2');

                const totNet = terpilih.reduce((s, r) => s + Number(r.netClaimed || 0), 0);
                const totGross = terpilih.reduce((s, r) => s + Number(r.grossClaimed || 0), 0);
                document.getElementById('rtCc2Ringkas').innerText =
                    terpilih.length + ' baris \u00b7 Net Claimed ' + rcNominalRingkas(totNet)
                    + ' \u00b7 Gross Claimed ' + rcNominalRingkas(totGross)
                    + (bulan ? '' : ' (seluruh bulan)');

                // Tren memakai SELURUH bulan, bukan hanya yang terpilih: sebuah tren yang hanya
                // memuat satu titik tidak menjelaskan apa pun.
                const perBulan = {};
                semua.forEach(function (r) {
                    if (!perBulan[r.bulan]) perBulan[r.bulan] = { label: r.namaBulan, net: 0, gross: 0 };
                    perBulan[r.bulan].net += Number(r.netClaimed || 0);
                    perBulan[r.bulan].gross += Number(r.grossClaimed || 0);
                });
                const kunci = Object.keys(perBulan).sort();
                rtGambarChart('rtChartCc2Tren', {
                    type: 'bar',
                    data: { labels: kunci.map(k => perBulan[k].label), datasets: [
                        { label: 'Net Claimed', data: kunci.map(k => perBulan[k].net), backgroundColor: '#22c55e', borderRadius: 4 },
                        { label: 'Gross Claimed', data: kunci.map(k => perBulan[k].gross), backgroundColor: '#10b981', borderRadius: 4 }
                    ] },
                    options: { responsive: true, maintainAspectRatio: false,
                        scales: { y: { ticks: { callback: v => rcNominal(v) } } },
                        plugins: { tooltip: { callbacks: { label: c => c.dataset.label + ': ' + rcNominalPenuh(c.raw) } } } }
                });

                const perCamp = {};
                const namaCamp2 = {};
                terpilih.forEach(function (r) {
                    if (r.kodeCampaign) namaCamp2[r.kodeCampaign] = r.namaCampaign || r.campaignName || '';
                    perCamp[r.kodeCampaign] = (perCamp[r.kodeCampaign] || 0) + Number(r.netClaimed || 0);
                });
                const urut = Object.keys(perCamp).map(k => ({ k: k, v: perCamp[k] }))
                    .sort((a, b) => b.v - a.v).slice(0, 12);
                rtGambarChart('rtChartCc2Camp', {
                    type: 'bar',
                    data: { labels: urut.map(x => x.k), datasets: [{ label: 'Net Claimed',
                        data: urut.map(x => x.v), backgroundColor: '#2563eb', borderRadius: 4 }] },
                    options: { indexAxis: 'y', responsive: true, maintainAspectRatio: false,
                        scales: { x: { ticks: { callback: v => rcNominal(v) } } },
                        plugins: { legend: { display: false },
                            tooltip: { callbacks: {
                                title: c => rtJudulCampaign(c[0].label, namaCamp2),
                                label: c => rcNominalPenuh(c.raw) } } } }
                });
            }

            // ---- Tab, filter dan ekspor -----------------------------------------------------
            // Ikut bersama karena bilah tab dan bilah filternya pun bersama. Yang TIDAK ada di
            // sini adalah loadReport(): dari mana datanya datang berbeda di kedua halaman -
            // portal memanggil satu RPC per tab dengan hak akses pemakainya, halaman publik
            // memanggil satu RPC untuk ketiganya. Masing-masing halaman menyediakannya sendiri,
            // dan itulah satu-satunya sambungan yang boleh berbeda.

            let rtTabAktif = 'dashboard';

            function switchReportTab(tab) {
                if(typeof rcEnterTab==='function'&&!rcEnterTab('report',tab))return;
                rtTabAktif = tab;
                // 'email' tidak lagi di sini: tab Email Otomatis pindah ke Access Management.
                ['dashboard', 'cc1', 'cc2'].forEach(t => {
                    const nama = t.charAt(0).toUpperCase() + t.slice(1);
                    const pane = document.getElementById('rtPane' + nama);
                    const btn = document.getElementById('rtTab' + nama);
                    if (pane) pane.classList.toggle('hidden', t !== tab);
                    if (btn) {
                        btn.classList.toggle('border-blue-600', t === tab);
                        btn.classList.toggle('text-blue-600', t === tab);
                        btn.classList.toggle('border-transparent', t !== tab);
                        btn.classList.toggle('text-gray-500', t !== tab);
                    }
                });
                setHiddenSafely('rtFilterBar', false);
                loadReport();
            }

            // Pilihan filter diturunkan dari data yang BENAR-BENAR ada pada laporan, bukan
            // dari master. Master memuat 52 depot dan 100 campaign, sedangkan claim hanya
            // menyentuh sebagian kecilnya; menawarkan pilihan yang pasti menghasilkan tabel
            // kosong hanya membuang waktu pembacanya. Pilihan yang sedang aktif selalu
            // dipertahankan walau tidak ada lagi di data, supaya filter tidak melompat sendiri.
            function rtIsiFilterDariData(res) {
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

                isi('rtRegion', [...new Set((res.region || [])
                        .map(r => r.region).filter(r => r && r !== '(belum diisi)'))]
                        .map(r => ({ v: r, t: r })), 'Semua Region');
                isi('rtDepot', (res.depot || [])
                        .map(d => ({ v: d.kodeDepot, t: d.kodeDepot + ' - ' + d.namaDepot })), 'Semua Depot');
                isi('rtCampaign', (res.campaign || [])
                        .map(c => ({ v: c.kodeCampaign, t: c.kodeCampaign + ' - ' + (c.namaCampaign || '') })), 'Semua Campaign');
                // Daftar tahun datang dari server dan TIDAK menyusut ketika tahun sedang dipilih,
                // sehingga selalu ada jalan kembali ke tahun lain.
                const elTahun = document.getElementById('rtTahunCampaign');
                if (elTahun) {
                    const terpilih = elTahun.value;
                    const tahun = (res.tahunTersedia || []).map(y => String(y));
                    elTahun.innerHTML = '<option value="">Semua Tahun</option>'
                        + tahun.map(y => '<option value="' + rcEsc(y) + '">' + rcEsc(y) + '</option>').join('');
                    elTahun.value = tahun.indexOf(terpilih) >= 0 ? terpilih : '';
                }
            }

            // Nilai kosong sengaja tetap dikirim sebagai string kosong: server memperlakukan
            // kosong sebagai "tanpa penyaring", dan menghilangkan kuncinya justru membuat
            // perilakunya bergantung pada bentuk payload, bukan pada isinya.
            function filterReport() {
                return {
                    region: document.getElementById('rtRegion').value,
                    depot: document.getElementById('rtDepot').value,
                    campaign: document.getElementById('rtCampaign').value,
                    tahunCampaign: rtNilai('rtTahunCampaign'),
                    billingStart: rtNilai('rtBillingStart'),
                    billingEnd: rtNilai('rtBillingEnd')
                };
            }

            // Penyaring baru ditambahkan pada panel BERSAMA, jadi ia ada di portal maupun di
            // halaman publik. Pembacaannya menoleransi elemen yang tidak ada supaya panel ini
            // tetap dapat dipasang di tempat yang belum memuat ketiganya.
            function rtNilai(id) {
                const el = document.getElementById(id);
                return el ? String(el.value || '').trim() : '';
            }

            function rtKosongkanFilter() {
                ['rtRegion', 'rtDepot', 'rtCampaign', 'rtTahunCampaign',
                 'rtBillingStart', 'rtBillingEnd'].forEach(function (id) {
                    const el = document.getElementById(id);
                    if (el) el.value = '';
                });
                loadReport();
            }

            // Ekspor Excel memuat SELURUH angka pada modul Report, bukan hanya tab yang
            // sedang terbuka.
            //
            // Sebelumnya yang terekspor hanya satu tabel - Performa per Campaign, Cost Center 1,
            // atau Cost Center 2, tergantung tab yang aktif - sehingga KPI, tren bulanan, sebaran
            // status, aging, per Region dan per Depot tidak pernah ikut. Pemilik menemukannya:
            // "untuk report semuanya bisa di excel kan yang berupa angka saya cek hanya beberapa
            // aja".
            //
            // Setiap bagian menjadi satu sheet. Bagian yang kosong dilewati, bukan menghasilkan
            // sheet kosong yang membuat orang mengira datanya hilang.
            // Elemen ketiga: judul kolom khusus lembar itu, karena istilah di layar berbeda per
            // tabel - netClaimed tampil sebagai "Done" di tabel Region, Depot dan Campaign, tetapi
            // "Net Claimed" di Cost Center.
            const RT_SHEET = [
                ['KPI',                  (d) => rtKpiBaris(d.dashboard)],
                ['Tren Bulanan',         (d) => (d.dashboard && d.dashboard.trenBulanan) || []],
                // Mengikuti cara baca yang sedang tampil (By Pending Group / By Stage), bukan
                // status mentah, supaya berkasnya sama dengan grafik di layar.
                ['Sebaran Status',       (d) => d.dashboard ? rtBarisStatus().map(b => ({ status: b.status, qty: b.qty, nilai: b.nilai })) : [],
                                         { qty: 'Dokumen' }],
                ['Aging',                (d) => (d.dashboard && d.dashboard.aging) || [], { qty: 'Dokumen' }],
                ['Per Region',           (d) => (d.dashboard && d.dashboard.region) || [],
                                         { netClaimed: 'Done', outstandingValue: 'Outstanding', clearingRate: 'Clearing' }],
                ['Per Depot',            (d) => (d.dashboard && d.dashboard.depot) || [],
                                         { netClaimed: 'Done', outstandingQty: 'Outstanding (dok)', outstandingValue: 'Outstanding', clearingRate: 'Clearing' }],
                ['Performa per Campaign',(d) => (d.dashboard && d.dashboard.campaign) || [], { netClaimed: 'Done' }],
                ['Cost Center 1',        (d) => (d.cc1 && d.cc1.rows) || [], { qty: 'Qty', clearingRate: 'Clearing' }],
                ['Cost Center 2',        (d) => (d.cc2 && d.cc2.rows) || [], { qty: 'Qty', clearingRate: 'Clearing' }]
            ];

            // Judul kolom berkas memakai istilah yang sama dengan tabel di layar, bukan nama
            // kunci data. Kunci yang tidak terdaftar di sini tetap ditulis apa adanya.
            const RT_JUDUL_KOLOM = {
                kodeDepot: 'Kode Depot', namaDepot: 'Nama Depot', region: 'Region',
                kodeCampaign: 'Kode Campaign', namaCampaign: 'Nama Campaign',
                qty: 'Klaim', netCb: 'Net CB', netClaimed: 'Net Claimed', grossClaimed: 'Gross Claimed',
                cbExpired: 'CB Expired', outstandingQty: 'Outstanding', outstandingValue: 'Outstanding Amt',
                outstandingRate: 'Outstanding %', clearingRate: 'Clearing Rate',
                bulan: 'Periode', label: 'Bulan', namaBulan: 'Bulan', nilai: 'Nilai',
                kelompok: 'Umur', status: 'Status'
            };

            const RT_URUT_KOLOM = ['Keterangan', 'Nilai', 'bulan', 'namaBulan', 'label', 'kelompok', 'status',
                'kodeDepot', 'namaDepot', 'region', 'kodeCampaign', 'namaCampaign', 'qty', 'netCb', 'netClaimed',
                'grossClaimed', 'cbExpired', 'outstandingQty', 'outstandingValue', 'outstandingRate', 'clearingRate', 'nilai'];
            function rtUrutKolom(k) { const i = RT_URUT_KOLOM.indexOf(k); return i < 0 ? RT_URUT_KOLOM.length : i; }

            // KPI berupa satu objek, bukan daftar baris. Diubah menjadi pasangan nama-nilai
            // supaya ia dapat dibaca di dalam sheet seperti tabel lainnya.
            function rtKpiBaris(dash) {
                const k = (dash && dash.kpi) || null;
                if (!k) return [];
                const label = {
                    claimQty: 'Total Klaim (dok)', netCb: 'Total Net CB',
                    netClaimed: 'Net Claimed (Done)', qtyDone: 'Qty Done',
                    cbExpired: 'CB Expired', qtyExpired: 'Qty Expired',
                    grossClaimed: 'Gross Claimed', outstandingQty: 'Outstanding (dok)',
                    outstandingValue: 'Outstanding (nilai)', clearingRate: 'Clearing Rate',
                    jumlahDepot: 'Jumlah Depot', jumlahCampaign: 'Jumlah Campaign'
                };
                return Object.keys(k).map(function (key) {
                    return { Keterangan: label[key] || key, Nilai: k[key] };
                });
            }

            // Tab yang belum pernah dibuka belum punya datanya, dan ekspor tidak boleh diam-diam
            // menghilangkan bagian itu - justru kekuranglengkapan seperti itulah yang dikeluhkan.
            // Bagian yang belum ada diminta dulu lewat rtMuatBagian(), yang disediakan
            // masing-masing halaman: portal mengambilnya lewat RPC bertahap, sementara halaman
            // publik sudah memuat ketiganya sejak awal sehingga tidak menyediakannya sama sekali.
            async function rtPastikanLengkap() {
                if (typeof rtMuatBagian !== 'function') return;
                for (const nama of ['dashboard', 'cc1', 'cc2']) {
                    if (!rtData[nama]) {
                        try { await rtMuatBagian(nama); }
                        catch (e) { /* bagian yang gagal diambil dilewati, sisanya tetap diekspor */ }
                    }
                }
            }

            async function downloadReportExcel() {
                await rtPastikanLengkap();
                if (typeof XLSX === 'undefined') {
                    showNotification('Pustaka Excel belum termuat. Muat ulang halaman.', 'error'); return;
                }
                const wb = XLSX.utils.book_new();
                const ikut = [];
                RT_SHEET.forEach(function (s) {
                    const rows = s[1](rtData) || [];
                    if (!rows.length) return;
                    // Urutan kolom mengikuti tabel di layar (pengenal dulu, lalu angka), bukan
                    // urutan kunci di data; kunci yang tidak dikenal menyusul di belakang.
                    const kolom = Object.keys(rows[0]).sort((a, b) => rtUrutKolom(a) - rtUrutKolom(b));
                    const aoa = [kolom.map(k => (s[2] && s[2][k]) || RT_JUDUL_KOLOM[k] || k)].concat(rows.map(function (r) {
                        return kolom.map(function (k) {
                            return /^kode/i.test(k) ? rcSelTeks(r[k]) : rcExportAmount(k, r[k], r);
                        });
                    }));
                    // Nama sheet Excel dibatasi 31 karakter dan tidak boleh memuat : \ / ? * [ ]
                    const nama = s[0].replace(/[:\/?*\[\]]/g, '-').slice(0, 31);
                    XLSX.utils.book_append_sheet(wb, XLSX.utils.aoa_to_sheet(aoa), nama);
                    ikut.push(s[0]);
                });
                if (!ikut.length) { showNotification('Belum ada data untuk diekspor.', 'warning'); return; }
                XLSX.writeFile(wb, 'RC_Report_' + new Date().toISOString().slice(0, 10) + '.xlsx');
                showNotification(ikut.length + ' sheet diekspor: ' + ikut.join(', '), 'success');
            }
