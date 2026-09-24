/*
 * Menggandakan backslash pada literal regex yang berada DI DALAM template literal.
 *
 * Sebabnya nyata dan sempat lolos berkali-kali: EXTRA_SCRIPT dan MODULES_SCRIPT adalah
 * template literal, dan di dalamnya `\d` bukan escape yang dikenali JavaScript. Backslash-nya
 * dibuang diam-diam, sehingga /^-?\d+$/ berubah menjadi /^-?d+$/ pada hasil build. Regex itu
 * tetap sah secara sintaksis, tidak menimbulkan error, dan hanya berhenti cocok. Kegagalannya
 * senyap total.
 *
 * Skrip ini memperbaikinya sekali, lalu scripts/check-template-regex.mjs menjaga agar tidak
 * terulang.
 *
 * Jalankan: node scripts/fix-template-regex.mjs
 */
import { readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const FILES = ['scripts/rc-extra-ui.mjs', 'scripts/rc-modules-ui.mjs', 'scripts/rc-signup-ui.mjs'];

const BS = String.fromCharCode(92);
// Kelas karakter regex yang kehilangan maknanya bila backslash-nya hilang.
const CLASSES = ['d', 'w', 's', 'S', 'W', 'D', 'b', '.'];

let total = 0;
for (const rel of FILES) {
  const file = path.join(root, rel);
  let src = await readFile(file, 'utf8');
  const before = src;

  src = src.split('\n').map((line) => {
    // Hanya baris yang memuat literal regex, dan hanya backslash tunggal.
    if (!line.includes('/^') && !line.includes('.test(')) return line;
    let out = '';
    for (let i = 0; i < line.length; i += 1) {
      const ch = line[i];
      const next = line[i + 1];
      if (ch === BS && next !== BS && CLASSES.includes(next)) {
        out += BS + BS + next;
        i += 1;
        total += 1;
      } else if (ch === BS && next === BS) {
        out += BS + BS;
        i += 1;
      } else {
        out += ch;
      }
    }
    return out;
  }).join('\n');

  if (src !== before) {
    await writeFile(file, src, 'utf8');
    console.log(`  diperbaiki: ${rel}`);
  }
}
console.log(total === 0 ? '  Tidak ada backslash yang perlu digandakan.' : `  ${total} backslash digandakan.`);
