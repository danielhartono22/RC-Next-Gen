"""Menulis Template Muat Ulang Data RC dari definisi kolom milik scripts/muat-ulang-data.mjs.

Dipanggil oleh `node scripts/muat-ulang-data.mjs --buat-template <berkas.xlsx>`, yang mengirim
definisi kolom lewat stdin, sehingga daftar kolom hanya ditulis di satu tempat.

openpyxl dipakai (bukan SheetJS) karena dua hal yang tidak dapat dibuat SheetJS edisi gratis:
format Text per KOLOM - berlaku juga untuk sel yang baru diketik, jadi nol di depan No Rekening
dan nomor batch tidak hilang - dan daftar pilihan (dropdown) untuk Status, Jenis CB dan Subyek
Pajak.
"""
import gc
import io
import json
import os
import sys
import tempfile
import time

from openpyxl import Workbook
from openpyxl.styles import Alignment, Font, PatternFill
from openpyxl.utils import get_column_letter
from openpyxl.cell.cell import ILLEGAL_CHARACTERS_RE
from openpyxl.worksheet.datavalidation import DataValidation

BARIS_PILIHAN = 20000
WAJIB = PatternFill('solid', fgColor='F8D7DA')
OPSIONAL = PatternFill('solid', fgColor='E9ECEF')
JUDUL = PatternFill('solid', fgColor='B91C1C')


def main():
    keluar = sys.argv[1]
    # Selalu UTF-8: di Windows sys.stdin memakai kodepage lokal dan merusak huruf non-ASCII.
    masukan = json.loads(sys.stdin.buffer.read().decode('utf-8'))
    # Bentuk template kosong: daftar definisi. Bentuk ekspor: {definisi, data: {lembar: [[nilai...]]}}.
    definisi = masukan['definisi'] if isinstance(masukan, dict) else masukan
    data = masukan.get('data', {}) if isinstance(masukan, dict) else {}
    wb = Workbook()

    p = wb.active
    p.title = 'Petunjuk'
    p['A1'] = 'TEMPLATE MUAT ULANG DATA RC NEXT GEN'
    p['A1'].font = Font(bold=True, size=14, color='B91C1C')
    p['A2'] = ('Isi lembar Campaign, Customer dan Klaim (wajib) serta Depot (opsional). Baris 1 tiap lembar '
               '= judul kolom, jangan diubah atau dipindah. Data mulai baris 2. Kolom bertanda merah wajib.')
    p['A3'] = ('Lembar Petunjuk ini diabaikan saat dimuat. Tanggal: ketik dd-mm-yyyy (mis. 15-04-2026) - '
               'kolom tanggal sudah berformat Text. Garis miring (15/04/2026) DITOLAK.')
    p['A4'] = 'Cara memeriksa dan memuat: docs/muat-ulang-data-prod.md'
    kepala = ['Lembar', 'Kolom', 'Wajib', 'Contoh', 'Keterangan']
    for c, v in enumerate(kepala, 1):
        sel = p.cell(row=6, column=c, value=v)
        sel.font = Font(bold=True, color='FFFFFF')
        sel.fill = JUDUL
    r = 7
    for lembar in definisi:
        p.cell(row=r, column=1, value=lembar['nama']).font = Font(bold=True)
        p.cell(row=r, column=2, value='(seluruh lembar)')
        p.cell(row=r, column=3, value='opsional' if lembar['opsional'] else 'wajib')
        p.cell(row=r, column=5, value=lembar['keterangan'])
        r += 1
        for k in lembar['kolom']:
            p.cell(row=r, column=1, value=lembar['nama'])
            p.cell(row=r, column=2, value=k['nama'])
            p.cell(row=r, column=3, value='ya' if k['wajib'] else '')
            p.cell(row=r, column=4, value=k['contoh'])
            p.cell(row=r, column=5, value=k['keterangan'])
            r += 1
        r += 1
    for kolom, lebar in zip('ABCDE', (12, 24, 9, 26, 110)):
        p.column_dimensions[kolom].width = lebar
    for baris in p.iter_rows(min_row=7, max_row=r):
        for sel in baris:
            sel.alignment = Alignment(wrap_text=True, vertical='top')

    for lembar in definisi:
        ws = wb.create_sheet(lembar['nama'])
        for c, k in enumerate(lembar['kolom'], 1):
            huruf = get_column_letter(c)
            sel = ws.cell(row=1, column=c, value=k['nama'])
            sel.font = Font(bold=True)
            sel.fill = WAJIB if k['wajib'] else OPSIONAL
            sel.alignment = Alignment(wrap_text=True, vertical='center')
            ws.column_dimensions[huruf].width = max(14, len(k['nama']) + 4)
            if k['teks']:
                ws.column_dimensions[huruf].number_format = '@'
            if k.get('pilihan'):
                dv = DataValidation(type='list', formula1='"' + ','.join(k['pilihan']) + '"', allow_blank=True,
                                    showErrorMessage=True, errorTitle=k['nama'],
                                    error='Pilih salah satu: ' + ', '.join(k['pilihan']))
                ws.add_data_validation(dv)
                dv.add(f'{huruf}2:{huruf}{BARIS_PILIHAN}')
        for i, baris in enumerate(data.get(lembar['nama'], []), 2):
            for c, (k, v) in enumerate(zip(lembar['kolom'], baris), 1):
                if v is None or v == '':
                    continue
                if isinstance(v, str) or k['teks']:
                    # Karakter kontrol tidak sah di XML Excel; dibuang, bukan membatalkan ekspor.
                    v = ILLEGAL_CHARACTERS_RE.sub('', str(v))
                ws.cell(row=i, column=c, value=v)
        ws.freeze_panes = 'A2'
        ws.row_dimensions[1].height = 30

    # Excel temuan (--temuan-xlsx) hanya memuat lembar data, tanpa petunjuk template.
    if isinstance(masukan, dict) and masukan.get('tanpaPetunjuk'):
        wb.remove(p)

    # openpyxl menulis tiap lembar ke berkas temp lalu menghapusnya. Di Windows, pemindai antivirus
    # kadang masih memegang berkas itu sehingga penghapusan gagal (WinError 32). Folder temp
    # dipindah ke .runtime/tmp proyek, hasilnya dirakit di memori, dan dicoba sekali lagi.
    for coba in (1, 2, 3):
        try:
            buf = io.BytesIO()
            wb.save(buf)
            with open(keluar, 'wb') as f:
                f.write(buf.getvalue())
            return
        except PermissionError:
            if coba == 3:
                raise
            gc.collect()
            time.sleep(2)


if __name__ == '__main__':
    tmp = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), '.runtime', 'tmp')
    os.makedirs(tmp, exist_ok=True)
    tempfile.tempdir = tmp
    main()
