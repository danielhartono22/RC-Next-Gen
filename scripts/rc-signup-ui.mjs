/*
 * The sign-up additions to the legacy page, kept in one file so the build can prove exactly
 * what was added to the markup and nothing else.
 *
 * Everything here is new UI the owner asked for on 17 September 2026: a Sign Up entry on the
 * login portal, and the dialog behind it. Classes and structure copy the page's existing
 * dialogs so the result looks like the rest of the application rather than bolted on.
 */

// Sits under the "Masuk ke Portal" button on the login card.
export const SIGNUP_LINK =
  '\n                    <p class="text-center text-sm text-gray-500 mt-5">Belum punya akun? ' +
  '<button type="button" onclick="openSignupModal()" class="font-bold text-red-600 hover:text-red-700 hover:underline">Daftar di sini</button></p>';

// Modelled on the Ganti PIN dialog: coloured header, body, action bar.
export const SIGNUP_MODAL = [
  '        <!-- MODAL DAFTAR AKUN BARU -->',
  '        <div id="signupModal" class="hidden fixed inset-0 bg-black/60 backdrop-blur-sm flex items-center justify-center z-[85] p-4">',
  '            <div class="bg-white rounded-2xl shadow-2xl w-full max-w-md overflow-hidden flex flex-col max-h-[92vh]"><div class="bg-red-50 p-6 text-center border-b border-red-100 relative"><button onclick="closeSignupModal()" class="absolute top-4 right-4 text-red-300 hover:text-red-600"><i class="fas fa-times text-xl"></i></button><div class="w-16 h-16 bg-white rounded-full flex items-center justify-center mx-auto mb-3 shadow-sm border border-red-100 text-red-500 text-2xl"><i class="fas fa-user-plus"></i></div><h3 class="font-black text-gray-800 text-xl tracking-tight mt-2">Daftar Akun Baru</h3><p class="text-xs text-gray-500 mt-1">Resource Collection</p></div><div class="p-6 bg-white overflow-auto space-y-4"><div id="signupError" class="hidden bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded text-sm font-bold"><span id="signupErrorText">-</span></div><div id="signupSuccess" class="hidden"><div class="bg-green-50 border-2 border-green-300 rounded-xl p-5 text-center"><div class="w-14 h-14 bg-green-100 rounded-full flex items-center justify-center mx-auto mb-3 text-green-600 text-3xl"><i class="fas fa-check-circle"></i></div><h4 class="font-black text-green-900 text-lg mb-1">Pendaftaran Berhasil</h4><p class="text-sm text-green-800 font-bold mb-3">User ID: <span id="signupDoneUser" class="font-black">-</span></p><p id="signupDoneNote" class="text-xs text-green-800 leading-relaxed">-</p></div></div><div id="signupFields" class="space-y-4"><p class="text-xs text-gray-500 leading-relaxed bg-gray-50 border border-gray-200 rounded-lg p-3">Setelah pendaftaran selesai, akun harus <strong class="text-red-600">disetujui System Manager</strong> sebelum dapat digunakan. Hak akses modul dan depot ditetapkan pada saat persetujuan.</p><div><label class="block text-sm font-medium text-gray-700 mb-1">User ID</label><input type="text" id="signupUserId" class="w-full px-4 py-3 border rounded-lg focus:ring-red-500 focus:border-red-500 bg-gray-50 focus:bg-white transition-all" placeholder="Contoh: DHARTONO"></div><div><label class="block text-sm font-medium text-gray-700 mb-1">Nama Lengkap</label><input type="text" id="signupName" class="w-full px-4 py-3 border rounded-lg focus:ring-red-500 focus:border-red-500 bg-gray-50 focus:bg-white transition-all" placeholder="Nama sesuai data karyawan"></div><div><label class="block text-sm font-medium text-gray-700 mb-1">Email Kantor</label><input type="email" id="signupEmail" class="w-full px-4 py-3 border rounded-lg focus:ring-red-500 focus:border-red-500 bg-gray-50 focus:bg-white transition-all" placeholder="nama@bi-nipponpaint.com"></div><div><label class="block text-sm font-medium text-gray-700 mb-1">Depot</label><select id="signupDepot" class="w-full px-4 py-3 border rounded-lg focus:ring-red-500 focus:border-red-500 bg-gray-50 focus:bg-white transition-all"><option value="">Memuat daftar depot...</option></select></div><div><label class="block text-sm font-medium text-gray-700 mb-1">Role yang Diminta</label><select id="signupRole" class="w-full px-4 py-3 border rounded-lg focus:ring-red-500 focus:border-red-500 bg-gray-50 focus:bg-white transition-all"><option value="admin">Admin Depot</option><option value="osc">OSC</option><option value="non-osc">Non-OSC</option><option value="finance">Finance</option><option value="supervisor">Supervisor</option><option value="system manager">System Manager</option></select></div><div><label class="block text-sm font-medium text-gray-700 mb-1">PIN Rahasia <span class="text-gray-400 font-normal">(minimal 8 karakter)</span></label><input type="password" id="signupPin" class="w-full px-4 py-3 border rounded-lg focus:ring-red-500 focus:border-red-500 bg-gray-50 focus:bg-white transition-all" placeholder="••••••••"></div><div><label class="block text-sm font-medium text-gray-700 mb-1">Ulangi PIN</label><input type="password" id="signupPin2" class="w-full px-4 py-3 border rounded-lg focus:ring-red-500 focus:border-red-500 bg-gray-50 focus:bg-white transition-all" placeholder="••••••••"></div></div></div><div class="p-4 bg-gray-50 border-t flex gap-3"><button onclick="closeSignupModal()" class="flex-1 py-2.5 bg-white border border-gray-300 text-gray-700 font-bold rounded-xl hover:bg-gray-100 transition">Tutup</button><button onclick="submitSignup()" id="btnSignup" class="flex-1 py-2.5 bg-red-600 hover:bg-red-700 text-white font-bold rounded-xl shadow-md transition flex justify-center items-center disabled:bg-red-400"><span id="btnSignupText">Daftar</span><div id="signupLoader" class="loader hidden ml-2 w-4 h-4 border-t-white border-2"></div></button></div></div>',
  '        </div>',
  ''
].join('\n');

// Added to the page's inline script. Uses the helpers the page already defines
// (setHiddenSafely, setDisabledSafely, fetchApp) so it behaves like the rest of the page.
export const SIGNUP_SCRIPT = `
            // Depot tidak boleh diketik bebas: kodenya harus ada di master depot, dan server
            // menolak apa pun di luar daftar ini. Daftar dimuat sekali lalu dipakai ulang.
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
            // akses apa pun sampai System Manager menyetujui lewat menu Kelola Akses.
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
`;
