# home-dashboard

Marc de fotos Android (Xoro CPF 10PF, Allwinner A133) convertit en dashboard familiar. Treballem des de WSL2.
Basat en <https://github.com/wesbos/photo-frame-dashboard> (clon a `~/photo-frame-dashboard`).

Regla: res d'escriptura al dispositiu fins tenir un backup verificat. `backups/`, `diagnostics/` i `frames/` són privats i ignorats per git.

## Fase 1 (només lectura)

1. [Configurar WSL i veure el marc per USB](docs/wsl-setup.md)
2. Comprovar la cadena USB i identificar el dispositiu:
   ```bash
   scripts/wsl-usb-check.sh
   scripts/identify.sh
   ```
3. Fer el backup (detalls, verificació i limitacions a [docs/backup.md](docs/backup.md)):
   ```bash
   scripts/backup.sh               # tot excepte /data: boot0/1, capçalera i cua del disc, particions
   scripts/backup.sh --with-data   # afegeix /data (UDISK és còpia en calent) i media_data
   scripts/verify-backup.sh backups/<carpeta>
   ```

## Backup, en resum

- Una sola ordre desa en una carpeta nova `backups/<data-hora>/` totes les peces, cada una com a `.img.gz` + `.sha256`.
- Es compara el hash del flux amb el calculat al propi marc; si no coincideix, el script s'atura.
- `/data` (UDISK) canvia mentre es llegeix: es desa en una sola passada, marcada amb una `.NOTE.txt` com a còpia en calent, íntegra però sense consistència de f2fs garantida.
- `verify-backup.sh` rellegeix els fitxers i en comprova hash, mida i que no hi hagi filler `0xCC`.
- Si `adb devices` es penja a WSL, vegeu [docs/wsl-setup.md](docs/wsl-setup.md).

## Docs

- [docs/wsl-setup.md](docs/wsl-setup.md): instal·lar eines i compartir el marc amb WSL (usbipd).
- [docs/backup.md](docs/backup.md): procediment, què cobreix el backup i què no, i com verificar-lo.
- [docs/xoro-cpf10pf.md](docs/xoro-cpf10pf.md): notes del nostre exemplar.
