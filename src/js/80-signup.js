            let rcSignupDepots = null;
            async function loadSignupDepots() {
                let sel = document.getElementById('signupDepot');
                if (!sel) return;
                if (rcSignupDepots) return;
                try {
                    let res = await fetchApp({ action: 'publicDepots' });
                    rcSignupDepots = (res && res.status === 'success') ? (res.rows || []) : [];
                } catch (e) { rcSignupDepots = []; }
                sel.innerHTML = '<option value="">-- Pilih Depot --</option>';
                rcSignupDepots.forEach(d => {
                    let o = document.createElement('option');
                    o.value = d.kode; o.textContent = d.kode + ' - ' + d.nama;
                    sel.appendChild(o);
                });
                if (rcSignupDepots.length === 0) {
                    sel.innerHTML = '<option value="">Daftar depot tidak tersedia</option>';
                }
            }

            function openSignupModal() {
                ['signupUserId','signupName','signupEmail','signupPin','signupPin2'].forEach(id => { let el = document.getElementById(id); if (el) el.value = ''; });
                let dep = document.getElementById('signupDepot'); if (dep) dep.value = '';
                loadSignupDepots();
                setHiddenSafely('signupError', true); setHiddenSafely('signupSuccess', true); setHiddenSafely('signupFields', false);
                setDisabledSafely('btnSignup', false);
                setHiddenSafely('signupModal', false);
            }
            function closeSignupModal() { setHiddenSafely('signupModal', true); }

            // Pendaftaran mandiri. Akun dibuat berstatus Pending dan belum memperoleh hak
            // akses apa pun sampai System Manager menyetujui lewat menu Access Management.
            async function submitSignup() {
                let errEl = document.getElementById('signupErrorText');
                let show = msg => { errEl.innerText = msg; setHiddenSafely('signupError', false); };
                let data = {
                    userId: document.getElementById('signupUserId').value.trim(),
                    fullName: document.getElementById('signupName').value.trim(),
                    email: document.getElementById('signupEmail').value.trim(),
                    depot: document.getElementById('signupDepot').value.trim(),
                    role: document.getElementById('signupRole').value,
                    pin: document.getElementById('signupPin').value,
                    pinConfirm: document.getElementById('signupPin2').value
                };
                setHiddenSafely('signupError', true);
                if (!data.userId || !data.fullName || !data.email) { show("User ID, nama lengkap dan email kantor wajib diisi."); return; }
                if (!data.depot) { show("Pilih depot dari daftar."); return; }
                if (data.pin.length < 8) { show("PIN minimal 8 karakter."); return; }
                if (data.pin !== data.pinConfirm) { show("Konfirmasi PIN tidak sama."); return; }

                setDisabledSafely('btnSignup', true); setHiddenSafely('signupLoader', false);
                document.getElementById('btnSignupText').innerText = "Mendaftarkan...";
                try {
                    let res = await fetchApp({ action: 'signUp', data: data });
                    if (res.status === 'success') {
                        document.getElementById('signupDoneUser').innerText = data.userId.toUpperCase();
                        document.getElementById('signupDoneNote').innerText = res.message ||
                            "Akun Anda menunggu persetujuan System Manager sebelum dapat digunakan.";
                        setHiddenSafely('signupFields', true); setHiddenSafely('signupSuccess', false);
                        setDisabledSafely('btnSignup', true);
                        document.getElementById('btnSignupText').innerText = "Selesai";
                    } else { show(res.message || "Pendaftaran gagal."); setDisabledSafely('btnSignup', false); }
                } catch (e) { show("Terjadi kesalahan jaringan saat mendaftar."); setDisabledSafely('btnSignup', false); }
                finally { setHiddenSafely('signupLoader', true); document.getElementById('btnSignupText').innerText = "Daftar"; }
            }

            // ===================== TAB OPEN, MATRIKS AKSES, COMPILE UPLOAD =================