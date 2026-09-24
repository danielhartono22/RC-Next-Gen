            function openMasterDepot() {
                let listContainer = document.getElementById('masterDepotList'); listContainer.innerHTML = '';
                if (!globalDepotList || globalDepotList.length === 0) { showNotification("Tidak ada data master depot yang tersedia untuk akun Anda.", "warning"); return; } 
                if (globalDepotList.length === 1) { let d = globalDepotList[0]; if (d.link) window.open(d.link, '_blank'); else showNotification("Link belum disetting untuk depot ini.", "warning"); return; }
                globalDepotList.forEach(d => {
                    let btn = document.createElement('button'); btn.className = "w-full text-left p-4 bg-gray-50 hover:bg-yellow-50 border border-gray-200 hover:border-yellow-300 rounded-xl transition flex justify-between items-center group shadow-sm";
                    btn.innerHTML = `<span class="font-bold text-gray-700 group-hover:text-yellow-700">${d.kode} - ${d.nama}</span> <i class="fas fa-external-link-alt text-gray-400 group-hover:text-yellow-600"></i>`;
                    btn.onclick = () => { if(d.link) window.open(d.link, '_blank'); else showNotification("Link belum disetting untuk depot ini.", "warning"); };
                    listContainer.appendChild(btn);
                });
                setHiddenSafely('masterDepotModal', false);
            }

            // openProfileEditModal() dan submitProfileUpdate() dihapus.
            //
            // Keduanya menulis dan membaca kolom p_kepala, p_alamat, p_k_sales dan seterusnya -
            // milik modal edit profil depot versi lama yang markup-nya sudah tidak ada sejak
            // profil depot dipindahkan ke Key Master > Depot Master. Yang tersisa hanyalah dua
            // fungsi yang membaca formulir kosong lalu mengirim nilai kosong ke server, dan
            // kartu "AJUKAN PERUBAHAN" yang tidak pernah ditampilkan.
            //
            // Jalur yang berlaku sekarang: Depot Master menyimpan lewat rc_depot_save, dan
            // server yang memutuskan apakah perubahannya langsung berlaku atau masuk antrean
            // Approval Request di Access Management.

            function toggleMultiSelect(id) { document.getElementById(id).classList.toggle("show"); }
            document.addEventListener('click', function (e) { if (!e.target.closest('.relative') && !e.target.closest('nav') && !e.target.closest('header')) { document.querySelectorAll('.multiselect-dropdown.show').forEach(d => { d.classList.remove('show'); }); } });
            function checkMultiSelect(cId) { let c = document.getElementById(cId); if (!c) return ""; let cb = c.querySelectorAll('input[type="checkbox"]:checked'); let v = []; cb.forEach(b => { if (b.value !== 'ALL') v.push(b.value); }); return v.join(', '); }
            function getMultiSelectLabel(cId) { let c = document.getElementById(cId); if (!c) return ""; let cb = c.querySelectorAll('input[type="checkbox"]:checked'); if (cb.length === 0) return "-- Semua --"; let l = []; cb.forEach(b => { if (b.value !== 'ALL') l.push(b.nextElementSibling.innerText); }); return l.length > 1 ? l.length + " Dipilih" : l.join(', '); }
            function toggleAllMultiselect(src, cId) { let c = document.getElementById(cId); if (!c) return; c.querySelectorAll('.single-cb').forEach(b => b.checked = src.checked); let s = src.closest('.relative')?.querySelector('button span'); if (s) s.innerText = getMultiSelectLabel(cId); }
            function buildMultiselectHTML(opts, isAll, cId, fn = "") {
                let h = ''; if (isAll) h += `<label class="flex items-center space-x-3 p-2.5 hover:bg-blue-50 border-b border-gray-100 cursor-pointer transition-colors"><input type="checkbox" value="ALL" onchange="toggleAllMultiselect(this,'${cId}'); ${fn}" class="rounded border-gray-300 w-4 h-4 text-blue-600 focus:ring-blue-500"><span class="font-bold text-gray-800 text-xs">Pilih Semua Opsi</span></label>`;
                opts.forEach(o => { h += `<label class="flex items-center space-x-3 p-2.5 hover:bg-gray-50 cursor-pointer transition-colors"><input type="checkbox" value="${rcEsc(o.value)}" class="single-cb rounded border-gray-300 w-4 h-4 text-blue-600 focus:ring-blue-500" onchange="let s=this.closest('.relative').querySelector('button span'); if(s) s.innerText=getMultiSelectLabel('${cId}'); ${fn}"><span class="text-gray-600 font-medium text-xs whitespace-normal break-words">${rcEsc(o.label)}</span></label>`; }); return h;
            }

            // MASS UPLOAD WEB GRID LOGIC