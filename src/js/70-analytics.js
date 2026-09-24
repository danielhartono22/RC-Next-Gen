            async function fetchDashboardData() {
                showLoadingOverlay("Mengkalkulasi Analitik & Historikal...");
                try {
                    let role = currentUserData.sysRole || currentUserData.role || '';
                    let res = await fetchApp({ action: 'getDashboardData', requesterId: currentUserData.userId, requesterRole: role, managedDepots: currentUserData.managedDepots });
                    if (res.status === 'success') { globalHistoryData = res.history || []; globalHistoryData.forEach(d => d.status = normalizeClaimStatus(d.status)); globalCompileData = res.compileData || []; populateDashFilters(); renderHistoryTable(true); renderSummary(); }
                    else throw new Error(res.message || "Unidentified Server Error");
                } catch (e) { showNotification(e.message || "Gagal memuat data dashboard.", "error"); renderHistoryTable(true); renderSummary(); } finally { hideLoadingOverlay(); }
            }

            function populateDashFilters() {
                let o = new Set(), d = new Set(), c = new Set(), y = new Set();
                globalHistoryData.forEach(x => { x.validYear = x.validYear || getValidYear(x.codeCampaign); if (x.osc) o.add(x.osc); if (x.depot) d.add(x.depot); if (x.codeCampaign) c.add(x.codeCampaign + " - " + x.campaign); y.add(x.validYear); });
                globalCompileData.forEach(x => { x.validYear = x.validYear || getValidYear(x.codeCampaign); if (x.depotName) d.add(x.depotName); if (x.codeCampaign) c.add(x.codeCampaign + " - " + x.campaign); y.add(x.validYear); });
                let oO = Array.from(o).map(x => ({ label: x, value: x })); let dO = Array.from(d).map(x => ({ label: x, value: x })); let cO = Array.from(c).map(x => ({ label: x, value: x })); let yO = Array.from(y).sort((a, b) => b - a).map(x => ({ label: x, value: x }));
                ['hist', 'sum'].forEach(p => {
                    let fn = p === 'hist' ? 'renderHistoryTable(true)' : 'renderSummary()';
                    if (document.getElementById(p + 'OscDropdown')) document.getElementById(p + 'OscDropdown').innerHTML = buildMultiselectHTML(oO, true, p + 'OscDropdown', fn);
                    if (document.getElementById(p + 'DepotDropdown')) document.getElementById(p + 'DepotDropdown').innerHTML = buildMultiselectHTML(dO, true, p + 'DepotDropdown', fn);
                    if (document.getElementById(p + 'CampDropdown')) document.getElementById(p + 'CampDropdown').innerHTML = buildMultiselectHTML(cO, true, p + 'CampDropdown', fn);
                    if (p === 'sum' && document.getElementById('sumYearDropdown')) document.getElementById('sumYearDropdown').innerHTML = buildMultiselectHTML(yO, true, 'sumYearDropdown', fn);
                    // Wadah filter Depot dan OSC selama ini selalu hidden di markup dan tidak
                    // pernah ada yang membukanya, sehingga kedua filter itu terisi lengkap
                    // namun tidak terlihat sama sekali. Sekarang dibuka bagi pengguna yang
                    // datanya memang mencakup lebih dari satu depot - yaitu OSC ke atas dan
                    // pengguna yang di-tagging ke depot lain, persis permintaan pemilik.
                    setHiddenSafely(p + 'FilterDepotContainer', dO.length < 2);
                    setHiddenSafely(p + 'FilterOscContainer', oO.length < 2);
                });
            }

            function toggleRowDetails(id) { let el = document.getElementById(id); if (el) el.classList.toggle('hidden'); }

            function renderHistoryTable(resetPage = false) {
                if (resetPage) histCurrentPage = 1;
                let sv = (document.getElementById('histSearch')?.value || "").toLowerCase();
                let stat = document.getElementById('histFilterStatus').value; let so = checkMultiSelect('histOscDropdown') ? checkMultiSelect('histOscDropdown').split(', ') : []; let sd = checkMultiSelect('histDepotDropdown') ? checkMultiSelect('histDepotDropdown').split(', ') : []; let sc = checkMultiSelect('histCampDropdown') ? checkMultiSelect('histCampDropdown').split(', ') : [];
                
                let filtered = globalHistoryData.filter(d => {
                    let matchSearch = !sv || Object.values(d).some(val => val !== null && String(val).toLowerCase().includes(sv));
                    // Nilai opsi kini persis sama dengan status yang dikirim server, jadi tidak perlu lagi
                    // pemetaan khusus. Pemetaan lama menggabungkan Submitted, Released dan Claimed
                    // menjadi satu pilihan "Sedang Diproses", sehingga dua status itu tidak pernah
                    // bisa disaring sendiri-sendiri.
                    let matchStatus = (stat === 'ALL' || d.status === stat);
                    let matchOsc = (so.length === 0 || so.includes(d.osc)); let matchDepot = (sd.length === 0 || sd.includes(d.depot)); let matchCamp = (sc.length === 0 || sc.includes(`${d.codeCampaign} - ${d.campaign}`));
                    return matchSearch && matchStatus && matchOsc && matchDepot && matchCamp;
                });

                let totalItems = filtered.length; let totalPages = Math.ceil(totalItems / histItemsPerPage);
                if (histCurrentPage > totalPages && totalPages > 0) histCurrentPage = totalPages;
                let startIndex = (histCurrentPage - 1) * histItemsPerPage; let paginated = filtered.slice(startIndex, startIndex + histItemsPerPage);
                let tb = document.getElementById('historyTableBody'); let rowsHtml = '';

                paginated.forEach(r => {
                    let bdgColor = rcStatusClass(r.status);
                    let bdg = `<span class="px-2 py-1 ${bdgColor} text-[10px] rounded uppercase font-bold">${r.status}</span>`;
                    const rowIndex=globalHistoryData.indexOf(r);
                    rowsHtml += `<tr class="hover:bg-slate-50 border-b border-gray-100"><td class="p-3 text-xs font-black text-blue-700 rc-wrap">${rcEsc(r.noDoc)}</td><td class="p-3 rc-wrap"><button class="text-blue-600 text-xs" onclick="rcHistoryCustomer(${rowIndex})">${rcEsc(r.kodeToko)}</button></td><td class="p-3 rc-wrap"><button class="font-bold text-sm" onclick="rcHistoryCustomer(${rowIndex})">${rcEsc(r.namaToko)}</button></td><td class="p-3 rc-wrap text-xs">${rcEsc(r.codeCampaign)}</td><td class="p-3 rc-wrap text-sm">${rcEsc(r.campaign)}</td><td class="p-3 text-right font-black text-red-600">${rcMoney(r.totalClaim)}</td><td class="p-3 text-center">${bdg}</td><td class="p-3 rc-time text-xs">${rcHistoryDates(r)}</td><td class="p-3"><button onclick="toggleRowDetails('hist-detail-${rowIndex}')" class="bg-blue-50 text-blue-600 font-bold px-3 py-1.5 rounded-lg text-xs">Details</button></td></tr><tr id="hist-detail-${rowIndex}" class="hidden expanded-details"><td colspan="9" class="p-4 bg-gray-50"><div class="grid grid-cols-1 md:grid-cols-3 gap-3">${rcHistoryDetails(r)}</div></td></tr>`;
                });
                tb.innerHTML = rowsHtml; renderHistoryPagination(totalItems, totalPages);
            }

            function renderHistoryPagination(total, totalPages) {
                let container = document.getElementById('historyPagination'); if (!container) return;
                let start = total === 0 ? 0 : (histCurrentPage - 1) * histItemsPerPage + 1; let end = Math.min(histCurrentPage * histItemsPerPage, total);
                container.innerHTML = `<div class="flex flex-col md:flex-row justify-between items-center text-xs text-gray-600 mt-5 px-3 bg-white p-3 border rounded-xl shadow-sm"><div class="mb-3 md:mb-0 font-medium">Menampilkan <span class="font-black text-gray-800">${start}</span> - <span class="font-black text-gray-800">${end}</span> dari <span class="font-black text-gray-800">${total}</span> Dokumen</div><div class="flex items-center gap-4"><select onchange="histItemsPerPage = parseInt(this.value); renderHistoryTable(true)" class="border border-gray-300 rounded-lg px-3 py-1.5 bg-gray-50 font-bold text-gray-700"><option value="10" ${histItemsPerPage === 10 ? 'selected' : ''}>10 / Halaman</option><option value="25" ${histItemsPerPage === 25 ? 'selected' : ''}>25 / Halaman</option><option value="50" ${histItemsPerPage === 50 ? 'selected' : ''}>50 / Halaman</option></select><nav class="flex rounded-lg shadow-sm overflow-hidden border border-gray-300"><button onclick="changeHistoryPage(${histCurrentPage - 1})" ${histCurrentPage === 1 ? 'disabled' : ''} class="px-4 py-2 bg-white disabled:bg-gray-100 disabled:text-gray-400"><i class="fas fa-chevron-left"></i></button><span class="px-4 py-2 bg-gray-50 border-x border-gray-300 font-black text-gray-700">${histCurrentPage} / ${totalPages > 0 ? totalPages : 1}</span><button onclick="changeHistoryPage(${histCurrentPage + 1})" ${histCurrentPage >= totalPages || totalPages === 0 ? 'disabled' : ''} class="px-4 py-2 bg-white disabled:bg-gray-100 disabled:text-gray-400"><i class="fas fa-chevron-right"></i></button></nav></div></div>`;
            }
            function changeHistoryPage(page) { histCurrentPage = page; renderHistoryTable(false); }

            function renderSummary() {
                let so = checkMultiSelect('sumOscDropdown') ? checkMultiSelect('sumOscDropdown').split(', ') : []; let sd = checkMultiSelect('sumDepotDropdown') ? checkMultiSelect('sumDepotDropdown').split(', ') : []; let sc = checkMultiSelect('sumCampDropdown') ? checkMultiSelect('sumCampDropdown').split(', ') : []; let sy = checkMultiSelect('sumYearDropdown') ? checkMultiSelect('sumYearDropdown').split(', ') : [];
                // Reporting Summary Chart/Executive Summary digrup berdasarkan Master Code (ListCampaign kolom V/W),
                // bukan campaign code individual - supaya campaign turunan dgn Jenis CB berbeda (mis. 202026 &
                // 202026B) diakumulasikan jadi satu baris. Filter Campaign di atas tetap mengecek codeCampaign asli
                // (per baris data), grouping-nya saja yang dipindah ke Master Code supaya tidak ada baris hilang/dobel.
                let sm = {}; let tn = 0, td = 0, tr = 0;
                globalCompileData.filter(c => { return (sd.length === 0 || sd.includes(c.depotName)) && (sc.length === 0 || sc.includes(c.codeCampaign + " - " + c.campaign)) && (sy.length === 0 || sy.includes(c.validYear)); }).forEach(c => { let mc = resolveMasterCode(c.codeCampaign); let k = mc.masterCode; if (!sm[k]) sm[k] = { name: mc.masterCodeName, code: mc.masterCode, r: 0, n: 0, d: 0 }; sm[k].r += Number(c.reward) || 0; });
                globalHistoryData.filter(d => { return (so.length === 0 || so.includes(d.osc)) && (sd.length === 0 || sd.includes(d.depot)) && (sc.length === 0 || sc.includes(d.codeCampaign + " - " + d.campaign)) && (sy.length === 0 || sy.includes(d.validYear)); }).forEach(d => { let mc = resolveMasterCode(d.codeCampaign); let k = mc.masterCode; if (!sm[k]) sm[k] = { name: mc.masterCodeName, code: mc.masterCode, r: 0, n: 0, d: 0 }; let v = Number(d.totalClaim) || 0; if (d.status === 'Done') { sm[k].d += v; td += v; } else if (d.status === 'Submitted') { sm[k].n += v; tn += v; } });
                let tb = document.getElementById('summaryTableBody'); let rowsHtml = '';
                for (let k in sm) {
                    let s = sm[k]; tr += s.r; let sisa = Math.max(0, s.r - s.d - s.n); let pt = s.r > 0 ? ((s.d / s.r) * 100).toFixed(2) + '%' : '0%';
                    rowsHtml += `<tr class="border-b hover:bg-blue-50 transition-colors"><td class="p-3.5 font-bold text-gray-700 text-xs">${s.code}</td><td class="p-3.5 font-bold text-sm text-gray-800 whitespace-normal"><button onclick="showDetailModal('campaign', '${s.code}', '${s.name}')" class="hover:text-blue-600 transition-colors">${s.name}</button></td><td class="p-3.5 text-right font-black text-blue-700 bg-blue-50/30">Rp ${Math.trunc(Number(s.r)||0).toLocaleString('id-ID')}</td><td class="p-3.5 text-right font-bold text-orange-600 bg-orange-50/30">Rp ${Math.trunc(Number(s.n)||0).toLocaleString('id-ID')}</td><td class="p-3.5 text-right font-black text-green-600 bg-green-50/30">Rp ${Math.trunc(Number(s.d)||0).toLocaleString('id-ID')}</td><td class="p-3.5 text-right font-black text-red-600 bg-red-50/30">Rp ${Math.trunc(Number(sisa)||0).toLocaleString('id-ID')}</td><td class="p-3.5 text-center font-black text-purple-700 bg-purple-50/30">${pt}</td></tr>`;
                }
                tb.innerHTML = rowsHtml;
                let totalSisa = Math.max(0, tr - td - tn); let gp = tr > 0 ? ((td / tr) * 100).toFixed(2) + '%' : '0%';
                document.getElementById('summaryTableFoot').innerHTML = `<tr><td colspan="2" class="p-4 text-right uppercase tracking-wider">Total Akumulasi Global</td><td class="p-4 text-right text-blue-800 text-sm">Rp ${Math.trunc(Number(tr)||0).toLocaleString('id-ID')}</td><td class="p-4 text-right text-orange-700 text-sm">Rp ${Math.trunc(Number(tn)||0).toLocaleString('id-ID')}</td><td class="p-4 text-right text-green-700 text-sm">Rp ${Math.trunc(Number(td)||0).toLocaleString('id-ID')}</td><td class="p-4 text-right text-red-700 text-sm">Rp ${Math.trunc(Number(totalSisa)||0).toLocaleString('id-ID')}</td><td class="p-4 text-center text-purple-800 text-sm">${gp}</td></tr>`;
                updatePieChart(tr, tn, td);
            }

            function updatePieChart(tot, ny, dn) {
                let el = document.getElementById('summaryPieChart'); if (!el) return; if (summaryChartInstance) summaryChartInstance.destroy(); let sisaKuota = Math.max(0, tot - dn - ny);
                summaryChartInstance = new Chart(el.getContext('2d'), { type: 'doughnut', data: { labels: ['Sisa Belum Cair', 'Sedang Diajukan', 'Sudah Cair'], datasets: [{ label: 'Nilai (Rp)', data: [sisaKuota, ny, dn], backgroundColor: ['#e2e8f0', '#f97316', '#22c55e'], borderWidth: 2, borderColor: '#fff', hoverOffset: 4 }] }, options: { responsive: true, maintainAspectRatio: false, cutout: '60%', plugins: { legend: { position: 'bottom' }, tooltip: { backgroundColor: 'rgba(0,0,0,0.8)', padding: 10, bodyFont: { size: 12 }, titleFont: { size: 13 }, callbacks: { label: function(context) { let label = context.label || ''; if (context.raw !== null) { let val = context.raw; let datasetTotal = context.chart.data.datasets[context.datasetIndex].data.reduce((a, b) => a + b, 0); let percentage = datasetTotal > 0 ? ((val / datasetTotal) * 100).toFixed(2) + '%' : '0%'; return [label, 'Rp ' + new Intl.NumberFormat('id-ID').format(val), '(' + percentage + ')']; } return label; } } } } } });
            }

            function showDetailModal(type, code, name) {
                let t_reward = 0, t_submitted = 0, t_done = 0; let filtered = []; let rowsHtml = '';
                if (type === 'toko') {
                    // Kode dan nama toko dipisah secara TATA LETAK, bukan diubah datanya: kodenya
                    // menjadi lencana yang tidak ikut melipat, namanya mengalir di sebelahnya dan
                    // boleh turun ke baris berikutnya. Sebelumnya keduanya satu kalimat panjang -
                    // "Toko: 659595 - CV.DUNIA WARNA BARU CABANG ..." - yang terpotong di ujung
                    // kotak dan tidak terbaca utuh.
                    document.getElementById('detailModalSubtitle').innerHTML =
                        '<span class="text-[10px] uppercase text-blue-400 font-black mr-1.5">Toko</span>'
                        + '<span class="font-black text-blue-800 whitespace-nowrap">' + rcEsc(code) + '</span>'
                        + '<span class="text-blue-300 mx-1.5">|</span>'
                        + '<span class="font-bold text-blue-900">' + rcEsc(name) + '</span>';
                    globalHistoryData.filter(d => d.kodeToko === code).forEach(d => { let v = Number(d.totalClaim) || 0; t_reward += v; if (d.status === 'Done') t_done += v; else if (d.status === 'Submitted') t_submitted += v; });
                    filtered = globalHistoryData.filter(d => d.kodeToko === code);
                    filtered.sort((a, b) => { return new Date(b.tglUpload || 0) - new Date(a.tglUpload || 0); });

                    document.getElementById('detailModalHead').innerHTML = `<tr><th class="p-3 text-[10px] font-black text-gray-500 uppercase tracking-wider">No Doc</th><th class="p-3 text-[10px] font-black text-gray-500 uppercase tracking-wider">Campaign</th><th class="p-3 text-[10px] font-black text-gray-500 uppercase tracking-wider text-center">Tgl Pencairan (Clearing)</th><th class="p-3 text-[10px] font-black text-gray-500 uppercase tracking-wider text-right">CB Net</th><th class="p-3 text-[10px] font-black text-gray-500 uppercase tracking-wider text-center">Status</th></tr>`;
                    filtered.forEach(d => {
                        let val = Number(d.totalClaim) || 0; let bdgColor = rcStatusClass(d.status);
                        let bdg = `<span class="px-2 py-1 ${bdgColor} text-[10px] rounded uppercase font-bold">${d.status}</span>`;
                        let tglDisplay = d.status === 'Done' ? (d.tglClearing || '-') : '-';
                        rowsHtml += `<tr class="hover:bg-blue-50 border-b"><td class="p-3 font-semibold">${d.noDoc}</td><td class="p-3 font-bold whitespace-normal">${d.campaign}</td><td class="p-3 text-center text-xs text-green-600 font-bold">${tglDisplay}</td><td class="p-3 text-right font-bold text-red-600">${val.toLocaleString('id-ID')}</td><td class="p-3 text-center">${bdg}</td></tr>`;
                    });
                } else if (type === 'campaign') {
                    // "code" di sini adalah Master Code (dipanggil dari renderSummary/Executive Summary), bukan
                    // codeCampaign individual - jadi filternya lewat resolveMasterCode supaya seluruh campaign
                    // turunan (mis. 202026 & 202026B) dengan Master Code sama ikut masuk ke drill-down ini.
                    document.getElementById('detailModalSubtitle').innerHTML =
                        '<span class="text-[10px] uppercase text-blue-400 font-black mr-1.5">Master Code</span>'
                        + '<span class="font-black text-blue-800 whitespace-nowrap">' + rcEsc(code) + '</span>'
                        + '<span class="text-blue-300 mx-1.5">|</span>'
                        + '<span class="font-bold text-blue-900">' + rcEsc(name) + '</span>';
                    let sy = checkMultiSelect('sumYearDropdown') ? checkMultiSelect('sumYearDropdown').split(', ') : []; let so = checkMultiSelect('sumOscDropdown') ? checkMultiSelect('sumOscDropdown').split(', ') : []; let sd = checkMultiSelect('sumDepotDropdown') ? checkMultiSelect('sumDepotDropdown').split(', ') : [];
                    let depotAgg = {};
                    globalCompileData.filter(c => resolveMasterCode(c.codeCampaign).masterCode === code).filter(c => { return (sd.length === 0 || sd.includes(c.depotName)) && (sy.length === 0 || sy.includes(c.validYear)); }).forEach(c => { if(!depotAgg[c.depotName]) depotAgg[c.depotName] = { reward: 0, submitted: 0, done: 0 }; depotAgg[c.depotName].reward += Number(c.reward) || 0; t_reward += Number(c.reward) || 0; });
                    globalHistoryData.filter(d => resolveMasterCode(d.codeCampaign).masterCode === code).filter(d => { return (so.length === 0 || so.includes(d.osc)) && (sd.length === 0 || sd.includes(d.depot)) && (sy.length === 0 || sy.includes(d.validYear)); }).forEach(d => { if(!depotAgg[d.depot]) depotAgg[d.depot] = { reward: 0, submitted: 0, done: 0 }; let v = Number(d.totalClaim) || 0; if (d.status === 'Done') { depotAgg[d.depot].done += v; t_done += v; } else if (d.status === 'Submitted') { depotAgg[d.depot].submitted += v; t_submitted += v; } });

                    document.getElementById('detailModalHead').innerHTML = `<tr><th class="p-3 text-[10px] font-black text-gray-500 uppercase tracking-wider">Depot</th><th class="p-3 text-[10px] font-black text-gray-500 uppercase tracking-wider text-right">Total CB (Rp)</th><th class="p-3 text-[10px] font-black text-orange-600 uppercase tracking-wider text-right">Pengajuan (Rp)</th><th class="p-3 text-[10px] font-black text-green-600 uppercase tracking-wider text-right">Sudah Cair (Rp)</th><th class="p-3 text-[10px] font-black text-red-600 uppercase tracking-wider text-right">Sisa (Rp)</th><th class="p-3 text-[10px] font-black text-purple-700 uppercase tracking-wider text-center">% Cair</th></tr>`;
                    
                    for(let dep in depotAgg) {
                        let agg = depotAgg[dep]; if(agg.reward === 0 && agg.submitted === 0 && agg.done === 0) continue;
                        let sisa = Math.max(0, agg.reward - agg.done - agg.submitted); let pct = agg.reward > 0 ? ((agg.done / agg.reward)*100).toFixed(2) + '%' : '0%';
                        rowsHtml += `<tr class="hover:bg-blue-50 border-b"><td class="p-3 font-bold text-gray-800">${dep}</td><td class="p-3 text-right font-black text-blue-600">${agg.reward.toLocaleString('id-ID')}</td><td class="p-3 text-right font-bold text-orange-600">${agg.submitted.toLocaleString('id-ID')}</td><td class="p-3 text-right font-bold text-green-600">${agg.done.toLocaleString('id-ID')}</td><td class="p-3 text-right font-bold text-red-600">${sisa.toLocaleString('id-ID')}</td><td class="p-3 text-center font-bold text-purple-700">${pct}</td></tr>`;
                        filtered.push(agg);
                    }
                }

                document.getElementById('detailMetricsDialog').innerHTML = `<div class="flex justify-between items-center text-[10px] w-full"><span class="text-blue-800 font-bold uppercase">Total Reward</span><span class="font-black text-blue-900 bg-blue-100 px-2 rounded tracking-wide text-xs">Rp ${Math.trunc(Number(t_reward)||0).toLocaleString('id-ID')}</span></div><div class="flex justify-between items-center text-[10px] w-full mt-1 border-t border-blue-100 pt-1"><span class="text-gray-500 font-bold uppercase">Sedang Diajukan</span><span class="font-bold text-orange-600 bg-white px-2 rounded shadow-sm text-xs">Rp ${Math.trunc(Number(t_submitted)||0).toLocaleString('id-ID')}</span></div><div class="flex justify-between items-center text-[10px] w-full mt-1 border-t border-blue-100 pt-1"><span class="text-gray-500 font-bold uppercase">Sudah Cair</span><span class="font-bold text-green-600 bg-white px-2 rounded shadow-sm text-xs">Rp ${Math.trunc(Number(t_done)||0).toLocaleString('id-ID')}</span></div>`;
                if (filtered.length === 0) rowsHtml = `<tr><td colspan="8" class="p-4 text-center text-gray-500">Tidak ada data untuk dirender.</td></tr>`;
                document.getElementById('detailModalBody').innerHTML = rowsHtml;

                let el = document.getElementById('detailPieChart');
                if (el) {
                    if (detailChartInstance) detailChartInstance.destroy();
                    let sisaKuota = Math.max(0, t_reward - t_done - t_submitted);
                    detailChartInstance = new Chart(el.getContext('2d'), { type: 'doughnut', data: { labels: ['Sisa Belum Cair', 'Sedang Diajukan', 'Sudah Cair'], datasets: [{ label: 'Nilai (Rp)', data: [sisaKuota, t_submitted, t_done], backgroundColor: ['#e2e8f0', '#f97316', '#22c55e'], borderWidth: 2, borderColor: '#fff', hoverOffset: 4 }] }, options: { responsive: true, maintainAspectRatio: false, cutout: '60%', plugins: { legend: { position: 'bottom' }, tooltip: { backgroundColor: 'rgba(0,0,0,0.8)', padding: 10, bodyFont: { size: 12 }, titleFont: { size: 13 }, callbacks: { label: function(context) { let label = context.label || ''; if (context.raw !== null) { let val = context.raw; let datasetTotal = context.chart.data.datasets[context.datasetIndex].data.reduce((a, b) => a + b, 0); let percentage = datasetTotal > 0 ? ((val / datasetTotal) * 100).toFixed(2) + '%' : '0%'; return [label, 'Rp ' + new Intl.NumberFormat('id-ID').format(val), '(' + percentage + ')']; } return label; } } } } } });
                }
                setHiddenSafely('detailHistoryModal', false);
            }
            function closeDetailModal() {
                // Bila salah satu kartu di dalam modal ini sedang diperbesar, perbesarannya
                // ditutup lebih dulu. Tanpa itu isinya tertinggal di dalam cardExpandModal
                // sementara modal induknya sudah hilang, dan grafiknya tidak pernah kembali
                // ke tempatnya ketika rincian dibuka lagi.
                if (typeof rcExpandAsal !== 'undefined' && rcExpandAsal) rcTutupCardExpand();
                setHiddenSafely('detailHistoryModal', true);
            }

            // Helper umum: ubah elemen <table> (thead/tbody/tfoot) menjadi array-of-arrays teks bersih, untuk diekspor ke Excel.
            function tableElementToAOA(tableEl) {
                let aoa = [];
                if (!tableEl) return aoa;
                tableEl.querySelectorAll('tr').forEach(tr => {
                    let row = [];
                    tr.querySelectorAll('th,td').forEach(cell => { row.push(cell.innerText.replace(/\s+/g, ' ').trim()); });
                    if (row.length) aoa.push(row);
                });
                return aoa;
            }

            // Helper umum: simpan array-of-arrays sebagai file .xlsx menggunakan SheetJS (sudah dimuat untuk fitur Template Upload).
            // Nilai yang polanya seperti angka Rupiah ("Rp 1.234.000" / "1.234.000") atau persen ("24.22%") otomatis
            // ditulis sebagai ANGKA asli (bukan teks) dengan format Accounting tanpa desimal, supaya bisa langsung dihitung di Excel.
            const XLSX_FMT_ACCOUNTING_RP = '_-"Rp"* #,##0_-;-"Rp"* #,##0_-;_-"Rp"* "-"_-;_-@_-';
            const XLSX_FMT_PERCENT = '0.00"%"';

            function classifyCellForExcel(text) {
                let t = (text === null || text === undefined) ? '' : String(text).trim();
                if (t === '' || t === '-') return { v: t, fmt: null };
                let pctMatch = t.match(/^-?\d+(\.\d+)?%$/);
                if (pctMatch) { let num = parseFloat(t.replace('%', '')); if (!isNaN(num)) return { v: num, fmt: XLSX_FMT_PERCENT }; }
                let cleaned = t.replace(/rp/gi, '').trim();
                if (/^-?\d{1,3}(\.\d{3})*$/.test(cleaned)) { let num = parseInt(cleaned.replace(/\./g, ''), 10); if (!isNaN(num)) return { v: num, fmt: XLSX_FMT_ACCOUNTING_RP }; }
                if (/^\d{10,}$/.test(t)) return { v: t, fmt: null, text: true };
                return { v: t, fmt: null };
            }

            function downloadAoaAsExcel(aoa, filename, sheetName) {
                let ws = {}; let maxCol = 0;
                aoa.forEach((row, r) => {
                    (row || []).forEach((cellText, c) => {
                        let cellObj = classifyCellForExcel(cellText);
                        let ref = XLSX.utils.encode_cell({ r: r, c: c });
                        if (typeof cellObj.v === 'number') { ws[ref] = cellObj.fmt ? { t: 'n', v: cellObj.v, z: cellObj.fmt } : { t: 'n', v: cellObj.v }; }
                        else { ws[ref] = cellObj.text ? { t: 's', v: cellObj.v, z: '@' } : { t: 's', v: cellObj.v }; }
                        if (c > maxCol) maxCol = c;
                    });
                });
                ws['!ref'] = XLSX.utils.encode_range({ s: { r: 0, c: 0 }, e: { r: Math.max(aoa.length - 1, 0), c: maxCol } });
                let colWidths = [];
                aoa.forEach(row => { (row || []).forEach((cellText, c) => { let len = String(cellText || '').length; colWidths[c] = Math.min(45, Math.max(colWidths[c] || 10, len + 2)); }); });
                ws['!cols'] = colWidths.map(w => ({ wch: w }));

                const wb = XLSX.utils.book_new();
                XLSX.utils.book_append_sheet(wb, ws, sheetName || 'Sheet1');
                XLSX.writeFile(wb, filename.toLowerCase().endsWith('.xlsx') ? filename : filename + '.xlsx');
            }

            function downloadDetailModalExcel() {
                // Dipakai oleh popup "Catatan Realisasi Detail" baik yang dibuka dari History Data (per Toko)
                // maupun dari Summary Chart (per Campaign) - keduanya memakai modal yang sama (detailHistoryModal).
                let titleEl = document.getElementById('detailModalTitle'); let subEl = document.getElementById('detailModalSubtitle');
                let title = titleEl ? titleEl.innerText.trim() : 'Catatan Realisasi Detail';
                let subtitle = subEl ? subEl.innerText.trim() : '';

                let metricsAoa = [];
                let metricsEl = document.getElementById('detailMetricsDialog');
                if (metricsEl) { metricsEl.querySelectorAll(':scope > div').forEach(row => { let spans = row.querySelectorAll('span'); if (spans.length >= 2) metricsAoa.push([spans[0].innerText.trim(), spans[spans.length - 1].innerText.replace(/\s+/g, ' ').trim()]); }); }

                let tableAoa = [];
                tableAoa = tableAoa.concat(tableElementToAOA(document.getElementById('detailModalHead')));
                tableAoa = tableAoa.concat(tableElementToAOA(document.getElementById('detailModalBody')));

                if (tableAoa.length === 0 && metricsAoa.length === 0) { showNotification("Tidak ada data untuk diunduh.", "warning"); return; }

                let aoa = [[title], [subtitle], []];
                if (metricsAoa.length) { aoa = aoa.concat(metricsAoa); aoa.push([]); }
                aoa = aoa.concat(tableAoa);

                let fname = subtitle.replace(/[^a-zA-Z0-9]+/g, '_').replace(/^_+|_+$/g, '').substring(0, 60) || 'Detail_Realisasi';
                downloadAoaAsExcel(aoa, fname, 'Detail');
                showNotification("File Excel berhasil diunduh.", "success");
            }

            function downloadSummaryTableExcel() {
                // Mengekspor tabel Executive Summary (Summary Chart) sesuai filter yang sedang aktif di layar.
                let wrap = document.getElementById('summaryTableWrap');
                let table = wrap ? wrap.querySelector('table') : null;
                if (!table || !document.getElementById('summaryTableBody') || document.getElementById('summaryTableBody').children.length === 0) { showNotification("Tidak ada data summary untuk diunduh.", "warning"); return; }
                let aoa = tableElementToAOA(table);
                downloadAoaAsExcel(aoa, 'Executive_Summary_Campaign', 'Summary');
                showNotification("File Excel berhasil diunduh.", "success");
            }

