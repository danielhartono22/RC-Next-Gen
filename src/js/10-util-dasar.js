            const SCRIPT_URL = "https://script.google.com/macros/s/AKfycbyaYkDLi2i3O8Aprc5V80prTbvzrG1IlCQ_xRKCVsclHu_58_-6wjwQtbmjqxVjmYgw/exec";
            let debounceTimer; 
            function debounceSearch(callback, delay = 300) { clearTimeout(debounceTimer); debounceTimer = setTimeout(callback, delay); }
            function triggerFilterCallback(fnKey) {
                if(fnKey === 'release') renderWorkflowTable('release');
                else if(fnKey === 'claim') renderWorkflowTable('claim');
                else if(fnKey === 'clearing') renderWorkflowTable('clearing');
                else if(fnKey === 'hist') renderHistoryTable(true);
                else if(fnKey === 'sum') renderSummary();
            }

            function showActionResult(title, successList, failList, actionType, batchNum = null) {
                document.getElementById('actionResultTitle').innerHTML = `<i class="fas fa-info-circle text-blue-500 mr-2"></i>` + title;
                let isReject = actionType === 'reject';
                let isExpired = actionType === 'expired';
                let successLabel = isReject ? 'Berhasil Ditolak' : (isExpired ? 'Ditandai Expired' : 'Berhasil');
                let successColor = isReject ? 'text-red-700' : (isExpired ? 'text-gray-700' : 'text-green-700');
                let successBg = isReject ? 'bg-red-50 border-red-200 text-red-600' : (isExpired ? 'bg-gray-100 border-gray-300 text-gray-700' : 'bg-green-50 border-green-200 text-green-600');
                let statsHtml = `<div class="flex-1 ${successBg} p-3 rounded-xl border"><span class="block text-[10px] uppercase font-bold mb-1">${successLabel}</span><span class="text-2xl font-black ${successColor}">${successList.length}</span></div>`;
                if (failList && failList.length > 0) { statsHtml += `<div class="flex-1 bg-gray-50 border border-gray-200 p-3 rounded-xl"><span class="block text-[10px] uppercase font-bold text-gray-600 mb-1">Gagal Diproses</span><span class="text-2xl font-black text-gray-700">${failList.length}</span></div>`; }
                let distinctTokoResult = new Set(successList.map(s => s.kodeToko).filter(Boolean)).size;
                let totalCashbackResult = successList.reduce((sum, s) => sum + (Number(s.reward) || 0), 0);
                let totalGrossUpResult = successList.reduce((sum, s) => sum + (Number(s.grossUp) || 0), 0);
                statsHtml += `<div class="flex-1 bg-purple-50 border border-purple-200 p-3 rounded-xl"><span class="block text-[10px] uppercase font-bold text-purple-700 mb-1">Total Toko</span><span class="text-2xl font-black text-purple-800">${distinctTokoResult}</span></div>`;
                statsHtml += `<div class="flex-1 bg-red-50 border border-red-200 p-3 rounded-xl"><span class="block text-[10px] uppercase font-bold text-red-600 mb-1">Total Cashback</span><span class="text-lg font-black text-red-700">Rp ${Math.trunc(Number(totalCashbackResult)||0).toLocaleString('id-ID')}</span></div>`;
                statsHtml += `<div class="flex-1 bg-orange-50 border border-orange-200 p-3 rounded-xl"><span class="block text-[10px] uppercase font-bold text-orange-600 mb-1">Total CB Gross Up</span><span class="text-lg font-black text-orange-700">Rp ${Math.trunc(Number(totalGrossUpResult)||0).toLocaleString('id-ID')}</span></div>`;
                document.getElementById('actionResultStats').innerHTML = statsHtml;
                let tbody = '';
                successList.forEach(s => { 
                    let rowBgClass = isReject ? 'bg-red-50/30 hover:bg-red-50' : (isExpired ? 'bg-gray-50 hover:bg-gray-100' : 'hover:bg-gray-50');
                    let docColor = isReject ? 'text-red-700' : (isExpired ? 'text-gray-700' : 'text-blue-700');
                    let badgeHtml = isReject ? `<span class="bg-red-100 text-red-800 px-2 py-1 rounded text-[10px] font-bold">Ditolak (Kembali)</span>` : (isExpired ? `<span class="bg-gray-800 text-white px-2 py-1 rounded text-[10px] font-bold">Expired</span>` : `<span class="bg-green-100 text-green-800 px-2 py-1 rounded text-[10px] font-bold">Sukses</span>`);
                    let valHtml = isReject ? `<span class="text-xs text-red-600 font-bold">Batch Prev:<br>${s.prevBatch || '-'}</span>` : `<span class="text-indigo-600 font-black">Rp ${Math.trunc(Number(Number(s.reward||0))||0).toLocaleString('id-ID')}</span>`;
                    tbody += `<tr class="${rowBgClass} transition-colors border-b border-gray-100"><td class="p-3 font-bold ${docColor}">${s.noDoc}</td><td class="p-3 text-xs"><span class="font-bold text-gray-800">${s.kodeCamp||"-"}</span><br><span class="text-gray-500">${s.namaCamp||"-"}</span></td><td class="p-3 text-xs"><span class="font-bold text-gray-800">${s.kodeToko||"-"}</span><br><span class="text-gray-500">${s.namaToko||"-"}</span></td><td class="p-3 text-right border-l border-gray-100">${valHtml}</td><td class="p-3 text-center">${badgeHtml}</td></tr>`; 
                });
                if (failList) failList.forEach(f => { tbody += `<tr class="bg-gray-50/50 hover:bg-gray-100 border-b border-gray-100"><td class="p-3 font-bold text-gray-600">${f.noDoc}</td><td class="p-3 text-xs">-</td><td class="p-3 text-xs font-medium text-gray-800">${f.toko||f.namaToko||"-"}</td><td class="p-3 text-right">-</td><td class="p-3 text-center"><span class="bg-gray-200 text-gray-700 px-2 py-0.5 rounded text-[10px] font-bold shadow-sm">Gagal: ${f.reason}</span></td></tr>`; });
                document.getElementById('actionResultBody').innerHTML = tbody; 
                let batchContainer = document.getElementById('actionBatchContainer');
                if (batchNum && batchNum !== '-' && !isReject) { batchContainer.classList.remove('hidden'); document.getElementById('actionResultBatchNo').innerText = batchNum; } else { batchContainer.classList.add('hidden'); }
                setHiddenSafely('actionResultModal', false);
            }

            function toggleWorkflowDetails(id) { let el = document.getElementById(id); if (el) el.classList.toggle('hidden'); }